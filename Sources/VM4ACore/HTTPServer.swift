import Foundation
import Network

// MARK: - HTTP types

public struct HTTPRequest: Sendable {
    public let method: String
    public let path: String
    public let query: [String: String]
    public let headers: [String: String]
    public let body: Data

    public init(method: String, path: String, query: [String: String], headers: [String: String], body: Data) {
        self.method = method
        self.path = path
        self.query = query
        self.headers = headers
        self.body = body
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var contentType: String
    public var body: Data

    public init(status: Int = 200, contentType: String = "application/json", body: Data = Data()) {
        self.status = status
        self.contentType = contentType
        self.body = body
    }

    public static func json<T: Encodable>(_ value: T, status: Int = 200) -> HTTPResponse {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(value)) ?? Data("{}".utf8)
        return HTTPResponse(status: status, contentType: "application/json", body: data)
    }

    public static func error(_ status: Int, message: String) -> HTTPResponse {
        struct Err: Encodable { let error: String; let status: Int }
        return .json(Err(error: message, status: status), status: status)
    }

    public static let methodNotAllowed = HTTPResponse.error(405, message: "Method Not Allowed")
    public static let notFound = HTTPResponse.error(404, message: "Not Found")
    public static let unauthorized = HTTPResponse.error(401, message: "Unauthorized")
}

// MARK: - HTTP/1.1 wire format

enum HTTPWire {
    /// Try to parse a single request out of the buffer. Returns the request
    /// and the count of bytes consumed (so the caller can drop them), or
    /// nil if the buffer doesn't yet hold a complete request.
    static func parse(_ buffer: Data) throws -> (HTTPRequest, Int)? {
        guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return nil // need more bytes
        }
        let headerData = buffer[..<headerEndRange.lowerBound]
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw HTTPParseError("non-utf8 headers")
        }
        let lines = headerStr.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first else { throw HTTPParseError("empty request") }
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { throw HTTPParseError("bad request line: \(firstLine)") }
        let method = String(parts[0])
        let target = String(parts[1])

        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let colon = line.firstIndex(of: ":") {
                let name = String(line[..<colon]).lowercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                headers[name] = value
            }
        }

        let bodyStart = headerEndRange.upperBound
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let bodyEnd = bodyStart + contentLength
        guard buffer.count >= bodyEnd else { return nil } // need more bytes
        let body = buffer[bodyStart..<bodyEnd]

        let (path, query) = parsePathAndQuery(target)
        let request = HTTPRequest(
            method: method,
            path: path,
            query: query,
            headers: headers,
            body: Data(body)
        )
        return (request, bodyEnd)
    }

    private static func parsePathAndQuery(_ target: String) -> (String, [String: String]) {
        guard let q = target.firstIndex(of: "?") else { return (target, [:]) }
        let path = String(target[..<q])
        let queryStr = String(target[target.index(after: q)...])
        var dict: [String: String] = [:]
        for pair in queryStr.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            dict[key] = value
        }
        return (path, dict)
    }

    static func encode(_ response: HTTPResponse) -> Data {
        let reason = statusReason(response.status)
        var out = "HTTP/1.1 \(response.status) \(reason)\r\n"
        out += "Content-Type: \(response.contentType)\r\n"
        out += "Content-Length: \(response.body.count)\r\n"
        out += "Connection: close\r\n"
        out += "\r\n"
        var data = Data(out.utf8)
        data.append(response.body)
        return data
    }

    private static func statusReason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 500: return "Internal Server Error"
        default:  return "OK"
        }
    }
}

struct HTTPParseError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

// MARK: - Router

public typealias HTTPHandler = @Sendable (HTTPRequest) async -> HTTPResponse

public struct HTTPRoute: Sendable {
    public let method: String
    public let path: String
    public let handler: HTTPHandler

    public init(method: String, path: String, handler: @escaping HTTPHandler) {
        self.method = method.uppercased()
        self.path = path
        self.handler = handler
    }
}

public actor HTTPRouter {
    private var routes: [HTTPRoute]
    public init(routes: [HTTPRoute] = []) { self.routes = routes }
    public func add(_ route: HTTPRoute) { routes.append(route) }

    public func handle(_ request: HTTPRequest) async -> HTTPResponse {
        for r in routes where r.method == request.method && r.path == request.path {
            return await r.handler(request)
        }
        // Distinguish 405 vs 404
        let pathExists = routes.contains { $0.path == request.path }
        return pathExists ? HTTPResponse.methodNotAllowed : HTTPResponse.notFound
    }
}

// MARK: - vm4a HTTP routes

public struct VM4AHTTPServerConfig: Sendable {
    public var host: String
    public var port: UInt16
    public var executablePath: String
    public var authToken: String?

    public init(host: String = "127.0.0.1", port: UInt16 = 7777, executablePath: String, authToken: String? = nil) {
        self.host = host
        self.port = port
        self.executablePath = executablePath
        self.authToken = authToken
    }
}

@Sendable private func vm4aAuthorized(_ request: HTTPRequest, token: String?) -> Bool {
    guard let token, !token.isEmpty else { return true }
    let auth = request.headers["authorization"] ?? ""
    let prefix = "Bearer "
    return auth.hasPrefix(prefix) && String(auth.dropFirst(prefix.count)) == token
}

@Sendable private func vm4aDecodeArgs(_ body: Data) -> [String: JSONValue] {
    if body.isEmpty { return [:] }
    return (try? JSONDecoder().decode(JSONValue.self, from: body))?.objectValue ?? [:]
}

public func makeVM4ARouter(config: VM4AHTTPServerConfig) -> HTTPRouter {
    let executable = config.executablePath
    let token = config.authToken

    return HTTPRouter(routes: [
        HTTPRoute(method: "GET", path: "/v1/health") { _ in
            struct Health: Encodable { let status = "ok"; let version = "2.0.0" }
            return .json(Health())
        },

        HTTPRoute(method: "POST", path: "/v1/spawn") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            do {
                let args = vm4aDecodeArgs(req.body)
                let storageStr = args["storage"]?.stringValue ?? FileManager.default.currentDirectoryPath
                guard let name = args["name"]?.stringValue else {
                    return .error(400, message: "missing 'name'")
                }
                let memBytes = try args["memory_gb"]?.intValue.map { try bytesFromGB($0, fieldName: "memory_gb") }
                let diskBytes = try args["disk_gb"]?.intValue.map { try bytesFromGB($0, fieldName: "disk_gb") }
                let networkMode: NetworkMode = args["network"]?.stringValue.flatMap(NetworkMode.parse) ?? .nat
                let outcome = try await runSpawn(options: SpawnOptions(
                    name: name,
                    os: .linux,
                    storage: URL(fileURLWithPath: storageStr, isDirectory: true),
                    from: args["from"]?.stringValue,
                    imagePath: args["image"]?.stringValue,
                    cpu: args["cpu"]?.intValue,
                    memoryBytes: memBytes,
                    diskBytes: diskBytes,
                    networkMode: networkMode,
                    bridgedInterface: args["bridged_interface"]?.stringValue,
                    rosetta: args["rosetta"]?.boolValue ?? false,
                    restoreStateAt: args["restore"]?.stringValue,
                    saveOnStopAt: args["save_on_stop"]?.stringValue,
                    waitIP: args["wait_ip"]?.boolValue ?? false,
                    waitSSH: args["wait_ssh"]?.boolValue ?? false,
                    sshUser: args["ssh_user"]?.stringValue,
                    sshKey: args["ssh_key"]?.stringValue,
                    hostOverride: args["host"]?.stringValue,
                    waitTimeout: TimeInterval(args["wait_timeout"]?.intValue ?? 90)
                ), executable: executable)
                return .json(outcome)
            } catch {
                return .error(500, message: "\(error)")
            }
        },

        HTTPRoute(method: "POST", path: "/v1/exec") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            do {
                let args = vm4aDecodeArgs(req.body)
                guard let vmPath = args["vm_path"]?.stringValue else {
                    return .error(400, message: "missing 'vm_path'")
                }
                let cmd = args["command"]?.arrayValue?.compactMap { $0.stringValue } ?? []
                guard !cmd.isEmpty else {
                    return .error(400, message: "missing 'command' (array of strings)")
                }
                let result = try runExec(options: ExecOptions(
                    vmPath: vmPath,
                    user: args["user"]?.stringValue,
                    key: args["key"]?.stringValue,
                    hostOverride: args["host"]?.stringValue,
                    timeout: TimeInterval(args["timeout"]?.intValue ?? 60),
                    command: cmd
                ))
                return .json(result)
            } catch {
                return .error(500, message: "\(error)")
            }
        },

        HTTPRoute(method: "POST", path: "/v1/cp") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            do {
                let args = vm4aDecodeArgs(req.body)
                guard let vmPath = args["vm_path"]?.stringValue,
                      let source = args["source"]?.stringValue,
                      let destination = args["destination"]?.stringValue else {
                    return .error(400, message: "missing required field")
                }
                let result = try runCp(options: CpOptions(
                    vmPath: vmPath,
                    source: source,
                    destination: destination,
                    recursive: args["recursive"]?.boolValue ?? false,
                    user: args["user"]?.stringValue,
                    key: args["key"]?.stringValue,
                    hostOverride: args["host"]?.stringValue,
                    timeout: TimeInterval(args["timeout"]?.intValue ?? 300)
                ))
                return .json(result)
            } catch {
                return .error(500, message: "\(error)")
            }
        },

        HTTPRoute(method: "POST", path: "/v1/fork") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            do {
                let args = vm4aDecodeArgs(req.body)
                guard let src = args["source_path"]?.stringValue,
                      let dst = args["destination_path"]?.stringValue else {
                    return .error(400, message: "missing 'source_path' or 'destination_path'")
                }
                let outcome = try runFork(options: ForkOptions(
                    sourcePath: src,
                    destinationPath: dst,
                    fromSnapshot: args["from_snapshot"]?.stringValue,
                    autoStart: args["auto_start"]?.boolValue ?? false,
                    waitIP: args["wait_ip"]?.boolValue ?? false,
                    waitSSH: args["wait_ssh"]?.boolValue ?? false,
                    sshUser: args["ssh_user"]?.stringValue,
                    sshKey: args["ssh_key"]?.stringValue,
                    waitTimeout: TimeInterval(args["wait_timeout"]?.intValue ?? 90)
                ), executable: executable)
                return .json(outcome)
            } catch {
                return .error(500, message: "\(error)")
            }
        },

        HTTPRoute(method: "POST", path: "/v1/reset") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            do {
                let args = vm4aDecodeArgs(req.body)
                guard let vmPath = args["vm_path"]?.stringValue,
                      let from = args["from"]?.stringValue else {
                    return .error(400, message: "missing 'vm_path' or 'from'")
                }
                let outcome = try runReset(options: ResetOptions(
                    vmPath: vmPath,
                    fromSnapshot: from,
                    waitIP: args["wait_ip"]?.boolValue ?? false,
                    stopTimeout: TimeInterval(args["stop_timeout"]?.intValue ?? 20),
                    waitTimeout: TimeInterval(args["wait_timeout"]?.intValue ?? 60)
                ), executable: executable)
                return .json(outcome)
            } catch {
                return .error(500, message: "\(error)")
            }
        },

        HTTPRoute(method: "GET", path: "/v1/vms") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            let storageStr = req.query["storage"] ?? FileManager.default.currentDirectoryPath
            let rows = listVMSummaries(in: URL(fileURLWithPath: storageStr, isDirectory: true))
            return .json(rows)
        },

        HTTPRoute(method: "GET", path: "/v1/vms/ip") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            guard let path = req.query["path"] else {
                return .error(400, message: "missing 'path' query param")
            }
            do {
                let model = try loadModel(rootPath: URL(fileURLWithPath: path, isDirectory: true))
                struct Lease: Encodable { let ip: String; let mac: String; let name: String? }
                let rows = findLeasesForBundle(model).map {
                    Lease(ip: $0.ipAddress, mac: $0.hardwareAddress, name: $0.name)
                }
                return .json(rows)
            } catch {
                return .error(500, message: "\(error)")
            }
        },

        HTTPRoute(method: "POST", path: "/v1/vms/stop") { req in
            guard vm4aAuthorized(req, token: token) else { return .unauthorized }
            let args = vm4aDecodeArgs(req.body)
            guard let vmPath = args["vm_path"]?.stringValue else {
                return .error(400, message: "missing 'vm_path'")
            }
            let timeout = args["timeout"]?.intValue ?? 20
            do {
                let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
                guard let pid = readPID(from: model.runPIDURL) else {
                    return .error(404, message: "No run pid for \(vmPath)")
                }
                struct StopOutcome: Encodable {
                    let stopped: Bool; let pid: Int32; let forced: Bool?; let reason: String?
                }
                guard isProcessRunning(pid: pid) else {
                    clearPID(at: model.runPIDURL)
                    return .json(StopOutcome(stopped: false, pid: pid, forced: nil, reason: "process \(pid) already exited"))
                }
                _ = kill(pid, SIGTERM)
                let deadline = Date().addingTimeInterval(TimeInterval(timeout))
                while Date() < deadline {
                    if !isProcessRunning(pid: pid) {
                        clearPID(at: model.runPIDURL)
                        return .json(StopOutcome(stopped: true, pid: pid, forced: false, reason: nil))
                    }
                    try? await Task.sleep(nanoseconds: 250_000_000)
                }
                _ = kill(pid, SIGKILL)
                try? await Task.sleep(nanoseconds: 500_000_000)
                clearPID(at: model.runPIDURL)
                return .json(StopOutcome(stopped: true, pid: pid, forced: true, reason: nil))
            } catch {
                return .error(500, message: "\(error)")
            }
        }
    ])
}

// MARK: - Network framework server

public final class HTTPServer: @unchecked Sendable {
    private let listener: NWListener
    private let router: HTTPRouter
    private let queue = DispatchQueue(label: "vm4a.http.listener")
    private let sessionsLock = NSLock()
    private var sessions: Set<ObjectIdentifier> = []
    private var sessionStore: [ObjectIdentifier: HTTPSession] = [:]
    private var stopped = false

    public init(host: String, port: UInt16, router: HTTPRouter) throws {
        let parameters = NWParameters.tcp
        parameters.acceptLocalOnly = (host == "127.0.0.1" || host == "localhost")
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw VM4AError.message("invalid port \(port)")
        }
        self.listener = try NWListener(using: parameters, on: nwPort)
        self.router = router
    }

    public func start() {
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.start(queue: queue)
    }

    public func stop() {
        stopped = true
        listener.cancel()
    }

    private func accept(_ connection: NWConnection) {
        let session = HTTPSession(connection: connection, router: router) { [weak self] sid in
            self?.removeSession(sid)
        }
        let sid = ObjectIdentifier(session)
        sessionsLock.lock()
        sessions.insert(sid)
        sessionStore[sid] = session
        sessionsLock.unlock()
        session.start()
    }

    private func removeSession(_ sid: ObjectIdentifier) {
        sessionsLock.lock()
        sessions.remove(sid)
        sessionStore.removeValue(forKey: sid)
        sessionsLock.unlock()
    }
}

private final class HTTPSession: @unchecked Sendable {
    private let connection: NWConnection
    private let router: HTTPRouter
    private var buffer = Data()
    private let queue = DispatchQueue(label: "vm4a.http.session")
    private let onClose: @Sendable (ObjectIdentifier) -> Void

    init(
        connection: NWConnection,
        router: HTTPRouter,
        onClose: @escaping @Sendable (ObjectIdentifier) -> Void
    ) {
        self.connection = connection
        self.router = router
        self.onClose = onClose
    }

    func start() {
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [self] data, _, isComplete, error in
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.tryServe()
            }
            if error != nil {
                self.close()
                return
            }
            if isComplete {
                self.close()
                return
            }
            self.receive()
        }
    }

    private func tryServe() {
        let parsed: (HTTPRequest, Int)?
        do {
            parsed = try HTTPWire.parse(buffer)
        } catch {
            send(.error(400, message: "Bad Request: \(error)"))
            return
        }
        guard let (request, consumed) = parsed else { return }
        buffer.removeSubrange(0..<consumed)
        Task {
            let response = await self.router.handle(request)
            self.send(response)
        }
    }

    private func send(_ response: HTTPResponse) {
        let bytes = HTTPWire.encode(response)
        connection.send(content: bytes, completion: .contentProcessed { [self] _ in
            self.close()
        })
    }

    private func close() {
        connection.cancel()
        onClose(ObjectIdentifier(self))
    }
}
