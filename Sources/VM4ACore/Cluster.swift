import Foundation

// MARK: - Multi-host scheduler
//
// A thin scheduler over remote `vm4a serve` nodes. Each node is an independent
// Mac running the HTTP API; this layer keeps a node registry and dispatches
// spawn/exec/status by calling `/v1/*` on the chosen node. No new daemon — it
// reuses the existing HTTP surface, so a node is "just" a `vm4a serve`.

public struct ClusterNode: Codable, Sendable, Equatable {
    public let name: String
    public let url: String
    public let token: String?

    public init(name: String, url: String, token: String? = nil) {
        self.name = name
        self.url = url
        self.token = token
    }

    public var baseURL: String { url.hasSuffix("/") ? String(url.dropLast()) : url }
}

public enum ClusterStore {
    public static func directory() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let dir = home.appending(path: ".vm4a/cluster", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func fileURL(for name: String) throws -> URL {
        try directory().appending(path: "\(name).json")
    }

    public static func save(_ node: ClusterNode) throws {
        try writeJSON(node, to: fileURL(for: node.name))
    }

    public static func remove(name: String) throws {
        let url = try fileURL(for: name)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            throw VM4AError.notFound("Cluster node '\(name)'")
        }
        try FileManager.default.removeItem(at: url)
    }

    public static func get(name: String) throws -> ClusterNode {
        let url = try fileURL(for: name)
        guard let data = try? Data(contentsOf: url),
              let node = try? JSONDecoder().decode(ClusterNode.self, from: data) else {
            throw VM4AError.notFound("Cluster node '\(name)'")
        }
        return node
    }

    public static func list() throws -> [ClusterNode] {
        let dir = try directory()
        let entries = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        var nodes: [ClusterNode] = []
        for e in entries where e.pathExtension == "json" {
            if let data = try? Data(contentsOf: e),
               let node = try? JSONDecoder().decode(ClusterNode.self, from: data) {
                nodes.append(node)
            }
        }
        return nodes.sorted { $0.name < $1.name }
    }
}

// MARK: - Remote HTTP client (calls a node's /v1/* surface)

public struct ClusterHTTPError: Error, CustomStringConvertible {
    public let status: Int
    public let body: String
    public var description: String { "node HTTP \(status): \(body)" }
}

func clusterRequest(node: ClusterNode, method: String, path: String, body: Data?) async throws -> Data {
    guard let url = URL(string: node.baseURL + path) else {
        throw VM4AError.message("Bad node URL: \(node.baseURL)\(path)")
    }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.setValue("application/json", forHTTPHeaderField: "Accept")
    if let body {
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    if let token = node.token, !token.isEmpty {
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    }
    let (data, response) = try await URLSession.shared.data(for: req)
    let status = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard (200..<300).contains(status) else {
        throw ClusterHTTPError(status: status, body: String(data: data, encoding: .utf8) ?? "")
    }
    return data
}

// MARK: - Scheduling

/// Index of the smallest count, or nil for an empty input. Pure + testable.
public func leastLoadedIndex(counts: [Int]) -> Int? {
    guard !counts.isEmpty else { return nil }
    var best = 0
    for i in counts.indices where counts[i] < counts[best] { best = i }
    return best
}

/// Count VMs currently reported by a node (best-effort; unreachable → Int.max
/// so it sorts last).
func nodeVMCount(_ node: ClusterNode, storage: String?) async -> Int {
    let path = storage.map { "/v1/vms?storage=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? "/v1/vms"
    guard let data = try? await clusterRequest(node: node, method: "GET", path: path, body: nil),
          let rows = try? JSONDecoder().decode([VMSummary].self, from: data) else {
        return Int.max
    }
    return rows.count
}

public struct ClusterSpawnResult: Codable, Sendable {
    public let node: String
    public let outcome: SpawnOutcome
}

struct ClusterSpawnBody: Encodable {
    let name: String
    let os: String
    let from: String?
    let image: String?
    let storage: String?
    let network: String?
    let wait_ssh: Bool
    let wait_timeout: Int
}

public struct ClusterSpawnOptions: Sendable {
    public var name: String
    public var os: VMOSType
    public var from: String?
    public var image: String?
    public var storage: String?
    public var network: String?
    public var waitSSH: Bool
    public var waitTimeout: Int

    public init(name: String, os: VMOSType = .linux, from: String? = nil, image: String? = nil,
                storage: String? = nil, network: String? = nil, waitSSH: Bool = false, waitTimeout: Int = 90) {
        self.name = name; self.os = os; self.from = from; self.image = image
        self.storage = storage; self.network = network; self.waitSSH = waitSSH; self.waitTimeout = waitTimeout
    }
}

/// Pick the least-loaded reachable node and spawn there.
public func clusterSpawn(options: ClusterSpawnOptions) async throws -> ClusterSpawnResult {
    let nodes = try ClusterStore.list()
    guard !nodes.isEmpty else { throw VM4AError.message("No cluster nodes. Add one with `vm4a cluster add`.") }

    var counts: [Int] = []
    for node in nodes { counts.append(await nodeVMCount(node, storage: options.storage)) }
    guard let idx = leastLoadedIndex(counts: counts), counts[idx] != Int.max else {
        throw VM4AError.message("No reachable cluster node.")
    }
    let node = nodes[idx]

    let body = try JSONEncoder().encode(ClusterSpawnBody(
        name: options.name,
        os: options.os.rawValue,
        from: options.from,
        image: options.image,
        storage: options.storage,
        network: options.network,
        wait_ssh: options.waitSSH,
        wait_timeout: options.waitTimeout
    ))
    let data = try await clusterRequest(node: node, method: "POST", path: "/v1/spawn", body: body)
    let outcome = try JSONDecoder().decode(SpawnOutcome.self, from: data)
    return ClusterSpawnResult(node: node.name, outcome: outcome)
}

struct ClusterExecBody: Encodable {
    let vm_path: String
    let command: [String]
    let timeout: Int
}

public func clusterExec(nodeName: String, vmPath: String, command: [String], timeout: Int) async throws -> ExecResult {
    let node = try ClusterStore.get(name: nodeName)
    let body = try JSONEncoder().encode(ClusterExecBody(vm_path: vmPath, command: command, timeout: timeout))
    let data = try await clusterRequest(node: node, method: "POST", path: "/v1/exec", body: body)
    return try JSONDecoder().decode(ExecResult.self, from: data)
}

public struct ClusterNodeStatus: Codable, Sendable {
    public let node: String
    public let url: String
    public let reachable: Bool
    public let vms: [VMSummary]
}

public func clusterStatus(storage: String?) async throws -> [ClusterNodeStatus] {
    let nodes = try ClusterStore.list()
    var out: [ClusterNodeStatus] = []
    for node in nodes {
        let path = storage.map { "/v1/vms?storage=\($0.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? $0)" } ?? "/v1/vms"
        if let data = try? await clusterRequest(node: node, method: "GET", path: path, body: nil),
           let rows = try? JSONDecoder().decode([VMSummary].self, from: data) {
            out.append(ClusterNodeStatus(node: node.name, url: node.baseURL, reachable: true, vms: rows))
        } else {
            out.append(ClusterNodeStatus(node: node.name, url: node.baseURL, reachable: false, vms: []))
        }
    }
    return out
}
