import ArgumentParser
import Foundation
import VM4ACore

struct PoolCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pool",
        abstract: "Manage agent VM pool definitions and warm-pool runtimes",
        discussion: """
            Pool definitions describe "how to mint a fresh per-task VM
            from a base bundle". They live as JSON at ~/.vm4a/pools/<name>.json.

            Two ways to use a pool:

            1. On-demand:        vm4a pool spawn <name>
               Equivalent to fork+autostart, useful when latency is fine.

            2. Pre-warmed:       vm4a pool serve <name> --size N    (foreground daemon)
                                 vm4a pool acquire <name>           (claim an idle VM)
                                 vm4a pool release <vm-path>        (return + refill)
               The daemon keeps N idle VMs ready; acquire is an atomic
               filesystem rename, so handing one out is millisecond-fast.
            """,
        subcommands: [
            PoolCreateCommand.self,
            PoolShowCommand.self,
            PoolListCommand.self,
            PoolSpawnCommand.self,
            PoolServeCommand.self,
            PoolAcquireCommand.self,
            PoolReleaseCommand.self,
            PoolDestroyCommand.self
        ],
        defaultSubcommand: PoolListCommand.self
    )
}

struct PoolCreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Save a pool definition")

    @Argument(help: "Pool name (used in spawn / destroy)")
    var name: String

    @Option(name: .long, help: "Base bundle path to fork from")
    var base: String

    @Option(name: .long, help: "Optional .vzstate snapshot to restore on each spawn")
    var snapshot: String?

    @Option(name: .long, help: "Naming prefix for forked VMs")
    var prefix: String?

    @Option(name: .long, help: "Where to put forked VMs")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Warm-pool target size (used by `vm4a pool serve`). 0 = on-demand only.")
    var size: Int = 0

    mutating func run() throws {
        let pool = PoolDefinition(
            name: name,
            basePath: normalizePath(base),
            snapshot: snapshot.map(normalizePath),
            prefix: prefix ?? name,
            storage: normalizePath(storage),
            size: size
        )
        try PoolStore.save(pool)
        print("Created pool '\(name)' (base \(pool.basePath), size=\(pool.size))")
    }
}

struct PoolShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a pool definition")

    @Argument(help: "Pool name")
    var name: String

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() throws {
        let pool = try PoolStore.load(name: name)
        switch output {
        case .json: try writeJSONLine(pool, pretty: pretty)
        case .text:
            print("name:     \(pool.name)")
            print("base:     \(pool.basePath)")
            print("snapshot: \(pool.snapshot ?? "-")")
            print("prefix:   \(pool.prefix)")
            print("storage:  \(pool.storage)")
            print("size:     \(pool.size)")
            let (warm, leased) = pool.discover()
            print("warm:     \(warm.count) (\(warm.map { $0.lastPathComponent }.joined(separator: ", ")))")
            print("leased:   \(leased.count) (\(leased.map { $0.lastPathComponent }.joined(separator: ", ")))")
        }
    }
}

struct PoolListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved pool definitions")

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() throws {
        let pools = try PoolStore.list()
        switch output {
        case .json: try writeJSONLine(pools, pretty: pretty)
        case .text:
            if pools.isEmpty {
                print("No pool definitions. Create one with: vm4a pool create <name> --base ...")
                return
            }
            for pool in pools {
                print("\(pool.name)\t\(pool.basePath)\t\(pool.snapshot ?? "-")")
            }
        }
    }
}

struct PoolDestroyCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "destroy", abstract: "Forget a pool definition")

    @Argument(help: "Pool name")
    var name: String

    mutating func run() throws {
        try PoolStore.remove(name: name)
        print("Removed pool '\(name)'")
    }
}

// MARK: - vm4a pool serve

struct PoolServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run the warm-pool daemon: keep N idle VMs ready, refill on demand",
        discussion: """
            Foreground daemon. Polls the storage directory every few seconds
            and ensures `--size` (or the pool definition's saved size) idle
            VMs exist as <storage>/<prefix>-warm-<n>. When `vm4a pool acquire`
            consumes one, the daemon spawns a replacement on its next tick.

            Warm VMs are forked from the base bundle (APFS clonefile) and
            optionally restored from the saved snapshot, then started.
            The daemon does not destroy them on exit — restart picks up
            where it left off.
            """
    )

    @Argument(help: "Pool name")
    var name: String

    @Option(name: .long, help: "Override the pool's saved warm-pool size")
    var size: Int?

    @Option(name: .long, help: "Poll interval in seconds")
    var interval: Int = 5

    mutating func run() async throws {
        guard let executable = Bundle.main.executablePath else {
            throw VM4AError.message("Cannot locate vm4a executable path")
        }
        let pool = try PoolStore.load(name: name)
        let target = size ?? pool.size
        guard target > 0 else {
            throw VM4AError.message("pool '\(name)' has size=0; pass --size N or recreate with --size.")
        }

        try FileManager.default.createDirectory(
            at: URL(fileURLWithPath: pool.storage, isDirectory: true),
            withIntermediateDirectories: true
        )

        FileHandle.standardError.write(Data("vm4a pool serve '\(name)': target size=\(target), interval=\(interval)s\n".utf8))

        var nextSeq = 1
        while true {
            let (warm, _) = pool.discover()
            // Bump the seq counter past any existing warm bundle's number
            for url in warm {
                let suffix = url.lastPathComponent
                    .replacingOccurrences(of: "\(pool.prefix)-warm-", with: "")
                if let n = Int(suffix), n >= nextSeq { nextSeq = n + 1 }
            }
            if warm.count < target {
                let toSpawn = target - warm.count
                for _ in 0..<toSpawn {
                    let dst = pool.warmPath(seq: nextSeq); nextSeq += 1
                    do {
                        FileHandle.standardError.write(Data("  spawning \(dst.lastPathComponent)\n".utf8))
                        _ = try runFork(options: ForkOptions(
                            sourcePath: pool.basePath,
                            destinationPath: dst.path(),
                            fromSnapshot: pool.snapshot,
                            autoStart: true,
                            waitIP: false,
                            waitSSH: false,
                            waitTimeout: 60
                        ), executable: executable)
                    } catch {
                        FileHandle.standardError.write(Data("  spawn failed: \(error)\n".utf8))
                    }
                }
            }
            try? await Task.sleep(nanoseconds: UInt64(interval) * 1_000_000_000)
        }
    }
}

// MARK: - vm4a pool acquire

struct PoolAcquireCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "acquire",
        abstract: "Atomically claim an idle warm VM from the pool"
    )

    @Argument(help: "Pool name")
    var name: String

    @Option(name: .long, help: "Lease label (default: timestamp). Becomes part of the destination path: <prefix>-leased-<label>.")
    var label: String?

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() throws {
        let pool = try PoolStore.load(name: name)
        let (warm, _) = pool.discover()
        guard let claim = warm.first else {
            throw VM4AError.invalidState("pool '\(name)' has no warm VMs available. Is `vm4a pool serve \(name)` running?")
        }
        let leaseLabel = label ?? "\(Int(Date().timeIntervalSince1970))"
        let dst = pool.leasedPath(label: leaseLabel)
        // Atomic rename (same volume) — handing out is race-safe.
        try FileManager.default.moveItem(at: claim, to: dst)

        struct Outcome: Encodable {
            let path: String
            let name: String
            let label: String
        }
        let outcome = Outcome(path: dst.path(), name: dst.lastPathComponent, label: leaseLabel)
        switch output {
        case .json: try writeJSONLine(outcome, pretty: pretty)
        case .text:
            print("Acquired \(outcome.path)")
        }
    }
}

// MARK: - vm4a pool release

struct PoolReleaseCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release",
        abstract: "Stop and remove a leased VM (the daemon will refill)"
    )

    @Argument(help: "Path to the leased VM bundle (from `vm4a pool acquire`)")
    var vmPath: String

    @Option(name: .long, help: "Stop timeout in seconds")
    var stopTimeout: Int = 20

    mutating func run() throws {
        let url = URL(fileURLWithPath: vmPath, isDirectory: true)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw VM4AError.notFound(vmPath)
        }
        // Best-effort stop: if a worker is running, send SIGTERM and wait.
        if let model = try? loadModel(rootPath: url),
           let pid = readPID(from: model.runPIDURL),
           isProcessRunning(pid: pid) {
            _ = kill(pid, SIGTERM)
            let deadline = Date().addingTimeInterval(TimeInterval(stopTimeout))
            while Date() < deadline {
                if !isProcessRunning(pid: pid) { break }
                Thread.sleep(forTimeInterval: 0.25)
            }
            if isProcessRunning(pid: pid) { _ = kill(pid, SIGKILL) }
        }
        try FileManager.default.removeItem(at: url)
        print("Released \(vmPath)")
    }
}

struct PoolSpawnCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "spawn",
        abstract: "Mint a fresh VM from a pool definition (today: fork+autostart)",
        discussion: """
            Today this is equivalent to calling `vm4a fork --auto-start
            --from-snapshot` with the parameters from the pool definition.
            The warm-pool runtime (idle pre-spawned VMs ready in milliseconds)
            ships in v2.4.
            """
    )

    @Argument(help: "Pool name")
    var name: String

    @Option(name: .long, help: "Override the generated VM name (default: <prefix>-<n>)")
    var asName: String?

    @Flag(name: .long, help: "Wait for the VM to acquire a NAT DHCP IP before returning")
    var waitIP: Bool = false

    @Flag(name: .long, help: "Wait for SSH (implies --wait-ip)")
    var waitSSH: Bool = false

    @Option(name: .long, help: "Wait timeout for IP / SSH in seconds")
    var waitTimeout: Int = 90

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() throws {
        let pool = try PoolStore.load(name: name)
        let storageURL = URL(fileURLWithPath: pool.storage, isDirectory: true)
        let vmName = asName ?? "\(pool.prefix)-\(Int(Date().timeIntervalSince1970))"
        let dst = storageURL.appending(path: vmName, directoryHint: .isDirectory).path()

        guard let executable = Bundle.main.executablePath else {
            throw VM4AError.message("Cannot locate vm4a executable path")
        }

        let outcome = try runFork(options: ForkOptions(
            sourcePath: pool.basePath,
            destinationPath: dst,
            fromSnapshot: pool.snapshot,
            autoStart: true,
            waitIP: waitIP || waitSSH,
            waitSSH: waitSSH,
            waitTimeout: TimeInterval(waitTimeout)
        ), executable: executable)

        switch output {
        case .json: try writeJSONLine(outcome, pretty: pretty)
        case .text:
            print("Pool '\(name)' minted: \(outcome.path)")
            if let pid = outcome.pid { print("  pid: \(pid)") }
            if let ip = outcome.ip { print("  ip:  \(ip)") }
        }
    }
}
