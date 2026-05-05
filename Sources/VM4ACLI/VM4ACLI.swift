import ArgumentParser
import VM4ACore
import Foundation
import Virtualization

extension VMOSType: ExpressibleByArgument {}
extension NetworkMode: ExpressibleByArgument {
    public init?(argument: String) {
        guard let v = NetworkMode.parse(argument) else { return nil }
        self = v
    }
}

enum OutputFormat: String, ExpressibleByArgument {
    case text
    case json
}

func writeJSONLine<T: Encodable>(_ value: T, pretty: Bool = false) throws {
    let encoder = JSONEncoder()
    var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
    if pretty { formatting.insert(.prettyPrinted) }
    encoder.outputFormatting = formatting
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

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM bundle (Linux from ISO, or macOS from IPSW)",
        discussion: """
            Linux: pass --image with an ARM64 ISO; the bundle attaches it as
            a USB device for first-boot install.

            macOS: pass --image with an .ipsw and Apple's VZMacOSInstaller
            runs end-to-end (10–20 minutes). The resulting bundle boots into
            Setup Assistant on first run, which Apple does not expose a
            scriptable skip for; complete that step interactively in VM4A.app
            or via the VZ framebuffer, after which all other vm4a commands
            (run/exec/cp/fork/reset/…) work on macOS bundles just like Linux.
            """
    )

    @Argument(help: "VM name")
    var name: String

    @Option(name: .long, help: "OS type: linux (default) or macOS")
    var os: VMOSType = .linux

    @Option(name: .long, help: "Parent directory to store VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Image spec: catalog id (see `vm4a image list`), local file path, https:// URL, or omit for macOS to auto-fetch the latest IPSW.")
    var image: String?

    @Option(name: .long, help: "vCPU count")
    var cpu: Int?

    @Option(name: .long, help: "Memory size in GB")
    var memoryGB: Int?

    @Option(name: .long, help: "Disk size in GB")
    var diskGB: Int?

    @Option(name: .long, help: "Network mode: none, nat (default), bridged, host (alias for bridged)")
    var network: NetworkMode = .nat

    @Option(name: .long, help: "Bridged interface bsdName (used with --network bridged). Use 'vm4a network list' to enumerate.")
    var bridgedInterface: String?

    @Flag(name: .long, help: "Enable Rosetta translation share (Linux guest only, macOS 13+ host).")
    var rosetta: Bool = false

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        let memoryBytes = try memoryGB.map { try bytesFromGB($0, fieldName: "memory-gb") }
        let diskBytes = try diskGB.map { try bytesFromGB($0, fieldName: "disk-gb") }

        let progressSink: @Sendable (String) -> Void = { line in
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }

        // Resolve --image (catalog id / URL / local path) into a real file
        // path on disk, downloading + caching if needed.
        let resolvedImagePath: String?
        if image != nil || os == .macOS {
            let resolved = try await resolveImage(spec: image, os: os, progress: progressSink)
            resolvedImagePath = resolved.path()
        } else {
            resolvedImagePath = nil
        }

        let outcome = try await createBundle(
            options: CreateBundleOptions(
                name: name,
                os: os,
                storage: storageURL,
                imagePath: resolvedImagePath,
                cpu: cpu,
                memoryBytes: memoryBytes,
                diskBytes: diskBytes,
                networkMode: network,
                bridgedInterface: bridgedInterface,
                rosetta: rosetta
            ),
            progress: progressSink
        )
        if let warning = outcome.rosettaWarning {
            FileHandle.standardError.write(Data("warning: \(warning)\n".utf8))
        }

        switch output {
        case .json:
            try writeJSONLine(outcome, pretty: pretty)
        case .text:
            if os == .macOS, image == nil {
                print("Created macOS bundle skeleton at \(outcome.path).")
                print("Note: no IPSW given. Pass --image foo.ipsw to drive the full install,")
                print("or use `vm4a pull` to populate from a pre-installed bundle.")
            } else if os == .macOS {
                print("Installed macOS into \(outcome.path).")
                print("First boot lands at Setup Assistant — complete it in VM4A.app, then")
                print("enable Remote Login (Settings → General → Sharing) for SSH access.")
            } else {
                print("Created VM: \(outcome.path)")
            }
        }
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List VM bundles in a directory")

    @Option(name: .long, help: "Parent directory that contains VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() throws {
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        let rows = listVMSummaries(in: storageURL)

        switch output {
        case .json:
            try writeJSONLine(rows, pretty: pretty)
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
        abstract: "Image catalog: list, prefetch, locate cached files",
        subcommands: [ImageListCommand.self, ImagePullCommand.self, ImageWhereCommand.self],
        defaultSubcommand: ImageListCommand.self
    )
}

struct ImageListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List curated images (Linux ISOs + macOS IPSW)")

    mutating func run() throws {
        print("# Linux (ARM64)")
        for entry in linuxImageCatalog() {
            print("\(entry.id)\t\(entry.displayName)")
            print("  \(entry.url)")
        }
        print("")
        print("# macOS")
        for entry in macOSCatalog() {
            print("\(entry.id)\t\(entry.displayName)")
            if entry.url.hasPrefix("vz://") {
                print("  (resolved at fetch time via VZMacOSRestoreImage.fetchLatestSupported)")
            } else {
                print("  \(entry.url)")
            }
        }
    }
}

struct ImagePullCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pull",
        abstract: "Download an image to ~/.cache/vm4a/images/ (no-op if already cached)"
    )

    @Argument(help: "Catalog id (see `vm4a image list`), https:// URL, or `macos-latest`")
    var spec: String

    mutating func run() async throws {
        // Pick os heuristically: known Linux catalog ids or macos-latest decide it;
        // otherwise treat as Linux ISO unless extension hints IPSW.
        let os: VMOSType
        if spec == macOSLatestImageID || macOSCatalog().contains(where: { $0.id == spec }) {
            os = .macOS
        } else if spec.hasSuffix(".ipsw") {
            os = .macOS
        } else {
            os = .linux
        }
        let resolved = try await resolveImage(
            spec: spec,
            os: os,
            progress: { line in FileHandle.standardError.write(Data("\(line)\n".utf8)) }
        )
        print(resolved.path())
    }
}

struct ImageWhereCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "where",
        abstract: "Print the cache directory and any cached image files"
    )

    mutating func run() throws {
        let dir = try ImageCache.directory()
        print(dir.path())
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        for e in entries {
            let size = (try? e.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let mb = Double(size) / 1_048_576.0
            print(String(format: "  %@\t%.1f MB", e.lastPathComponent, mb))
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

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

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
            try writeJSONLine(rows, pretty: pretty)
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

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        _ = try loadModel(rootPath: rootURL)
        guard let beat = readGuestAgentHeartbeat(bundleRoot: rootURL) else {
            FileHandle.standardError.write(Data("No heartbeat found. Guest agent must be running inside the VM and mounting guest-agent/ via virtiofs.\n".utf8))
            throw ExitCode(4)
        }
        switch output {
        case .json: try writeJSONLine(beat, pretty: pretty)
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
