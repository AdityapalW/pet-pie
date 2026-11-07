import Foundation
import Network

/// Tiny HTTP server on 127.0.0.1 that the VS Code / Antigravity extension talks to.
///
///   GET  /v1/ping                → {"ok":true}
///   POST /v1/state  {EditorState} → editor reports the open project / file / activity
///   POST /v1/save   {workspacePath, reason, note?} → save the project's CONTEXT.md
///   POST /v1/note   {title, body} → save a Markdown note
///
/// Requests with an `Origin` header (i.e. from a web page) or without a JSON body are rejected,
/// so websites in your browser can't poke at Pi.
final class BridgeServer: @unchecked Sendable {
    static let defaultPort: UInt16 = 47615

    typealias Handler = @Sendable (_ path: String, _ body: [String: Any]) async -> [String: Any]

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pi.bridge")
    private let handler: Handler
    let port: UInt16

    init(port: UInt16 = BridgeServer.defaultPort, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() {
        do {
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params)
            l.newConnectionHandler = { [weak self] c in self?.accept(c) }
            l.stateUpdateHandler = { state in
                if case .failed(let e) = state { NSLog("PiePet bridge failed: \(e)") }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            NSLog("PiePet bridge could not start: \(error)")
        }
    }

    private func accept(_ c: NWConnection) {
        c.start(queue: queue)
        receive(c, buffer: Data())
    }

    private func receive(_ c: NWConnection, buffer: Data) {
        c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, done, err in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if buf.count > 2_000_000 || err != nil { c.cancel(); return }
            if let req = Self.parse(buf) {
                self.respond(c, req)
            } else if done {
                c.cancel()
            } else {
                self.receive(c, buffer: buf)
            }
        }
    }

    private struct Request {
        var method: String
        var path: String
        var headers: [String: String]
        var body: Data
    }

    /// Returns a request once headers + full body (per Content-Length) have arrived.
    private static func parse(_ data: Data) -> Request? {
        guard let sep = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        guard let head = String(data: data[..<sep.lowerBound], encoding: .utf8) else { return nil }
        var lines = head.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ")
        guard start.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            if let i = l.firstIndex(of: ":") {
                headers[l[..<i].lowercased()] = l[l.index(after: i)...].trimmingCharacters(in: .whitespaces)
            }
        }
        let len = Int(headers["content-length"] ?? "0") ?? 0
        let body = data[sep.upperBound...]
        guard body.count >= len else { return nil }
        return Request(method: String(start[0]), path: String(start[1]), headers: headers, body: Data(body.prefix(len)))
    }

    private func respond(_ c: NWConnection, _ req: Request) {
        func send(_ status: String, _ obj: [String: Any]) {
            let json = (try? JSONSerialization.data(withJSONObject: obj)) ?? Data("{}".utf8)
            var out = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
            out.append(json)
            c.send(content: out, completion: .contentProcessed { _ in c.cancel() })
        }

        if req.headers["origin"] != nil { return send("403 Forbidden", ["error": "browser requests not allowed"]) }
        if req.method == "GET" && req.path == "/v1/ping" { return send("200 OK", ["ok": true, "app": "PiePet"]) }
        guard req.method == "POST", (req.headers["content-type"] ?? "").hasPrefix("application/json") else {
            return send("400 Bad Request", ["error": "POST application/json only"])
        }
        let body = (try? JSONSerialization.jsonObject(with: req.body) as? [String: Any]) ?? [:]
        let path = req.path
        let handler = self.handler
        Task {
            let result = await handler(path, body)
            self.queue.async { send(result["error"] == nil ? "200 OK" : "400 Bad Request", result) }
        }
    }
}
