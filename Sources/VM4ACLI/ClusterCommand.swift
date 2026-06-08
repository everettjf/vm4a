import ArgumentParser
import Foundation
import VM4ACore

struct ClusterCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cluster",
        abstract: "Schedule VMs across remote `vm4a serve` nodes",
        discussion: """
            Each node is an independent Mac running `vm4a serve`. Register nodes,
            then `cluster spawn` lands a VM on the least-loaded one.

              vm4a cluster add mac-studio --url http://10.0.0.5:7777 --token $TOK
              vm4a cluster spawn dev --from ghcr.io/org/python-dev:latest --wait-ssh
              vm4a cluster status
            """,
        subcommands: [
            ClusterAddCommand.self,
            ClusterRemoveCommand.self,
            ClusterListCommand.self,
            ClusterSpawnCommand.self,
            ClusterExecCommand.self,
            ClusterStatusCommand.self
        ],
        defaultSubcommand: ClusterListCommand.self
    )
}

struct ClusterAddCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "add", abstract: "Register a remote node")

    @Argument(help: "Node name")
    var name: String

    @Option(name: .long, help: "Base URL of the node's `vm4a serve` (e.g. http://10.0.0.5:7777)")
    var url: String

    @Option(name: .long, help: "Bearer token if the node was started with VM4A_AUTH_TOKEN")
    var token: String?

    mutating func run() throws {
        guard URL(string: url) != nil, url.hasPrefix("http") else {
            throw VM4AError.message("--url must be an http(s) URL")
        }
        try ClusterStore.save(ClusterNode(name: name, url: url, token: token))
        print("Added node \(name) → \(url)")
    }
}

struct ClusterRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "remove", abstract: "Unregister a node")

    @Argument(help: "Node name")
    var name: String

    mutating func run() throws {
        try ClusterStore.remove(name: name)
        print("Removed node \(name)")
    }
}

struct ClusterListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List registered nodes")

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() throws {
        let nodes = try ClusterStore.list()
        switch output {
        case .json:
            try writeJSONLine(nodes, pretty: pretty)
        case .text:
            if nodes.isEmpty { print("No cluster nodes. Add one with `vm4a cluster add`."); return }
            for n in nodes { print("\(n.name)\t\(n.url)\t\(n.token != nil ? "auth" : "open")") }
        }
    }
}

struct ClusterSpawnCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "spawn", abstract: "Spawn on the least-loaded node")

    @Argument(help: "VM name")
    var name: String

    @Option(name: .long, help: "OS type: linux (default) or macOS")
    var os: VMOSType = .linux

    @Option(name: .long, help: "OCI reference to pull if bundle missing")
    var from: String?

    @Option(name: .long, help: "Image spec (catalog id / path / URL)")
    var image: String?

    @Option(name: .long, help: "Remote parent directory for bundles")
    var storage: String?

    @Option(name: .long, help: "Network mode: none, nat (default), bridged, host")
    var network: String?

    @Flag(name: .long, help: "Wait for SSH before returning")
    var waitSSH: Bool = false

    @Option(name: .long, help: "Wait timeout seconds")
    var waitTimeout: Int = 90

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        let result = try await clusterSpawn(options: ClusterSpawnOptions(
            name: name, os: os, from: from, image: image, storage: storage,
            network: network, waitSSH: waitSSH, waitTimeout: waitTimeout
        ))
        switch output {
        case .json:
            try writeJSONLine(result, pretty: pretty)
        case .text:
            print("Spawned \(result.outcome.name) on node \(result.node)")
            print("  path: \(result.outcome.path)")
            if let ip = result.outcome.ip { print("  ip:   \(ip)") }
            if waitSSH { print("  ssh:  \(result.outcome.sshReady ? "ready" : "not ready")") }
        }
    }
}

struct ClusterExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "exec", abstract: "Exec on a specific node's VM")

    @Option(name: .long, help: "Node name that holds the VM")
    var node: String

    @Argument(help: "VM bundle path on the remote node")
    var vmPath: String

    @Option(name: .long, help: "Wall-clock timeout seconds")
    var timeout: Int = 60

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    @Argument(parsing: .postTerminator, help: "Command and arguments to run in the VM (after `--`)")
    var command: [String] = []

    mutating func run() async throws {
        guard !command.isEmpty else {
            throw VM4AError.message("Provide a command after `--`.")
        }
        let result = try await clusterExec(nodeName: node, vmPath: vmPath, command: command, timeout: timeout)
        switch output {
        case .json:
            try writeJSONLine(result, pretty: pretty)
        case .text:
            FileHandle.standardOutput.write(Data(result.stdout.utf8))
            FileHandle.standardError.write(Data(result.stderr.utf8))
        }
        if result.exitCode != 0 { throw ExitCode(result.exitCode) }
    }
}

struct ClusterStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(commandName: "status", abstract: "Aggregate VM counts across nodes")

    @Option(name: .long, help: "Remote storage dir to query (passed to each node)")
    var storage: String?

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    mutating func run() async throws {
        let rows = try await clusterStatus(storage: storage)
        switch output {
        case .json:
            try writeJSONLine(rows, pretty: pretty)
        case .text:
            if rows.isEmpty { print("No cluster nodes."); return }
            for r in rows {
                let state = r.reachable ? "\(r.vms.count) vm(s)" : "unreachable"
                print("\(r.node)\t\(r.url)\t\(state)")
            }
        }
    }
}
