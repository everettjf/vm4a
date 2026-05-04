import Foundation
import VM4ACore

#if canImport(Darwin)
import Darwin
#endif

/// Minimal guest agent for macOS guests. Run inside a VM where the
/// host's bundle's `guest-agent/` directory is mounted via virtiofs
/// (VZSharedDirectory). Writes a heartbeat every few seconds and
/// polls for commands.
///
/// This is a scaffold. Current commands: `ping`. Future commands
/// (clipboard, run-script, shutdown) require additional privilege +
/// OS-specific integration. Contributions welcome.
@main
struct VM4AGuestMain {
    static let agentVersion = "0.1.0"

    static func main() async {
        let args = CommandLine.arguments
        guard args.count >= 2 else {
            FileHandle.standardError.write(Data("usage: vm4a-guest <path-to-shared-agent-dir>\n".utf8))
            exit(64)
        }
        let dir = URL(fileURLWithPath: args[1], isDirectory: true)
        guard FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)) else {
            FileHandle.standardError.write(Data("agent dir not found: \(dir.path())\n".utf8))
            exit(2)
        }
        do {
            try await runLoop(agentDir: dir)
        } catch {
            FileHandle.standardError.write(Data("vm4a-guest: \(error)\n".utf8))
            exit(1)
        }
    }

    static func runLoop(agentDir: URL) async throws {
        let host = ProcessInfo.processInfo.hostName
        let startedAt = Date()
        var lastCommandId: String?

        while true {
            let beat = GuestAgentHeartbeat(
                timestamp: Date(),
                version: agentVersion,
                hostname: host,
                uptimeSeconds: Date().timeIntervalSince(startedAt)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(beat)
            try atomicWrite(data: data, to: agentDir.appending(path: GuestAgentTag.heartbeatFile))

            let cmdURL = agentDir.appending(path: GuestAgentTag.commandFile)
            if let cmdData = try? Data(contentsOf: cmdURL),
               let command = try? JSONDecoder().decode(GuestAgentCommand.self, from: cmdData),
               command.id != lastCommandId {
                lastCommandId = command.id
                let response = try await handle(command: command)
                let respData = try JSONEncoder().encode(response)
                try atomicWrite(data: respData, to: agentDir.appending(path: GuestAgentTag.responseFile))
            }

            try await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    static func handle(command: GuestAgentCommand) async throws -> GuestAgentResponse {
        switch command.kind {
        case .ping:
            return GuestAgentResponse(id: command.id, ok: true, output: "pong")
        case .shutdown, .runScript, .setClipboard, .getClipboard:
            return GuestAgentResponse(id: command.id, ok: false, error: "command '\(command.kind.rawValue)' not implemented in scaffold")
        }
    }
}
