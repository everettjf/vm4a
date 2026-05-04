import ArgumentParser
import VM4ACore
import Foundation
import Virtualization

extension VMOSType: ExpressibleByArgument {}

enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
}

func writeJSONLine<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let data = try encoder.encode(value)
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct VM4ACLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vm4a",
        abstract: "VM4A — Virtual Machines for Agents (Apple Silicon)",
        subcommands: [
            // Agent-first primitives (P0)
            SpawnCommand.self,
            ExecCommand.self,
            CpCommand.self,
            ForkCommand.self,
            ResetCommand.self,
            // Agent integrations (P1, v2.1)
            MCPCommand.self,
            ServeCommand.self,
            // Sessions + pools (v2.3 + v2.4 foundations)
            SessionCommand.self,
            PoolCommand.self,
            // Classic lifecycle
            CreateCommand.self,
            ListCommand.self,
            RunCommand.self,
            StopCommand.self,
            CloneCommand.self,
            NetworkCommand.self,
            ImageCommand.self,
            PushCommand.self,
            PullCommand.self,
            IPCommand.self,
            SSHCommand.self,
            AgentCommand.self,
            RunWorkerCommand.self
        ]
    )
}

struct CreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a VM bundle")

    @Argument(help: "VM name")
    var name: String

    @Option(name: .long, help: "OS type: macOS or linux")
    var os: VMOSType

    @Option(name: .long, help: "Parent directory to store VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Initial image path (ISO/IPSW). Optional.")
    var image: String?

    @Option(name: .long, help: "vCPU count")
    var cpu: Int?

    @Option(name: .long, help: "Memory size in GB")
    var memoryGB: Int?

    @Option(name: .long, help: "Disk size in GB")
    var diskGB: Int?

    @Option(name: .long, help: "Bridged interface bsdName (enables bridged networking). Use 'vm4a network list' to enumerate.")
    var bridgedInterface: String?

    @Flag(name: .long, help: "Enable Rosetta translation share (Linux only, macOS 13+).")
    var rosetta: Bool = false

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        let memoryBytes = try memoryGB.map { try bytesFromGB($0, fieldName: "memory-gb") }
        let diskBytes = try diskGB.map { try bytesFromGB($0, fieldName: "disk-gb") }
        let outcome = try createBundle(options: CreateBundleOptions(
            name: name,
            os: os,
            storage: storageURL,
            imagePath: image,
            cpu: cpu,
            memoryBytes: memoryBytes,
            diskBytes: diskBytes,
            bridgedInterface: bridgedInterface,
            rosetta: rosetta
        ))
        if let warning = outcome.rosettaWarning {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        switch output {
        case .json:
            try writeJSONLine(outcome)
        case .text:
            if os == .macOS {
                print("Created macOS VM skeleton. Complete installation using GUI flow to generate HardwareModel/AuxiliaryStorage.")
            }
            print("Created VM: \(outcome.path)")
        }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List VM bundles in a directory")

    @Option(name: .long, help: "Parent directory that contains VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        let rows = listVMSummaries(in: storageURL)

        switch output {
        case .json:
            try writeJSONLine(rows)
        case .text:
            if rows.isEmpty {
                print("No VM bundles found in \(storageURL.path())")
            } else {
                for row in rows {
                    let status = row.status == "running" ? "running(pid:\(row.pid ?? 0))" : "stopped"
                    let ip = row.ip ?? "-"
                    print("\(row.name)\t\(row.os)\t\(status)\t\(ip)\t\(row.path)")
                }
            }
        }
    }
}

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a VM")

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Flag(name: .long, help: "Start macOS VM in recovery mode")
    var recovery = false

    @Flag(name: .long, help: "Run in foreground")
    var foreground = false

    @Option(name: .long, help: "Restore VM state from .vzstate file before starting (macOS 14+)")
    var restore: String?

    @Option(name: .long, help: "Save VM state to this path when stopping (macOS 14+)")
    var saveOnStop: String?

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)

        if let pid = readPID(from: model.runPIDURL), isProcessRunning(pid: pid) {
            throw VM4AError.invalidState("VM is already running (pid \(pid))")
        }
        clearPID(at: model.runPIDURL)

        let restoreURL = restore.map { URL(fileURLWithPath: normalizePath($0)) }
        let saveURL = saveOnStop.map { URL(fileURLWithPath: normalizePath($0)) }
        let runOptions = RunOptions(recoveryMode: recovery, restoreStateAt: restoreURL, saveStateOnStopAt: saveURL)

        if foreground {
            try writePID(getpid(), to: model.runPIDURL)
            defer { clearPID(at: model.runPIDURL) }
            try runVM(model: model, options: runOptions)
            return
        }

        guard let executable = Bundle.main.executablePath else {
            throw VM4AError.message("Cannot locate executable path")
        }

        FileManager.default.createFile(atPath: model.runLogURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: model.runLogURL)
        try logHandle.truncate(atOffset: 0)

        var workerArgs: [String] = ["_run-worker", vmPath]
        if recovery { workerArgs.append("--recovery") }
        if let r = restore { workerArgs += ["--restore", normalizePath(r)] }
        if let s = saveOnStop { workerArgs += ["--save-on-stop", normalizePath(s)] }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = workerArgs

        let null = FileHandle.nullDevice
        process.standardInput = null
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        Thread.sleep(forTimeInterval: 1.0)

        if let pid = readPID(from: model.runPIDURL), isProcessRunning(pid: pid) {
            print("Started VM worker pid \(pid)")
            return
        }

        let logText = (try? String(contentsOf: model.runLogURL)) ?? ""
        let nonEmptyLog = logText.trimmingCharacters(in: .whitespacesAndNewlines)
        if nonEmptyLog.isEmpty {
            throw VM4AError.message("VM worker exited early. Check \(model.runLogURL.path())")
        }
        throw VM4AError.message("VM worker failed to start:\n\(nonEmptyLog)")
    }
}

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a running VM")

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Wait timeout in seconds")
    var timeout: Int = 20

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)

        guard let pid = readPID(from: model.runPIDURL) else {
            throw VM4AError.message("No run pid found for \(vmPath)")
        }
        guard isProcessRunning(pid: pid) else {
            clearPID(at: model.runPIDURL)
            throw VM4AError.message("Process \(pid) is not running")
        }

        guard kill(pid, SIGTERM) == 0 else {
            throw VM4AError.message("Failed to send SIGTERM to pid \(pid)")
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if !isProcessRunning(pid: pid) {
                clearPID(at: model.runPIDURL)
                print("Stopped VM process \(pid)")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        _ = kill(pid, SIGKILL)
        let killDeadline = Date().addingTimeInterval(5)
        while Date() < killDeadline {
            if !isProcessRunning(pid: pid) {
                clearPID(at: model.runPIDURL)
                print("Stopped VM process \(pid) (forced)")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        throw VM4AError.message("Timed out waiting for pid \(pid) to stop, even after SIGKILL")
    }
}

struct CloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clone", abstract: "Clone a VM bundle")

    @Argument(help: "Source VM root path")
    var sourcePath: String

    @Argument(help: "Destination VM root path")
    var destinationPath: String

    mutating func run() throws {
        let src = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let dst = URL(fileURLWithPath: destinationPath, isDirectory: true)

        guard FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else {
            throw VM4AError.notFound("Source VM: \(src.path())")
        }
        let viaClone = try cloneDirectory(from: src, to: dst)
        let model = try loadModel(rootPath: dst)
        clearPID(at: model.runPIDURL)
        try? FileManager.default.removeItem(at: model.runLogURL)

        switch model.config.type {
        case .linux:
            let newIdentifier = VZGenericMachineIdentifier()
            try newIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
        case .macOS:
            let newIdentifier = VZMacMachineIdentifier()
            try newIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
        }

        print("Cloned VM to \(dst.path()) \(viaClone ? "(APFS clonefile)" : "(byte copy)")")
    }
}

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Inspect host network interfaces",
        subcommands: [ListBridgedCommand.self],
        defaultSubcommand: ListBridgedCommand.self
    )
}

struct ListBridgedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List bridged interfaces available to VMs")

    mutating func run() throws {
        let interfaces = availableBridgedInterfaces()
        if interfaces.isEmpty {
            print("No bridged interfaces available. Ensure the CLI is signed with com.apple.vm.networking entitlement.")
            return
        }
        for iface in interfaces {
            if let name = iface.displayName {
                print("\(iface.identifier)\t\(name)")
            } else {
                print(iface.identifier)
            }
        }
    }
}

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Linux image catalog and local operations",
        subcommands: [ImageListCommand.self],
        defaultSubcommand: ImageListCommand.self
    )
}

struct ImageListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List curated Linux ARM64 images")

    mutating func run() throws {
        for entry in linuxImageCatalog() {
            print("\(entry.id)\t\(entry.displayName)")
            print("  \(entry.url)")
        }
    }
}

struct PushCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push",
        abstract: "Push a VM bundle to an OCI-compatible registry",
        discussion: """
            Use VM4A_REGISTRY_USER / VM4A_REGISTRY_PASSWORD for authenticated registries.
            Example: vm4a push /tmp/vm4a/demo ghcr.io/youruser/demo:latest
            """
    )

    @Argument(help: "Path to VM bundle")
    var bundlePath: String

    @Argument(help: "Registry reference (e.g. ghcr.io/user/name:tag)")
    var reference: String

    mutating func run() async throws {
        let bundle = URL(fileURLWithPath: normalizePath(bundlePath), isDirectory: true)
        guard FileManager.default.fileExists(atPath: bundle.path(percentEncoded: false)) else {
            throw VM4AError.message("Bundle does not exist: \(bundle.path())")
        }
        try await ociPush(bundleDir: bundle, reference: reference) { line in
            print(line)
        }
    }
}

struct PullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Pull a VM bundle from an OCI-compatible registry"
    )

    @Argument(help: "Registry reference (e.g. ghcr.io/user/name:tag)")
    var reference: String

    @Option(name: .long, help: "Parent directory to place the bundle into")
    var storage: String = FileManager.default.currentDirectoryPath

    mutating func run() async throws {
        let parent = URL(fileURLWithPath: normalizePath(storage), isDirectory: true)
        let bundle = try await ociPull(reference: reference, into: parent) { line in
            print(line)
        }
        print("Pulled to \(bundle.path())")
    }
}

struct IPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ip", abstract: "Resolve VM's IP address (NAT DHCP leases)")

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    struct Row: Encodable {
        let ip: String
        let mac: String
        let name: String?
    }

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)
        let leases = findLeasesForBundle(model)
        let rows = leases.map { Row(ip: $0.ipAddress, mac: $0.hardwareAddress, name: $0.name) }
        switch output {
        case .json:
            try writeJSONLine(rows)
        case .text:
            if rows.isEmpty {
                FileHandle.standardError.write(Data("No DHCP lease found for \(model.config.name). VM may not be running or may use bridged networking (try arp -an).\n".utf8))
                throw ExitCode(1)
            }
            for row in rows {
                if let name = row.name {
                    print("\(row.ip)\t\(row.mac)\t\(name)")
                } else {
                    print("\(row.ip)\t\(row.mac)")
                }
            }
        }
    }
}

struct SSHCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ssh",
        abstract: "SSH into a running VM via its NAT DHCP lease"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Login user")
    var user: String = NSUserName()

    @Option(name: .long, help: "Override target IP")
    var host: String?

    @Argument(parsing: .captureForPassthrough, help: "Extra arguments passed to ssh")
    var extra: [String] = []

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)
        let target: String
        if let host { target = host }
        else {
            let leases = findLeasesForBundle(model)
            guard let lease = leases.first else {
                throw VM4AError.message("No DHCP lease found for \(model.config.name); pass --host <ip> if bridged.")
            }
            target = lease.ipAddress
        }
        let args = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "\(user)@\(target)"] + extra
        let exe = "/usr/bin/ssh"
        FileHandle.standardError.write(Data("vm4a: exec \(exe) \(args.joined(separator: " "))\n".utf8))
        let cArgs: [UnsafeMutablePointer<CChar>?] = ([exe] + args).map { strdup($0) } + [nil]
        _ = execv(exe, cArgs)
        throw VM4AError.message("execv failed: \(String(cString: strerror(errno)))")
    }
}

struct AgentCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Communicate with the in-guest VM4AGuest agent (scaffold)",
        subcommands: [AgentStatusCommand.self, AgentPingCommand.self],
        defaultSubcommand: AgentStatusCommand.self
    )
}

struct AgentStatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Show last heartbeat from the guest agent")

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        _ = try loadModel(rootPath: rootURL)
        guard let beat = readGuestAgentHeartbeat(bundleRoot: rootURL) else {
            FileHandle.standardError.write(Data("No heartbeat found. Guest agent must be running inside the VM and mounting guest-agent/ via virtiofs.\n".utf8))
            throw ExitCode(4)
        }
        switch output {
        case .json: try writeJSONLine(beat)
        case .text:
            print("host:      \(beat.hostname)")
            print("version:   \(beat.version)")
            print("uptime_s:  \(Int(beat.uptimeSeconds))")
            print("timestamp: \(ISO8601DateFormatter().string(from: beat.timestamp))")
        }
    }
}

struct AgentPingCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "ping", abstract: "Send a ping command to the guest agent")

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Wait timeout in seconds")
    var timeout: Int = 10

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        _ = try loadModel(rootPath: rootURL)
        let command = GuestAgentCommand(kind: .ping)
        try writeGuestAgentCommand(bundleRoot: rootURL, command: command)

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if let resp = readGuestAgentResponse(bundleRoot: rootURL, id: command.id) {
                if resp.ok {
                    print(resp.output ?? "")
                    return
                } else {
                    throw VM4AError.message(resp.error ?? "guest agent returned failure")
                }
            }
            Thread.sleep(forTimeInterval: 0.5)
        }
        throw VM4AError.invalidState("Timed out waiting for guest agent response. Is vm4a-guest running inside the VM?")
    }
}

struct RunWorkerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_run-worker",
        abstract: "Internal worker command"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Flag(name: .long, help: "Start macOS VM in recovery mode")
    var recovery = false

    @Option(name: .long, help: "Restore VM state from this path before starting")
    var restore: String?

    @Option(name: .long, help: "Save VM state to this path when stopping")
    var saveOnStop: String?

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)
        try writePID(getpid(), to: model.runPIDURL)
        defer { clearPID(at: model.runPIDURL) }
        let restoreURL = restore.map { URL(fileURLWithPath: normalizePath($0)) }
        let saveURL = saveOnStop.map { URL(fileURLWithPath: normalizePath($0)) }
        try runVM(model: model, options: RunOptions(recoveryMode: recovery, restoreStateAt: restoreURL, saveStateOnStopAt: saveURL))
    }
}

@main
struct VM4AEntrypoint {
    static func main() async {
        await VM4ACLI.main()
    }
}
