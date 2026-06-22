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
        discussion: """
            Quick start (zero flags — auto-named default Linux VM):
              vm4a spawn                 create + start, then `vm4a ssh <name>`
              vm4a spawn --wait-ssh      block until SSH is reachable

            Commands are grouped below. The five at the top cover most use; the
            rest are grouped by area. Run `vm4a <command> --help` for details.
            """,
        version: vm4aVersion,
        subcommands: [
            // Most-used, shown first as the ungrouped "SUBCOMMANDS" set.
            SpawnCommand.self,
            ExecCommand.self,
            CpCommand.self,
            SSHCommand.self,
            ListCommand.self,
            // Internal worker (hidden via shouldDisplay: false on its config),
            // kept registered because `vm4a run` re-invokes it as a subprocess.
            RunWorkerCommand.self
        ],
        groupedSubcommands: [
            CommandGroup(name: "Agent workflow", subcommands: [
                ForkCommand.self,
                ResetCommand.self,
                RunCodeCommand.self,
                ExposePortCommand.self,
                AgentCommand.self
            ]),
            CommandGroup(name: "VM lifecycle", subcommands: [
                CreateCommand.self,
                RunCommand.self,
                StopCommand.self,
                CloneCommand.self,
                IPCommand.self
            ]),
            CommandGroup(name: "Snapshots", subcommands: [
                SnapshotCommand.self,
                RestoreCommand.self
            ]),
            CommandGroup(name: "Images & registry", subcommands: [
                ImageCommand.self,
                PushCommand.self,
                PullCommand.self
            ]),
            CommandGroup(name: "Networking", subcommands: [
                NetworkCommand.self
            ]),
            CommandGroup(name: "Scale & orchestration", subcommands: [
                PoolCommand.self,
                ClusterCommand.self
            ]),
            CommandGroup(name: "Sessions & servers", subcommands: [
                SessionCommand.self,
                ServeCommand.self,
                MCPCommand.self
            ])
        ]
    )
}

struct CreateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "create",
        abstract: "Create a VM bundle (Linux from ISO, or macOS from IPSW)",
        discussion: """
            Quick start: `vm4a create` with no arguments builds a Linux VM from
            the default image with an auto-generated name and sensible CPU /
            memory / disk / NAT defaults. Override only what you need.

            Linux: --image takes an ARM64 ISO (catalog id, local path, or URL);
            the bundle attaches it as a USB device for first-boot install. Omit
            it to use the default distro (\(defaultLinuxImageID)).

            macOS: pass --image with an .ipsw (or omit it to auto-fetch Apple's
            latest supported IPSW); VZMacOSInstaller runs end-to-end (10–20 min).
            The resulting bundle boots into Setup Assistant on first run, which
            Apple does not expose a scriptable skip for; complete that step
            interactively in VM4A.app or via the VZ framebuffer, after which all
            other vm4a commands (run/exec/cp/fork/reset/…) work just like Linux.
            """
    )

    @Argument(help: "VM name (optional; auto-generated as vm-XXXXXX if omitted)")
    var name: String?

    @Option(name: .long, help: "OS type: linux (default) or macOS")
    var os: VMOSType = .linux

    @Option(name: .long, help: "Parent directory to store VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Image spec: catalog id (see `vm4a image list`), local file path, or https:// URL. Omit to use a sensible default (Linux → \(defaultLinuxImageID); macOS → latest IPSW).")
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
        let vmName = name ?? generatedVMName()
        let memoryBytes = try memoryGB.map { try bytesFromGB($0, fieldName: "memory-gb") }
        let diskBytes = try diskGB.map { try bytesFromGB($0, fieldName: "disk-gb") }

        let progressSink: @Sendable (String) -> Void = { line in
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }

        // Resolve --image (catalog id / URL / local path) into a real file
        // path on disk, downloading + caching if needed. Omitting --image
        // falls back to a sensible default for the chosen OS.
        let resolved = try await resolveImage(spec: image, os: os, progress: progressSink)
        let resolvedImagePath: String? = resolved.path()

        let outcome = try await createBundle(
            options: CreateBundleOptions(
                name: vmName,
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
            if os == .macOS {
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

        // Make the clone a fully independent VM: fresh MachineIdentifier + NIC
        // MAC (so it doesn't share a DHCP lease with the source), and a name
        // matching its own directory.
        try reidentifyVM(model: model)
        try renameBundle(at: dst, to: dst.lastPathComponent)

        print("Cloned VM to \(dst.path()) \(viaClone ? "(APFS clonefile)" : "(byte copy)")")
    }
}

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Inspect host network interfaces and apply guest egress policy",
        subcommands: [ListBridgedCommand.self, GuardCommand.self],
        defaultSubcommand: ListBridgedCommand.self
    )
}

struct GuardCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "guard",
        abstract: "Apply (or re-apply) an nftables egress allow-list inside a running Linux guest",
        discussion: """
            With --allow-domains, writes the policy to <bundle>/egress.json and
            applies it. Without it, re-applies the previously saved policy.

            Example:
              vm4a network guard /tmp/vm4a/dev --allow-domains pypi.org,github.com
            """
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Comma-separated domains to allow. If omitted, reuse <bundle>/egress.json.")
    var allowDomains: String?

    @Option(name: .long, help: "SSH login user")
    var user: String?

    @Option(name: .long, help: "SSH key path")
    var key: String?

    @Option(name: .long, help: "Override target host (skip DHCP lookup)")
    var host: String?

    @Option(name: .long, help: "Wall-clock timeout in seconds")
    var timeout: Int = 60

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)
        guard model.config.type == .linux else {
            throw VM4AError.message("Egress policy is Linux-only (guest needs nftables).")
        }

        let domains: [String]
        if let parsed = allowDomains.map(parseCommaList), !parsed.isEmpty {
            domains = parsed
            try writeEgressPolicy(EgressPolicy(allowDomains: domains), to: model.egressPolicyURL)
        } else if let saved = readEgressPolicy(at: model.egressPolicyURL), !saved.allowDomains.isEmpty {
            domains = saved.allowDomains
        } else {
            throw VM4AError.message("No --allow-domains given and no saved policy at \(model.egressPolicyURL.path()).")
        }

        let target: String
        if let host { target = host }
        else if let lease = findLeasesForBundle(model).first { target = lease.ipAddress }
        else { throw VM4AError.notFound("DHCP lease for \(model.config.name); pass --host if bridged.") }

        let user = self.user ?? "root"
        let result = try applyEgressPolicy(
            host: target,
            sshOptions: SSHOptions(user: user, keyPath: key),
            allowDomains: domains,
            timeout: TimeInterval(timeout)
        )
        FileHandle.standardOutput.write(Data(result.stdout.utf8))
        FileHandle.standardError.write(Data(result.stderr.utf8))
        if result.exitCode != 0 { throw ExitCode(result.exitCode) }
    }
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

    @Argument(parsing: .postTerminator, help: "Extra ssh args / remote command (after `--`)")
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
        abstract: "Internal worker command",
        shouldDisplay: false
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
