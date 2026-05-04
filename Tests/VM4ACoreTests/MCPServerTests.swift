import VM4ACore
import Foundation
import Testing

/// In-memory MCP transport: queue lines on input, capture lines on output.
final class InMemoryMCPTransport: MCPTransport, @unchecked Sendable {
    private var inputLines: [String]
    private(set) var outputLines: [String] = []
    private let lock = NSLock()

    init(input: [String]) { self.inputLines = input }

    func readLine() throws -> String? {
        lock.lock(); defer { lock.unlock() }
        guard !inputLines.isEmpty else { return nil }
        return inputLines.removeFirst()
    }

    func write(_ line: String) throws {
        lock.lock(); defer { lock.unlock() }
        outputLines.append(line.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

private func parseResponse(_ line: String) throws -> [String: Any] {
    let data = Data(line.utf8)
    return try (JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
}

struct MCPServerTests {
    @Test
    func initializeReturnsServerInfoAndProtocolVersion() async throws {
        let req = """
        {"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"unit","version":"0"}}}
        """
        let transport = InMemoryMCPTransport(input: [req])
        let server = MCPServer(
            config: MCPServerConfig(executablePath: "/usr/bin/true"),
            transport: transport
        )
        try await server.run()

        #expect(transport.outputLines.count == 1)
        let resp = try parseResponse(transport.outputLines[0])
        #expect(resp["jsonrpc"] as? String == "2.0")
        #expect(resp["id"] as? Int == 1)
        let result = try #require(resp["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == "2024-11-05")
        let serverInfo = try #require(result["serverInfo"] as? [String: Any])
        #expect(serverInfo["name"] as? String == "vm4a")
    }

    @Test
    func toolsListEnumeratesAllAgentTools() async throws {
        let req = #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#
        let transport = InMemoryMCPTransport(input: [req])
        let server = MCPServer(
            config: MCPServerConfig(executablePath: "/usr/bin/true"),
            transport: transport
        )
        try await server.run()

        let resp = try parseResponse(transport.outputLines[0])
        let result = try #require(resp["result"] as? [String: Any])
        let tools = try #require(result["tools"] as? [[String: Any]])
        let names = Set(tools.compactMap { $0["name"] as? String })
        #expect(names.contains("spawn"))
        #expect(names.contains("exec"))
        #expect(names.contains("cp"))
        #expect(names.contains("fork"))
        #expect(names.contains("reset"))
        #expect(names.contains("list"))
        #expect(names.contains("ip"))
        #expect(names.contains("stop"))
    }

    @Test
    func toolsCallListReturnsEmptyArrayForEmptyDirectory() async throws {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-mcp-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let req = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"list","arguments":{"storage":"\#(temp.path())"}}}"#
        let transport = InMemoryMCPTransport(input: [req])
        let server = MCPServer(
            config: MCPServerConfig(executablePath: "/usr/bin/true"),
            transport: transport
        )
        try await server.run()

        let resp = try parseResponse(transport.outputLines[0])
        let result = try #require(resp["result"] as? [String: Any])
        let content = try #require(result["content"] as? [[String: Any]])
        #expect(content.count == 1)
        let text = try #require(content[0]["text"] as? String)
        // Result text is pretty-printed JSON of a [VMSummary] array; empty.
        let parsed = try JSONSerialization.jsonObject(with: Data(text.utf8))
        let arr = try #require(parsed as? [Any])
        #expect(arr.isEmpty)
    }

    @Test
    func unknownToolRetursIsErrorFrame() async throws {
        let req = #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"nonexistent","arguments":{}}}"#
        let transport = InMemoryMCPTransport(input: [req])
        let server = MCPServer(
            config: MCPServerConfig(executablePath: "/usr/bin/true"),
            transport: transport
        )
        try await server.run()

        let resp = try parseResponse(transport.outputLines[0])
        let result = try #require(resp["result"] as? [String: Any])
        #expect(result["isError"] as? Bool == true)
    }

    @Test
    func unknownMethodReturnsMethodNotFound() async throws {
        let req = #"{"jsonrpc":"2.0","id":5,"method":"definitely_not_real"}"#
        let transport = InMemoryMCPTransport(input: [req])
        let server = MCPServer(
            config: MCPServerConfig(executablePath: "/usr/bin/true"),
            transport: transport
        )
        try await server.run()

        let resp = try parseResponse(transport.outputLines[0])
        let error = try #require(resp["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32601)
    }

    @Test
    func notificationsProduceNoResponse() async throws {
        let req = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#
        let transport = InMemoryMCPTransport(input: [req])
        let server = MCPServer(
            config: MCPServerConfig(executablePath: "/usr/bin/true"),
            transport: transport
        )
        try await server.run()

        #expect(transport.outputLines.isEmpty)
    }

    @Test
    func malformedJSONProducesParseError() async throws {
        let req = "not json at all {"
        let transport = InMemoryMCPTransport(input: [req])
        let server = MCPServer(
            config: MCPServerConfig(executablePath: "/usr/bin/true"),
            transport: transport
        )
        try await server.run()

        let resp = try parseResponse(transport.outputLines[0])
        let error = try #require(resp["error"] as? [String: Any])
        #expect(error["code"] as? Int == -32700)
    }

    @Test
    func jsonValueRoundTripsCommonTypes() throws {
        let original: JSONValue = .object([
            "n": .null,
            "b": .bool(true),
            "i": .int(42),
            "d": .double(3.14),
            "s": .string("hi"),
            "a": .array([.int(1), .int(2)]),
            "o": .object(["k": .string("v")])
        ])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(original)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: data)
        #expect(decoded == original)
    }
}
