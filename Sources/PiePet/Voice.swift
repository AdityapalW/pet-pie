import AppKit
import AVFoundation
import Speech

/// Push-to-talk speech recognition (on-device when available) + spoken replies.
@MainActor
final class VoiceController: NSObject, ObservableObject {
    @Published private(set) var listening = false
    @Published private(set) var transcript = ""

    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
    private let engine = AVAudioEngine()
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private var silenceTimer: Timer?
    private var onFinish: ((String) -> Void)?
    private let synth = AVSpeechSynthesizer()

    /// Starts listening; calls `done` with the final text after a pause in speech (or when `stop()` is called).
    func start(onPartial: @escaping (String) -> Void, done: @escaping (String) -> Void) {
        guard !listening else { stop(); return }
        synth.stopSpeaking(at: .immediate)
        onFinish = done
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else {
                    done("")
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_SpeechRecognition")!)
                    return
                }
                AVCaptureDevice.requestAccess(for: .audio) { ok in
                    Task { @MainActor in
                        if ok { self.begin(onPartial: onPartial) } else {
                            done("")
                            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                        }
                    }
                }
            }
        }
    }

    private func begin(onPartial: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else { finish(); return }
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        request = req
        transcript = ""

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak req] buf, _ in req?.append(buf) }
        do {
            engine.prepare()
            try engine.start()
        } catch {
            finish(); return
        }
        listening = true
        armSilence(seconds: 6)   // give up if nothing is said at all

        task = recognizer.recognitionTask(with: req) { [weak self] result, error in
            Task { @MainActor in
                guard let self else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    onPartial(self.transcript)
                    self.armSilence(seconds: 1.6)
                    if result.isFinal { self.finish() }
                } else if error != nil {
                    self.finish()
                }
            }
        }
    }

    private func armSilence(seconds: Double) {
        silenceTimer?.invalidate()
        silenceTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in
            Task { @MainActor in self?.finish() }
        }
    }

    func stop() { finish() }

    private func finish() {
        silenceTimer?.invalidate()
        silenceTimer = nil
        if engine.isRunning {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
        }
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        let wasListening = listening
        listening = false
        if let cb = onFinish {
            onFinish = nil
            cb(wasListening ? transcript : "")
        }
    }

    func speak(_ text: String) {
        let u = AVSpeechUtterance(string: Self.speakable(text))
        u.voice = Self.currentVoice()
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.04
        u.pitchMultiplier = 1.0
        u.postUtteranceDelay = 0
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
    }

    /// Turns Markdown into something that sounds natural: no symbols, no emoji, bullets become sentences.
    static func speakable(_ text: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            var l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("```") || l.isEmpty { continue }
            l = l.replacingOccurrences(of: #"^([-*•]\s+(\[[ xX]\]\s+)?|#+\s*|>\s*|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            l = l.replacingOccurrences(of: #"\[([^\]]+)\]\([^)]+\)"#, with: "$1", options: .regularExpression)   // links
            l = l.replacingOccurrences(of: #"[*_`~|]"#, with: "", options: .regularExpression)
            l = String(l.unicodeScalars.filter { !($0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000)) }
                .map(Character.init))
            l = l.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { continue }
            if let last = l.last, !".!?:;".contains(last) { l += "." }
            lines.append(l)
        }
        let joined = lines.joined(separator: " ")
        return joined.count > 600 ? String(joined.prefix(600)) + "… The rest is in the dashboard." : joined
    }

    // MARK: Voice choice

    /// English voices, best quality first.
    static func availableVoices() -> [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") && !$0.voiceTraits.contains(.isNoveltyVoice) }
            .sorted { a, b in
                if a.quality.rawValue != b.quality.rawValue { return a.quality.rawValue > b.quality.rawValue }
                if (a.language == "en-US") != (b.language == "en-US") { return a.language == "en-US" }
                return a.name < b.name
            }
    }

    static func currentVoice() -> AVSpeechSynthesisVoice? {
        if let id = UserDefaults.standard.string(forKey: "voiceID"), let v = AVSpeechSynthesisVoice(identifier: id) { return v }
        return availableVoices().first
    }

    static func qualityLabel(_ v: AVSpeechSynthesisVoice) -> String {
        switch v.quality {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Standard"
        }
    }

    func preview(_ v: AVSpeechSynthesisVoice) {
        UserDefaults.standard.set(v.identifier, forKey: "voiceID")
        speak("Hi, I'm Pi. This is how I'll sound.")
    }
}

/// Turns Do Not Disturb on/off through two Shortcuts ("Pi Lock In On" / "Pi Lock In Off"),
/// since macOS has no public API for Focus modes.
enum DoNotDisturb {
    static let onName = "Pi Lock In On"
    static let offName = "Pi Lock In Off"

    static func installed() async -> Bool {
        let out = await run(["list"])
        let names = Set(out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) })
        return names.contains(onName) && names.contains(offName)
    }

    static func set(_ on: Bool) async {
        _ = await run(["run", on ? onName : offName])
    }

    /// Opens the bundled .shortcut files so the user can click "Add Shortcut".
    @MainActor static func offerInstall() {
        for name in [onName, offName] {
            if let url = Bundle.main.url(forResource: name, withExtension: "shortcut") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    private static func run(_ args: [String]) async -> String {
        await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = args
            let out = Pipe()
            p.standardOutput = out
            p.standardError = Pipe()
            do { try p.run() } catch { return "" }
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(data: data, encoding: .utf8) ?? ""
        }.value
    }
}
