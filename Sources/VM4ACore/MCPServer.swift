import Foundation

// MARK: - JSONValue: a heterogeneous JSON node, used by JSON-RPC params/results.

public enum JSONValue: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null; return
        }
        if let v = try? c.decode(Bool.self) { self = .bool(v); return }
        if let v = try? c.decode(Int64.self) { self = .int(v); return }
        if let v = try? c.decode(Double.self) { self = .double(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        if let v = try? c.decode([JSONValue].self) { self = .array(v); return }
        if let v = try? c.decode([String: JSONValue].self) { self = .object(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null:                   try c.encodeNil()
        case .bool(let v):            try c.encode(v)
        case .int(let v):             try c.encode(v)
        case .double(let v):          try c.encode(v)
        case .string(let v):          try c.encode(v)
        case .array(let v):           try c.encode(v)
        case .object(let v):          try c.encode(v)
        }
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }; return nil
    }
    public var intValue: Int? {
        if case .int(let v) = self { return Int(v) }
        if case .double(let v) = self { return Int(v) }
        return nil
    }
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }; return nil
    }
    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }; return nil
    }
    public var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }; return nil
    }
}

// MARK: - JSON-RPC 2.0 message types

public enum JSONRPCID: Codable, Sendable, Equatable {
    case number(Int64)
    case string(String)
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null; return }
        if let v = try? c.decode(Int64.self) { self = .number(v); return }
        if let v = try? c.decode(String.self) { self = .string(v); return }
        throw DecodingError.dataCorruptedError(in: c, debugDescription: "id must be string, number, or null")
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .number(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .null:          try c.encodeNil()
        }
    }
}

public struct JSONRPCRequest: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID?
    public let method: String
    public let params: JSONValue?

    public init(jsonrpc: String = "2.0", id: JSONRPCID?, method: String, params: JSONValue?) {
        self.jsonrpc = jsonrpc
        self.id = id
        self.method = method
        self.params = params
    }
}

public struct JSONRPCError: Codable, Sendable {
    public let code: Int
    public let message: String
    public let data: JSONValue?

    public init(code: Int, message: String, data: JSONValue? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }

    public static let parseError      = -32700
    public static let invalidRequest  = -32600
    public static let methodNotFound  = -32601
    public static let invalidParams   = -32602
    public static let internalError   = -32603
}

public struct JSONRPCResponse: Codable, Sendable {
    public let jsonrpc: String
    public let id: JSONRPCID
    public let result: JSONValue?
    public let error: JSONRPCError?

    public init(id: JSONRPCID, result: JSONValue) {
        self.jsonrpc = "2.0"; self.id = id; self.result = result; self.error = nil
    }
    public init(id: JSONRPCID, error: JSONRPCError) {
        self.jsonrpc = "2.0"; self.id = id; self.result = nil; self.error = error
    }
}

// MARK: - Helpers to convert Codable types to JSONValue

public func jsonValue<T: Encodable>(_ value: T) throws -> JSONValue {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(JSONValue.self, from: data)
}

public func decodeJSONValue<T: Decodable>(_ value: JSONValue, as type: T.Type) throws -> T {
    let encoder = JSONEncoder()
    let data = try encoder.encode(value)
    return try JSONDecoder().decode(type, from: data)
}

// MARK: - MCP types

public struct MCPTool: Codable, Sendable {
    public let name: String
    public let description: String
    public let inputSchema: JSONValue

    public init(name: String, description: String, inputSchema: JSONValue) {
        self.name = name; self.description = description; self.inputSchema = inputSchema
    }
}

public struct MCPContent: Codable, Sendable {
    public let type: String
    public let text: String

    public init(text: String) { self.type = "text"; self.text = text }
}

public struct MCPCallResult: Codable, Sendable {
    public let content: [MCPContent]
    public let isError: Bool

    public init(content: [MCPContent], isError: Bool = false) {
        self.content = content; self.isError = isError
    }
}

public struct MCPInitializeResult: Codable, Sendable {
    public let protocolVersion: String
    public let capabilities: JSONValue
    public let serverInfo: ServerInfo

    public struct ServerInfo: Codable, Sendable {
        public let name: String
        public let version: String
    }
}

public struct MCPToolsListResult: Codable, Sendable {
    public let tools: [MCPTool]
}

// MARK: - Tool registry

public protocol MCPTransport: Sendable {
    func readLine() throws -> String?
    func write(_ line: String) throws
}

public struct MCPServerConfig: Sendable {
    public var serverName: String
    public var serverVersion: String
    public var protocolVersion: String
    public var executablePath: String

    public init(
        serverName: String = "vm4a",
        serverVersion: String = "2.0.0",
        protocolVersion: String = "2024-11-05",
        executablePath: String
    ) {
        self.serverName = serverName
        self.serverVersion = serverVersion
        self.protocolVersion = protocolVersion
        self.executablePath = executablePath
    }
}

public actor MCPServer {
    private let config: MCPServerConfig
    private let transport: MCPTransport

    public init(config: MCPServerConfig, transport: MCPTransport) {
        self.config = config
        self.transport = transport
    }

    public func run() async throws {
        while let line = try transport.readLine() {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            await handleLine(trimmed)
        }
    }

    func handleLine(_ line: String) async {
        guard let data = line.data(using: .utf8) else { return }
        let req: JSONRPCRequest
        do {
            req = try JSONDecoder().decode(JSONRPCRequest.self, from: data)
        } catch {
            // Parse error: send error with null id only if we can't read id
            send(.init(id: .null, error: .init(code: JSONRPCError.parseError, message: "Parse error: \(error)")))
            return
        }
        let response = await dispatch(request: req)
        if let response { send(response) }
    }

    func dispatch(request: JSONRPCRequest) async -> JSONRPCResponse? {
        // Notifications (no id) get no response.
        let isNotification = request.id == nil
        let id = request.id ?? .null

        switch request.method {
        case "initialize":
            let result = MCPInitializeResult(
                protocolVersion: config.protocolVersion,
                capabilities: .object(["tools": .object([:])]),
                serverInfo: .init(name: config.serverName, version: config.serverVersion)
            )
            return wrap(id: id, result: result)

        case "notifications/initialized", "notifications/cancelled":
            return nil

        case "ping":
            return .init(id: id, result: .object([:]))

        case "tools/list":
            return wrap(id: id, result: MCPToolsListResult(tools: vm4aTools()))

        case "tools/call":
            do {
                let call = try parseToolCall(request.params)
                let outcome = try await runTool(name: call.name, arguments: call.arguments)
                return wrap(id: id, result: outcome)
            } catch let err as MCPCallError {
                let errResult = MCPCallResult(content: [.init(text: err.message)], isError: true)
                if let v = try? jsonValue(errResult) {
                    return .init(id: id, result: v)
                }
                return .init(id: id, error: .init(code: JSONRPCError.internalError, message: err.message))
            } catch {
                return .init(id: id, error: .init(code: JSONRPCError.internalError, message: "\(error)"))
            }

        default:
            if isNotification { return nil }
            return .init(id: id, error: .init(code: JSONRPCError.methodNotFound, message: "Method not found: \(request.method)"))
        }
    }

    // MARK: - Tool definitions

    func vm4aTools() -> [MCPTool] {
        return [
            MCPTool(
                name: "spawn",
                description: "Create + start a VM in one shot. If <storage>/<name> exists, just (re)starts it; else uses --from <oci-ref> or --image <iso>. Returns {id, name, path, os, pid, ip, ssh_ready}.",
                inputSchema: schemaObject(
                    required: ["name"],
                    properties: [
                        "name": schemaString("VM name (becomes <storage>/<name>)"),
                        "os": schemaEnum(["linux", "macOS"], description: "Default linux"),
                        "storage": schemaString("Parent directory for bundles. Default cwd."),
                        "from": schemaString("OCI reference to pull if bundle missing"),
                        "image": schemaString("Local ISO/IPSW path to install fresh"),
                        "cpu": schemaInteger("vCPU count"),
                        "memory_gb": schemaInteger("Memory in GB"),
                        "disk_gb": schemaInteger("Disk size in GB"),
                        "bridged_interface": schemaString("Bridged interface bsdName"),
                        "rosetta": schemaBoolean("Enable Rosetta share (Linux only)"),
                        "restore": schemaString(".vzstate path to restore on start"),
                        "save_on_stop": schemaString(".vzstate path to save on clean stop"),
                        "wait_ip": schemaBoolean("Wait for NAT DHCP IP"),
                        "wait_ssh": schemaBoolean("Wait for SSH; implies wait_ip"),
                        "ssh_user": schemaString("SSH user for wait_ssh probe"),
                        "ssh_key": schemaString("SSH private key path"),
                        "host": schemaString("Override IP (skip DHCP lookup)"),
                        "wait_timeout": schemaInteger("Seconds for IP/SSH wait. Default 90.")
                    ]
                )
            ),
            MCPTool(
                name: "exec",
                description: "Run a command in a running VM via SSH. Returns {exit_code, stdout, stderr, duration_ms, timed_out}.",
                inputSchema: schemaObject(
                    required: ["vm_path", "command"],
                    properties: [
                        "vm_path": schemaString("Path to VM bundle"),
                        "command": schemaArray(of: schemaString(""), description: "argv to run in the guest"),
                        "user": schemaString("SSH user. Default root for linux, current user for macOS."),
                        "key": schemaString("SSH private key path"),
                        "host": schemaString("Override target IP"),
                        "timeout": schemaInteger("Wall-clock timeout seconds. Default 60.")
                    ]
                )
            ),
            MCPTool(
                name: "cp",
                description: "Copy a file between host and guest via SCP. Use ':' prefix on a path to mark it as guest-side. Exactly one side must be guest.",
                inputSchema: schemaObject(
                    required: ["vm_path", "source", "destination"],
                    properties: [
                        "vm_path": schemaString("Path to VM bundle"),
                        "source": schemaString("Source path. ':' prefix = guest."),
                        "destination": schemaString("Destination path. ':' prefix = guest."),
                        "recursive": schemaBoolean("Recursive copy (-r)"),
                        "user": schemaString("SSH user"),
                        "key": schemaString("SSH key path"),
                        "host": schemaString("Override IP"),
                        "timeout": schemaInteger("Timeout seconds. Default 300.")
                    ]
                )
            ),
            MCPTool(
                name: "fork",
                description: "APFS-clone a VM bundle, re-randomise MachineIdentifier, optionally auto-start with snapshot restore. Designed for parallel agent traces.",
                inputSchema: schemaObject(
                    required: ["source_path", "destination_path"],
                    properties: [
                        "source_path": schemaString("Source bundle path"),
                        "destination_path": schemaString("Destination bundle path"),
                        "from_snapshot": schemaString(".vzstate path to restore"),
                        "auto_start": schemaBoolean("Start the fork after cloning"),
                        "wait_ip": schemaBoolean("Wait for IP after auto-start"),
                        "wait_ssh": schemaBoolean("Wait for SSH"),
                        "ssh_user": schemaString("SSH user for probe"),
                        "ssh_key": schemaString("SSH key path"),
                        "wait_timeout": schemaInteger("Seconds. Default 90.")
                    ]
                )
            ),
            MCPTool(
                name: "reset",
                description: "Stop a VM if running, then start it from a .vzstate snapshot. For try → fail → reset → retry agent loops.",
                inputSchema: schemaObject(
                    required: ["vm_path", "from"],
                    properties: [
                        "vm_path": schemaString("Path to VM bundle"),
                        "from": schemaString(".vzstate snapshot to restore"),
                        "wait_ip": schemaBoolean("Wait for IP after restart"),
                        "stop_timeout": schemaInteger("Stop timeout seconds. Default 20."),
                        "wait_timeout": schemaInteger("IP wait timeout seconds. Default 60.")
                    ]
                )
            ),
            MCPTool(
                name: "list",
                description: "List VM bundles in a directory. Returns array of {id, name, path, os, status, pid, ip}.",
                inputSchema: schemaObject(
                    required: [],
                    properties: [
                        "storage": schemaString("Parent directory. Default cwd.")
                    ]
                )
            ),
            MCPTool(
                name: "ip",
                description: "Resolve a NAT VM's IP via Apple's DHCP leases. Returns array of {ip, mac, name?}.",
                inputSchema: schemaObject(
                    required: ["vm_path"],
                    properties: [
                        "vm_path": schemaString("Path to VM bundle")
                    ]
                )
            ),
            MCPTool(
                name: "stop",
                description: "Send SIGTERM (then SIGKILL if needed) to the worker for a running VM.",
                inputSchema: schemaObject(
                    required: ["vm_path"],
                    properties: [
                        "vm_path": schemaString("Path to VM bundle"),
                        "timeout": schemaInteger("Wait timeout seconds. Default 20.")
                    ]
                )
            )
        ]
    }

    // MARK: - Tool dispatcher

    struct ToolCall: Sendable {
        let name: String
        let arguments: JSONValue
    }

    func parseToolCall(_ params: JSONValue?) throws -> ToolCall {
        guard let params, let obj = params.objectValue else {
            throw MCPCallError("tools/call params must be an object")
        }
        guard let name = obj["name"]?.stringValue else {
            throw MCPCallError("tools/call missing 'name'")
        }
        let args = obj["arguments"] ?? .object([:])
        return ToolCall(name: name, arguments: args)
    }

    func runTool(name: String, arguments: JSONValue) async throws -> MCPCallResult {
        let exec = config.executablePath
        switch name {
        case "spawn":     return try await callSpawn(arguments, executable: exec)
        case "exec":      return try callExec(arguments)
        case "cp":        return try callCp(arguments)
        case "fork":      return try callFork(arguments, executable: exec)
        case "reset":     return try callReset(arguments, executable: exec)
        case "list":      return try callList(arguments)
        case "ip":        return try callIP(arguments)
        case "stop":      return try callStop(arguments)
        default:
            throw MCPCallError("Unknown tool: \(name)")
        }
    }

    // MARK: - Per-tool wrappers

    func callSpawn(_ args: JSONValue, executable: String) async throws -> MCPCallResult {
        let obj = args.objectValue ?? [:]
        let storageStr = obj["storage"]?.stringValue ?? FileManager.default.currentDirectoryPath
        let storageURL = URL(fileURLWithPath: storageStr, isDirectory: true)
        guard let name = obj["name"]?.stringValue else {
            throw MCPCallError("spawn: 'name' required")
        }
        let osStr = obj["os"]?.stringValue ?? "linux"
        guard let os = VMOSType(rawValue: osStr) else {
            throw MCPCallError("spawn: invalid os '\(osStr)'")
        }
        let memBytes = try obj["memory_gb"]?.intValue.map { try bytesFromGB($0, fieldName: "memory_gb") }
        let diskBytes = try obj["disk_gb"]?.intValue.map { try bytesFromGB($0, fieldName: "disk_gb") }
        let options = SpawnOptions(
            name: name,
            os: os,
            storage: storageURL,
            from: obj["from"]?.stringValue,
            imagePath: obj["image"]?.stringValue,
            cpu: obj["cpu"]?.intValue,
            memoryBytes: memBytes,
            diskBytes: diskBytes,
            bridgedInterface: obj["bridged_interface"]?.stringValue,
            rosetta: obj["rosetta"]?.boolValue ?? false,
            restoreStateAt: obj["restore"]?.stringValue,
            saveOnStopAt: obj["save_on_stop"]?.stringValue,
            waitIP: obj["wait_ip"]?.boolValue ?? false,
            waitSSH: obj["wait_ssh"]?.boolValue ?? false,
            sshUser: obj["ssh_user"]?.stringValue,
            sshKey: obj["ssh_key"]?.stringValue,
            hostOverride: obj["host"]?.stringValue,
            waitTimeout: TimeInterval(obj["wait_timeout"]?.intValue ?? 90)
        )
        let outcome = try await runSpawn(options: options, executable: executable)
        return try textResult(outcome)
    }

    func callExec(_ args: JSONValue) throws -> MCPCallResult {
        let obj = args.objectValue ?? [:]
        guard let vmPath = obj["vm_path"]?.stringValue else { throw MCPCallError("exec: 'vm_path' required") }
        guard let cmdArr = obj["command"]?.arrayValue else { throw MCPCallError("exec: 'command' required (array of strings)") }
        let command = cmdArr.compactMap { $0.stringValue }
        let result = try runExec(options: ExecOptions(
            vmPath: vmPath,
            user: obj["user"]?.stringValue,
            key: obj["key"]?.stringValue,
            hostOverride: obj["host"]?.stringValue,
            timeout: TimeInterval(obj["timeout"]?.intValue ?? 60),
            command: command
        ))
        return try textResult(result, isError: result.exitCode != 0)
    }

    func callCp(_ args: JSONValue) throws -> MCPCallResult {
        let obj = args.objectValue ?? [:]
        guard let vmPath = obj["vm_path"]?.stringValue else { throw MCPCallError("cp: 'vm_path' required") }
        guard let source = obj["source"]?.stringValue else { throw MCPCallError("cp: 'source' required") }
        guard let destination = obj["destination"]?.stringValue else { throw MCPCallError("cp: 'destination' required") }
        let result = try runCp(options: CpOptions(
            vmPath: vmPath,
            source: source,
            destination: destination,
            recursive: obj["recursive"]?.boolValue ?? false,
            user: obj["user"]?.stringValue,
            key: obj["key"]?.stringValue,
            hostOverride: obj["host"]?.stringValue,
            timeout: TimeInterval(obj["timeout"]?.intValue ?? 300)
        ))
        return try textResult(result, isError: result.exitCode != 0)
    }

    func callFork(_ args: JSONValue, executable: String) throws -> MCPCallResult {
        let obj = args.objectValue ?? [:]
        guard let src = obj["source_path"]?.stringValue else { throw MCPCallError("fork: 'source_path' required") }
        guard let dst = obj["destination_path"]?.stringValue else { throw MCPCallError("fork: 'destination_path' required") }
        let outcome = try runFork(options: ForkOptions(
            sourcePath: src,
            destinationPath: dst,
            fromSnapshot: obj["from_snapshot"]?.stringValue,
            autoStart: obj["auto_start"]?.boolValue ?? false,
            waitIP: obj["wait_ip"]?.boolValue ?? false,
            waitSSH: obj["wait_ssh"]?.boolValue ?? false,
            sshUser: obj["ssh_user"]?.stringValue,
            sshKey: obj["ssh_key"]?.stringValue,
            waitTimeout: TimeInterval(obj["wait_timeout"]?.intValue ?? 90)
        ), executable: executable)
        return try textResult(outcome)
    }

    func callReset(_ args: JSONValue, executable: String) throws -> MCPCallResult {
        let obj = args.objectValue ?? [:]
        guard let vmPath = obj["vm_path"]?.stringValue else { throw MCPCallError("reset: 'vm_path' required") }
        guard let from = obj["from"]?.stringValue else { throw MCPCallError("reset: 'from' required") }
        let outcome = try runReset(options: ResetOptions(
            vmPath: vmPath,
            fromSnapshot: from,
            waitIP: obj["wait_ip"]?.boolValue ?? false,
            stopTimeout: TimeInterval(obj["stop_timeout"]?.intValue ?? 20),
            waitTimeout: TimeInterval(obj["wait_timeout"]?.intValue ?? 60)
        ), executable: executable)
        return try textResult(outcome)
    }

    func callList(_ args: JSONValue) throws -> MCPCallResult {
        let obj = args.objectValue ?? [:]
        let storageStr = obj["storage"]?.stringValue ?? FileManager.default.currentDirectoryPath
        let rows = listVMSummaries(in: URL(fileURLWithPath: storageStr, isDirectory: true))
        return try textResult(rows)
    }

    func callIP(_ args: JSONValue) throws -> MCPCallResult {
        let obj = args.objectValue ?? [:]
        guard let vmPath = obj["vm_path"]?.stringValue else { throw MCPCallError("ip: 'vm_path' required") }
        let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
        struct Lease: Codable { let ip: String; let mac: String; let name: String? }
        let rows = findLeasesForBundle(model).map { Lease(ip: $0.ipAddress, mac: $0.hardwareAddress, name: $0.name) }
        return try textResult(rows)
    }

    func callStop(_ args: JSONValue) throws -> MCPCallResult {
        struct StopOutcome: Codable {
            let stopped: Bool
            let pid: Int32?
            let forced: Bool?
            let reason: String?
        }
        let obj = args.objectValue ?? [:]
        guard let vmPath = obj["vm_path"]?.stringValue else { throw MCPCallError("stop: 'vm_path' required") }
        let timeout = obj["timeout"]?.intValue ?? 20
        let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
        guard let pid = readPID(from: model.runPIDURL) else {
            throw MCPCallError("No run pid for \(vmPath)")
        }
        guard isProcessRunning(pid: pid) else {
            clearPID(at: model.runPIDURL)
            return try textResult(StopOutcome(stopped: false, pid: pid, forced: nil, reason: "process \(pid) already exited"))
        }
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if !isProcessRunning(pid: pid) {
                clearPID(at: model.runPIDURL)
                return try textResult(StopOutcome(stopped: true, pid: pid, forced: false, reason: nil))
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        _ = kill(pid, SIGKILL)
        Thread.sleep(forTimeInterval: 0.5)
        clearPID(at: model.runPIDURL)
        return try textResult(StopOutcome(stopped: true, pid: pid, forced: true, reason: nil))
    }

    // MARK: - Output helpers

    func wrap<T: Encodable>(id: JSONRPCID, result: T) -> JSONRPCResponse {
        do {
            let v = try jsonValue(result)
            return .init(id: id, result: v)
        } catch {
            return .init(id: id, error: .init(code: JSONRPCError.internalError, message: "\(error)"))
        }
    }

    func textResult<T: Encodable>(_ value: T, isError: Bool = false) throws -> MCPCallResult {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let data = try encoder.encode(value)
        let text = String(data: data, encoding: .utf8) ?? "{}"
        return MCPCallResult(content: [.init(text: text)], isError: isError)
    }

    func send(_ response: JSONRPCResponse) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            let data = try encoder.encode(response)
            var line = String(data: data, encoding: .utf8) ?? "{}"
            line += "\n"
            try transport.write(line)
        } catch {
            // Best effort: drop on the floor. The peer will time out.
        }
    }

}

// MARK: - Errors

public struct MCPCallError: Error {
    public let message: String
    public init(_ message: String) { self.message = message }
}

// MARK: - Schema helpers (compact builders for JSON Schema)

func schemaObject(required: [String], properties: [String: JSONValue]) -> JSONValue {
    var dict: [String: JSONValue] = [
        "type": .string("object"),
        "properties": .object(properties)
    ]
    if !required.isEmpty {
        dict["required"] = .array(required.map { .string($0) })
    }
    return .object(dict)
}

func schemaString(_ description: String) -> JSONValue {
    .object(["type": .string("string"), "description": .string(description)])
}

func schemaInteger(_ description: String) -> JSONValue {
    .object(["type": .string("integer"), "description": .string(description)])
}

func schemaBoolean(_ description: String) -> JSONValue {
    .object(["type": .string("boolean"), "description": .string(description)])
}

func schemaArray(of items: JSONValue, description: String) -> JSONValue {
    .object(["type": .string("array"), "items": items, "description": .string(description)])
}

func schemaEnum(_ values: [String], description: String) -> JSONValue {
    .object([
        "type": .string("string"),
        "enum": .array(values.map { .string($0) }),
        "description": .string(description)
    ])
}

// MARK: - Stdio transport

public final class StdioMCPTransport: MCPTransport, @unchecked Sendable {
    private let stdin: FileHandle
    private let stdout: FileHandle
    private var buffer = Data()
    private let lock = NSLock()

    public init(stdin: FileHandle = .standardInput, stdout: FileHandle = .standardOutput) {
        self.stdin = stdin
        self.stdout = stdout
    }

    public func readLine() throws -> String? {
        // Block-read up to 4 KiB at a time, splitting on '\n'.
        while true {
            if let nlIdx = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer[..<nlIdx]
                buffer.removeSubrange(...nlIdx)
                return String(data: Data(lineData), encoding: .utf8) ?? ""
            }
            let chunk = stdin.availableData
            if chunk.isEmpty {
                if buffer.isEmpty { return nil }
                let s = String(data: buffer, encoding: .utf8)
                buffer.removeAll()
                return s
            }
            buffer.append(chunk)
        }
    }

    public func write(_ line: String) throws {
        lock.lock(); defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            stdout.write(data)
        }
    }
}
