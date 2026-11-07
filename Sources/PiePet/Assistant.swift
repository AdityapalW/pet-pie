import AppKit
import Foundation

enum ClipAction: String, CaseIterable {
    case summarize, fix, explain, reply

    var label: String {
        switch self {
        case .summarize: return "Summarize"
        case .fix: return "Fix writing"
        case .explain: return "Explain"
        case .reply: return "Draft reply"
        }
    }

    var instruction: String {
        switch self {
        case .summarize: return "Summarize this in a few short bullet points."
        case .fix: return "Fix grammar, spelling and clarity. Keep the meaning and tone. Return only the corrected text."
        case .explain: return "Explain this simply, like to a smart friend. If it's code, say what it does."
        case .reply: return "Draft a short, friendly reply to this message. Return only the reply."
        }
    }
}

enum FocusPhase { case focus, rest }

/// The pet's brain: routes messages, talks to Ollama, fires reminders and check-ins.
@MainActor
final class Assistant: ObservableObject {
    /// Messages of the conversation shown in the dashboard. Every change is mirrored into the history store.
    @Published var messages: [ChatMessage] = [] {
        didSet { chats.updateCurrent(messages) }
    }
    let chats = ConversationStore()
    let voice = VoiceController()
    /// When true, the next reply is also spoken aloud (set by the 🎙 Talk button).
    private var speakNext = false
    private var dndActive = false
    private var dndOfferedThisLaunch = false
    @Published var busy = false
    @Published var focusPhase: FocusPhase?
    @Published var focusEnd: Date?
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "model") }
    }
    @Published var checkInsEnabled: Bool {
        didSet { UserDefaults.standard.set(checkInsEnabled, forKey: "checkIns") }
    }

    let pet: PetState
    let store: TaskStore
    let notes: NotesStore
    private(set) var projects: ProjectTracker!
    var isChatOpen: () -> Bool = { false }

    private let baseURL = URL(string: UserDefaults.standard.string(forKey: "ollamaURL") ?? "http://127.0.0.1:11434")!
    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var morningHour: Int { defaults.object(forKey: "morningHour") as? Int ?? 9 }
    var recapHour: Int { defaults.object(forKey: "recapHour") as? Int ?? 18 }

    var client: OllamaClient { OllamaClient(baseURL: baseURL, model: model) }

    init(pet: PetState, store: TaskStore, notes: NotesStore) {
        self.pet = pet
        self.store = store
        self.notes = notes
        self.model = UserDefaults.standard.string(forKey: "model") ?? "gemma4:e4b"
        self.checkInsEnabled = UserDefaults.standard.object(forKey: "checkIns") as? Bool ?? true
        self.projects = ProjectTracker(notes: notes, pet: pet, model: { [weak self] in
            self?.client ?? OllamaClient(baseURL: URL(string: "http://127.0.0.1:11434")!, model: "gemma4:e4b")
        })
    }

    private var projectLine: String {
        guard let p = projects.current else { return "" }
        let file = p.activeFile.map { " — current file: \(($0 as NSString).lastPathComponent)" } ?? ""
        return "\nThe user is coding in project \"\(p.name)\" in \(p.editor)\(file)."
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
        pet.say("Hi, I'm Pi. Click me for the dashboard, or tap the mic to talk.", mood: .excited, seconds: 6)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            self.tick()
        }
    }

    // MARK: - Persona

    private var systemPrompt: String {
        """
        You are Pi, a desktop assistant that helps with tasks, planning, focus, notes and coding questions.
        Style rules (follow strictly):
        - Answer directly. First sentence = the answer. No greetings, no "Great question", no recap of the question, no sign-off.
        - No filler, no hype, no exclamation marks unless truly needed.
        - Short answers: 1-2 sentences. Bigger ideas: a short lead line, then "- " bullets (one idea per bullet, under 15 words each).
        - Use at most ONE emoji in a whole reply, and usually none.
        - Plain, friendly, professional tone.
        Current local time: \(Self.nowString()).\(projectLine)
        The user's open tasks:
        \(store.promptList())
        """
    }

    static func nowString() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE yyyy-MM-dd HH:mm"
        return f.string(from: Date())
    }

    // MARK: - Conversations

    func newChat() {
        guard !busy else { return }
        chats.newConversation()
        messages = []
    }

    func openChat(_ id: UUID) {
        guard !busy, let c = chats.all.first(where: { $0.id == id }) else { return }
        chats.currentID = id
        messages = c.messages
    }

    func deleteChat(_ id: UUID) {
        guard !busy else { return }
        let wasCurrent = chats.currentID == id
        chats.delete(id)
        if wasCurrent { messages = [] ; chats.newConversation() }
    }

    /// Gives a fresh conversation a short title once it has its first answer.
    private func titleIfNeeded() async {
        guard let c = chats.current, c.title == "New Conversation",
              let first = messages.first(where: { $0.role == "user" }) else { return }
        let id = c.id
        let t = (try? await client.complete([
            ChatMessage(role: "system", content: "Reply with only a 2-4 word title for this chat. No quotes, no punctuation at the end."),
            ChatMessage(role: "user", content: String(first.content.prefix(600))),
        ]))?.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.\n ")) ?? ""
        chats.rename(id, to: t.isEmpty ? String(first.content.prefix(30)) : String(t.prefix(40)))
    }

    // MARK: - Voice

    /// 🎙 Talk button: listen, then answer in a bubble and out loud.
    func talk() {
        if voice.listening { voice.stop(); return }
        guard !busy else { return }
        pet.touch()
        pet.say("Listening…", mood: .excited, seconds: 30)
        voice.start(onPartial: { [weak self] text in
            self?.pet.say("“\(text)”", mood: .excited, seconds: 30)
        }, done: { [weak self] text in
            guard let self else { return }
            guard !text.trimmingCharacters(in: .whitespaces).isEmpty else {
                self.pet.say("Didn't catch that. Tap the mic and try again.", seconds: 4)
                return
            }
            self.speakNext = true
            self.send(text)
        })
    }

    // MARK: - Chat entry point

    func send(_ raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !busy else { return }
        pet.touch()
        if chats.current == nil { chats.newConversation() }
        messages.append(ChatMessage(role: "user", content: text))
        busy = true
        pet.mood = .thinking

        Task { @MainActor in
            defer { busy = false; speakNext = false; if pet.mood == .thinking { pet.mood = .idle } }
            do {
                let route = try await classify(text)
                try await handle(route: route, text: text)
            } catch {
                reportError(error)
            }
            await titleIfNeeded()
        }
    }

    private struct Route {
        var intent: String
        var title: String
        var due: Date?
        var taskNumber: Int
        var clip: ClipAction?
        var noteText = ""
    }

    private func classify(_ text: String) async throws -> Route {
        let schema: [String: Any] = [
            "type": "object",
            "properties": [
                "intent": ["type": "string",
                           "enum": ["add_task", "complete_task", "list_tasks", "plan_day", "recap", "clipboard",
                                    "save_note", "save_chat_note", "save_progress", "resume", "open_notes", "chat"]],
                "title": ["type": "string"],
                "note_text": ["type": "string"],
                "in_minutes": ["type": "integer"],
                "due": ["type": "string"],
                "task_number": ["type": "integer"],
                "clipboard_action": ["type": "string", "enum": ["summarize", "fix", "explain", "reply", "none"]],
            ],
            "required": ["intent", "title", "note_text", "in_minutes", "due", "task_number", "clipboard_action"],
        ]
        let sys = """
        You route messages for a desktop assistant. Current local time: \(Self.nowString()).
        Open tasks:
        \(store.promptList())

        Choose intent:
        - add_task: user wants to remember/do something or be reminded ("remind me to...", "add ...", "todo: ..."). \
        title = short task text without the time words. If a relative time is given ("in 20 minutes", "in 2 hours") set in_minutes. \
        If a clock time or day is given set due as "YYYY-MM-DD HH:mm" (24h, local). Otherwise in_minutes=0 and due="".
        - complete_task: user says they finished a task. task_number = its number in the open task list.
        - list_tasks: user asks what's on their list.
        - plan_day: user asks to plan their day / what to do next.
        - recap: user asks for a recap/summary of their day.
        - clipboard: user refers to what they copied / the clipboard. clipboard_action = summarize|fix|explain|reply.
        - save_note: user wants to write down / keep information as a note ("note: ...", "jot down ...", "save a note that ..."). \
        title = 2-6 word title, note_text = the full content to save.
        - save_chat_note: user wants this conversation/answer saved as a note.
        - save_progress: user wants to save their coding project progress / context now.
        - resume: user asks where they left off / what they were doing on their project.
        - open_notes: user wants to open/see their notes folder.
        - chat: anything else (questions, conversation, help).
        Unused fields: "" or 0 or "none".
        """
        let obj = try await client.structured(
            [ChatMessage(role: "system", content: sys), ChatMessage(role: "user", content: text)],
            schema: schema)

        var route = Route(intent: obj["intent"] as? String ?? "chat",
                          title: (obj["title"] as? String ?? "").trimmingCharacters(in: .whitespaces),
                          due: nil,
                          taskNumber: obj["task_number"] as? Int ?? 0,
                          clip: ClipAction(rawValue: obj["clipboard_action"] as? String ?? ""),
                          noteText: obj["note_text"] as? String ?? "")
        if let mins = obj["in_minutes"] as? Int, mins > 0 {
            route.due = Date().addingTimeInterval(Double(mins) * 60)
        } else if let s = obj["due"] as? String, !s.isEmpty {
            route.due = Self.parseDue(s)
        }
        return route
    }

    static func parseDue(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd HH:mm", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd"] {
            f.dateFormat = fmt
            if let d = f.date(from: s) { return fmt == "yyyy-MM-dd" ? d.addingTimeInterval(9 * 3600) : d }
        }
        f.dateFormat = "HH:mm"
        if let t = f.date(from: s) {
            let cal = Calendar.current
            let c = cal.dateComponents([.hour, .minute], from: t)
            if var d = cal.date(bySettingHour: c.hour ?? 9, minute: c.minute ?? 0, second: 0, of: Date()) {
                if d < Date() { d = cal.date(byAdding: .day, value: 1, to: d) ?? d }
                return d
            }
        }
        return nil
    }

    private func handle(route: Route, text: String) async throws {
        switch route.intent {
        case "add_task" where !route.title.isEmpty:
            let t = store.add(route.title, due: route.due)
            let when = t.due.map { " I'll remind you \(TaskStore.fmt.string(from: $0))." } ?? ""
            reply("Added “\(t.title)”." + when, mood: .excited)

        case "complete_task":
            let open = store.open
            let idx = route.taskNumber - 1
            if open.indices.contains(idx) {
                store.complete(open[idx].id)
                reply("Done: “\(open[idx].title)”.", mood: .excited)
            } else {
                reply("Which one? Here's your list:\n" + store.promptList())
            }

        case "list_tasks":
            reply(store.open.isEmpty ? "Your list is empty." : "Open tasks:\n" + store.promptList())

        case "plan_day":
            try await planDay(userAsked: true)

        case "recap":
            try await recap(userAsked: true)

        case "clipboard":
            try await runClipboard(route.clip ?? .explain, note: text)

        case "save_note":
            let body = route.noteText.isEmpty ? text : route.noteText
            let url = notes.saveNote(title: route.title.isEmpty ? "Quick note" : route.title, body: body)
            reply("Saved to PiNotes/notes/\(url.lastPathComponent)", mood: .excited)

        case "save_chat_note":
            try await saveChatAsNote()

        case "save_progress":
            guard let p = projects.current else {
                reply("I don't see a project open in Antigravity. Open one (with the Pi Companion extension) and I'll track it!")
                return
            }
            reply("Saving where you left off in \(p.name)…")
            if let url = await projects.save(path: p.path, reason: "manual", note: text) {
                reply("Done! Saved to PiNotes/projects/\(url.deletingLastPathComponent().lastPathComponent)/CONTEXT.md")
            }

        case "resume":
            resume()

        case "open_notes":
            notes.openFolder()
            reply("Opened PiNotes.")

        default:
            try await streamReply(history: Array(messages.suffix(14)))
        }
    }

    // MARK: - Features

    func clipboard(_ action: ClipAction) {
        guard !busy else { return }
        pet.touch()
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await runClipboard(action, note: nil) } catch { reportError(error) }
        }
    }

    private func runClipboard(_ action: ClipAction, note: String?) async throws {
        guard let clip = NSPasteboard.general.string(forType: .string), !clip.isEmpty else {
            if note == nil { messages.append(ChatMessage(role: "user", content: "Clipboard: \(action.label)")) }
            reply("Your clipboard has no text. Copy something first (⌘C) and try again!")
            return
        }
        let snippet = String(clip.prefix(6000))
        if note == nil {
            let preview = snippet.count > 80 ? String(snippet.prefix(80)) + "…" : snippet
            messages.append(ChatMessage(role: "user", content: "Clipboard – \(action.label): “\(preview)”"))
        }
        let prompt = "\(action.instruction)\n\n---\n\(snippet)\n---" + (note.map { "\n\nUser's request: \($0)" } ?? "")
        try await streamReply(history: [ChatMessage(role: "user", content: prompt)], persona: false)
    }

    func planDayFromMenu() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await planDay(userAsked: true) } catch { reportError(error) }
        }
    }

    func recapFromMenu() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await recap(userAsked: true) } catch { reportError(error) }
        }
    }

    // MARK: Notes & projects

    func saveChatFromMenu() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            do { try await saveChatAsNote() } catch { reportError(error) }
        }
    }

    private func saveChatAsNote() async throws {
        let convo = messages.suffix(20).filter { !$0.content.isEmpty }
        guard convo.count > 1 else { reply("There's nothing in our chat to save yet!"); return }
        pet.mood = .thinking
        let transcript = convo.map { "\($0.role == "user" ? "Me" : "Pi"): \($0.content)" }.joined(separator: "\n\n")
        let obj = try await client.structured([
            ChatMessage(role: "system", content: "Turn this chat into a tidy Markdown note: the useful info and answers, not the chit-chat. Use short headings and bullets."),
            ChatMessage(role: "user", content: String(transcript.suffix(12000))),
        ], schema: ["type": "object",
                    "properties": ["title": ["type": "string"], "markdown": ["type": "string"]],
                    "required": ["title", "markdown"]])
        let title = obj["title"] as? String ?? "Chat with Pi"
        let url = notes.saveNote(title: title, body: obj["markdown"] as? String ?? transcript)
        reply("Saved this chat as “\(title)” in PiNotes/notes/\(url.lastPathComponent)", mood: .excited)
    }

    /// Shows the saved context for the project that's open (or the most recently saved one).
    func resume() {
        let name = projects.current?.name
            ?? notes.recent.first(where: { $0.kind == "context" })?.url.deletingLastPathComponent().lastPathComponent
        guard let name, let ctx = notes.readContext(project: name) else {
            reply("I don't have a saved context yet. I save one when you close a project in Antigravity or step away for a while.")
            return
        }
        messages.append(ChatMessage(role: "assistant", content: ctx))
        pet.mood = .talking
    }

    private func planDay(userAsked: Bool) async throws {
        let ask = """
        Make a short, realistic plan for the rest of my day from my open tasks (time-ordered, \
        biggest-impact first, include a break). If I have no tasks, say so in one line and suggest adding some. \
        Max 6 bullets. No greeting, start with the first item.
        """
        if !userAsked {
            chats.newConversation(title: "Morning plan · \(NotesStore.stamp("MMM d"))")
            messages = [ChatMessage(role: "user", content: "Morning check-in")]
        }
        let plan = try await streamReply(history: [ChatMessage(role: "user", content: ask)])
        notes.appendDaily(heading: "Plan", body: plan)
    }

    private func recap(userAsked: Bool) async throws {
        let done = store.doneToday.map { "- \($0.title)" }.joined(separator: "\n")
        let ask = """
        Give me a short end-of-day recap. Completed today:
        \(done.isEmpty ? "(nothing marked done)" : done)
        Still open: see task list. Bullets only: what got done, the top 1-2 things for tomorrow. Max 5 lines.
        """
        if !userAsked {
            chats.newConversation(title: "Day recap · \(NotesStore.stamp("MMM d"))")
            messages = [ChatMessage(role: "user", content: "Evening check-in")]
        }
        let text = try await streamReply(history: [ChatMessage(role: "user", content: ask)])
        notes.appendDaily(heading: "Recap", body: text)
    }

    @discardableResult
    private func streamReply(history: [ChatMessage], persona: Bool = true) async throws -> String {
        var convo = history
        if persona { convo.insert(ChatMessage(role: "system", content: systemPrompt), at: 0) }
        messages.append(ChatMessage(role: "assistant", content: ""))
        let idx = messages.count - 1
        pet.mood = .talking
        try await client.stream(convo) { [weak self] token in
            guard let self else { return }
            self.messages[idx].content += token
        }
        let full = Self.limitEmoji(messages[idx].content.trimmingCharacters(in: .whitespacesAndNewlines))
        messages[idx].content = full
        if speakNext { voice.speak(full); speakNext = false }
        if !isChatOpen() {
            pet.say(Self.preview(full) + (full.count > 160 ? "\n(click me for more)" : ""), mood: .talking, seconds: 12)
        } else {
            pet.mood = .idle
        }
        return full
    }

    private func reply(_ text: String, mood: Mood = .talking) {
        messages.append(ChatMessage(role: "assistant", content: text))
        if speakNext { voice.speak(text); speakNext = false }
        if isChatOpen() {
            pet.mood = mood
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                if self.pet.mood == mood { self.pet.mood = .idle }
            }
        } else {
            pet.say(text, mood: mood)
        }
    }

    private func reportError(_ error: Error) {
        let hint = (error as? URLError) != nil
            ? "Can't reach Ollama. Open the Ollama app or run `ollama serve`."
            : "Oops: \(error.localizedDescription)"
        // Drop an empty streaming placeholder if one was left behind.
        if let last = messages.last, last.role == "assistant", last.content.isEmpty { messages.removeLast() }
        reply(hint)
    }

    /// Keeps the first emoji in a reply and removes the rest.
    static func limitEmoji(_ s: String) -> String {
        var seen = false
        var out = ""
        for ch in s {
            let isEmoji = ch.unicodeScalars.contains { $0.properties.isEmojiPresentation || ($0.properties.isEmoji && $0.value > 0x2000) }
            if isEmoji {
                if seen { continue }
                seen = true
            }
            out.append(ch)
        }
        return out.replacingOccurrences(of: "  ", with: " ")
    }

    static func preview(_ s: String) -> String {
        let firstLines = s.split(separator: "\n").prefix(3).joined(separator: "\n")
        return firstLines.count > 160 ? String(firstLines.prefix(160)) + "…" : firstLines
    }

    // MARK: - Focus timer

    var lockInMinutes: Int {
        get { defaults.object(forKey: "lockInMinutes") as? Int ?? 25 }
        set { defaults.set(newValue, forKey: "lockInMinutes"); objectWillChange.send() }
    }

    /// 🔒 Lock in: focus timer + Do Not Disturb.
    func startFocus(minutes: Int? = nil) {
        let mins = minutes ?? lockInMinutes
        if let minutes { lockInMinutes = minutes }
        pet.touch()
        focusPhase = .focus
        focusEnd = Date().addingTimeInterval(Double(mins) * 60)
        pet.say("Locked in for \(mins) min. Notifications off.", mood: .excited, seconds: 5)
        Task { @MainActor in
            if await DoNotDisturb.installed() {
                await DoNotDisturb.set(true)
                dndActive = true
            } else if !dndOfferedThisLaunch {
                // Offer once per launch until the shortcuts are actually added.
                dndOfferedThisLaunch = true
                DoNotDisturb.offerInstall()
                pet.say("To silence notifications while locked in, click “Add Shortcut” on the two Shortcuts windows (one time only).", seconds: 20)
            }
        }
    }

    func stopFocus() {
        focusPhase = nil
        focusEnd = nil
        endDND()
        pet.say("Lock-in stopped. Notifications are back on.", seconds: 3)
    }

    private func endDND() {
        guard dndActive else { return }
        dndActive = false
        Task { await DoNotDisturb.set(false) }
    }

    /// Turn DND back off if Pi quits mid lock-in.
    func shutdown() {
        chats.save()
        if dndActive {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/shortcuts")
            p.arguments = ["run", DoNotDisturb.offName]
            try? p.run()
            p.waitUntilExit()
        }
    }

    // MARK: - Heartbeat

    private func tick() {
        projects.tick()

        // Reminders
        for t in store.dueNow() {
            store.markReminded(t.id)
            pet.say("Reminder: \(t.title)", mood: .excited, seconds: 30)
            NSSound(named: "Glass")?.play()
        }

        // Focus / break cycle
        if let end = focusEnd, Date() >= end {
            NSSound(named: "Hero")?.play()
            if focusPhase == .focus {
                endDND()
                focusPhase = .rest
                focusEnd = Date().addingTimeInterval(5 * 60)
                pet.say("Focus block done. 5-minute break: stand up, drink water.", mood: .excited, seconds: 20)
            } else {
                focusPhase = nil
                focusEnd = nil
                pet.say("Break over. Tap the lock to start another block.", mood: .talking, seconds: 20)
            }
        }

        // Daily check-ins
        if checkInsEnabled && !busy {
            let cal = Calendar.current
            let hour = cal.component(.hour, from: Date())
            let today = cal.startOfDay(for: Date())
            if hour >= morningHour && hour < 12, (defaults.object(forKey: "lastMorning") as? Date ?? .distantPast) < today {
                defaults.set(Date(), forKey: "lastMorning")
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { try await planDay(userAsked: false) } catch { reportError(error) }
                }
            } else if hour >= recapHour, (defaults.object(forKey: "lastRecap") as? Date ?? .distantPast) < today {
                defaults.set(Date(), forKey: "lastRecap")
                busy = true
                Task { @MainActor in
                    defer { busy = false }
                    do { try await recap(userAsked: false) } catch { reportError(error) }
                }
            }
        }

        // Doze off when ignored for a while
        if pet.mood == .idle && pet.bubble == nil && !busy && !isChatOpen()
            && Date().timeIntervalSince(pet.lastInteraction) > 10 * 60 {
            pet.mood = .sleeping
        }
    }
}
