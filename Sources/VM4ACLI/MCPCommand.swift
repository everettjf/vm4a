import ArgumentParser
import Foundation
import VM4ACore

struct MCPCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp",
        abstract: "Run as a Model Context Protocol (MCP) server over stdio",
        discussion: """
            Speaks JSON-RPC 2.0 framed by newlines on stdin/stdout. Designed
            to be registered with Claude Code, Cursor, Cline, etc.

            Example .mcp.json registration (Claude Code):
              {
                "mcpServers": {
                  "vm4a": { "command": "vm4a", "args": ["mcp"] }
                }
              }

            Tools exposed: spawn, exec, cp, fork, reset, list, ip, stop.
            Each tool returns a JSON-encoded outcome inside the standard
            MCP {content:[{type:"text", text:"..."}], isError:false} frame.
            """
    )

    mutating func run() async throws {
        guard let executable = Bundle.main.executablePath else {
            throw VM4AError.message("Cannot locate vm4a executable path")
        }
        let server = MCPServer(
            config: MCPServerConfig(executablePath: executable),
            transport: StdioMCPTransport()
        )
        try await server.run()
    }
}
