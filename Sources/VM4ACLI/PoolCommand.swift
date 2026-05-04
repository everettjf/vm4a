import ArgumentParser
import Foundation
import VM4ACore

struct PoolCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "pool",
        abstract: "Manage agent VM pool definitions (v2.4 scaffolding)",
        discussion: """
            A pool definition records "how to mint a fresh per-task VM from
            a base bundle". Today `vm4a pool spawn` just performs a
            `fork --auto-start --from-snapshot` using the saved definition.
            The full warm-pool runtime (keep N idle VMs hot, hand one out
            on demand, refill in the background) lands in v2.4.

            Definitions are JSON files at ~/.vm4a/pools/<name>.json.
            """,
        subcommands: [
            PoolCreateCommand.self,
            PoolShowCommand.self,
            PoolListCommand.self,
            PoolSpawnCommand.self,
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

    mutating func run() throws {
        let pool = PoolDefinition(
            name: name,
            basePath: normalizePath(base),
            snapshot: snapshot.map(normalizePath),
            prefix: prefix ?? name,
            storage: normalizePath(storage)
        )
        try PoolStore.save(pool)
        print("Created pool '\(name)' (base \(pool.basePath))")
    }
}

struct PoolShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a pool definition")

    @Argument(help: "Pool name")
    var name: String

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let pool = try PoolStore.load(name: name)
        switch output {
        case .json: try writeJSONLine(pool)
        case .text:
            print("name:     \(pool.name)")
            print("base:     \(pool.basePath)")
            print("snapshot: \(pool.snapshot ?? "-")")
            print("prefix:   \(pool.prefix)")
            print("storage:  \(pool.storage)")
        }
    }
}

struct PoolListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List saved pool definitions")

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let pools = try PoolStore.list()
        switch output {
        case .json: try writeJSONLine(pools)
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
        case .json: try writeJSONLine(outcome)
        case .text:
            print("Pool '\(name)' minted: \(outcome.path)")
            if let pid = outcome.pid { print("  pid: \(pid)") }
            if let ip = outcome.ip { print("  ip:  \(ip)") }
        }
    }
}
