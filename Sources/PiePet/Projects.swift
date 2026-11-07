import Foundation

/// What the editor extension last told us about one open workspace.
struct EditorState: Equatable {
    var editor: String
    var name: String
    var path: String
    var activeFile: String?
    var cursorLine: Int?
    var selection: String?
    var openFiles: [String] = []
    var lastActivity = Date()
    var lastSeen = Date()
    var lastSaved: Date?
    var activitySinceSave = false
}

/// Tracks projects open in VS Code / Antigravity and writes CONTEXT.md when you close one.
@MainActor
final class ProjectTracker: ObservableObject {
    @Published private(set) var projects: [String: EditorState] = [:]
    @Published private(set) var current: EditorState?
    @Published private(set) var saving: String?

    let notes: NotesStore
    let pet: PetState
    var model: () -> OllamaClient

    private var greeted = Set<String>()

    init(notes: NotesStore, pet: PetState, model: @escaping () -> OllamaClient) {
        self.notes = notes
        self.pet = pet
        self.model = model
    }

    // MARK: Events from the extension

    func handleState(_ b: [String: Any]) -> [String: Any] {
        guard let path = b["workspacePath"] as? String, !path.isEmpty else { return ["error": "workspacePath required"] }
        let event = b["event"] as? String ?? "heartbeat"
        var s = projects[path] ?? EditorState(editor: b["editor"] as? String ?? "Editor",
                                              name: b["workspaceName"] as? String ?? (path as NSString).lastPathComponent,
                                              path: path)
        s.editor = b["editor"] as? String ?? s.editor
        s.activeFile = (b["activeFile"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? s.activeFile
        s.cursorLine = b["cursorLine"] as? Int ?? s.cursorLine
        s.selection = (b["selection"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(4000)) }
        if let open = b["openFiles"] as? [String] { s.openFiles = Array(open.prefix(30)) }
        s.lastSeen = Date()
        if b["active"] as? Bool == true || event == "edit" || event == "save" {
            s.lastActivity = Date()
            s.activitySinceSave = true
        }
        projects[path] = s
        if event != "heartbeat" || current == nil || current?.path == path { current = s }

        if event == "open" && !greeted.contains(path) {
            greeted.insert(path)
            welcomeBack(s)
        }
        return ["ok": true, "contextFile": notes.contextURL(s.name).path]
    }

    func handleSave(_ b: [String: Any]) async -> [String: Any] {
        guard let path = b["workspacePath"] as? String, !path.isEmpty else { return ["error": "workspacePath required"] }
        let reason = b["reason"] as? String ?? "manual"
        let note = b["note"] as? String
        var s = projects[path] ?? EditorState(editor: b["editor"] as? String ?? "Editor",
                                              name: b["workspaceName"] as? String ?? (path as NSString).lastPathComponent,
                                              path: path)
        if let f = b["activeFile"] as? String, !f.isEmpty { s.activeFile = f }
        if let l = b["cursorLine"] as? Int { s.cursorLine = l }
        projects[path] = s
        // A close with no edits since the last save has nothing new to record.
        if reason == "close" && !s.activitySinceSave && s.lastSaved != nil {
            projects[path] = nil
            return ["ok": true, "skipped": "no changes since last save"]
        }
        let url = await save(path: path, reason: reason, note: note)
        if reason == "close" { projects[path] = nil; if current?.path == path { current = nil } }
        return url.map { ["ok": true, "file": $0.path] } ?? ["error": "save failed"]
    }

    // MARK: Saving

    @discardableResult
    func save(path: String, reason: String, note: String? = nil) async -> URL? {
        guard var s = projects[path], saving != path else { return nil }
        saving = path
        defer { saving = nil }
        pet.mood = .thinking

        let previous = notes.readContext(project: s.name)
        let snap = await ContextWriter.gather(s, previous: previous)
        do {
            let md = try await ContextWriter.write(snap, state: s, reason: reason, userNote: note, client: model())
            let url = notes.saveContext(project: s.name, markdown: md)
            s.lastSaved = Date()
            s.activitySinceSave = false
            projects[path] = s
            let why = ["close": "you closed it", "editor gone": "the editor closed"][reason] ?? "you asked"
            pet.say("Saved where you left off in \(s.name) (\(why)).", mood: .excited, seconds: 6)
            return url
        } catch {
            pet.say("I couldn't save \(s.name)'s progress: \(error.localizedDescription)", seconds: 8)
            return nil
        }
    }

    /// Called from the assistant's heartbeat. Saving normally happens when the project closes;
    /// this only catches editors that quit or crashed without saying goodbye (no heartbeat for 3 min).
    func tick() {
        let now = Date()
        for (path, s) in projects where s.activitySinceSave && saving == nil
            && now.timeIntervalSince(s.lastSeen) > 3 * 60 {
            Task {
                await self.save(path: path, reason: "editor gone")
                self.projects[path] = nil
                if self.current?.path == path { self.current = nil }
            }
            break   // one at a time; the next tick picks up the rest
        }
        // Forget editors we haven't heard from in a long while.
        for (path, s) in projects where !s.activitySinceSave && now.timeIntervalSince(s.lastSeen) > 15 * 60 {
            projects[path] = nil
            if current?.path == path { current = nil }
        }
    }

    // MARK: Resume

    func welcomeBack(_ s: EditorState) {
        guard let ctx = notes.readContext(project: s.name) else {
            pet.say("Tracking \(s.name). I'll save your progress when you close it.", seconds: 5)
            return
        }
        let left = Self.section("Where I left off", in: ctx) ?? Self.section("What I'm working on", in: ctx) ?? ""
        let short = left.count > 170 ? String(left.prefix(170)) + "…" : left
        pet.say("Back in \(s.name). Last time: \(short)\n(click for full context)", mood: .excited, seconds: 20)
    }

    /// Returns the body of a "## Heading" section from Markdown.
    static func section(_ heading: String, in md: String) -> String? {
        let lines = md.components(separatedBy: "\n")
        guard let i = lines.firstIndex(where: { $0.hasPrefix("## ") && $0.localizedCaseInsensitiveContains(heading) }) else { return nil }
        var out: [String] = []
        for l in lines[(i + 1)...] {
            if l.hasPrefix("## ") || l.hasPrefix("# ") || l.hasPrefix("---") { break }
            out.append(l)
        }
        let text = out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - Context generation

struct ProjectSnapshot: Sendable {
    var isGit = false
    var branch = ""
    var status = ""
    var diffStat = ""
    var diff = ""
    var log = ""
    var files = ""
    var readme = ""
    var activeExcerpt = ""
    var previous = ""
}

enum ContextWriter {
    static func gather(_ s: EditorState, previous: String?) async -> ProjectSnapshot {
        let path = s.path, active = s.activeFile, line = s.cursorLine
        return await Task.detached {
            var p = ProjectSnapshot()
            p.previous = String((previous ?? "").prefix(3000))
            // Ignore a repo whose root is the home folder (a stray `git init ~`): it isn't this project's history.
            let top = run(["rev-parse", "--show-toplevel"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
            p.isGit = !top.isEmpty && top != NSHomeDirectory()
            if p.isGit {
                p.branch = run(["rev-parse", "--abbrev-ref", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines)
                p.status = cap(run(["status", "--short", "--", "."], in: path), lines: 60)
                p.diffStat = cap(run(["diff", "HEAD", "--stat", "--", "."], in: path), lines: 40)
                p.diff = String(run(["diff", "HEAD", "-U2", "--", "."], in: path).prefix(7000))
                p.log = run(["log", "--oneline", "-12", "--date=relative", "--format=%h %ar  %s"], in: path)
                p.files = cap(run(["ls-files"], in: path), lines: 150)
            } else {
                p.files = listFiles(path)
            }
            for name in ["README.md", "readme.md", "README"] {
                if let r = try? String(contentsOfFile: (path as NSString).appendingPathComponent(name), encoding: .utf8) {
                    p.readme = String(r.prefix(1500)); break
                }
            }
            if let active, let text = try? String(contentsOfFile: active, encoding: .utf8) {
                let all = text.components(separatedBy: "\n")
                let center = max(0, (line ?? 1) - 1)
                let lo = max(0, center - 60), hi = min(all.count, center + 60)
                let excerpt = all[lo..<hi].enumerated().map { "\(lo + $0.offset + 1): \($0.element)" }.joined(separator: "\n")
                p.activeExcerpt = String(excerpt.prefix(6000))
            }
            return p
        }.value
    }

    static func write(_ p: ProjectSnapshot, state s: EditorState, reason: String, userNote: String?, client: OllamaClient) async throws -> String {
        let rel: (String) -> String = { f in
            f.hasPrefix(s.path + "/") ? String(f.dropFirst(s.path.count + 1)) : f
        }
        var data = "PROJECT: \(s.name)\nPATH: \(s.path)\n"
        if p.isGit { data += "BRANCH: \(p.branch)\n" }
        if let f = s.activeFile { data += "CURRENT FILE: \(rel(f)) (cursor line \(s.cursorLine ?? 0))\n" }
        if !s.openFiles.isEmpty { data += "OPEN TABS: \(s.openFiles.map(rel).joined(separator: ", "))\n" }
        if let n = userNote, !n.isEmpty { data += "\nUSER'S OWN NOTE: \(n)\n" }
        if let sel = s.selection { data += "\nSELECTED CODE:\n\(sel)\n" }
        if !p.status.isEmpty { data += "\nGIT STATUS (uncommitted):\n\(p.status)\n" }
        if !p.diff.isEmpty { data += "\nUNCOMMITTED DIFF (truncated):\n\(p.diff)\n" }
        if !p.log.isEmpty { data += "\nRECENT COMMITS:\n\(p.log)\n" }
        if !p.activeExcerpt.isEmpty { data += "\nCURRENT FILE AROUND CURSOR:\n\(p.activeExcerpt)\n" }
        if !p.readme.isEmpty { data += "\nREADME (start):\n\(p.readme)\n" }
        if !p.files.isEmpty { data += "\nFILES:\n\(p.files)\n" }
        if !p.previous.isEmpty { data += "\nPREVIOUS CONTEXT NOTE (may be outdated):\n\(p.previous)\n" }

        let instructions = """
        Write a handoff note so I (the developer) can resume this project later, using ONLY the data below. \
        Be specific: name files, functions and concrete changes. Don't invent things not supported by the data. \
        Output Markdown with exactly these sections and nothing before them:

        ## What I'm working on
        (1-3 sentences: the goal of the current work)
        ## Where I left off
        (1-3 sentences: the exact spot — file, function, what was half-done)
        ## Done so far
        (bullets, from commits + uncommitted changes)
        ## Next steps
        (3-6 "- [ ]" checkboxes, most important first)
        ## Open questions / risks
        (bullets, or "- None noticed")
        ## Key files
        (bullets: `path` — why it matters)
        """
        var c = client
        c.options = ["num_ctx": 16384, "temperature": 0.3]
        let body = try await c.complete([
            ChatMessage(role: "system", content: "You write concise, accurate developer handoff notes."),
            ChatMessage(role: "user", content: instructions + "\n\n=== DATA ===\n" + data),
        ]).trimmingCharacters(in: .whitespacesAndNewlines)

        let why = ["close": "closed the project", "editor gone": "editor closed", "manual": "saved manually"][reason] ?? reason
        var md = "# \(s.name) — where I left off\n\n"
        md += "> Saved \(NotesStore.stamp("EEE MMM d yyyy, h:mm a")) · \(why) · \(s.editor)\n"
        md += "> Path: `\(s.path)`" + (p.isGit ? " · branch `\(p.branch)`" : "") + "\n"
        if let f = s.activeFile { md += "> Resume at: `\(rel(f))`" + (s.cursorLine.map { " line \($0)" } ?? "") + "\n" }
        if let n = userNote, !n.isEmpty { md += "\n**My note:** \(n)\n" }
        md += "\n" + body + "\n"
        if !p.diffStat.isEmpty {
            md += "\n## Uncommitted changes (git)\n\n```\n\(p.diffStat.trimmingCharacters(in: .whitespacesAndNewlines))\n```\n"
        }
        return md
    }

    // MARK: helpers

    static func run(_ args: [String], in dir: String) -> String {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        proc.arguments = ["-C", dir] + args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = Pipe()
        do { try proc.run() } catch { return "" }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    static func cap(_ s: String, lines n: Int) -> String {
        let l = s.split(separator: "\n", omittingEmptySubsequences: false)
        return l.count > n ? l.prefix(n).joined(separator: "\n") + "\n… (\(l.count - n) more)" : s
    }

    static func listFiles(_ root: String) -> String {
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "dist", ".venv", "venv", "__pycache__", "DerivedData", ".next", "Pods"]
        var out: [String] = []
        let fm = FileManager.default
        guard let e = fm.enumerator(atPath: root) else { return "" }
        while let f = e.nextObject() as? String, out.count < 150 {
            let name = (f as NSString).lastPathComponent
            if skip.contains(name) || name.hasPrefix(".") { e.skipDescendants(); continue }
            if (e.level) > 4 { e.skipDescendants(); continue }
            var isDir: ObjCBool = false
            fm.fileExists(atPath: (root as NSString).appendingPathComponent(f), isDirectory: &isDir)
            if !isDir.boolValue { out.append(f) }
        }
        return out.joined(separator: "\n")
    }
}
