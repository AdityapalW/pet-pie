import Foundation

struct ChatMessage: Codable, Identifiable, Equatable {
    var id = UUID()
    var role: String   // "system" | "user" | "assistant"
    var content: String

    enum CodingKeys: String, CodingKey { case role, content }
}

enum OllamaError: LocalizedError {
    case http(Int, String)
    var errorDescription: String? {
        switch self {
        case .http(let code, let body): return "Ollama returned \(code): \(body)"
        }
    }
}

/// Minimal client for Ollama's /api/chat endpoint.
struct OllamaClient {
    var baseURL: URL
    var model: String
    /// How long Ollama keeps the model in memory after a request. Short so the Mac cools down.
    var keepAlive = "3m"
    /// Extra model options, e.g. ["num_ctx": 16384].
    var options: [String: Any] = [:]

    private func request(_ body: [String: Any]) throws -> URLRequest {
        var req = URLRequest(url: baseURL.appendingPathComponent("api/chat"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 180
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        return req
    }

    private func payload(_ messages: [ChatMessage]) -> [[String: String]] {
        messages.map { ["role": $0.role, "content": $0.content] }
    }

    /// Streams the assistant reply token by token.
    func stream(_ messages: [ChatMessage], onToken: @escaping @MainActor (String) -> Void) async throws {
        let req = try request([
            "model": model, "stream": true, "think": false, "keep_alive": keepAlive,
            "options": options, "messages": payload(messages),
        ])
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            var body = ""
            for try await line in bytes.lines { body += line }
            throw OllamaError.http(http.statusCode, body)
        }
        for try await line in bytes.lines {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            if let err = obj["error"] as? String { throw OllamaError.http(500, err) }
            if let msg = obj["message"] as? [String: Any], let piece = msg["content"] as? String, !piece.isEmpty {
                await onToken(piece)
            }
            if obj["done"] as? Bool == true { break }
        }
    }

    /// One-shot reply constrained to a JSON schema (Ollama structured outputs).
    func structured(_ messages: [ChatMessage], schema: [String: Any]) async throws -> [String: Any] {
        let req = try request([
            "model": model, "stream": false, "think": false, "keep_alive": keepAlive,
            "format": schema, "options": ["temperature": 0],
            "messages": payload(messages),
        ])
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw OllamaError.http(http.statusCode, String(data: data, encoding: .utf8) ?? "")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let msg = obj["message"] as? [String: Any],
              let content = msg["content"] as? String,
              let inner = try JSONSerialization.jsonObject(with: Data(content.utf8)) as? [String: Any]
        else { return [:] }
        return inner
    }

    /// Plain non-streaming reply.
    func complete(_ messages: [ChatMessage]) async throws -> String {
        var out = ""
        try await stream(messages) { out += $0 }
        return out
    }

    func installedModels() async -> [String] {
        let url = baseURL.appendingPathComponent("api/tags")
        guard let (data, _) = try? await URLSession.shared.data(from: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = obj["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
}
