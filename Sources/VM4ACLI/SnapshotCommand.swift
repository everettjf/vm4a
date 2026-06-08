import ArgumentParser
import Foundation
import VM4ACore

// MARK: - Helpers shared by snapshot subcommands

private func snapshotExecutablePath() throws -> String {
    guard let path = Bundle.main.executablePath else {
        throw VM4AError.message("Cannot locate vm4a executable path")
    }
    return path
}

/// Restore a bundle from one of its named snapshots. Stops a running worker
/// first, then restarts from the snapshot (reuses the `reset` machinery).
func restoreNamedSnapshot(vmPath: String, name: String, waitIP: Bool) throws -> ResetOutcome {
    let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
    let snapshot = model.snapshotURL(name: name)
    guard FileManager.default.fileExists(atPath: snapshot.path(percentEncoded: false)) else {
        throw VM4AError.notFound("Snapshot '\(name)' in \(model.snapshotsDirURL.path()). List with `vm4a snapshot list \(vmPath)`.")
    }
    return try runReset(
        options: ResetOptions(
            vmPath: vmPath,
            fromSnapshot: snapshot.path(percentEncoded: false),
            waitIP: waitIP
        ),
        executable: try snapshotExecutablePath()
    )
}

// MARK: - vm4a snapshot

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Save, restore, list, and delete named VM snapshots (macOS 14+)",
        discussion: """
            Snapshots capture a VM's full live state (RAM + devices) and restore
            in well under a second. They are stored inside the bundle by name, so
            you never juggle .vzstate paths:

              vm4a run /tmp/vm4a/dev              # boot, do some setup
              vm4a snapshot save /tmp/vm4a/dev clean
              vm4a restore /tmp/vm4a/dev clean    # roll back anytime

            `save` captures the running VM and then stops it; `restore` boots the
            VM back to that exact state.
            """,
        subcommands: [
            SnapshotSaveCommand.self,
            SnapshotRestoreCommand.self,
            SnapshotListCommand.self,
            SnapshotRemoveCommand.self,
        ]
    )
}

struct SnapshotSaveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "save",
        abstract: "Save a running VM's live state as a named snapshot (stops the VM)"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Argument(help: "Snapshot name (stored as <bundle>/.vm4a-snapshots/<name>.vzstate)")
    var name: String

    @Option(name: .long, help: "Seconds to wait for the save to finish")
    var timeout: Int = 120

    func run() throws {
        guard #available(macOS 14.0, *) else {
            throw VM4AError.hostUnsupported("VZ snapshots require macOS 14+")
        }
        let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
        guard let pid = readPID(from: model.runPIDURL), isProcessRunning(pid: pid) else {
            throw VM4AError.invalidState("VM is not running. Snapshots capture live state — start it with `vm4a run \(vmPath)` first.")
        }

        try FileManager.default.createDirectory(at: model.snapshotsDirURL, withIntermediateDirectories: true)
        let target = model.snapshotURL(name: name)
        try? FileManager.default.removeItem(at: target)
        try? FileManager.default.removeItem(at: model.snapshotErrorURL)

        // Hand the worker the target path, then signal it to save + stop.
        try Data(target.path(percentEncoded: false).utf8).write(to: model.snapshotRequestURL)
        guard kill(pid, SIGUSR1) == 0 else {
            throw VM4AError.message("Failed to signal VM worker (pid \(pid)).")
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if !isProcessRunning(pid: pid) { break }
            if FileManager.default.fileExists(atPath: model.snapshotErrorURL.path(percentEncoded: false)) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if !isProcessRunning(pid: pid) { clearPID(at: model.runPIDURL) }
        try? FileManager.default.removeItem(at: model.snapshotRequestURL)

        if let reason = try? String(contentsOf: model.snapshotErrorURL, encoding: .utf8) {
            try? FileManager.default.removeItem(at: model.snapshotErrorURL)
            throw VM4AError.message("Snapshot failed: \(reason.trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw VM4AError.message("Snapshot didn't complete in \(timeout)s. See \(model.runLogURL.path()).")
        }
        print("Saved snapshot '\(name)'. VM stopped. Restore with: vm4a restore \(vmPath) \(name)")
    }
}

struct SnapshotRestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Boot a VM back to a named snapshot"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Argument(help: "Snapshot name to restore")
    var name: String

    @Flag(name: .long, help: "Wait for the VM to get a NAT IP after restoring")
    var waitIP: Bool = false

    func run() throws {
        let outcome = try restoreNamedSnapshot(vmPath: vmPath, name: name, waitIP: waitIP)
        if let ip = outcome.ip {
            print("Restored '\(name)' → pid \(outcome.pid.map(String.init) ?? "?"), ip \(ip)")
        } else {
            print("Restored '\(name)' → pid \(outcome.pid.map(String.init) ?? "?")")
        }
    }
}

struct SnapshotListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List a bundle's saved snapshots"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Output format: text or json")
    var output: OutputFormat = .text

    @Flag(name: .long, help: "Pretty-print JSON output")
    var pretty: Bool = false

    struct Row: Codable {
        let name: String
        let bytes: Int
        let modified: String
    }

    func run() throws {
        let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: model.snapshotsDirURL,
            includingPropertiesForKeys: keys
        )) ?? []
        let iso = ISO8601DateFormatter()
        let rows = entries
            .filter { $0.pathExtension == "vzstate" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { url -> Row in
                let values = try? url.resourceValues(forKeys: Set(keys))
                return Row(
                    name: url.deletingPathExtension().lastPathComponent,
                    bytes: values?.fileSize ?? 0,
                    modified: (values?.contentModificationDate).map(iso.string(from:)) ?? ""
                )
            }

        switch output {
        case .json:
            try writeJSONLine(rows, pretty: pretty)
        case .text:
            if rows.isEmpty {
                print("No snapshots in \(model.snapshotsDirURL.path())")
                return
            }
            for row in rows {
                let mb = String(format: "%.1f", Double(row.bytes) / 1_048_576)
                print("\(row.name)\t\(mb) MB\t\(row.modified)")
            }
        }
    }
}

struct SnapshotRemoveCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rm",
        abstract: "Delete a named snapshot"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Argument(help: "Snapshot name to delete")
    var name: String

    func run() throws {
        let model = try loadModel(rootPath: URL(fileURLWithPath: vmPath, isDirectory: true))
        let target = model.snapshotURL(name: name)
        guard FileManager.default.fileExists(atPath: target.path(percentEncoded: false)) else {
            throw VM4AError.notFound("Snapshot '\(name)' in \(model.snapshotsDirURL.path())")
        }
        try FileManager.default.removeItem(at: target)
        print("Deleted snapshot '\(name)'")
    }
}

// MARK: - Top-level `vm4a restore` alias (primary verb)

struct RestoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore",
        abstract: "Boot a VM back to a named snapshot (alias for `snapshot restore`)"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Argument(help: "Snapshot name to restore")
    var name: String

    @Flag(name: .long, help: "Wait for the VM to get a NAT IP after restoring")
    var waitIP: Bool = false

    func run() throws {
        let outcome = try restoreNamedSnapshot(vmPath: vmPath, name: name, waitIP: waitIP)
        if let ip = outcome.ip {
            print("Restored '\(name)' → pid \(outcome.pid.map(String.init) ?? "?"), ip \(ip)")
        } else {
            print("Restored '\(name)' → pid \(outcome.pid.map(String.init) ?? "?")")
        }
    }
}
