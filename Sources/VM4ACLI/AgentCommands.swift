import ArgumentParser
import Foundation
import VM4ACore

private func ownExecutablePath() throws -> String {
    guard let path = Bundle.main.executablePath else {
        throw VM4AError.message("Cannot locate vm4a executable path")
    }
    return path
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
              - Else if --image <iso>: create from scratch (Linux), then start.

            Designed for AI agents: --output json + --wait-ssh together give a
            single call that returns {ip, ssh_ready=true} or fails fast.
            """
    )

    @Argument(help: "VM name (becomes <storage>/<name>)")
    var name: String

    @Option(name: .long, help: "Parent directory to store VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Pull this OCI reference if bundle does not yet exist")
    var from: String?

    @Option(name: .long, help: "Local Linux ISO path to install from when creating fresh")
    var image: String?

    @Option(name: .long, help: "vCPU count")
    var cpu: Int?

    @Option(name: .long, help: "Memory size in GB")
    var memoryGB: Int?

    @Option(name: .long, help: "Disk size in GB")
    var diskGB: Int?

    @Option(name: .long, help: "Network mode: none, nat (default), bridged, host (alias for bridged)")
    var network: NetworkMode = .nat

    @Option(name: .long, help: "Bridged interface bsdName (used with --network bridged)")
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

    @Option(name: .long, help: "Append a session event to <bundle>/.vm4a-sessions/<id>.jsonl")
    var session: String?

    mutating func run() async throws {
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        let recorder = SessionRecorder(id: session, kind: "spawn", args: [
            "name": .string(name),
            "from": from.map { .string($0) } ?? .null,
            "image": image.map { .string($0) } ?? .null,
        ])
        defer { recorder.record() }

        let memoryBytes = try memoryGB.map { try bytesFromGB($0, fieldName: "memory-gb") }
        let diskBytes = try diskGB.map { try bytesFromGB($0, fieldName: "disk-gb") }
        let options = SpawnOptions(
            name: name,
            os: .linux,
            storage: storageURL,
            from: from,
            imagePath: image,
            cpu: cpu,
            memoryBytes: memoryBytes,
            diskBytes: diskBytes,
            networkMode: network,
            bridgedInterface: bridgedInterface,
            rosetta: rosetta,
            restoreStateAt: restore,
            saveOnStopAt: saveOnStop,
            waitIP: waitIP,
            waitSSH: waitSSH,
            sshUser: sshUser,
            sshKey: sshKey,
            hostOverride: host,
            waitTimeout: TimeInterval(waitTimeout)
        )
        let outcome = try await runSpawn(
            options: options,
            executable: try ownExecutablePath(),
            progress: { line in
                FileHandle.standardError.write(Data("\(line)\n".utf8))
            }
        )

        recorder.markSuccess(
            vmPath: outcome.path,
            outcome: try? jsonValue(outcome),
            summary: "spawn \(outcome.name) → ip=\(outcome.ip ?? "-") ssh=\(outcome.sshReady)"
        )

        switch output {
        case .json:
            try writeJSONLine(outcome)
        case .text:
            print("Spawned \(outcome.name) at \(outcome.path) (id=\(outcome.id))")
            if let pid = outcome.pid { print("  pid: \(pid)") }
            if let ip = outcome.ip { print("  ip:  \(ip)") }
            if waitSSH { print("  ssh: \(outcome.sshReady ? "ready" : "not ready")") }
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

    @Option(name: .long, help: "SSH login user (default: root)")
    var user: String?

    @Option(name: .long, help: "SSH key path")
    var key: String?

    @Option(name: .long, help: "Override target host (skip DHCP lookup)")
    var host: String?

    @Option(name: .long, help: "Wall-clock timeout in seconds")
    var timeout: Int = 60

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Option(name: .long, help: "Append a session event to <bundle>/.vm4a-sessions/<id>.jsonl")
    var session: String?

    @Argument(parsing: .captureForPassthrough, help: "Command and arguments to run in the VM")
    var command: [String] = []

    mutating func run() throws {
        guard !command.isEmpty else {
            throw VM4AError.message("Provide a command after `--`. Example: vm4a exec /path/to/vm -- whoami")
        }
        let recorder = SessionRecorder(
            id: session,
            kind: "exec",
            args: ["command": .array(command.map { .string($0) })],
            vmPath: vmPath
        )
        defer { recorder.record() }

        let result = try runExec(options: ExecOptions(
            vmPath: vmPath,
            user: user,
            key: key,
            hostOverride: host,
            timeout: TimeInterval(timeout),
            command: command
        ))

        if result.exitCode == 0 {
            recorder.markSuccess(
                vmPath: vmPath,
                outcome: try? jsonValue(result),
                summary: "exec \(command.first ?? "") → exit 0"
            )
        } else {
            recorder.outcomeJSON = try? jsonValue(result)
            recorder.markFailure(
                vmPath: vmPath,
                summary: "exec \(command.first ?? "") → exit \(result.exitCode)\(result.timedOut ? " (timed out)" : "")"
            )
        }

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

    @Option(name: .long, help: "Append a session event to <bundle>/.vm4a-sessions/<id>.jsonl")
    var session: String?

    mutating func run() throws {
        let recorder = SessionRecorder(
            id: session,
            kind: "cp",
            args: [
                "source": .string(source),
                "destination": .string(destination),
                "recursive": .bool(recursive),
            ],
            vmPath: vmPath
        )
        defer { recorder.record() }

        let result = try runCp(options: CpOptions(
            vmPath: vmPath,
            source: source,
            destination: destination,
            recursive: recursive,
            user: user,
            key: key,
            hostOverride: host,
            timeout: TimeInterval(timeout)
        ))

        if result.exitCode == 0 {
            recorder.markSuccess(
                vmPath: vmPath,
                outcome: try? jsonValue(result),
                summary: "cp \(source) → \(destination)"
            )
        } else {
            recorder.outcomeJSON = try? jsonValue(result)
            recorder.markFailure(
                vmPath: vmPath,
                summary: "cp \(source) → \(destination) (exit \(result.exitCode))"
            )
        }

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

struct ForkCommand: ParsableCommand {
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

    @Option(name: .long, help: "Append a session event to <bundle>/.vm4a-sessions/<id>.jsonl")
    var session: String?

    mutating func run() throws {
        let recorder = SessionRecorder(
            id: session,
            kind: "fork",
            args: [
                "source_path": .string(sourcePath),
                "destination_path": .string(destinationPath),
                "auto_start": .bool(autoStart),
            ]
        )
        defer { recorder.record() }

        let outcome = try runFork(
            options: ForkOptions(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                fromSnapshot: fromSnapshot,
                autoStart: autoStart,
                waitIP: waitIP,
                waitSSH: waitSSH,
                sshUser: sshUser,
                sshKey: sshKey,
                waitTimeout: TimeInterval(waitTimeout)
            ),
            executable: try ownExecutablePath()
        )

        recorder.markSuccess(
            vmPath: outcome.path,
            outcome: try? jsonValue(outcome),
            summary: "fork \(sourcePath) → \(outcome.path)\(outcome.started ? " (started)" : "")"
        )

        switch output {
        case .json:
            try writeJSONLine(outcome)
        case .text:
            print("Forked \(sourcePath) → \(outcome.path)")
            if outcome.started, let pid = outcome.pid { print("  started, pid \(pid)") }
            if let ip = outcome.ip { print("  ip:  \(ip)") }
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

    @Option(name: .long, help: "Append a session event to <bundle>/.vm4a-sessions/<id>.jsonl")
    var session: String?

    mutating func run() throws {
        let recorder = SessionRecorder(
            id: session,
            kind: "reset",
            args: ["from": .string(from)],
            vmPath: vmPath
        )
        defer { recorder.record() }

        let outcome = try runReset(
            options: ResetOptions(
                vmPath: vmPath,
                fromSnapshot: from,
                waitIP: waitIP,
                stopTimeout: TimeInterval(stopTimeout),
                waitTimeout: TimeInterval(waitTimeout)
            ),
            executable: try ownExecutablePath()
        )

        recorder.markSuccess(
            vmPath: outcome.path,
            outcome: try? jsonValue(outcome),
            summary: "reset \(outcome.path) ← \(outcome.restored)"
        )

        switch output {
        case .json:
            try writeJSONLine(outcome)
        case .text:
            print("Reset \(outcome.path) from snapshot \(outcome.restored)")
            if let pid = outcome.pid { print("  pid: \(pid)") }
            if let ip = outcome.ip { print("  ip:  \(ip)") }
        }
    }
}
