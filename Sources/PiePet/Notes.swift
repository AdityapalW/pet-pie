import AppKit
import Foundation

struct NoteFile: Identifiable, Equatable {
    var id: URL { url }
    let url: URL
    let title: String
    let kind: String      // "note" | "context" | "daily"
    let modified: Date
}

/// Everything Pi writes lives as Markdown under one folder (default: ~/Documents/Hackathon/PiNotes).
///
///     PiNotes/
///       notes/2026-11-07_buy-a-new-keyboard.md
///       daily/2026-11-07.md                      ← morning plan + evening recap
///       projects/<project>/CONTEXT.md            ← latest "where I left off"
///       projects/<project>/history/2026-11-07_1130.md
@MainActor
final class NotesStore: ObservableObject {
    @Published private(set) var recent: [NoteFile] = []

    let root: URL

    init() {
        let path = UserDefaults.standard.string(forKey: "notesDir")
            ?? (NSHomeDirectory() as NSString).appendingPathComponent("Documents/Hackathon/PiNotes")
        root = URL(fileURLWithPath: path, isDirectory: true)
        for sub in ["notes", "daily", "projects"] {
            try? FileManager.default.createDirectory(at: root.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        writeReadmeIfMissing()
        refresh()
    }

    // MARK: Paths

    nonisolated static func slug(_ s: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let parts = s.lowercased().unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let collapsed = String(parts).split(separator: "-").joined(separator: "-")
        return collapsed.isEmpty ? "untitled" : String(collapsed.prefix(50))
    }

    nonisolated static func stamp(_ fmt: String, _ d: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = fmt
        return f.string(from: d)
    }

    func projectDir(_ name: String) -> URL {
        root.appendingPathComponent("projects").appendingPathComponent(Self.slug(name), isDirectory: true)
    }

    func contextURL(_ project: String) -> URL {
        projectDir(project).appendingPathComponent("CONTEXT.md")
    }

    // MARK: Writing

    @discardableResult
    func saveNote(title: String, body: String) -> URL {
        let cleanTitle = title.isEmpty ? "Note" : title
        var url = root.appendingPathComponent("notes/\(Self.stamp("yyyy-MM-dd"))_\(Self.slug(cleanTitle)).md")
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            url = root.appendingPathComponent("notes/\(Self.stamp("yyyy-MM-dd"))_\(Self.slug(cleanTitle))-\(n).md")
            n += 1
        }
        let text = "# \(cleanTitle)\n\n_\(Self.stamp("EEEE, MMM d yyyy · h:mm a"))_\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        refresh()
        return url
    }

    /// Appends a section to today's daily file.
    func appendDaily(heading: String, body: String) {
        let url = root.appendingPathComponent("daily/\(Self.stamp("yyyy-MM-dd")).md")
        var text = (try? String(contentsOf: url, encoding: .utf8))
            ?? "# \(Self.stamp("EEEE, MMMM d yyyy"))\n"
        text += "\n## \(heading) · \(Self.stamp("h:mm a"))\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n"
        try? text.write(to: url, atomically: true, encoding: .utf8)
        refresh()
    }

    /// Writes the project's CONTEXT.md and keeps a timestamped copy in history/.
    @discardableResult
    func saveContext(project: String, markdown: String) -> URL {
        let dir = projectDir(project)
        let hist = dir.appendingPathComponent("history", isDirectory: true)
        try? FileManager.default.createDirectory(at: hist, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("CONTEXT.md")
        try? markdown.write(to: url, atomically: true, encoding: .utf8)
        try? markdown.write(to: hist.appendingPathComponent("\(Self.stamp("yyyy-MM-dd_HHmm")).md"), atomically: true, encoding: .utf8)
        refresh()
        return url
    }

    func readContext(project: String) -> String? {
        try? String(contentsOf: contextURL(project), encoding: .utf8)
    }

    // MARK: Listing

    func refresh() {
        let fm = FileManager.default
        var out: [NoteFile] = []
        let groups: [(String, String)] = [("notes", "note"), ("daily", "daily")]
        for (dir, kind) in groups {
            let d = root.appendingPathComponent(dir)
            for f in (try? fm.contentsOfDirectory(at: d, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
            where f.pathExtension == "md" {
                out.append(NoteFile(url: f, title: Self.title(of: f), kind: kind, modified: Self.mtime(f)))
            }
        }
        let projects = root.appendingPathComponent("projects")
        for p in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
            let c = p.appendingPathComponent("CONTEXT.md")
            if fm.fileExists(atPath: c.path) {
                out.append(NoteFile(url: c, title: "\(p.lastPathComponent) — context", kind: "context", modified: Self.mtime(c)))
            }
        }
        recent = out.sorted { $0.modified > $1.modified }
    }

    static func mtime(_ u: URL) -> Date {
        (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }

    static func title(of u: URL) -> String {
        if let s = try? String(contentsOf: u, encoding: .utf8),
           let first = s.split(separator: "\n").first, first.hasPrefix("# ") {
            return String(first.dropFirst(2))
        }
        return u.deletingPathExtension().lastPathComponent
    }

    func open(_ url: URL) { NSWorkspace.shared.open(url) }
    func openFolder() { NSWorkspace.shared.open(root) }

    private func writeReadmeIfMissing() {
        let url = root.appendingPathComponent("README.md")
        guard !FileManager.default.fileExists(atPath: url.path) else { return }
        let text = """
        # PiNotes

        Everything Pi saves for you, as plain Markdown.

        - `notes/` — notes you asked Pi to keep ("note: …", "save this chat as a note")
        - `daily/` — one file per day with Pi's morning plan and evening recap
        - `projects/<name>/CONTEXT.md` — where you left off in each project (saved when you close it or go idle)
        - `projects/<name>/history/` — every previous context snapshot
        """
        try? text.write(to: url, atomically: true, encoding: .utf8)
    }
}
