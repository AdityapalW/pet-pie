import Foundation

struct PetTask: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var due: Date?
    var done = false
    var reminded = false
    var created = Date()
    var completedAt: Date?
}

/// Persists tasks as JSON in ~/Library/Application Support/PiePet/tasks.json
@MainActor
final class TaskStore: ObservableObject {
    @Published private(set) var tasks: [PetTask] = []

    private let url: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PiePet", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("tasks.json")
    }()

    init() { load() }

    var open: [PetTask] {
        tasks.filter { !$0.done }.sorted { ($0.due ?? .distantFuture) < ($1.due ?? .distantFuture) }
    }

    var doneToday: [PetTask] {
        tasks.filter { $0.done && Calendar.current.isDateInToday($0.completedAt ?? .distantPast) }
    }

    @discardableResult
    func add(_ title: String, due: Date?) -> PetTask {
        let t = PetTask(title: title, due: due)
        tasks.append(t)
        save()
        return t
    }

    func toggle(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].done.toggle()
        tasks[i].completedAt = tasks[i].done ? Date() : nil
        save()
    }

    func complete(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }), !tasks[i].done else { return }
        tasks[i].done = true
        tasks[i].completedAt = Date()
        save()
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
        save()
    }

    func markReminded(_ id: UUID) {
        guard let i = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[i].reminded = true
        save()
    }

    func clearCompleted() {
        tasks.removeAll { $0.done }
        save()
    }

    /// Tasks whose reminder time has passed and that haven't fired yet.
    func dueNow() -> [PetTask] {
        let now = Date()
        return tasks.filter { !$0.done && !$0.reminded && ($0.due.map { $0 <= now } ?? false) }
    }

    /// Numbered list used in prompts so the model can refer to tasks by number.
    func promptList() -> String {
        let list = open
        if list.isEmpty { return "(no open tasks)" }
        return list.enumerated().map { i, t in
            "\(i + 1). \(t.title)" + (t.due.map { " (due \(Self.fmt.string(from: $0)))" } ?? "")
        }.joined(separator: "\n")
    }

    static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f
    }()

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        tasks = (try? dec.decode([PetTask].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(tasks).write(to: url, options: .atomic)
    }
}
