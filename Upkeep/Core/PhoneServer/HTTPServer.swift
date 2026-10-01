import Foundation
import Network

/// Just enough HTTP/1.1 for the phone server: one request per connection, GET and POST with
/// `Content-Length`, no chunked bodies. Runs on its own queue; handlers hop to the main actor.
final class HTTPServer: @unchecked Sendable {
    struct Request: Sendable {
        var method: String
        var path: String
        var query: String
        var headers: [String: String]
        var body: Data
        /// The device's address, e.g. "192.168.1.23".
        var client = ""

        func header(_ name: String) -> String? { headers[name.lowercased()] }
    }

    struct Response: Sendable {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()

        static func text(_ status: Int, _ text: String) -> Response {
            Response(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
        }

        static func json(_ status: Int, _ object: Any) -> Response {
            let data = (try? JSONSerialization.data(withJSONObject: object)) ?? Data("{}".utf8)
            return Response(status: status, headers: ["Content-Type": "application/json"], body: data)
        }

        static func redirect(_ location: String) -> Response {
            Response(status: 302, headers: ["Location": location])
        }
    }

    typealias Handler = @Sendable (Request) async -> Response

    static let maxBody = 32 * 1024 * 1024

    private let listener: NWListener
    private let queue = DispatchQueue(label: "upkeep.http")
    private let handler: Handler
    var onStateChange: (@Sendable (NWListener.State) -> Void)?
    /// A client dropped the TLS handshake, e.g. a phone that doesn't trust the home certificate yet.
    var onTLSFailure: (@Sendable (_ client: String, _ status: OSStatus) -> Void)?

    init(port: UInt16, tls: NWProtocolTLS.Options?, handler: @escaping Handler) throws {
        let tcp = NWProtocolTCP.Options()
        let params = tls.map { NWParameters(tls: $0, tcp: tcp) } ?? NWParameters(tls: nil, tcp: tcp)
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        self.handler = handler
    }

    func start() {
        listener.stateUpdateHandler = { [weak self] state in self?.onStateChange?(state) }
        listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
        listener.start(queue: queue)
    }

    func stop() {
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let client: String = {
            if case .hostPort(let host, _) = connection.endpoint { return "\(host)".components(separatedBy: "%").first ?? "\(host)" }
            return "\(connection.endpoint)"
        }()
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed(let error), .waiting(let error):
                if case .tls(let status) = error { self?.onTLSFailure?(client, status) }
                connection.cancel()
            default: break
            }
        }
        connection.start(queue: queue)
        receive(on: connection, buffer: Data(), client: client)
        // Idle or stuck clients don't hold a connection forever.
        queue.asyncAfter(deadline: .now() + 60) { connection.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data, client: String) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let error {
                if case .tls(let status) = error { self.onTLSFailure?(client, status) }
                #if DEBUG
                NSLog("http: %@ connection error %@", client, "\(error)")
                #endif
                connection.cancel()
                return
            }
            switch Self.parse(buffer) {
            case .complete(var request):
                request.client = client
                Task {
                    let response = await self.handler(request)
                    self.send(response, for: request, on: connection)
                }
            case .incomplete where !isComplete:
                self.receive(on: connection, buffer: buffer, client: client)
            case .incomplete, .invalid:
                self.send(.text(400, "Bad request"), for: nil, on: connection)
            case .tooLarge:
                self.send(.text(413, "Too large"), for: nil, on: connection)
            }
        }
    }

    private enum ParseResult { case complete(Request), incomplete, invalid, tooLarge }

    private static func parse(_ buffer: Data) -> ParseResult {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return buffer.count > 64 * 1024 ? .invalid : .incomplete
        }
        guard let head = String(data: buffer[..<end.lowerBound], encoding: .utf8) else { return .invalid }
        var lines = head.components(separatedBy: "\r\n")
        let parts = lines.removeFirst().split(separator: " ")
        guard parts.count >= 2 else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let length = Int(headers["content-length"] ?? "0") ?? 0
        guard length <= maxBody else { return .tooLarge }
        let bodyStart = end.upperBound
        guard buffer.count - bodyStart >= length else { return .incomplete }
        let target = String(parts[1])
        let pathPart = target.split(separator: "?", maxSplits: 1).map(String.init)
        let path = pathPart.first?.removingPercentEncoding ?? "/"
        return .complete(Request(method: String(parts[0]).uppercased(), path: path,
                                 query: pathPart.count > 1 ? pathPart[1] : "",
                                 headers: headers, body: buffer[bodyStart..<(bodyStart + length)]))
    }

    private func send(_ response: Response, for request: Request?, on connection: NWConnection) {
        var head = "HTTP/1.1 \(response.status) \(Self.reason(response.status))\r\n"
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["X-Content-Type-Options"] = "nosniff"
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var data = Data(head.utf8)
        if request?.method != "HEAD" { data.append(response.body) }
        // "Processed" only means queued, not delivered. Cancelling then tore the connection down
        // with the response still in flight, leaving nothing to resend whatever Wi-Fi dropped — so
        // phones lost the end of larger files (sw.js among them, so no offline copy ever installed),
        // while the Mac talking to itself never did. End our side instead, and close once the
        // client has read it all and hung up (or the idle limit in `accept` comes first).
        connection.send(content: data, contentContext: .finalMessage, isComplete: true, completion: .contentProcessed { [weak self] _ in
            self?.closeWhenClientDoes(connection)
        })
    }

    private func closeWhenClientDoes(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, isComplete, error in
            if isComplete || error != nil { connection.cancel() } else { self?.closeWhenClientDoes(connection) }
        }
    }

    private static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 204: "No Content"
        case 302: "Found"
        case 304: "Not Modified"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 409: "Conflict"
        case 413: "Payload Too Large"
        case 422: "Unprocessable Content"
        case 503: "Service Unavailable"
        default: "Status"
        }
    }
}
