import Foundation

// MARK: - Session events

/// A single event in an agent run, append-only. The SwiftUI Time Machine
/// view (v2.3) reads these and renders a timeline; for now the CLI also
/// reads them via `vm4a session show <id>`.
public struct SessionEvent: Codable, Sendable {
    public let id: String              // session id
    public let seq: Int                // monotonic per-session sequence
    public let timestamp: Date
    public let kind: String            // spawn | exec | cp | fork | reset | stop
    public let vmPath: String?
    public let success: Bool
    public let durationMs: Int?
    public let summary: String?        // human one-liner ("python3 step.py → exit 0")
    public let args: JSONValue?        // tool arguments, redacted
    public let outcome: JSONValue?     // tool outcome (truncated for stdout/stderr)

    public init(
        id: String,
        seq: Int,
        timestamp: Date = Date(),
        kind: String,
        vmPath: String?,
        success: Bool,
        durationMs: Int?,
        summary: String?,
        args: JSONValue?,
        outcome: JSONValue?
    ) {
        self.id = id
        self.seq = seq
        self.timestamp = timestamp
        self.kind = kind
        self.vmPath = vmPath
        self.success = success
        self.durationMs = durationMs
        self.summary = summary
        self.args = args
        self.outcome = outcome
    }
}

// MARK: - Storage layout

/// Sessions live under <bundle>/.vm4a-sessions/<id>.jsonl. We append one
/// JSON object per line; readers split on '\n'. If `vmPath` is nil (e.g.
/// fork before destination is known), events are stored under the *home*
/// fallback ~/.vm4a/sessions/<id>.jsonl.
public enum SessionStore {
    public static let dirNameInBundle = ".vm4a-sessions"
    public static let homeDirName = ".vm4a/sessions"

    /// Resolve the per-session JSONL file. If `bundlePath` is provided,
    /// store inside the bundle; otherwise fall back to ~/.vm4a/sessions.
    public static func sessionFileURL(id: String, bundlePath: String?) throws -> URL {
        if let bundlePath {
            let dir = URL(fileURLWithPath: bundlePath, isDirectory: true)
                .appending(path: dirNameInBundle, directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            return dir.appending(path: "\(id).jsonl")
        }
        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let dir = home.appending(path: homeDirName, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "\(id).jsonl")
    }

    public static func append(_ event: SessionEvent, bundlePath: String?) throws {
        let url = try sessionFileURL(id: event.id, bundlePath: bundlePath)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(event)
        line.append(0x0A) // '\n'

        let fm = FileManager.default
        if !fm.fileExists(atPath: url.path(percentEncoded: false)) {
            try line.write(to: url)
            return
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: line)
    }

    /// Decode every event from a session file in order. Skips malformed
    /// lines so a partial write doesn't break the whole session.
    public static func read(id: String, bundlePath: String?) throws -> [SessionEvent] {
        let url = try sessionFileURL(id: id, bundlePath: bundlePath)
        guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            return []
        }
        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var events: [SessionEvent] = []
        var start = data.startIndex
        for i in data.indices where data[i] == 0x0A {
            let line = data[start..<i]
            start = data.index(after: i)
            if line.isEmpty { continue }
            if let event = try? decoder.decode(SessionEvent.self, from: line) {
                events.append(event)
            }
        }
        if start < data.endIndex {
            let tail = data[start..<data.endIndex]
            if !tail.isEmpty,
               let event = try? decoder.decode(SessionEvent.self, from: tail) {
                events.append(event)
            }
        }
        return events
    }

    /// List sessions across the typical roots (a single bundle if given,
    /// plus the home fallback). Returns descriptors sorted by most-recent.
    public static func discoverSessions(bundlePath: String?) -> [SessionDescriptor] {
        var roots: [(URL, String?)] = []
        if let bundlePath {
            roots.append((
                URL(fileURLWithPath: bundlePath, isDirectory: true)
                    .appending(path: dirNameInBundle, directoryHint: .isDirectory),
                bundlePath
            ))
        }
        let homeRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: homeDirName, directoryHint: .isDirectory)
        roots.append((homeRoot, nil))

        var rows: [SessionDescriptor] = []
        for (dir, ownerBundle) in roots {
            guard let entries = try? FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
            ) else { continue }
            for entry in entries where entry.pathExtension == "jsonl" {
                let id = entry.deletingPathExtension().lastPathComponent
                let attrs = try? entry.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                rows.append(SessionDescriptor(
                    id: id,
                    bundlePath: ownerBundle,
                    file: entry.path(),
                    modified: attrs?.contentModificationDate ?? Date.distantPast,
                    bytes: Int(attrs?.fileSize ?? 0)
                ))
            }
        }
        rows.sort { $0.modified > $1.modified }
        return rows
    }
}

public struct SessionDescriptor: Codable, Sendable {
    public let id: String
    public let bundlePath: String?
    public let file: String
    public let modified: Date
    public let bytes: Int
}

// MARK: - Sequence numbering (per-session, in-process)

private final class _SessionSeq: @unchecked Sendable {
    static let shared = _SessionSeq()
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    func next(_ id: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = (counters[id] ?? 0) + 1
        counters[id] = n
        return n
    }
}

public func nextSessionSeq(_ id: String) -> Int { _SessionSeq.shared.next(id) }

// MARK: - Recording helper

/// Mutable recorder that captures duration + outcome around a runner call.
/// Use with `defer` so the success and the throwing paths both log.
///
///     let recorder = SessionRecorder(id: session, kind: "spawn", args: [...])
///     defer { recorder.record() }
///     let outcome = try await runSpawn(...)
///     recorder.markSuccess(vmPath: outcome.path, outcome: try? jsonValue(outcome),
///                          summary: "spawn \(outcome.name)")
public final class SessionRecorder: @unchecked Sendable {
    public let id: String?
    public let kind: String
    public let args: [String: JSONValue]
    public let started: Date

    public var vmPath: String?
    public var outcomeJSON: JSONValue?
    public var success: Bool = false
    public var summary: String?

    public init(id: String?, kind: String, args: [String: JSONValue], vmPath: String? = nil) {
        self.id = id
        self.kind = kind
        self.args = args
        self.vmPath = vmPath
        self.started = Date()
        self.summary = "\(kind) (failed before reaching outcome)"
    }

    public func markSuccess(vmPath: String?, outcome: JSONValue?, summary: String) {
        self.vmPath = vmPath ?? self.vmPath
        self.outcomeJSON = outcome
        self.success = true
        self.summary = summary
    }

    public func markFailure(vmPath: String? = nil, summary: String) {
        if let vmPath { self.vmPath = vmPath }
        self.success = false
        self.summary = summary
    }

    public func record() {
        let durationMs = Int(Date().timeIntervalSince(started) * 1000)
        recordSessionEvent(
            id: id,
            kind: kind,
            vmPath: vmPath,
            args: args,
            outcome: outcomeJSON,
            success: success,
            durationMs: durationMs,
            summary: summary,
            timestamp: started
        )
    }
}

/// Best-effort event recorder. If `id` is nil, does nothing. Failures
/// (disk full, permission denied, etc.) are swallowed — the agent flow
/// must not break because of log I/O.
public func recordSessionEvent(
    id: String?,
    kind: String,
    vmPath: String?,
    args: [String: JSONValue],
    outcome: JSONValue?,
    success: Bool,
    durationMs: Int,
    summary: String?,
    timestamp: Date = Date()
) {
    guard let id, !id.isEmpty else { return }
    let event = SessionEvent(
        id: id,
        seq: nextSessionSeq(id),
        timestamp: timestamp,
        kind: kind,
        vmPath: vmPath,
        success: success,
        durationMs: durationMs,
        summary: summary,
        args: .object(args),
        outcome: outcome
    )
    try? SessionStore.append(event, bundlePath: vmPath)
}

// MARK: - Pools (v2.4 scaffolding — definitions only)

/// A pool definition: how to mint a fresh per-task VM from a base bundle.
/// The runtime that keeps N idle VMs warm is intentionally not part of
/// this commit; see templates/POOLS.md for the design.
public struct PoolDefinition: Codable, Sendable {
    public let name: String
    public let basePath: String
    public let snapshot: String?
    public let prefix: String       // generated VMs are prefix-001, prefix-002, …
    public let storage: String

    public init(name: String, basePath: String, snapshot: String?, prefix: String, storage: String) {
        self.name = name
        self.basePath = basePath
        self.snapshot = snapshot
        self.prefix = prefix
        self.storage = storage
    }
}

public enum PoolStore {
    public static func dir() throws -> URL {
        let url = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appending(path: ".vm4a/pools", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    public static func file(name: String) throws -> URL {
        try dir().appending(path: "\(name).json")
    }

    public static func save(_ pool: PoolDefinition) throws {
        let url = try file(name: pool.name)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try encoder.encode(pool).write(to: url)
    }

    public static func load(name: String) throws -> PoolDefinition {
        let url = try file(name: name)
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(PoolDefinition.self, from: data)
    }

    public static func list() throws -> [PoolDefinition] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: try dir(),
            includingPropertiesForKeys: nil
        )) ?? []
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(PoolDefinition.self, from: Data(contentsOf: $0)) }
    }

    public static func remove(name: String) throws {
        let url = try file(name: name)
        if FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
