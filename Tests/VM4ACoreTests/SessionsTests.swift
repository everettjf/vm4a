import VM4ACore
import Foundation
import Testing

struct SessionsTests {
    @Test
    func appendAndReadRoundTripsEvents() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-sess-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let id = "test-\(UUID().uuidString)"
        let e1 = SessionEvent(
            id: id, seq: 1, kind: "exec", vmPath: bundle.path(),
            success: true, durationMs: 12, summary: "first",
            args: .object(["k": .string("v")]), outcome: .object(["x": .int(1)])
        )
        let e2 = SessionEvent(
            id: id, seq: 2, kind: "fork", vmPath: bundle.path(),
            success: true, durationMs: 34, summary: "second",
            args: nil, outcome: nil
        )
        try SessionStore.append(e1, bundlePath: bundle.path())
        try SessionStore.append(e2, bundlePath: bundle.path())

        let read = try SessionStore.read(id: id, bundlePath: bundle.path())
        #expect(read.count == 2)
        #expect(read[0].seq == 1)
        #expect(read[0].summary == "first")
        #expect(read[1].seq == 2)
        #expect(read[1].kind == "fork")
    }

    @Test
    func discoverFindsSessionsInBundleAndHome() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-sess-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let id = "disco-\(UUID().uuidString)"
        let event = SessionEvent(
            id: id, seq: 1, kind: "exec", vmPath: bundle.path(),
            success: true, durationMs: 1, summary: nil, args: nil, outcome: nil
        )
        try SessionStore.append(event, bundlePath: bundle.path())

        let rows = SessionStore.discoverSessions(bundlePath: bundle.path())
        #expect(rows.contains { $0.id == id })
    }

    @Test
    func recordSessionEventNoOpsForNilID() throws {
        // Should not throw, should not write anything.
        recordSessionEvent(
            id: nil, kind: "exec", vmPath: nil,
            args: [:], outcome: nil, success: true, durationMs: 0, summary: nil
        )
    }

    @Test
    func nextSessionSeqIsMonotonic() throws {
        let id = "seq-\(UUID().uuidString)"
        #expect(nextSessionSeq(id) == 1)
        #expect(nextSessionSeq(id) == 2)
        #expect(nextSessionSeq(id) == 3)
        let other = "seq-\(UUID().uuidString)"
        #expect(nextSessionSeq(other) == 1)  // independent counters
    }

    @Test
    func poolSaveAndLoadRoundTrips() throws {
        let name = "pooltest-\(UUID().uuidString.prefix(8))"
        let pool = PoolDefinition(
            name: name,
            basePath: "/tmp/base",
            snapshot: "/tmp/base/clean.vzstate",
            prefix: "task",
            storage: "/tmp/storage"
        )
        try PoolStore.save(pool)
        defer { try? PoolStore.remove(name: name) }

        let loaded = try PoolStore.load(name: name)
        #expect(loaded.name == name)
        #expect(loaded.basePath == "/tmp/base")
        #expect(loaded.snapshot == "/tmp/base/clean.vzstate")

        let allPools = try PoolStore.list()
        #expect(allPools.contains { $0.name == name })

        try PoolStore.remove(name: name)
        #expect(throws: (any Error).self) { _ = try PoolStore.load(name: name) }
    }

    @Test
    func sessionRecorderRecordsFailureWhenMarkSuccessNotCalled() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-rec-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let id = "fail-\(UUID().uuidString)"
        let recorder = SessionRecorder(
            id: id,
            kind: "exec",
            args: ["command": .array([.string("nope")])],
            vmPath: bundle.path()
        )
        // Simulate a thrown call before reaching markSuccess.
        recorder.record()

        let events = try SessionStore.read(id: id, bundlePath: bundle.path())
        #expect(events.count == 1)
        #expect(events[0].success == false)
        #expect(events[0].kind == "exec")
        #expect(events[0].summary?.contains("failed") == true)
    }

    @Test
    func sessionRecorderRecordsSuccessWhenMarked() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-rec-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let id = "ok-\(UUID().uuidString)"
        let recorder = SessionRecorder(
            id: id,
            kind: "fork",
            args: [:],
            vmPath: bundle.path()
        )
        recorder.markSuccess(vmPath: bundle.path(), outcome: nil, summary: "fork ok")
        recorder.record()

        let events = try SessionStore.read(id: id, bundlePath: bundle.path())
        #expect(events.count == 1)
        #expect(events[0].success == true)
        #expect(events[0].summary == "fork ok")
    }

    @Test
    func malformedJSONLLineIsSkippedNotFatal() throws {
        let bundle = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-sess-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        let id = "mal-\(UUID().uuidString)"
        let url = try SessionStore.sessionFileURL(id: id, bundlePath: bundle.path())
        // Manually write a bad line, then a good one.
        let bad = Data("not json\n".utf8)
        try bad.write(to: url)
        let good = SessionEvent(
            id: id, seq: 99, kind: "exec", vmPath: bundle.path(),
            success: true, durationMs: 1, summary: "ok", args: nil, outcome: nil
        )
        try SessionStore.append(good, bundlePath: bundle.path())

        let read = try SessionStore.read(id: id, bundlePath: bundle.path())
        #expect(read.count == 1)
        #expect(read[0].seq == 99)
    }
}
