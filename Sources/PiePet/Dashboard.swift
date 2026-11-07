import AppKit
import SwiftUI

// MARK: - Shared styling

enum Theme {
    static let cream = Color(red: 1.0, green: 0.97, blue: 0.91)
    static let brown = Color(red: 0.42, green: 0.31, blue: 0.10)
    static let green = Color(red: 0.55, green: 0.70, blue: 0.33)
    static let blue = Color(red: 0.66, green: 0.83, blue: 0.88)
    static let orange = Color(red: 0.95, green: 0.55, blue: 0.37)
    static let crust = Color(red: 0.96, green: 0.80, blue: 0.30)
}

/// Native blur material behind SwiftUI content.
struct Glass: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow
    var light = false
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        if light { v.appearance = NSAppearance(named: .aqua) }
        v.blendingMode = .behindWindow
        v.state = .active
        return v
    }
    func updateNSView(_ v: NSVisualEffectView, context: Context) { v.material = material }
}

/// Glossy round icon button (dashboard toolbar style).
struct GlossyCircle: View {
    let systemName: String
    var size: CGFloat = 44
    var tint: Color = .white
    var active = false

    var body: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [Color.white.opacity(active ? 0.30 : 0.20), Color.white.opacity(active ? 0.16 : 0.07)],
                                         startPoint: .top, endPoint: .bottom))
            Circle().strokeBorder(LinearGradient(colors: [Color.white.opacity(0.35), Color.white.opacity(0.06)],
                                                 startPoint: .top, endPoint: .bottom), lineWidth: 1)
            Image(systemName: systemName)
                .font(.system(size: size * 0.40, weight: .medium))
                .foregroundColor(tint.opacity(0.9))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.35), radius: 6, y: 3)
        .contentShape(Circle())
    }
}

// MARK: - Speech bubble above the pet

struct BubbleView: View {
    let text: String
    var onTap: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Text(text)
                .font(.system(size: 12.5, weight: .medium, design: .rounded))
                .foregroundColor(Theme.brown)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12).padding(.vertical, 9)
                .frame(width: 230, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cream))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.brown, lineWidth: 1.5))
            Triangle().fill(Theme.cream)
                .overlay(Triangle().stroke(Theme.brown, lineWidth: 1.5))
                .frame(width: 14, height: 8)
                .offset(y: -1.5)
        }
        .padding(4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onTap)
    }
}

struct Triangle: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addLine(to: CGPoint(x: r.midX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.minY))
        return p
    }
}

// MARK: - Dashboard

enum SidebarMode: String, CaseIterable { case history = "History", tasks = "Tasks", notes = "Notes" }

struct DashboardView: View {
    @ObservedObject var assistant: Assistant
    @ObservedObject var chats: ConversationStore
    @ObservedObject var store: TaskStore
    @ObservedObject var notes: NotesStore
    @ObservedObject var projects: ProjectTracker
    @ObservedObject var voice: VoiceController

    @State private var showSidebar = true
    @State private var mode: SidebarMode = .history
    @State private var searching = false
    @State private var query = ""
    @State private var input = ""
    @State private var newTask = ""
    @FocusState private var inputFocused: Bool

    var body: some View {
        HStack(spacing: 0) {
            if showSidebar {
                sidebar
                    .frame(width: 310)
                    .background(ZStack { Glass(material: .sidebar); Color.white.opacity(0.035) })
                    .transition(.move(edge: .leading))
            }
            main
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ZStack { Glass(material: .underWindowBackground); Color.black.opacity(0.18) })
        }
        .ignoresSafeArea()
        .preferredColorScheme(.dark)
        .frame(minWidth: 720, minHeight: 500)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Spacer()
                Menu {
                    Picker("Show", selection: $mode) {
                        ForEach(SidebarMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.inline)
                    Divider()
                    Button("Hide Sidebar") { withAnimation(.easeInOut(duration: 0.2)) { showSidebar = false } }
                } label: {
                    GlossyCircle(systemName: "line.3.horizontal.decrease", size: 40)
                }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .fixedSize()
            }
            .padding(.horizontal, 14)
            .frame(height: 64)

            if searching && mode == .history {
                TextField("Search chats", text: $query)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12).padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
                    .padding(.horizontal, 14).padding(.bottom, 8)
            }

            switch mode {
            case .history: historyList
            case .tasks: taskList
            case .notes: notesList
            }
        }
    }

    private var historyList: some View {
        let items = chats.history.filter {
            query.isEmpty || $0.title.localizedCaseInsensitiveContains(query)
                || $0.messages.contains { $0.content.localizedCaseInsensitiveContains(query) }
        }
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 4) {
                if items.isEmpty {
                    Text(query.isEmpty ? "Your chats with Pi will show up here." : "No chats match “\(query)”.")
                        .font(.system(size: 13)).foregroundColor(.white.opacity(0.4))
                        .padding(.horizontal, 10).padding(.top, 8)
                }
                ForEach(Self.group(items), id: \.0) { section, convs in
                    Text(section).font(.system(size: 15, weight: .semibold)).foregroundColor(.white.opacity(0.45))
                        .padding(.horizontal, 10).padding(.top, 14).padding(.bottom, 6)
                    ForEach(convs) { c in historyRow(c) }
                }
            }
            .padding(.horizontal, 12).padding(.bottom, 16)
        }
    }

    private func historyRow(_ c: Conversation) -> some View {
        let selected = c.id == chats.currentID
        return Button { assistant.openChat(c.id) } label: {
            VStack(alignment: .leading, spacing: 4) {
                Text(c.title).font(.system(size: 15, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                if !c.preview.isEmpty {
                    Text(c.preview).font(.system(size: 13)).foregroundColor(.white.opacity(0.5)).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 14).padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 14)
                    .fill(LinearGradient(colors: [Color.white.opacity(0.16), Color.white.opacity(0.09)], startPoint: .top, endPoint: .bottom))
                    .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.white.opacity(0.08)))
                    .opacity(selected ? 1 : 0)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Save as Note") {
                notes.saveNote(title: c.title, body: c.messages.map { "**\($0.role == "user" ? "Me" : "Pi"):** \($0.content)" }.joined(separator: "\n\n"))
            }
            Button("Delete", role: .destructive) { assistant.deleteChat(c.id) }
        }
    }

    static func group(_ items: [Conversation]) -> [(String, [Conversation])] {
        let cal = Calendar.current
        let now = Date()
        func bucket(_ d: Date) -> String {
            if cal.isDateInToday(d) { return "Today" }
            if cal.isDateInYesterday(d) { return "Yesterday" }
            let days = cal.dateComponents([.day], from: d, to: now).day ?? 0
            if days < 7 { return "Previous 7 Days" }
            if days < 30 { return "Previous 30 Days" }
            return "Older"
        }
        let order = ["Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "Older"]
        let grouped = Dictionary(grouping: items) { bucket($0.updated) }
        return order.compactMap { k in grouped[k].map { (k, $0) } }
    }

    private var taskList: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Add a task… (“call mom at 6pm”)", text: $newTask)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        let t = newTask.trimmingCharacters(in: .whitespaces)
                        guard !t.isEmpty else { return }
                        newTask = ""
                        assistant.send("Add task: \(t)")
                    }
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(Capsule().fill(Color.white.opacity(0.08)))
            .padding(.horizontal, 14).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if store.tasks.isEmpty {
                        Text("No tasks. Add one above or just tell Pi.").font(.system(size: 13)).foregroundColor(.white.opacity(0.4))
                    }
                    ForEach(store.open + store.tasks.filter(\.done)) { t in
                        HStack(alignment: .top, spacing: 10) {
                            Button { store.toggle(t.id) } label: {
                                Image(systemName: t.done ? "checkmark.circle.fill" : "circle")
                                    .font(.system(size: 17)).foregroundColor(t.done ? Theme.green : .white.opacity(0.5))
                            }.buttonStyle(.plain)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(t.title).font(.system(size: 14)).strikethrough(t.done)
                                    .foregroundColor(.white.opacity(t.done ? 0.4 : 0.92))
                                if let due = t.due {
                                    Text(TaskStore.fmt.string(from: due)).font(.system(size: 11.5))
                                        .foregroundColor(!t.done && due < Date() ? Theme.orange : .white.opacity(0.45))
                                }
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 12).padding(.vertical, 9)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                        .contextMenu { Button("Delete", role: .destructive) { store.delete(t.id) } }
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack {
                Text("\(store.doneToday.count) done today").font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                Spacer()
                Button("Clear done") { store.clearCompleted() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.orange)
            }
            .padding(14)
        }
    }

    private var notesList: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    if notes.recent.isEmpty {
                        Text("No notes yet. Say “note: …” to Pi.").font(.system(size: 13)).foregroundColor(.white.opacity(0.4))
                    }
                    ForEach(notes.recent.prefix(80)) { n in
                        Button { notes.open(n.url) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: n.kind == "context" ? "arrow.uturn.backward.circle" : n.kind == "daily" ? "calendar" : "note.text")
                                    .foregroundColor(.white.opacity(0.6))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(n.title).font(.system(size: 14)).foregroundColor(.white.opacity(0.92)).lineLimit(1)
                                    Text(TaskStore.fmt.string(from: n.modified)).font(.system(size: 11.5)).foregroundColor(.white.opacity(0.45))
                                }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 12)
            }
            HStack {
                Text("PiNotes").font(.system(size: 12)).foregroundColor(.white.opacity(0.45))
                Spacer()
                Button("Open folder") { notes.openFolder() }.buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold)).foregroundColor(Theme.orange)
            }
            .padding(14)
        }
        .onAppear { notes.refresh() }
    }

    // MARK: Main column

    private var main: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                if assistant.messages.isEmpty {
                    emptyState
                } else {
                    messagesList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            bottomBar
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            if !showSidebar {
                Color.clear.frame(width: 70, height: 1)   // room for the traffic lights
                Button { withAnimation(.easeInOut(duration: 0.2)) { showSidebar = true } } label: {
                    GlossyCircle(systemName: "sidebar.left", size: 40)
                }.buttonStyle(.plain)
            }
            Button { assistant.newChat(); inputFocused = true } label: {
                GlossyCircle(systemName: "square.and.pencil", size: 40)
            }
            .buttonStyle(.plain)
            .help("New conversation")

            Spacer()
            if let p = projects.current {
                Label(p.name, systemImage: "hammer")
                    .font(.system(size: 12, weight: .medium)).foregroundColor(.white.opacity(0.7))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.08)))
            }
            if let end = assistant.focusEnd {
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    let left = max(0, Int(end.timeIntervalSinceNow))
                    Label("\(left / 60):\(String(format: "%02d", left % 60))",
                          systemImage: assistant.focusPhase == .rest ? "cup.and.saucer" : "lock.fill")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundColor(.white.opacity(0.85))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Capsule().fill(Theme.green.opacity(0.35)))
                }
            }
            Spacer()

            Button {
                withAnimation { showSidebar = true; mode = .history; searching.toggle(); if !searching { query = "" } }
            } label: {
                GlossyCircle(systemName: "magnifyingglass", size: 40, active: searching)
            }
            .buttonStyle(.plain)
            .help("Search chats")
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Canvas { ctx, size in
                let s = min(size.width / 150, size.height / 190)
                ctx.translateBy(x: (size.width - 150 * s) / 2, y: 0)
                ctx.scaleBy(x: s, y: s)
                PetDrawing.draw(in: &ctx, t: 1, mood: .idle)
            }
            .frame(width: 190, height: 240)
            .saturation(0)
            .opacity(0.13)
            if let p = projects.current, FileManager.default.fileExists(atPath: notes.contextURL(p.name).path) {
                Button { assistant.resume() } label: {
                    Label("Where did I leave off in \(p.name)?", systemImage: "arrow.uturn.backward")
                        .font(.system(size: 13, weight: .medium)).foregroundColor(.white.opacity(0.75))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }.buttonStyle(.plain)
            }
        }
    }

    private var messagesList: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(assistant.messages) { m in
                        DashMessage(message: m).id(m.id)
                    }
                    if assistant.busy && assistant.messages.last?.role == "user" {
                        TypingDots().id("typing")
                    }
                }
                .frame(maxWidth: 720)
                .padding(.horizontal, 28).padding(.vertical, 20)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: assistant.messages) { _, msgs in
                if let last = msgs.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: assistant.busy) { _, busy in
                if busy { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
            }
            .onAppear { if let last = assistant.messages.last { proxy.scrollTo(last.id, anchor: .bottom) } }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Menu {
                Button("Plan my day") { assistant.planDayFromMenu() }
                Button("Day recap") { assistant.recapFromMenu() }
                Menu("Clipboard") {
                    ForEach(ClipAction.allCases, id: \.self) { a in Button(a.label) { assistant.clipboard(a) } }
                }
                Divider()
                Button("Where did I leave off?") { assistant.resume() }
                Button("Save this chat as a note") { assistant.saveChatFromMenu() }
                Button("Open notes folder") { notes.openFolder() }
            } label: {
                GlossyCircle(systemName: "plus", size: 44)
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .disabled(assistant.busy)

            TextField(voice.listening ? "Listening…" : "Ask Pi", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($inputFocused)
                .onSubmit(send)
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(Capsule().fill(Color.white.opacity(0.10)))
                .overlay(Capsule().strokeBorder(Color.white.opacity(0.10)))

            Button(action: dictate) {
                GlossyCircle(systemName: voice.listening ? "waveform" : "mic.fill", size: 44,
                             tint: voice.listening ? .red : .white, active: voice.listening)
            }
            .buttonStyle(.plain)
            .help("Dictate")
        }
        .padding(.horizontal, 22).padding(.bottom, 20).padding(.top, 8)
    }

    private func send() {
        guard !assistant.busy else { return }
        assistant.send(input)
        input = ""
    }

    private func dictate() {
        if voice.listening { voice.stop(); return }
        voice.start(onPartial: { input = $0 }, done: { text in
            input = text
            if !text.trimmingCharacters(in: .whitespaces).isEmpty { send() }
        })
    }
}

/// One message in the dashboard: user = glossy pill on the right, Pi = plain text on the left.
struct DashMessage: View {
    let message: ChatMessage
    @State private var hover = false
    @State private var copied = false

    var body: some View {
        if message.role == "user" {
            HStack {
                Spacer(minLength: 80)
                Text(message.content)
                    .font(.system(size: 15)).foregroundColor(.white)
                    .textSelection(.enabled)
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 20)
                        .fill(LinearGradient(colors: [Color.white.opacity(0.20), Color.white.opacity(0.11)], startPoint: .top, endPoint: .bottom)))
                    .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.10)))
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                MarkdownText(text: message.content.isEmpty ? "…" : message.content)
                if hover && message.content.count > 30 {
                    Button(copied ? "Copied" : "Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(message.content, forType: .string)
                        copied = true
                    }
                    .buttonStyle(.plain).font(.system(size: 11.5, weight: .medium)).foregroundColor(.white.opacity(0.45))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onHover { hover = $0; if !$0 { copied = false } }
        }
    }
}

/// Small Markdown renderer: headings, bullets, checkboxes, code fences, inline styles.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, b in b }
        }
        .textSelection(.enabled)
    }

    private var blocks: [AnyView] {
        var out: [AnyView] = []
        var code: [String]? = nil
        for raw in text.components(separatedBy: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                if let c = code {
                    out.append(AnyView(Text(c.joined(separator: "\n")).font(.system(size: 13, design: .monospaced))
                        .foregroundColor(.white.opacity(0.85)).padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.black.opacity(0.3)))))
                    code = nil
                } else { code = [] }
                continue
            }
            if code != nil { code?.append(raw); continue }
            if line.isEmpty { continue }
            if line.hasPrefix("#") {
                let t = line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)
                out.append(AnyView(inline(t).font(.system(size: 16, weight: .bold)).padding(.top, 4)))
            } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                let done = line.hasPrefix("- [x]")
                out.append(AnyView(HStack(alignment: .top, spacing: 8) {
                    Image(systemName: done ? "checkmark.square" : "square").foregroundColor(.white.opacity(0.6))
                    inline(String(line.dropFirst(6))).font(.system(size: 15))
                }))
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                out.append(AnyView(HStack(alignment: .top, spacing: 8) {
                    Text("•").foregroundColor(.white.opacity(0.6))
                    inline(String(line.dropFirst(2))).font(.system(size: 15))
                }))
            } else if line.hasPrefix(">") {
                out.append(AnyView(inline(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))
                    .font(.system(size: 13)).foregroundColor(.white.opacity(0.55))))
            } else {
                out.append(AnyView(inline(line).font(.system(size: 15))))
            }
        }
        if let c = code { out.append(AnyView(Text(c.joined(separator: "\n")).font(.system(size: 13, design: .monospaced)))) }
        return out
    }

    private func inline(_ s: String) -> Text {
        let attr = (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(s)
        return Text(attr).foregroundColor(.white.opacity(0.92))
    }
}

struct TypingDots: View {
    var body: some View {
        TimelineView(.animation(minimumInterval: 0.2)) { tl in
            let step = Int(tl.date.timeIntervalSinceReferenceDate * 3) % 3
            HStack(spacing: 5) {
                ForEach(0..<3) { i in
                    Circle().fill(Color.white.opacity(i == step ? 0.8 : 0.3)).frame(width: 7, height: 7)
                }
            }
            .padding(.vertical, 6)
        }
    }
}
