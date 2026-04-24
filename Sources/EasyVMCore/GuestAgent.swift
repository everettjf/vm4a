import Foundation

public enum GuestAgentTag {
    public static let shareName = "easyvm-agent"
    public static let heartbeatFile = "heartbeat.json"
    public static let commandFile = "command.json"
    public static let responseFile = "response.json"
}

public struct GuestAgentHeartbeat: Codable, Sendable {
    public let timestamp: Date
    public let version: String
    public let hostname: String
    public let uptimeSeconds: Double

    public init(timestamp: Date, version: String, hostname: String, uptimeSeconds: Double) {
        self.timestamp = timestamp
        self.version = version
        self.hostname = hostname
        self.uptimeSeconds = uptimeSeconds
    }
}

public struct GuestAgentCommand: Codable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case ping
        case shutdown
        case runScript
        case setClipboard
        case getClipboard
    }
    public let id: String
    public let kind: Kind
    public let payload: String?

    public init(id: String = UUID().uuidString, kind: Kind, payload: String? = nil) {
        self.id = id
        self.kind = kind
        self.payload = payload
    }
}

public struct GuestAgentResponse: Codable, Sendable {
    public let id: String
    public let ok: Bool
    public let output: String?
    public let error: String?

    public init(id: String, ok: Bool, output: String? = nil, error: String? = nil) {
        self.id = id
        self.ok = ok
        self.output = output
        self.error = error
    }
}

public func guestAgentDirectory(bundleRoot: URL) -> URL {
    bundleRoot.appending(path: "guest-agent", directoryHint: .isDirectory)
}

public func ensureGuestAgentDirectory(bundleRoot: URL) throws -> URL {
    let url = guestAgentDirectory(bundleRoot: bundleRoot)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

public func writeGuestAgentCommand(bundleRoot: URL, command: GuestAgentCommand) throws {
    let dir = try ensureGuestAgentDirectory(bundleRoot: bundleRoot)
    let data = try JSONEncoder().encode(command)
    try atomicWrite(data: data, to: dir.appending(path: GuestAgentTag.commandFile))
}

public func readGuestAgentHeartbeat(bundleRoot: URL) -> GuestAgentHeartbeat? {
    let url = guestAgentDirectory(bundleRoot: bundleRoot).appending(path: GuestAgentTag.heartbeatFile)
    guard let data = try? Data(contentsOf: url) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(GuestAgentHeartbeat.self, from: data)
}

public func readGuestAgentResponse(bundleRoot: URL, id: String) -> GuestAgentResponse? {
    let url = guestAgentDirectory(bundleRoot: bundleRoot).appending(path: GuestAgentTag.responseFile)
    guard let data = try? Data(contentsOf: url) else { return nil }
    guard let resp = try? JSONDecoder().decode(GuestAgentResponse.self, from: data) else { return nil }
    return resp.id == id ? resp : nil
}

public func atomicWrite(data: Data, to url: URL) throws {
    let tmp = url.appendingPathExtension("tmp-\(UUID().uuidString)")
    try data.write(to: tmp)
    _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
}
