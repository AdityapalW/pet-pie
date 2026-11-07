import Foundation

struct Conversation: Codable, Identifiable, Equatable {
    var id = UUID()
    var title = "New Conversation"
    var created = Date()
    var updated = Date()
    var messages: [ChatMessage] = []

    var preview: String {
        let text = messages.last(where: { $0.role == "assistant" && !$0.content.isEmpty })?.content
            ?? messages.last?.content ?? ""
        // Strip Markdown symbols so the sidebar shows plain text.
        return text
            .replacingOccurrences(of: #"(?m)^\s*([-*•]\s+(\[[ xX]\]\s+)?|#+\s*|>\s*|\d+\.\s+)"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*`_]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: #"\s{2,}"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Chat history, persisted to ~/Library/Application Support/PiePet/conversations.json
@MainActor
final class ConversationStore: ObservableObject {
    @Published private(set) var all: [Conversation] = []
    @Published var currentID: UUID?

    private var saveTask: Task<Void, Never>?
    /// Preview renders use sample data and must never write to disk.
    private var previewMode = false

    func loadPreviewSamples() {
        previewMode = true
        let now = Date()
        func c(_ t: String, _ ago: Double, _ a: String) -> Conversation {
            Conversation(title: t, created: now - ago, updated: now - ago,
                         messages: [ChatMessage(role: "user", content: t), ChatMessage(role: "assistant", content: a)])
        }
        all = [
            c("Mutex vs semaphore", 600, "A mutex lets one thread in at a time; a semaphore counts how many can enter."),
            c("Plan for Saturday", 3600 * 26, "Here's a calm plan: finish the bridge, lunch, then a long walk."),
            c("Swift concurrency", 3600 * 24 * 5, "Actors protect their state by running one task at a time."),
            c("Hackathon pitch ideas", 3600 * 24 * 12, "1. A desktop pet that remembers where you left off…"),
        ]
        currentID = all[0].id
    }
    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PiePet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }()

    init() {
        load()
    }

    var current: Conversation? { all.first { $0.id == currentID } }

    /// Conversations with at least one message, newest first.
    var history: [Conversation] {
        all.filter { !$0.messages.isEmpty }.sorted { $0.updated > $1.updated }
    }

    @discardableResult
    func newConversation(title: String = "New Conversation") -> Conversation {
        // Reuse an empty conversation instead of piling them up.
        if let empty = all.firstIndex(where: { $0.messages.isEmpty }) {
            all[empty].title = title
            all[empty].updated = Date()
            currentID = all[empty].id
            return all[empty]
        }
        let c = Conversation(title: title)
        all.append(c)
        currentID = c.id
        return c
    }

    func updateCurrent(_ messages: [ChatMessage]) {
        if currentID == nil || current == nil { newConversation() }
        guard let i = all.firstIndex(where: { $0.id == currentID }) else { return }
        guard all[i].messages != messages else { return }
        all[i].messages = messages
        all[i].updated = Date()
        scheduleSave()
    }

    func rename(_ id: UUID, to title: String) {
        guard let i = all.firstIndex(where: { $0.id == id }) else { return }
        all[i].title = title
        scheduleSave()
    }

    func delete(_ id: UUID) {
        all.removeAll { $0.id == id }
        if currentID == id { currentID = nil }
        scheduleSave()
    }

    private func scheduleSave() {
        guard !previewMode else { return }
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            guard !Task.isCancelled else { return }
            self?.save()
        }
    }

    func save() {
        guard !previewMode else { return }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        let keep = all.filter { !$0.messages.isEmpty }
        try? enc.encode(keep).write(to: url, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        all = (try? dec.decode([Conversation].self, from: data)) ?? []
    }
}
