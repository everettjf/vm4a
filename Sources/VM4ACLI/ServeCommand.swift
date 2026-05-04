import ArgumentParser
import Foundation
import VM4ACore

struct ServeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Run an HTTP API server (REST) on localhost",
        discussion: """
            Endpoints (all under /v1):
              GET  /v1/health
              POST /v1/spawn      body: SpawnOptions JSON
              POST /v1/exec       body: {vm_path, command:[...], ...}
              POST /v1/cp         body: {vm_path, source, destination, ...}
              POST /v1/fork       body: {source_path, destination_path, ...}
              POST /v1/reset      body: {vm_path, from, ...}
              GET  /v1/vms        ?storage=/path
              GET  /v1/vms/ip     ?path=/path/to/bundle
              POST /v1/vms/stop   body: {vm_path, timeout?}

            Auth: set VM4A_AUTH_TOKEN to require Bearer token; otherwise
            the server is open (and bound to localhost only by default).

            For agent integration, see also `vm4a mcp` (stdio MCP server).
            """
    )

    @Option(name: .long, help: "Bind address (default 127.0.0.1; pass 0.0.0.0 for all interfaces)")
    var bind: String = "127.0.0.1"

    @Option(name: .long, help: "TCP port")
    var port: UInt16 = 7777

    mutating func run() async throws {
        guard let executable = Bundle.main.executablePath else {
            throw VM4AError.message("Cannot locate vm4a executable path")
        }
        let token = ProcessInfo.processInfo.environment["VM4A_AUTH_TOKEN"]
        let config = VM4AHTTPServerConfig(
            host: bind,
            port: port,
            executablePath: executable,
            authToken: token
        )
        let router = makeVM4ARouter(config: config)
        let server = try HTTPServer(host: bind, port: port, router: router)
        server.start()

        let authMode = (token?.isEmpty == false) ? "bearer-token" : "none"
        FileHandle.standardError.write(Data("vm4a serve listening on http://\(bind):\(port) (auth: \(authMode))\n".utf8))

        // Block forever; signal handlers come from the harness
        try await Task.sleep(nanoseconds: UInt64.max)
    }
}
