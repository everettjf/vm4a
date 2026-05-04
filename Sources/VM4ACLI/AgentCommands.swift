import ArgumentParser
import Foundation
import VM4ACore
import Virtualization

// MARK: - Helpers shared by agent commands

private func ownExecutablePath() throws -> String {
    guard let path = Bundle.main.executablePath else {
        throw VM4AError.message("Cannot locate vm4a executable path")
    }
    return path
}

private func bundleExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appending(path: "config.json").path(percentEncoded: false))
}

private func resolveHost(model: VMModel, override: String?) throws -> String {
    if let override, !override.isEmpty { return override }
    if let lease = findLeasesForBundle(model).first { return lease.ipAddress }
    throw VM4AError.notFound("DHCP lease for \(model.config.name); pass --host <ip> if bridged.")
}

private func defaultSSHUser(for os: VMOSType) -> String {
    switch os {
    case .linux:  return "root"
    case .macOS:  return NSUserName()
    }
}

// MARK: - vm4a spawn

struct SpawnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spawn",
        abstract: "Create + start a VM in one shot, optionally waiting for IP / SSH",
        discussion: """
            Behavior:
              - If <storage>/<name> already exists, just (re)start it.
              - Else if --from <oci-ref>: pull, then start.
              - Else if --image <iso-or-ipsw>: create from scratch, then start.

            Designed for AI agents: --output json + --wait-ssh together give a
            single call that returns {ip, ssh_ready=true} or fails fast.
            """
    )

    @Argument(help: "VM name (becomes <storage>/<name>)")
    var name: String

    @Option(name: .long, help: "OS type: macOS or linux")
    var os: VMOSType = .linux

    @Option(name: .long, help: "Parent directory to store VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Pull this OCI reference if bundle does not yet exist")
    var from: String?

    @Option(name: .long, help: "Local ISO/IPSW path to install from when creating fresh")
    var image: String?

    @Option(name: .long, help: "vCPU count")
    var cpu: Int?

    @Option(name: .long, help: "Memory size in GB")
    var memoryGB: Int?

    @Option(name: .long, help: "Disk size in GB")
    var diskGB: Int?

    @Option(name: .long, help: "Bridged interface bsdName")
    var bridgedInterface: String?

    @Flag(name: .long, help: "Enable Rosetta share (Linux only)")
    var rosetta: Bool = false

    @Option(name: .long, help: "Restore from this .vzstate file before starting (macOS 14+)")
    var restore: String?

    @Option(name: .long, help: "Save VM state to this path on clean stop (macOS 14+)")
    var saveOnStop: String?

    @Flag(name: .long, help: "Wait for the VM to acquire a NAT DHCP IP before returning")
    var waitIP: Bool = false

    @Flag(name: .long, help: "Wait for SSH on the VM to accept connections (implies --wait-ip)")
    var waitSSH: Bool = false

    @Option(name: .long, help: "SSH username (used by --wait-ssh)")
    var sshUser: String?

    @Option(name: .long, help: "SSH key path (used by --wait-ssh)")
    var sshKey: String?

    @Option(name: .long, help: "Override IP (skip DHCP lookup; used by --wait-ssh on bridged setups)")
    var host: String?

    @Option(name: .long, help: "Wait timeout in seconds for IP / SSH")
    var waitTimeout: Int = 90

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() async throws {
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        try FileManager.default.createDirectory(at: storageURL, withIntermediateDirectories: true)
        let bundleURL = storageURL.appending(path: name, directoryHint: .isDirectory)

        if !bundleExists(at: bundleURL) {
            if let ref = from {
                FileHandle.standardError.write(Data("Pulling \(ref) → \(bundleURL.path())\n".utf8))
                let pulled = try await ociPull(reference: ref, into: storageURL) { line in
                    FileHandle.standardError.write(Data("  \(line)\n".utf8))
                }
                if pulled.path() != bundleURL.path() {
                    try FileManager.default.moveItem(at: pulled, to: bundleURL)
                }
            } else if let imagePath = image {
                try createFreshBundle(at: bundleURL, imagePath: imagePath)
            } else {
                throw VM4AError.message("Bundle '\(bundleURL.path())' not found. Pass --from <oci-ref> or --image <path>.")
            }
        }

        let model = try loadModel(rootPath: bundleURL)
        let pid = try startVMWorker(
            executable: try ownExecutablePath(),
            vmPath: bundleURL.path(),
            recovery: false,
            restoreStateAt: restore.map { normalizePath($0) },
            saveOnStopAt: saveOnStop.map { normalizePath($0) }
        )

        var resolvedIP: String? = host
        var sshReady = false

        if waitIP || waitSSH {
            if resolvedIP == nil {
                resolvedIP = waitForVMIP(model: model, timeout: TimeInterval(waitTimeout))
            }
        }

        if waitSSH, let ip = resolvedIP {
            let user = sshUser ?? defaultSSHUser(for: model.config.type)
            let opts = SSHOptions(user: user, keyPath: sshKey)
            sshReady = waitForSSHReady(host: ip, options: opts, timeout: TimeInterval(waitTimeout))
        }

        let outcome = SpawnOutcome(
            id: vmShortID(forPath: bundleURL),
            name: model.config.name,
            path: bundleURL.path(),
            os: model.config.type.rawValue,
            pid: pid,
            ip: resolvedIP,
            sshReady: sshReady
        )

        switch output {
        case .json:
            try writeJSONLine(outcome)
        case .text:
            print("Spawned \(outcome.name) at \(outcome.path) (id=\(outcome.id))")
            if let pid = outcome.pid { print("  pid: \(pid)") }
            if let ip = outcome.ip { print("  ip:  \(ip)") }
            if waitSSH { print("  ssh: \(sshReady ? "ready" : "not ready")") }
        }
    }

    private func createFreshBundle(at bundleURL: URL, imagePath: String) throws {
        let memoryBytes = try memoryGB.map { try bytesFromGB($0, fieldName: "memory-gb") }
        let diskBytes = try diskGB.map { try bytesFromGB($0, fieldName: "disk-gb") }
        var config = VMConfigModel.defaults(osType: os, name: name, cpu: cpu, memoryBytes: memoryBytes, diskBytes: diskBytes)
        let normalizedImagePath = normalizePath(imagePath)

        let network: [VMModelFieldNetworkDevice]
        if let bridgedInterface {
            let interfaces = availableBridgedInterfaces()
            if interfaces.first(where: { $0.identifier == bridgedInterface }) == nil {
                let available = interfaces.map { $0.identifier }.joined(separator: ", ")
                throw VM4AError.message("Bridged interface '\(bridgedInterface)' not found. Available: \(available)")
            }
            network = [.init(type: .Bridged, identifier: bridgedInterface)]
        } else {
            network = config.networkDevices
        }

        let rosettaField: VMModelFieldRosetta?
        if rosetta {
            if os != .linux { throw VM4AError.message("--rosetta only applies to Linux guests") }
            switch VMModelFieldRosetta.hostAvailability {
            case .notSupported: throw VM4AError.hostUnsupported("Rosetta is not supported on this host")
            case .notInstalled: throw VM4AError.rosettaNotInstalled
            case .installed: break
            }
            rosettaField = .init(enabled: true)
        } else {
            rosettaField = nil
        }

        let storageDevices: [VMModelFieldStorageDevice]
        if os == .linux, !normalizedImagePath.isEmpty {
            storageDevices = config.storageDevices + [.init(type: .USB, size: 0, imagePath: normalizedImagePath)]
        } else {
            storageDevices = config.storageDevices
        }

        config = VMConfigModel(
            type: config.type,
            name: config.name,
            remark: config.remark,
            cpu: config.cpu,
            memory: config.memory,
            graphicsDevices: config.graphicsDevices,
            storageDevices: storageDevices,
            networkDevices: network,
            pointingDevices: config.pointingDevices,
            audioDevices: config.audioDevices,
            directorySharingDevices: config.directorySharingDevices,
            rosetta: rosettaField
        )

        try FileManager.default.createDirectory(at: bundleURL, withIntermediateDirectories: true)
        let state = VMStateModel(imagePath: URL(fileURLWithPath: normalizedImagePath))
        let model = VMModel(rootPath: bundleURL, config: config, state: state)
        try writeJSON(config, to: model.configURL)
        try writeJSON(state, to: model.stateURL)
        try ensureDiskImagesExist(model: model)

        if os == .linux {
            try VZGenericMachineIdentifier().dataRepresentation.write(to: model.machineIdentifierURL)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: model.efiVariableStoreURL)
        }
    }
}

// MARK: - vm4a exec

struct ExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command inside a running VM via SSH; return JSON {exit_code, stdout, stderr, duration_ms, timed_out}",
        discussion: """
            Examples:
              vm4a exec /tmp/vm4a/dev -- python3 -c 'print(1+1)'
              vm4a exec /tmp/vm4a/dev --output json -- "ls /etc | head"

            Without --output json, stdout/stderr stream and the exit code becomes
            this process's exit code.
            """
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "SSH login user (default: root for linux, current user for macOS)")
    var user: String?

    @Option(name: .long, help: "SSH key path")
    var key: String?

    @Option(name: .long, help: "Override target host (skip DHCP lookup)")
    var host: String?

    @Option(name: .long, help: "Wall-clock timeout in seconds")
    var timeout: Int = 60

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments to run in the VM")
    var command: [String] = []

    mutating func run() throws {
        guard !command.isEmpty else {
            throw VM4AError.message("Provide a command after `--`. Example: vm4a exec /path/to/vm -- whoami")
        }
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)
        let target = try resolveHost(model: model, override: host)
        let sshUser = user ?? defaultSSHUser(for: model.config.type)
        let opts = SSHOptions(user: sshUser, keyPath: key)
        let result = sshExec(host: target, options: opts, command: command, timeout: TimeInterval(timeout))

        switch output {
        case .json:
            try writeJSONLine(result)
        case .text:
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        if result.exitCode != 0 {
            throw ExitCode(result.exitCode)
        }
    }
}

// MARK: - vm4a cp

struct CpCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cp",
        abstract: "Copy files between host and guest via SCP",
        discussion: """
            Path convention: a leading ':' marks a guest path, otherwise host path.

            Examples:
              vm4a cp /tmp/vm4a/dev ./local.py :/work/script.py     # host → guest
              vm4a cp /tmp/vm4a/dev :/var/log/syslog ./syslog.txt    # guest → host
              vm4a cp /tmp/vm4a/dev -r ./project :/srv/code          # recursive
            """
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Argument(help: "Source path (':' prefix = guest, otherwise host)")
    var source: String

    @Argument(help: "Destination path (':' prefix = guest, otherwise host)")
    var destination: String

    @Flag(name: [.short, .long], help: "Recursive copy")
    var recursive: Bool = false

    @Option(name: .long, help: "SSH login user")
    var user: String?

    @Option(name: .long, help: "SSH key path")
    var key: String?

    @Option(name: .long, help: "Override target host")
    var host: String?

    @Option(name: .long, help: "Wall-clock timeout in seconds")
    var timeout: Int = 300

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)
        let target = try resolveHost(model: model, override: host)
        let sshUser = user ?? defaultSSHUser(for: model.config.type)

        let src = parseCopyEndpoint(source)
        let dst = parseCopyEndpoint(destination)
        let scpSource: String
        let scpDestination: String
        switch (src, dst) {
        case (.host(let s), .guest(let g)):
            scpSource = s
            scpDestination = "\(sshUser)@\(target):\(g)"
        case (.guest(let g), .host(let s)):
            scpSource = "\(sshUser)@\(target):\(g)"
            scpDestination = s
        case (.host, .host):
            throw VM4AError.message("cp: at least one side must be a guest path (prefix it with ':')")
        case (.guest, .guest):
            throw VM4AError.message("cp: copying between two guest paths is not supported in one call")
        }

        let opts = SSHOptions(user: sshUser, keyPath: key)
        let result = scpCopy(options: opts, source: scpSource, destination: scpDestination, recursive: recursive, timeout: TimeInterval(timeout))

        switch output {
        case .json:
            try writeJSONLine(result)
        case .text:
            if !result.stdout.isEmpty { FileHandle.standardOutput.write(Data(result.stdout.utf8)) }
            if !result.stderr.isEmpty { FileHandle.standardError.write(Data(result.stderr.utf8)) }
        }
        if result.exitCode != 0 {
            throw ExitCode(result.exitCode)
        }
    }
}

// MARK: - vm4a fork

struct ForkCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "fork",
        abstract: "Clone a VM bundle and optionally start it (with optional snapshot restore)",
        discussion: """
            Designed for parallel agent traces: each fork is APFS-clonefiled
            from the source so creating a new sibling is instantaneous.
            """
    )

    @Argument(help: "Source VM bundle path")
    var sourcePath: String

    @Argument(help: "Destination VM bundle path")
    var destinationPath: String

    @Option(name: .long, help: "Restore from this .vzstate file when starting (macOS 14+)")
    var fromSnapshot: String?

    @Flag(name: .long, help: "Start the new VM after forking")
    var autoStart: Bool = false

    @Flag(name: .long, help: "Wait for IP after auto-start")
    var waitIP: Bool = false

    @Flag(name: .long, help: "Wait for SSH after auto-start (implies --wait-ip)")
    var waitSSH: Bool = false

    @Option(name: .long, help: "SSH login user (used by --wait-ssh)")
    var sshUser: String?

    @Option(name: .long, help: "SSH key path (used by --wait-ssh)")
    var sshKey: String?

    @Option(name: .long, help: "Wait timeout for IP / SSH in seconds")
    var waitTimeout: Int = 90

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() async throws {
        let src = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let dst = URL(fileURLWithPath: destinationPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else {
            throw VM4AError.notFound("Source VM: \(src.path())")
        }
        _ = try cloneDirectory(from: src, to: dst)
        let model = try loadModel(rootPath: dst)
        clearPID(at: model.runPIDURL)
        try? FileManager.default.removeItem(at: model.runLogURL)
        try reidentifyVM(model: model)

        var pid: Int32?
        var ip: String?

        if autoStart {
            pid = try startVMWorker(
                executable: try ownExecutablePath(),
                vmPath: dst.path(),
                restoreStateAt: fromSnapshot.map { normalizePath($0) }
            )
            if waitIP || waitSSH {
                ip = waitForVMIP(model: model, timeout: TimeInterval(waitTimeout))
            }
            if waitSSH, let ip {
                let user = sshUser ?? defaultSSHUser(for: model.config.type)
                let opts = SSHOptions(user: user, keyPath: sshKey)
                _ = waitForSSHReady(host: ip, options: opts, timeout: TimeInterval(waitTimeout))
            }
        }

        let outcome = ForkOutcome(
            path: dst.path(),
            name: model.config.name,
            started: autoStart,
            pid: pid,
            ip: ip
        )

        switch output {
        case .json:
            try writeJSONLine(outcome)
        case .text:
            print("Forked \(src.path()) → \(dst.path())")
            if autoStart, let pid { print("  started, pid \(pid)") }
            if let ip { print("  ip:  \(ip)") }
        }
    }
}

// MARK: - vm4a reset

struct ResetCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reset",
        abstract: "Stop the VM (if running) and start it again, restoring from a baseline snapshot",
        discussion: """
            Designed for try → fail → reset → retry agent loops. Requires a
            previously-saved .vzstate file (see --save-on-stop).
            """
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Restore from this .vzstate file (required, macOS 14+)")
    var from: String

    @Flag(name: .long, help: "Wait for IP after restart")
    var waitIP: Bool = false

    @Option(name: .long, help: "Stop timeout in seconds")
    var stopTimeout: Int = 20

    @Option(name: .long, help: "Wait timeout for IP in seconds")
    var waitTimeout: Int = 60

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)

        if let pid = readPID(from: model.runPIDURL), isProcessRunning(pid: pid) {
            _ = kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(TimeInterval(stopTimeout))
            while Date() < deadline {
                if !isProcessRunning(pid: pid) { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if isProcessRunning(pid: pid) {
                _ = kill(pid, SIGKILL)
                Thread.sleep(forTimeInterval: 0.5)
            }
            clearPID(at: model.runPIDURL)
        }

        let snapshotPath = normalizePath(from)
        guard FileManager.default.fileExists(atPath: snapshotPath) else {
            throw VM4AError.notFound("Snapshot file: \(snapshotPath)")
        }

        let pid = try startVMWorker(
            executable: try ownExecutablePath(),
            vmPath: vmPath,
            restoreStateAt: snapshotPath
        )
        var ip: String?
        if waitIP {
            ip = waitForVMIP(model: model, timeout: TimeInterval(waitTimeout))
        }

        struct Outcome: Encodable {
            let path: String
            let restored: String
            let pid: Int32?
            let ip: String?
        }
        let outcome = Outcome(path: rootURL.path(), restored: snapshotPath, pid: pid, ip: ip)
        switch output {
        case .json:
            try writeJSONLine(outcome)
        case .text:
            print("Reset \(rootURL.path()) from snapshot \(snapshotPath)")
            if let pid { print("  pid: \(pid)") }
            if let ip { print("  ip:  \(ip)") }
        }
    }
}
