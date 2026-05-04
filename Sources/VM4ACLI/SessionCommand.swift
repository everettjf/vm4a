import ArgumentParser
import Foundation
import VM4ACore

struct SessionCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "session",
        abstract: "List and inspect agent run sessions",
        discussion: """
            Sessions are append-only JSONL logs of agent activity, written
            when commands are run with --session <id>. Stored at
            <bundle>/.vm4a-sessions/<id>.jsonl when a vm path is known,
            else at ~/.vm4a/sessions/<id>.jsonl.

            The SwiftUI Time Machine view (v2.3) will read these to render
            session timelines and snapshot diffs.
            """,
        subcommands: [SessionListCommand.self, SessionShowCommand.self],
        defaultSubcommand: SessionListCommand.self
    )
}

struct SessionListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List known sessions across bundles + ~/.vm4a/sessions")

    @Option(name: .long, help: "Restrict to sessions stored under this bundle")
    var bundle: String?

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let rows = SessionStore.discoverSessions(bundlePath: bundle)
        switch output {
        case .json:
            try writeJSONLine(rows)
        case .text:
            if rows.isEmpty {
                print("No sessions found.")
                return
            }
            let formatter = ISO8601DateFormatter()
            for row in rows {
                let when = formatter.string(from: row.modified)
                let owner = row.bundlePath ?? "(home)"
                print("\(row.id)\t\(when)\t\(row.bytes)B\t\(owner)")
            }
        }
    }
}

struct SessionShowCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "show", abstract: "Print every event in a session, in order")

    @Argument(help: "Session id")
    var id: String

    @Option(name: .long, help: "Bundle the session is stored under (skip for ~/.vm4a/sessions/<id>.jsonl)")
    var bundle: String?

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    mutating func run() throws {
        let events = try SessionStore.read(id: id, bundlePath: bundle)
        switch output {
        case .json:
            try writeJSONLine(events)
        case .text:
            if events.isEmpty {
                print("Session '\(id)' has no events.")
                return
            }
            let formatter = ISO8601DateFormatter()
            for event in events {
                let mark = event.success ? "✓" : "✗"
                let when = formatter.string(from: event.timestamp)
                let dur = event.durationMs.map { "\($0)ms" } ?? "-"
                let summary = event.summary ?? "\(event.kind)"
                print("\(mark) #\(event.seq)\t\(when)\t\(dur)\t\(summary)")
            }
        }
    }
}
