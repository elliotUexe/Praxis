import Foundation
import Network
import MCP

/// A loopback-only HTTP/1.1 listener, just wide enough for MCP.
///
/// The MCP SDK's HTTP server transport is framework-agnostic: it hands us
/// `handleRequest(HTTPRequest) -> HTTPResponse` and expects the caller to bring the socket.
/// What MCP actually sends is a `POST /mcp` with a JSON body and a handful of headers, so
/// the parsing needed is small and bounded — read up to the blank line, take
/// `Content-Length`, read that many bytes. That is why this is `NWListener` and a hundred
/// lines rather than Vapor or Hummingbird inside a note-taking app that already carries
/// MLX and WhisperKit.
///
/// Bound to `127.0.0.1` explicitly, never to all interfaces: nothing outside this machine
/// can reach it, whatever the firewall says.
final class LocalHTTPListener: @unchecked Sendable {
    typealias Handler = @Sendable (HTTPRequest) async -> HTTPResponse

    private let port: UInt16
    private let handler: Handler
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "praxis.mcp.http", qos: .userInitiated)

    /// Requests larger than this are refused outright. A tool call carrying a task title
    /// and a description is a few kilobytes; a megabyte is not a legitimate request.
    private static let maximumBodyBytes = 1 << 20

    init(port: UInt16, handler: @escaping Handler) {
        self.port = port
        self.handler = handler
    }

    func start() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!
        )
        let listener = try NWListener(using: parameters)
        listener.newConnectionHandler = { [weak self] connection in
            self?.serve(connection)
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - One connection

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        readRequest(on: connection, buffered: Data())
    }

    /// Accumulates bytes until the head is complete and the body has arrived, then answers.
    /// HTTP/1.1 keep-alive is honoured minimally: after a response the loop reads the next
    /// request on the same connection, which is how `mcp-remote` talks.
    private func readRequest(on connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let chunk { buffer.append(chunk) }

            if error != nil || (isComplete && buffer.isEmpty) {
                connection.cancel()
                return
            }

            switch Self.parse(buffer) {
            case .incomplete:
                if buffer.count > Self.maximumBodyBytes + 8192 {
                    self.respond(on: connection, status: 413, body: "Payload too large", keepAlive: false)
                } else {
                    self.readRequest(on: connection, buffered: buffer)
                }
            case .malformed:
                self.respond(on: connection, status: 400, body: "Bad request", keepAlive: false)
            case let .request(request, consumed):
                let remainder = buffer.subdata(in: consumed..<buffer.count)
                Task {
                    let response = await self.handler(request)
                    self.write(response, on: connection) {
                        self.readRequest(on: connection, buffered: remainder)
                    }
                }
            }
        }
    }

    // MARK: - Parsing

    private enum Parsed {
        case incomplete
        case malformed
        case request(HTTPRequest, consumed: Int)
    }

    private static func parse(_ data: Data) -> Parsed {
        guard let headEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return .incomplete }
        guard let head = String(data: data.subdata(in: 0..<headEnd.lowerBound), encoding: .utf8) else {
            return .malformed
        }

        var lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .malformed }
        lines.removeFirst()
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .malformed }
        let method = String(parts[0])
        let path = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            headers[name] = value
        }

        let bodyStart = headEnd.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maximumBodyBytes else { return .malformed }
        guard data.count >= bodyStart + length else { return .incomplete }
        let body = length > 0 ? data.subdata(in: bodyStart..<(bodyStart + length)) : nil

        let request = HTTPRequest(method: method, headers: headers, body: body, path: path)
        return .request(request, consumed: bodyStart + length)
    }

    // MARK: - Writing

    private func write(_ response: HTTPResponse, on connection: NWConnection, then next: @escaping () -> Void) {
        switch response {
        case let .data(data, headers):
            send(status: 200, headers: headers, body: data, on: connection, then: next)
        case let .ok(headers):
            send(status: 200, headers: headers, body: Data(), on: connection, then: next)
        case let .accepted(headers):
            send(status: 202, headers: headers, body: Data(), on: connection, then: next)
        case let .error(statusCode, error, _, extraHeaders):
            let body = Data("{\"error\":\"\(error.localizedDescription)\"}".utf8)
            var headers = extraHeaders
            headers["Content-Type"] = "application/json"
            send(status: statusCode, headers: headers, body: body, on: connection, then: next)
        case .stream:
            // Only the stateless transport is used, which never streams. If that changes,
            // this is the case to implement — not one to silently swallow.
            respond(on: connection, status: 501, body: "Streaming not supported", keepAlive: false)
        }
    }

    private func respond(on connection: NWConnection, status: Int, body: String, keepAlive: Bool) {
        send(status: status, headers: ["Content-Type": "text/plain"], body: Data(body.utf8), on: connection) {
            if !keepAlive { connection.cancel() }
        }
    }

    private func send(status: Int, headers: [String: String], body: Data, on connection: NWConnection, then next: @escaping () -> Void) {
        var head = "HTTP/1.1 \(status) \(Self.reason(for: status))\r\n"
        var merged = headers
        merged["Content-Length"] = String(body.count)
        merged["Connection"] = "keep-alive"
        for (name, value) in merged {
            head += "\(name): \(value)\r\n"
        }
        head += "\r\n"
        var payload = Data(head.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { _ in next() })
    }

    private static func reason(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 202: return "Accepted"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 501: return "Not Implemented"
        default: return "Error"
        }
    }
}
