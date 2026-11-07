import AppKit
import AVFoundation
import Combine
import SwiftUI

/// Small pill under Pi (Codex-style): type, talk, lock in.
struct ActionPill: View {
    @ObservedObject var assistant: Assistant
    @ObservedObject var voice: VoiceController
    @ObservedObject var snow: SnowController
    var onType: () -> Void

    private let ink = Color(white: 0.17)

    private func icon(_ name: String, color: Color? = nil) -> some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(color ?? ink)
            .frame(width: 36, height: 38)
            .contentShape(Rectangle())
    }

    private var divider: some View {
        Rectangle().fill(ink.opacity(0.22)).frame(width: 1, height: 18)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: onType) { icon("square.and.pencil") }
                .buttonStyle(.plain)
                .help("Type to Pi")

            divider

            Button { assistant.talk() } label: {
                icon("waveform", color: voice.listening ? .red : nil)
                    .symbolEffect(.variableColor.iterative, isActive: voice.listening)
            }
            .buttonStyle(.plain)
            .help(voice.listening ? "Stop listening" : "Talk to Pi")

            divider

            Button { snow.toggle() } label: {
                icon("snowflake", color: snow.isOn ? Color(red: 0.25, green: 0.55, blue: 0.85) : nil)
                    .symbolEffect(.bounce, value: snow.isOn)
            }
            .buttonStyle(.plain)
            .help(snow.isOn ? "Stop the snow (right-click for more)" : "Let it snow (right-click for more)")
            .contextMenu {
                Button(snow.isOn ? "Stop the snow" : "Let it snow") { snow.toggle() }
                Picker("Snowfall", selection: $snow.intensity) {
                    ForEach(SnowIntensity.allCases) { Text($0.label).tag($0) }
                }
                Toggle("Santas", isOn: $snow.santas)
                if snow.isOn {
                    Divider()
                    Button("Shake the snow off my windows") { snow.shakeOff() }
                }
            }

            divider

            Button {
                if assistant.focusPhase == nil { assistant.startFocus() } else { assistant.stopFocus() }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: assistant.focusPhase == .focus ? "lock.fill"
                          : assistant.focusPhase == .rest ? "cup.and.saucer.fill" : "lock.open")
                        .font(.system(size: 14.5, weight: .semibold))
                    if let end = assistant.focusEnd {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            let left = max(0, Int(end.timeIntervalSinceNow))
                            Text("\(left / 60):\(String(format: "%02d", left % 60))")
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                        }
                    }
                }
                .foregroundColor(assistant.focusPhase == .focus ? Color(red: 0.25, green: 0.42, blue: 0.12) : ink)
                .padding(.horizontal, 9)
                .frame(minWidth: 36)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(assistant.focusPhase == nil ? "Lock in: \(assistant.lockInMinutes) min focus + Do Not Disturb (right-click for length)" : "Stop lock-in")
            .contextMenu {
                ForEach([15, 25, 50, 90], id: \.self) { m in
                    Button("Lock in for \(m) min") { assistant.startFocus(minutes: m) }
                }
                if assistant.focusPhase != nil {
                    Divider()
                    Button("Stop") { assistant.stopFocus() }
                }
            }
        }
        .padding(.horizontal, 5)
        .background(
            // Frosted glass: blur of what's behind + a light translucent tint.
            ZStack {
                Glass(material: .hudWindow, light: true).clipShape(Capsule()).opacity(0.85)
                Capsule().fill(LinearGradient(colors: [Color.white.opacity(0.30), Color.white.opacity(0.08)],
                                              startPoint: .top, endPoint: .bottom))
            }
        )
        .overlay(Capsule().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.75), Color.white.opacity(0.12)],
                                                         startPoint: .top, endPoint: .bottom), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
    }
}

/// Compact "Ask Pi…" field that pops up next to Pi from the pill's type button.
struct QuickAskView: View {
    var onSubmit: (String) -> Void
    var onCancel: () -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "square.and.pencil").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(white: 0.3))
            TextField("", text: $text, prompt: Text("Ask Pi…").foregroundColor(Color(white: 0.5)))
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundColor(Color(white: 0.12))
                .focused($focused)
                .onSubmit {
                    let t = text.trimmingCharacters(in: .whitespaces)
                    text = ""
                    if t.isEmpty { onCancel() } else { onSubmit(t) }
                }
                .onExitCommand(perform: onCancel)
        }
        .padding(.horizontal, 12)
        .frame(width: 260, height: 32)
        .background(Capsule().fill(LinearGradient(colors: [Color(white: 0.96), Color(white: 0.86)], startPoint: .top, endPoint: .bottom)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.9), lineWidth: 0.8))
        .shadow(color: .black.opacity(0.25), radius: 5, y: 2)
        .padding(6)
        .environment(\.colorScheme, .light)
        .onAppear { focused = true }
    }
}

/// Borderless panel that can take keyboard focus (for the quick-ask field).
final class KeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Pet + pill sizes (Pi is drawn in a 150x190 box and scaled to fit).
enum PetLayout {
    static let pet = NSSize(width: 100, height: 127)
    static let window = NSSize(width: 200, height: 172)   // wide enough for the pill with a lock-in timer
}

/// Root view of the pet window: drag to move, click for the dashboard, right-click for more.
struct PetContainer: View {
    @ObservedObject var pet: PetState
    @ObservedObject var assistant: Assistant
    @ObservedObject var snow: SnowController
    var onClick: () -> Void
    var onDragStart: () -> Void
    var onDrag: () -> Void
    var onType: () -> Void = {}
    var onPocketPaste: () -> Void = {}

    @State private var dragging = false
    @State private var moved = false

    private var showPill: Bool {
        pet.hovering || dragging
    }

    var body: some View {
        VStack(spacing: 0) {
            PetView(state: pet)
                .frame(width: PetLayout.pet.width, height: PetLayout.pet.height)
                .background(
                    // Warm glow while an image hovers over Pi.
                    Ellipse()
                        .fill(RadialGradient(colors: [PetDrawing.gold.opacity(0.75), PetDrawing.gold.opacity(0)],
                                             center: .center, startRadius: 4, endRadius: 62))
                        .frame(width: 124, height: 118)
                        .opacity(pet.dropTargeted ? 1 : 0)
                        .scaleEffect(pet.dropTargeted ? 1 : 0.7)
                        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: pet.dropTargeted)
                )
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0, coordinateSpace: .global)
                        .onChanged { v in
                            if !dragging { dragging = true; moved = false; onDragStart() }
                            if abs(v.translation.width) + abs(v.translation.height) > 3 { moved = true }
                            if moved { onDrag() }
                        }
                        .onEnded { _ in
                            dragging = false
                            if !moved { onClick() }
                        }
                )
                .contextMenu {
                    Button("Open Dashboard") { onClick() }
                    Button("Plan my day") { assistant.planDayFromMenu() }
                    Button("Day recap") { assistant.recapFromMenu() }
                    Menu("Clipboard") {
                        ForEach(ClipAction.allCases, id: \.self) { a in Button(a.label) { assistant.clipboard(a) } }
                    }
                    Button(snow.isOn ? "Stop the snow" : "Let it snow ❄️") { snow.toggle() }
                    Button("Put copied image in my pocket") { onPocketPaste() }
                    Divider()
                    Button(pet.mood == .sleeping ? "Wake up" : "Nap") {
                        if pet.mood == .sleeping { pet.touch() } else { pet.hideBubble(); pet.mood = .sleeping }
                    }
                    Button("Quit Pi") { NSApp.terminate(nil) }
                }
            ZStack(alignment: .top) {
                if pet.dropTargeted {
                    HStack(spacing: 6) {
                        Image(systemName: "tray.and.arrow.down.fill").font(.system(size: 13, weight: .semibold))
                        Text("Drop to keep").font(.system(size: 12, weight: .semibold, design: .rounded))
                    }
                    .foregroundColor(Theme.brown)
                    .padding(.horizontal, 12)
                    .frame(height: 30)
                    .background(Capsule().fill(Theme.cream))
                    .overlay(Capsule().strokeBorder(Theme.brown, lineWidth: 1.4))
                    .shadow(color: .black.opacity(0.22), radius: 3, y: 1.5)
                    .padding(.top, 4)
                    .transition(.scale(scale: 0.5, anchor: .top).combined(with: .opacity))
                } else if showPill {
                    ActionPill(assistant: assistant, voice: assistant.voice, snow: snow, onType: onType)
                        .transition(.scale(scale: 0.4, anchor: .top).combined(with: .opacity))
                } else {
                    // Collapsed handle, like a tiny grabber; green while locked in, icy while snowing.
                    Capsule()
                        .fill(LinearGradient(colors: assistant.focusPhase == .focus
                                             ? [Color(red: 0.62, green: 0.82, blue: 0.45), Color(red: 0.42, green: 0.64, blue: 0.28)]
                                             : snow.isOn ? [Color(red: 0.86, green: 0.94, blue: 1.0), Color(red: 0.55, green: 0.74, blue: 0.92)]
                                             : [Color(white: 0.88), Color(white: 0.70)],
                                             startPoint: .top, endPoint: .bottom))
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.8), lineWidth: 0.6))
                        .frame(width: 34, height: 7)
                        .shadow(color: .black.opacity(0.2), radius: 2, y: 1)
                        .padding(.top, 6)
                        .transition(.opacity)
                }
            }
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: showPill)
            .animation(.spring(response: 0.28, dampingFraction: 0.8), value: pet.dropTargeted)
        }
        .frame(width: PetLayout.window.width, height: PetLayout.window.height, alignment: .top)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let pet = PetState()
    let store = TaskStore()
    let notes = NotesStore()
    let snow = SnowController()
    let pocket = PocketStore()
    lazy var assistant = Assistant(pet: pet, store: store, notes: notes)
    var bridge: BridgeServer?

    var petPanel: NSPanel!
    var pocketPanel: NSPanel!
    var bubblePanel: NSPanel!
    var quickPanel: KeyPanel!
    var dashboard: NSWindow!
    var statusItem: NSStatusItem!
    var cancellables = Set<AnyCancellable>()

    private var dragStartMouse = NSPoint.zero
    private var dragStartOrigin = NSPoint.zero

    func applicationDidFinishLaunching(_ notification: Notification) {
        makePetPanel()
        makePocketPanel()
        makeBubblePanel()
        makeQuickPanel()
        makeDashboard()
        makeStatusItem()

        assistant.isChatOpen = { [weak self] in self?.dashboard.isKeyWindow ?? false }

        pet.$bubble
            .receive(on: RunLoop.main)
            .sink { [weak self] text in self?.updateBubble(text) }
            .store(in: &cancellables)

        assistant.start()
        startBridge()
        startHoverTracking()
        snow.pet = pet
        snow.restore()
    }

    func applicationWillTerminate(_ notification: Notification) {
        assistant.shutdown()
    }

    /// Local HTTP bridge for the Antigravity extension.
    private func startBridge() {
        let projects = assistant.projects!
        let notes = self.notes
        bridge = BridgeServer { path, body in
            let quick = await MainActor.run { () -> [String: Any]? in
                switch path {
                case "/v1/state": return projects.handleState(body)
                case "/v1/note":
                    let url = notes.saveNote(title: body["title"] as? String ?? "Note", body: body["body"] as? String ?? "")
                    return ["ok": true, "file": url.path]
                default: return nil
                }
            }
            if let quick { return quick }
            if path == "/v1/save" { return await projects.handleSave(body) }
            return ["error": "unknown endpoint \(path)"]
        }
        bridge?.start()
    }

    // MARK: Windows

    private func floatingPanel(_ rect: NSRect) -> NSPanel {
        let p = NSPanel(contentRect: rect, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        return p
    }

    private func makePetPanel() {
        let size = PetLayout.window
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin = NSPoint(x: screen.maxX - size.width - 30, y: screen.minY + 10)
        if let saved = UserDefaults.standard.string(forKey: "petOrigin") {
            let p = NSPointFromString(saved)
            if NSScreen.screens.contains(where: { $0.frame.contains(NSPoint(x: p.x + size.width / 2, y: p.y + size.height / 2)) }) { origin = p }
        }
        petPanel = floatingPanel(NSRect(origin: origin, size: size))
        let view = PetContainer(
            pet: pet, assistant: assistant, snow: snow,
            onClick: { [weak self] in self?.petClicked() },
            onDragStart: { [weak self] in self?.dragStart() },
            onDrag: { [weak self] in self?.dragMove() },
            onType: { [weak self] in self?.toggleQuickAsk() },
            onPocketPaste: { [weak self] in self?.pocketPaste() })
        let host = DropHostingView(rootView: view)
        host.onTargetChange = { [weak self] on in self?.setDropTarget(on) }
        host.onDrop = { [weak self] pb in self?.takeDrop(pb) ?? false }
        petPanel.contentView = host
        petPanel.orderFrontRegardless()
    }

    // MARK: Pocket

    private func makePocketPanel() {
        pocketPanel = floatingPanel(NSRect(origin: .zero, size: PocketView.collapsed))
        let host = DropHostingView(rootView: PocketView(pocket: pocket))
        host.onTargetChange = { [weak self] on in self?.setDropTarget(on) }
        host.onDrop = { [weak self] pb in self?.takeDrop(pb) ?? false }
        pocketPanel.contentView = host
        pocket.announce = { [weak self] text in self?.pet.say(text, mood: .excited, seconds: 2.5) }
        pocket.$items
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.layoutPocket() }
            .store(in: &cancellables)
        layoutPocket()
    }

    /// Keeps the pocket tucked against Pi's pie (left side, or right near the screen's left edge).
    private func layoutPocket() {
        guard let pocketPanel else { return }
        guard petPanel.isVisible, !pocket.items.isEmpty else {
            pocket.expanded = false
            pocketPanel.orderOut(nil)
            return
        }
        let f = petPanel.frame
        let petRect = NSRect(x: f.midX - PetLayout.pet.width / 2, y: f.maxY - PetLayout.pet.height,
                             width: PetLayout.pet.width, height: PetLayout.pet.height)
        let size = PocketView.size(for: pocket)
        let widest = PocketView.expandedSize(count: pocket.items.count).width
        let vis = petPanel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? f
        let onLeft = petRect.minX + 10 - widest >= vis.minX
        if pocket.onLeft != onLeft { pocket.onLeft = onLeft }
        var x = onLeft ? petRect.minX + 10 - size.width : petRect.maxX - 10
        var y = petRect.minY - 2
        x = min(max(x, vis.minX), vis.maxX - size.width)
        y = min(max(y, vis.minY), vis.maxY - size.height)
        pocketPanel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        if !pocketPanel.isVisible { pocketPanel.orderFrontRegardless() }
    }

    private func setDropTarget(_ on: Bool) {
        guard pet.dropTargeted != on else { return }
        pet.dropTargeted = on
        if on {
            pet.touch()
            if pet.mood == .idle { pet.mood = .excited }
        } else if pet.mood == .excited && pet.bubble == nil {
            pet.mood = .idle
        }
    }

    private func takeDrop(_ pb: NSPasteboard) -> Bool {
        pocket.take(from: pb) { [weak self] n in
            guard let self else { return }
            if n > 0 {
                pet.say(n == 1 ? "Got it! It's in my pocket. Drag it out whenever you need it."
                               : "Got \(n)! They're in my pocket.", mood: .excited, seconds: 4)
            } else {
                pet.say("Hmm, I couldn't hold on to that one.", seconds: 3)
            }
        }
    }

    func pocketPaste() {
        guard PocketStore.canAccept(.general) else {
            pet.say("There's no image on your clipboard right now.", seconds: 3)
            return
        }
        _ = takeDrop(.general)
    }

    private func makeBubblePanel() {
        bubblePanel = floatingPanel(NSRect(x: 0, y: 0, width: 240, height: 60))
    }

    // MARK: Hover

    private var hoverTimer: Timer?
    private var lastInside = Date.distantPast

    /// Polls the mouse position (panels of a background app don't get reliable hover events).
    private func startHoverTracking() {
        hoverTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateHover() }
        }
    }

    private func updateHover() {
        guard petPanel.isVisible else { return }
        let inside = petPanel.frame.insetBy(dx: -8, dy: -8).contains(NSEvent.mouseLocation)
            || quickPanel.isVisible || assistant.voice.listening
        if inside { lastInside = Date() }
        // Show right away; hide after a short delay so it doesn't flicker.
        let show = inside || Date().timeIntervalSince(lastInside) < 0.7
        if pet.hovering != show { pet.hovering = show }
        updatePocketHover()
    }

    private var lastInPocket = Date.distantPast

    /// Opens the pocket into a tray while the mouse is over it; stays open during a drag out.
    private func updatePocketHover() {
        guard pocketPanel.isVisible else { return }
        let over = pocketPanel.frame.insetBy(dx: -4, dy: -4).contains(NSEvent.mouseLocation)
        if over { lastInPocket = Date() }
        let holding = NSEvent.pressedMouseButtons != 0
        let want = over || (pocket.expanded && (holding || Date().timeIntervalSince(lastInPocket) < 0.5))
        if want != pocket.expanded {
            pocket.expanded = want
            layoutPocket()
        }
    }

    // MARK: Quick ask

    private func makeQuickPanel() {
        let p = KeyPanel(contentRect: NSRect(x: 0, y: 0, width: 272, height: 44),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = false
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.delegate = self
        quickPanel = p
    }

    func toggleQuickAsk() {
        if quickPanel.isVisible { quickPanel.orderOut(nil); return }
        pet.touch()
        // Fresh view each time so the field starts empty and focused.
        quickPanel.contentView = NSHostingView(rootView: QuickAskView(
            onSubmit: { [weak self] text in
                self?.quickPanel.orderOut(nil)
                self?.assistant.send(text)
            },
            onCancel: { [weak self] in self?.quickPanel.orderOut(nil) }))
        let f = petPanel.frame, s = quickPanel.frame.size
        var x = f.midX - s.width / 2
        var y = f.minY - s.height + 4           // just under the pill
        if let vis = petPanel.screen?.visibleFrame {
            if y < vis.minY { y = f.maxY - 8 }  // no room below: show above Pi
            x = min(max(x, vis.minX + 4), vis.maxX - s.width - 4)
        }
        quickPanel.setFrameOrigin(NSPoint(x: x, y: y))
        NSApp.activate(ignoringOtherApps: true)
        quickPanel.makeKeyAndOrderFront(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === quickPanel { quickPanel.orderOut(nil) }
    }

    private func makeDashboard() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1000, height: 720),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Pi"
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.isMovableByWindowBackground = true
        w.appearance = NSAppearance(named: .darkAqua)
        w.backgroundColor = .clear
        w.isOpaque = false
        w.isReleasedWhenClosed = false
        w.minSize = NSSize(width: 720, height: 500)
        // A toolbar gives the taller title bar, so the traffic lights sit level with the glossy buttons.
        let tb = NSToolbar(identifier: "PiDashboard")
        tb.showsBaselineSeparator = false
        w.toolbar = tb
        w.toolbarStyle = .unified
        w.delegate = self
        w.contentView = NSHostingView(rootView: DashboardView(
            assistant: assistant, chats: assistant.chats, store: store, notes: notes,
            projects: assistant.projects, voice: assistant.voice))
        w.center()
        w.setFrameAutosaveName("PiDashboard")
        dashboard = w
    }

    private func updateBubble(_ text: String?) {
        guard let text, !dashboard.isKeyWindow else { bubblePanel.orderOut(nil); return }
        let host = NSHostingView(rootView: BubbleView(text: text, onTap: { [weak self] in
            self?.pet.hideBubble()
            self?.showDashboard()
        }))
        let size = host.fittingSize
        bubblePanel.contentView = host
        bubblePanel.setContentSize(size)
        positionBubble()
        bubblePanel.orderFrontRegardless()
    }

    private func positionBubble() {
        let f = petPanel.frame
        let s = bubblePanel.frame.size
        var x = f.midX - s.width / 2
        var y = f.maxY - 12
        if let vis = petPanel.screen?.visibleFrame {
            x = min(max(x, vis.minX + 4), vis.maxX - s.width - 4)
            if y + s.height > vis.maxY { y = f.minY - s.height }
        }
        bubblePanel.setFrameOrigin(NSPoint(x: x, y: y))
    }

    // MARK: Interaction

    private func dragStart() {
        dragStartMouse = NSEvent.mouseLocation
        dragStartOrigin = petPanel.frame.origin
        pet.touch()
    }

    private func dragMove() {
        let m = NSEvent.mouseLocation
        petPanel.setFrameOrigin(NSPoint(x: dragStartOrigin.x + m.x - dragStartMouse.x,
                                        y: dragStartOrigin.y + m.y - dragStartMouse.y))
        if bubblePanel.isVisible { positionBubble() }
        if quickPanel.isVisible { quickPanel.orderOut(nil) }
        layoutPocket()
        UserDefaults.standard.set(NSStringFromPoint(petPanel.frame.origin), forKey: "petOrigin")
    }

    private func petClicked() {
        pet.touch()
        if dashboard.isVisible && dashboard.isKeyWindow { dashboard.orderOut(nil) } else { showDashboard() }
    }

    func showDashboard() {
        pet.hideBubble()
        bubblePanel.orderOut(nil)
        NSApp.activate(ignoringOtherApps: true)
        dashboard.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        if (notification.object as? NSWindow) === dashboard { bubblePanel.orderOut(nil) }
    }

    // MARK: Menu bar

    private func makeStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "🥧"
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
    }

    @objc private func togglePet() {
        if petPanel.isVisible { petPanel.orderOut(nil); bubblePanel.orderOut(nil) }
        else { petPanel.orderFrontRegardless() }
        layoutPocket()
    }
    @objc private func pocketPasteMenu() { pocketPaste() }
    @objc private func openPocketFolder() { pocket.openFolder() }
    @objc private func emptyPocket() { pocket.clear() }
    @objc private func openDashboard() { showDashboard() }
    @objc private func planDay() { assistant.planDayFromMenu() }
    @objc private func recap() { assistant.recapFromMenu() }
    @objc private func lockIn() { assistant.startFocus() }
    @objc private func stopFocus() { assistant.stopFocus() }
    @objc private func toggleSnow() { snow.toggle() }
    @objc private func shakeSnow() { snow.shakeOff() }
    @objc private func toggleCheckIns() { assistant.checkInsEnabled.toggle() }
    @objc private func setupDND() { DoNotDisturb.offerInstall() }
    @objc private func pickModel(_ sender: NSMenuItem) {
        assistant.model = sender.title
        pet.say("Switched to \(sender.title).", seconds: 3)
    }
    @objc private func openNotes() { notes.openFolder() }
    @objc private func pickVoice(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let v = AVSpeechSynthesisVoice(identifier: id) else { return }
        assistant.voice.preview(v)
    }
    @objc private func downloadVoices() {
        // Premium/Enhanced voices are free downloads in System Settings → Accessibility → Spoken Content.
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent")!)
    }
    @objc private func resetPosition() {
        guard let vis = NSScreen.main?.visibleFrame else { return }
        petPanel.setFrameOrigin(NSPoint(x: vis.maxX - 200, y: vis.minY + 10))
        UserDefaults.standard.set(NSStringFromPoint(petPanel.frame.origin), forKey: "petOrigin")
        layoutPocket()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func item(_ title: String, _ sel: Selector, _ key: String = "") -> NSMenuItem {
            let i = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            i.target = self
            return i
        }
        menu.addItem(item("Open Dashboard", #selector(openDashboard)))
        menu.addItem(item(petPanel.isVisible ? "Hide Pi" : "Show Pi", #selector(togglePet)))
        menu.addItem(.separator())
        menu.addItem(item("Plan My Day", #selector(planDay)))
        menu.addItem(item("Day Recap", #selector(recap)))
        if assistant.focusPhase == nil {
            menu.addItem(item("Lock In (\(assistant.lockInMinutes) min)", #selector(lockIn)))
        } else {
            menu.addItem(item("Stop Lock-in", #selector(stopFocus)))
        }
        let snowItem = item("Let It Snow ❄️", #selector(toggleSnow))
        snowItem.state = snow.isOn ? .on : .off
        menu.addItem(snowItem)
        if snow.isOn { menu.addItem(item("Shake Off the Snow", #selector(shakeSnow))) }
        let pocketItem = NSMenuItem(title: "Pocket (\(pocket.items.count))", action: nil, keyEquivalent: "")
        let pocketMenu = NSMenu()
        pocketMenu.addItem(item("Put Copied Image in Pocket", #selector(pocketPasteMenu)))
        pocketMenu.addItem(item("Open Pocket Folder", #selector(openPocketFolder)))
        if !pocket.items.isEmpty { pocketMenu.addItem(item("Empty Pocket", #selector(emptyPocket))) }
        pocketItem.submenu = pocketMenu
        menu.addItem(pocketItem)
        menu.addItem(.separator())
        let checkIns = item("Daily Check-ins", #selector(toggleCheckIns))
        checkIns.state = assistant.checkInsEnabled ? .on : .off
        menu.addItem(checkIns)
        menu.addItem(item("Set Up Do Not Disturb…", #selector(setupDND)))

        let modelItem = NSMenuItem(title: "Model: \(assistant.model)", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        sub.addItem(NSMenuItem(title: "Loading…", action: nil, keyEquivalent: ""))
        modelItem.submenu = sub
        menu.addItem(modelItem)
        Task { @MainActor in
            let models = await assistant.client.installedModels()
            sub.removeAllItems()
            if models.isEmpty { sub.addItem(NSMenuItem(title: "Ollama not reachable", action: nil, keyEquivalent: "")) }
            for m in models {
                let mi = NSMenuItem(title: m, action: #selector(self.pickModel(_:)), keyEquivalent: "")
                mi.target = self
                mi.state = m == self.assistant.model ? .on : .off
                sub.addItem(mi)
            }
        }
        let voiceItem = NSMenuItem(title: "Voice: \(VoiceController.currentVoice()?.name ?? "Default")", action: nil, keyEquivalent: "")
        let voices = NSMenu()
        let current = VoiceController.currentVoice()?.identifier
        for v in VoiceController.availableVoices().prefix(16) {
            let vi = NSMenuItem(title: "\(v.name) (\(v.language), \(VoiceController.qualityLabel(v)))", action: #selector(pickVoice(_:)), keyEquivalent: "")
            vi.target = self
            vi.representedObject = v.identifier
            vi.state = v.identifier == current ? .on : .off
            voices.addItem(vi)
        }
        voices.addItem(.separator())
        let more = NSMenuItem(title: "Download Better Voices…", action: #selector(downloadVoices), keyEquivalent: "")
        more.target = self
        voices.addItem(more)
        voiceItem.submenu = voices
        menu.addItem(voiceItem)
        menu.addItem(item("Open Notes Folder", #selector(openNotes)))
        menu.addItem(item("Reset Position", #selector(resetPosition)))
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Pi", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)
    }
}

// MARK: - Entry point

MainActor.assumeIsolated {
    // `PiePet --render-preview out.png` renders every mood to an image and exits.
    let args = CommandLine.arguments
    if let i = args.firstIndex(of: "--render-preview"), i + 1 < args.count {
        let moods: [Mood] = [.idle, .talking, .thinking, .excited, .sleeping]
        let strip = HStack(spacing: 10) {
            ForEach(moods, id: \.self) { m in
                VStack {
                    Canvas { ctx, size in
                        ctx.scaleBy(x: size.width / 150, y: size.height / 190)
                        PetDrawing.draw(in: &ctx, t: 1.0, mood: m)
                    }
                    .frame(width: 150, height: 190)
                    Text(m.rawValue).font(.caption)
                }
            }
        }
        .padding(12).background(Color.white)
        let r = ImageRenderer(content: strip)
        r.scale = args.contains("--large") ? 5 : 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }

    // `PiePet --render-snow out.png` renders the Santa poses and a snowball.
    if let i = args.firstIndex(of: "--render-snow"), i + 1 < args.count {
        let strip = HStack(spacing: 14) {
            ForEach(SantaPose.allCases, id: \.self) { pose in
                if let cg = SnowArt.santaImage(pose) { Image(decorative: cg, scale: 3).resizable().frame(width: 162, height: 162) }
            }
        }
        .padding(16).background(Color(red: 0.55, green: 0.66, blue: 0.80))
        let r = ImageRenderer(content: strip)
        r.scale = 2
        if let img = r.nsImage, let tiff = img.tiffRepresentation,
           let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 1]))
        }
        exit(0)
    }

    // `PiePet --render-pocket <images-dir> out.png` renders Pi with the pocket closed, open, and as a drop target,
    // using the images in <images-dir> (they are copied to a temp pocket; nothing real is touched).
    if let i = args.firstIndex(of: "--render-pocket"), i + 2 < args.count {
        _ = NSApplication.shared
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("PiePocketPreview-\(UUID().uuidString)")
        let pocket = PocketStore(dir: tmp)
        let srcs = ((try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: args[i + 1]), includingPropertiesForKeys: nil)) ?? [])
            .filter(PocketStore.isImage).sorted { $0.path < $1.path }
        for src in srcs {
            let pb = NSPasteboard(name: .init("PiePocketPreview"))
            pb.clearContents()
            pb.writeObjects([src as NSURL])
            pocket.take(from: pb) { _ in }
        }
        let pet = PetState(), store = TaskStore(), notes = NotesStore()
        let a = Assistant(pet: pet, store: store, notes: notes)
        @MainActor func scene(expanded: Bool, target: Bool) -> some View {
            pocket.expanded = expanded
            pet.dropTargeted = target
            pet.mood = target ? .excited : .idle
            let ps = PocketView.size(for: pocket)
            return ZStack(alignment: .bottomLeading) {
                PocketView(pocket: pocket).offset(x: 0, y: -(172 - 127 + 2))
                PetContainer(pet: pet, assistant: a, snow: SnowController(), onClick: {}, onDragStart: {}, onDrag: {})
                    .offset(x: ps.width - 10 - 50)
            }
            .frame(width: ps.width + 150, height: max(ps.height + 47, 172), alignment: .bottomLeading)
        }
        var shots: [NSImage] = []
        for (e, t) in [(false, false), (true, false), (false, true)] {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.borderless], backing: .buffered, defer: false)
            let host = NSHostingView(rootView: scene(expanded: e, target: t).padding(10).background(Color(red: 0.32, green: 0.42, blue: 0.55)))
            w.contentView = host
            w.setContentSize(host.fittingSize)
            w.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                let img = NSImage(size: host.bounds.size); img.addRepresentation(rep); shots.append(img)
            }
            w.orderOut(nil)
        }
        let total = NSSize(width: shots.map(\.size.width).reduce(0, +), height: shots.map(\.size.height).max() ?? 0)
        let out = NSImage(size: total)
        out.lockFocus()
        var x: CGFloat = 0
        for s in shots { s.draw(at: NSPoint(x: x, y: total.height - s.size.height), from: .zero, operation: .copy, fraction: 1); x += s.size.width }
        out.unlockFocus()
        if let tiff = out.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
            try? png.write(to: URL(fileURLWithPath: args[i + 2]))
        }
        try? FileManager.default.removeItem(at: tmp)
        exit(0)
    }

    // `PiePet --render-dashboard out.png` renders the dashboard + pet with sample chats (nothing is saved).
    if let i = args.firstIndex(of: "--render-dashboard"), i + 1 < args.count {
        _ = NSApplication.shared
        let pet = PetState(), store = TaskStore(), notes = NotesStore()
        let a = Assistant(pet: pet, store: store, notes: notes)
        a.chats.loadPreviewSamples()
        a.messages = a.chats.all[0].messages + [
            ChatMessage(role: "user", content: "what should I do next on the bridge?"),
            ChatMessage(role: "assistant", content: "## Next up\n- [ ] Handle the **close** event in `ProjectTracker`\n- Test a save from Antigravity\n\nYou're close! 🥧"),
        ]
        func snap(_ view: some View, _ size: NSSize, _ out: String) {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            w.titlebarAppearsTransparent = true
            w.appearance = NSAppearance(named: .darkAqua)
            let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
            w.contentView = host
            w.orderFrontRegardless()
            RunLoop.current.run(until: Date().addingTimeInterval(0.8))
            if let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: out))
            }
            w.orderOut(nil)
        }
        snap(DashboardView(assistant: a, chats: a.chats, store: store, notes: notes, projects: a.projects, voice: a.voice),
             NSSize(width: 1000, height: 700), args[i + 1])
        snap(PetContainer(pet: pet, assistant: a, snow: SnowController(), onClick: {}, onDragStart: {}, onDrag: {}).background(Color(white: 0.2)),
             PetLayout.window, args[i + 1].replacingOccurrences(of: ".png", with: "-pet.png"))
        pet.hovering = true
        snap(PetContainer(pet: pet, assistant: a, snow: SnowController(), onClick: {}, onDragStart: {}, onDrag: {}).background(Color(white: 0.2)),
             PetLayout.window, args[i + 1].replacingOccurrences(of: ".png", with: "-pet-hover.png"))
        snap(QuickAskView(onSubmit: { _ in }, onCancel: {}).background(Color(white: 0.2)),
             NSSize(width: 272, height: 44), args[i + 1].replacingOccurrences(of: ".png", with: "-ask.png"))
        exit(0)
    }

    // If the .app was started from a terminal/script instead of Finder/`open`, macOS treats the *launcher*
    // as responsible for microphone & speech permissions and kills Pi on first use. Relaunch through
    // Launch Services so Pi owns its own permissions.
    if ProcessInfo.processInfo.environment["PIEPET_LS"] == nil,
       Bundle.main.bundleURL.pathExtension == "app", !args.contains("--no-relaunch") {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        cfg.activates = false
        cfg.environment = ["PIEPET_LS": "1"]
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, error in
            if let error { NSLog("PiePet relaunch failed: \(error)") }
            exit(0)
        }
        RunLoop.main.run()
    }

    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
