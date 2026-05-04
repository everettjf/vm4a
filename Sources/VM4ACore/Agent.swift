import Foundation
@preconcurrency import Virtualization

// MARK: - Public types

public struct ExecResult: Codable, Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMs: Int
    public let timedOut: Bool

    public init(exitCode: Int32, stdout: String, stderr: String, durationMs: Int, timedOut: Bool) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.durationMs = durationMs
        self.timedOut = timedOut
    }
}

public struct VMSummary: Codable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let os: String
    public let status: String
    public let pid: Int32?
    public let ip: String?

    public init(id: String, name: String, path: String, os: String, status: String, pid: Int32?, ip: String?) {
        self.id = id
        self.name = name
        self.path = path
        self.os = os
        self.status = status
        self.pid = pid
        self.ip = ip
    }
}

public struct SpawnOutcome: Codable, Sendable {
    public let id: String
    public let name: String
    public let path: String
    public let os: String
    public let pid: Int32?
    public let ip: String?
    public let sshReady: Bool

    public init(id: String, name: String, path: String, os: String, pid: Int32?, ip: String?, sshReady: Bool) {
        self.id = id
        self.name = name
        self.path = path
        self.os = os
        self.pid = pid
        self.ip = ip
        self.sshReady = sshReady
    }
}

public struct ForkOutcome: Codable, Sendable {
    public let path: String
    public let name: String
    public let started: Bool
    public let pid: Int32?
    public let ip: String?

    public init(path: String, name: String, started: Bool, pid: Int32?, ip: String?) {
        self.path = path
        self.name = name
        self.started = started
        self.pid = pid
        self.ip = ip
    }
}

// MARK: - Stable VM identifier derived from absolute bundle path

/// FNV-1a 64-bit hash of the standardized absolute path. Used by the agent
/// layer (MCP / HTTP) to refer to a VM without leaking full filesystem paths.
/// Trailing slashes are stripped so `/tmp/foo` and `/tmp/foo/` map to the same ID.
public func vmShortID(forPath path: URL) -> String {
    var normalized = path.standardizedFileURL.path()
    while normalized.count > 1, normalized.hasSuffix("/") {
        normalized.removeLast()
    }
    var hash: UInt64 = 0xcbf29ce484222325
    for byte in normalized.utf8 {
        hash ^= UInt64(byte)
        hash &*= 0x100000001b3
    }
    return "vm-" + String(format: "%012x", hash & 0xffffffffffff)
}

// MARK: - Process helper with timeout

private final class _MutBool: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    func get() -> Bool { lock.lock(); defer { lock.unlock() }; return value }
}

/// Run an external process to completion, capturing stdout/stderr and
/// enforcing a wall-clock timeout. After the timeout the process gets
/// SIGTERM, then SIGKILL one second later if still alive.
public func runProcess(
    executable: String,
    arguments: [String],
    timeout: TimeInterval,
    inheritStdin: Bool = false
) -> ExecResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    process.standardInput = inheritStdin ? FileHandle.standardInput : FileHandle.nullDevice

    let timedOut = _MutBool()
    let started = Date()

    do {
        try process.run()
    } catch {
        return ExecResult(
            exitCode: -1,
            stdout: "",
            stderr: "failed to start \(executable): \(error)",
            durationMs: 0,
            timedOut: false
        )
    }

    let queue = DispatchQueue(label: "vm4a.run.timeout")
    let timer = DispatchSource.makeTimerSource(queue: queue)
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler {
        if process.isRunning {
            timedOut.set()
            process.terminate()
            queue.asyncAfter(deadline: .now() + 1.0) {
                if process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
        }
    }
    timer.resume()

    process.waitUntilExit()
    timer.cancel()

    let elapsed = Date().timeIntervalSince(started)
    let outData = (try? stdoutPipe.fileHandleForReading.readToEnd()) ?? Data()
    let errData = (try? stderrPipe.fileHandleForReading.readToEnd()) ?? Data()

    return ExecResult(
        exitCode: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? "",
        durationMs: Int(elapsed * 1000),
        timedOut: timedOut.get()
    )
}

// MARK: - SSH / SCP

public struct SSHOptions: Sendable {
    public var user: String
    public var port: Int
    public var keyPath: String?
    public var connectTimeoutSeconds: Int
    public var strictHostKeyChecking: Bool

    public init(user: String, port: Int = 22, keyPath: String? = nil, connectTimeoutSeconds: Int = 10, strictHostKeyChecking: Bool = false) {
        self.user = user
        self.port = port
        self.keyPath = keyPath
        self.connectTimeoutSeconds = connectTimeoutSeconds
        self.strictHostKeyChecking = strictHostKeyChecking
    }
}

private func baseSSHCommonFlags(_ opts: SSHOptions) -> [String] {
    var flags: [String] = []
    if !opts.strictHostKeyChecking {
        flags += ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null"]
    }
    flags += ["-o", "ConnectTimeout=\(opts.connectTimeoutSeconds)"]
    flags += ["-o", "BatchMode=yes"]
    if let key = opts.keyPath { flags += ["-i", key] }
    return flags
}

public func sshExec(host: String, options: SSHOptions, command: [String], timeout: TimeInterval) -> ExecResult {
    var args = baseSSHCommonFlags(options)
    if options.port != 22 { args += ["-p", "\(options.port)"] }
    args.append("\(options.user)@\(host)")
    args.append(contentsOf: command)
    return runProcess(executable: "/usr/bin/ssh", arguments: args, timeout: timeout)
}

public func scpCopy(options: SSHOptions, source: String, destination: String, recursive: Bool, timeout: TimeInterval) -> ExecResult {
    var args = baseSSHCommonFlags(options)
    if options.port != 22 { args += ["-P", "\(options.port)"] }
    if recursive { args.append("-r") }
    args.append(source)
    args.append(destination)
    return runProcess(executable: "/usr/bin/scp", arguments: args, timeout: timeout)
}

// MARK: - Polling / waiting

/// Poll DHCP leases until an IP is found for this VM bundle, or timeout.
public func waitForVMIP(model: VMModel, timeout: TimeInterval = 60, pollInterval: TimeInterval = 1.0) -> String? {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let leases = findLeasesForBundle(model)
        if let lease = leases.first {
            return lease.ipAddress
        }
        Thread.sleep(forTimeInterval: pollInterval)
    }
    return nil
}

/// Poll SSH `true` until it succeeds with exit 0, or timeout.
public func waitForSSHReady(host: String, options: SSHOptions, timeout: TimeInterval = 60, pollInterval: TimeInterval = 2.0) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        let result = sshExec(host: host, options: options, command: ["true"], timeout: TimeInterval(options.connectTimeoutSeconds + 2))
        if result.exitCode == 0 { return true }
        Thread.sleep(forTimeInterval: pollInterval)
    }
    return false
}

// MARK: - Cp endpoint parsing

public enum CopyEndpoint: Sendable, Equatable {
    case host(String)
    case guest(String)
}

/// Parse a path argument: a leading `:` denotes the guest side, otherwise it's the host.
/// Examples: `:/etc/hostname` → guest, `./local.txt` → host, `:relative/path` → guest.
public func parseCopyEndpoint(_ raw: String) -> CopyEndpoint {
    if raw.hasPrefix(":") {
        return .guest(String(raw.dropFirst()))
    }
    return .host(raw)
}

// MARK: - VM identity helpers

/// Re-randomize a VM bundle's MachineIdentifier file so a clone boots as a
/// distinct machine. Caller should make sure the VM is not running.
public func reidentifyVM(model: VMModel) throws {
    switch model.config.type {
    case .linux:
        let data = VZGenericMachineIdentifier().dataRepresentation
        try data.write(to: model.machineIdentifierURL)
    case .macOS:
        let data = VZMacMachineIdentifier().dataRepresentation
        try data.write(to: model.machineIdentifierURL)
    }
}

// MARK: - List helper used by both CLI list and MCP/HTTP

public func listVMSummaries(in storageURL: URL) -> [VMSummary] {
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: storageURL,
        includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles]
    ) else {
        return []
    }
    var rows: [VMSummary] = []
    for entry in entries {
        guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        let configURL = entry.appending(path: "config.json")
        guard FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)),
              let model = try? loadModel(rootPath: entry) else {
            continue
        }
        var pid = readPID(from: model.runPIDURL)
        let running = pid.map(isProcessRunning(pid:)) ?? false
        if pid != nil, !running {
            clearPID(at: model.runPIDURL)
            pid = nil
        }
        var ip: String?
        if running {
            ip = findLeasesForBundle(model).first?.ipAddress
        }
        rows.append(VMSummary(
            id: vmShortID(forPath: entry),
            name: model.config.name,
            path: entry.path(),
            os: model.config.type.rawValue,
            status: running ? "running" : "stopped",
            pid: running ? pid : nil,
            ip: ip
        ))
    }
    return rows
}

// MARK: - Spawn worker invocation

/// Launch the runner worker for a VM bundle as a detached child process,
/// returning the worker pid (or nil if the worker failed to start). This is
/// the same mechanism used by `vm4a run`; agent flows reuse it so a single
/// codepath manages PID files and run logs.
public func startVMWorker(
    executable: String,
    vmPath: String,
    recovery: Bool = false,
    restoreStateAt: String? = nil,
    saveOnStopAt: String? = nil,
    bootstrapDelay: TimeInterval = 1.0
) throws -> Int32? {
    let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
    if let existing = readPID(from: model.runPIDURL), isProcessRunning(pid: existing) {
        throw VM4AError.invalidState("VM is already running (pid \(existing))")
    }
    clearPID(at: model.runPIDURL)

    FileManager.default.createFile(atPath: model.runLogURL.path(percentEncoded: false), contents: nil)
    let logHandle = try FileHandle(forWritingTo: model.runLogURL)
    try logHandle.truncate(atOffset: 0)

    var workerArgs: [String] = ["_run-worker", vmPath]
    if recovery { workerArgs.append("--recovery") }
    if let r = restoreStateAt { workerArgs += ["--restore", r] }
    if let s = saveOnStopAt { workerArgs += ["--save-on-stop", s] }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = workerArgs
    process.standardInput = FileHandle.nullDevice
    process.standardOutput = logHandle
    process.standardError = logHandle
    try process.run()

    Thread.sleep(forTimeInterval: bootstrapDelay)
    return readPID(from: model.runPIDURL)
}
