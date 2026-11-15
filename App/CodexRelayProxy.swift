import Foundation
import Network

/// A loopback-only HTTP forwarder between Codex and an API relay.
///
/// Codex's built-in `openai` provider always tries the Responses WebSocket first. Relays tend to accept the
/// upgrade (101) and then close the socket, which Codex treats as a dropped stream: it retries five times per
/// question before falling back to HTTP. Answering the upgrade with 426 makes Codex fall back at once, and
/// keeping the built-in provider keeps every thread in one list (a custom provider would hide the old ones).
/// Everything else is passed through to the relay unchanged and streamed back.
final class CodexRelayProxy: @unchecked Sendable {
    static let shared = CodexRelayProxy()
    static let preferredPorts: [UInt16] = Array(47811...47830)

    private let queue = DispatchQueue(label: "com.lazymice.qiehao.codex-proxy")
    private var listener: NWListener?
    private var upstreamRoot: URL?
    private var connections: [ObjectIdentifier: ProxyConnection] = [:]
    private(set) var port: UInt16 = 0

    var isRunning: Bool { queue.sync { listener != nil } }

    /// The base URL Codex should use while this forwarder serves a relay.
    var codexBaseURL: String? { port == 0 ? nil : "http://127.0.0.1:\(port)/v1" }

    static func isProxyURL(_ string: String?) -> Bool {
        guard let string, let url = URL(string: string), let host = url.host, let port = url.port else { return false }
        return host == "127.0.0.1" && preferredPorts.contains(UInt16(port))
    }

    /// Starts (once) on the first free preferred port, or on `wanted` when given and free. Returns the port.
    @discardableResult
    func start(upstream: URL, wanted: UInt16? = nil) -> UInt16? {
        queue.sync { upstreamRoot = upstream }
        if queue.sync(execute: { listener != nil }) { return port }
        let candidates = (wanted.map { [$0] } ?? []) + Self.preferredPorts.filter { $0 != wanted }
        for candidate in candidates {
            if let listener = makeListener(port: candidate) {
                queue.sync { self.listener = listener; self.port = candidate }
                return candidate
            }
        }
        return nil
    }

    func setUpstream(_ url: URL?) { queue.sync { upstreamRoot = url } }

    func stop() {
        queue.sync {
            listener?.cancel(); listener = nil; port = 0
            connections.values.forEach { $0.cancel() }
            connections.removeAll()
        }
    }

    private func makeListener(port: UInt16) -> NWListener? {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        guard let listener = try? NWListener(using: parameters) else { return nil }
        let ready = DispatchSemaphore(value: 0)
        var ok = false
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready: ok = true; ready.signal()
            case .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
        _ = ready.wait(timeout: .now() + 1.5)
        if !ok { listener.cancel(); return nil }
        listener.stateUpdateHandler = nil
        return listener
    }

    private func accept(_ connection: NWConnection) {
        let handler = ProxyConnection(connection: connection, queue: queue, upstream: { [weak self] in self?.upstreamRoot }) { [weak self] done in
            self?.connections[ObjectIdentifier(done)] = nil
        }
        connections[ObjectIdentifier(handler)] = handler
        handler.start()
    }
}

/// One request: read it, answer a WebSocket upgrade with 426, otherwise forward and stream the reply back.
/// Every response closes the connection, so there is no keep-alive state to track.
private final class ProxyConnection: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let connection: NWConnection
    private let queue: DispatchQueue
    private let upstream: () -> URL?
    private let finished: (ProxyConnection) -> Void
    private var buffer = Data()
    private var session: URLSession?
    private var closed = false

    init(connection: NWConnection, queue: DispatchQueue, upstream: @escaping () -> URL?, finished: @escaping (ProxyConnection) -> Void) {
        self.connection = connection
        self.queue = queue
        self.upstream = upstream
        self.finished = finished
    }

    func start() {
        connection.start(queue: queue)
        readHead()
    }

    func cancel() { close() }

    // MARK: Reading the request

    private func readHead() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let end = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handleHead(end)
            } else if complete || error != nil || self.buffer.count > 256 * 1024 {
                self.close()
            } else {
                self.readHead()
            }
        }
    }

    private struct Head {
        var method: String
        var target: String
        var headers: [(String, String)]
        func value(_ name: String) -> String? { headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1 }
    }

    private func handleHead(_ end: Range<Data.Index>) {
        let text = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        let rest = Data(buffer[end.upperBound...])
        buffer.removeAll()
        var lines = text.components(separatedBy: "\r\n")
        let start = lines.removeFirst().split(separator: " ", maxSplits: 2).map(String.init)
        guard start.count >= 2 else { respond(400, "bad request"); return }
        let headers = lines.compactMap { line -> (String, String)? in
            guard let colon = line.firstIndex(of: ":") else { return nil }
            return (String(line[..<colon]).trimmingCharacters(in: .whitespaces),
                    String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces))
        }
        let head = Head(method: start[0], target: start[1], headers: headers)
        if head.value("Upgrade")?.lowercased().contains("websocket") == true {
            // Codex falls back to HTTP immediately on this status, with no retries.
            respond(426, "websocket not supported by relay", extra: ["Upgrade": "HTTP/1.1"])
            return
        }
        if let length = head.value("Content-Length").flatMap(Int.init) {
            readBody(length: length, have: rest) { [weak self] body in self?.forward(head, body: body) }
        } else if head.value("Transfer-Encoding")?.lowercased().contains("chunked") == true {
            readChunked(have: rest, body: Data()) { [weak self] body in self?.forward(head, body: body) }
        } else {
            forward(head, body: rest.isEmpty ? nil : rest)
        }
    }

    private func readBody(length: Int, have: Data, then: @escaping (Data) -> Void) {
        if have.count >= length { then(have.prefix(length)); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: max(1, min(1 << 20, length - have.count))) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = have
            if let data { next.append(data) }
            if next.count >= length { then(next.prefix(length)) }
            else if complete || error != nil { self.close() }
            else { self.readBody(length: length, have: next, then: then) }
        }
    }

    /// Decodes a chunked body; reads more from the socket whenever a chunk is incomplete.
    private func readChunked(have: Data, body: Data, then: @escaping (Data) -> Void) {
        var data = have, out = body
        while let lineEnd = data.range(of: Data("\r\n".utf8)) {
            let sizeText = String(decoding: data[..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else { close(); return }
            let chunkStart = lineEnd.upperBound
            if size == 0 { then(out); return }
            guard data.count >= chunkStart + size + 2 else { break }
            out.append(data[chunkStart..<(chunkStart + size)])
            data = Data(data[(chunkStart + size + 2)...])
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] more, _, complete, error in
            guard let self else { return }
            guard let more, !more.isEmpty else { if complete || error != nil { self.close() }; return }
            self.readChunked(have: data + more, body: out, then: then)
        }
    }

    // MARK: Forwarding

    private static let hopHeaders: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "keep-alive",
                                                  "proxy-connection", "proxy-authorization", "upgrade", "te", "trailer", "accept-encoding"]

    private func forward(_ head: Head, body: Data?) {
        guard let root = upstream(), let url = URL(string: root.absoluteString + head.target) else {
            respond(502, "no relay selected in 切号"); return
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 900)
        request.httpMethod = head.method
        for (name, value) in head.headers where !Self.hopHeaders.contains(name.lowercased()) {
            request.addValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 900
        config.timeoutIntervalForResource = 6 * 3600
        config.urlCache = nil
        let delegateQueue = OperationQueue()
        delegateQueue.maxConcurrentOperationCount = 1
        delegateQueue.underlyingQueue = queue
        let session = URLSession(configuration: config, delegate: self, delegateQueue: delegateQueue)
        self.session = session
        session.dataTask(with: request).resume()
    }

    private var sentHead = false

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else { completionHandler(.cancel); return }
        var head = "HTTP/1.1 \(http.statusCode) \(HTTPURLResponse.localizedString(forStatusCode: http.statusCode).capitalized)\r\n"
        // URLSession already decoded the body, so its encoding and length no longer apply.
        let skip: Set<String> = ["content-length", "transfer-encoding", "connection", "content-encoding", "keep-alive"]
        for (key, value) in http.allHeaderFields {
            guard let name = key as? String, !skip.contains(name.lowercased()) else { continue }
            head += "\(name): \(value)\r\n"
        }
        head += "Transfer-Encoding: chunked\r\nConnection: close\r\n\r\n"
        sentHead = true
        send(Data(head.utf8))
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        var chunk = Data(String(data.count, radix: 16).utf8)
        chunk.append(Data("\r\n".utf8)); chunk.append(data); chunk.append(Data("\r\n".utf8))
        send(chunk)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        session.finishTasksAndInvalidate()
        self.session = nil
        if sentHead {
            connection.send(content: Data("0\r\n\r\n".utf8), completion: .contentProcessed { [weak self] _ in self?.close() })
        } else {
            respond(502, "relay unreachable: \((error as? URLError)?.code.rawValue ?? -1)")
        }
    }

    // MARK: Writing

    private func send(_ data: Data) {
        connection.send(content: data, completion: .contentProcessed { _ in })
    }

    private func respond(_ status: Int, _ message: String, extra: [String: String] = [:]) {
        let body = Data("{\"error\":{\"message\":\"\(message)\",\"type\":\"yuliang_proxy\"}}".utf8)
        var head = "HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status).capitalized)\r\n"
        head += "Content-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in extra { head += "\(name): \(value)\r\n" }
        head += "\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in self?.close() })
    }

    private func close() {
        guard !closed else { return }
        closed = true
        session?.invalidateAndCancel()
        session = nil
        connection.cancel()
        finished(self)
    }
}
