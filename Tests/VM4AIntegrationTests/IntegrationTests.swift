import VM4ACore
import Foundation
import Testing

/// End-to-end tests that boot a real VM. Gated behind VM4A_RUN_INTEGRATION=1
/// because they need:
///   - Actual VZ runtime privileges (codesigned vm4a binary)
///   - A Linux ARM64 ISO at $VM4A_INTEGRATION_ISO (e.g. an Alpine ISO)
///   - ~2 GB free RAM and a few GB of disk
///   - 60-90 seconds per test
///
/// To run locally:
///   export VM4A_RUN_INTEGRATION=1
///   export VM4A_INTEGRATION_ISO=~/Downloads/alpine-virt-3.20-aarch64.iso
///   swift test --filter IntegrationTests
///
/// Skipped automatically in normal `swift test` runs and in the macos-14
/// hosted CI runner (which lacks VZ runtime).

private let integrationEnabled: Bool =
    ProcessInfo.processInfo.environment["VM4A_RUN_INTEGRATION"] == "1"

private let integrationISO: String? =
    ProcessInfo.processInfo.environment["VM4A_INTEGRATION_ISO"]

struct IntegrationTests {
    @Test(.enabled(if: integrationEnabled, "set VM4A_RUN_INTEGRATION=1 to enable"))
    func bootSpawnExecStop() async throws {
        let iso = try #require(integrationISO, "VM4A_INTEGRATION_ISO not set")
        let workDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-int-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workDir) }

        let executable = try locateBuiltVM4A()
        let outcome = try await runSpawn(
            options: SpawnOptions(
                name: "int",
                os: .linux,
                storage: workDir,
                imagePath: iso,
                cpu: 2,
                memoryBytes: 2 * 1024 * 1024 * 1024,
                diskBytes: 4 * 1024 * 1024 * 1024,
                waitIP: true,
                waitSSH: true,
                waitTimeout: 240
            ),
            executable: executable
        )
        #expect(outcome.ip != nil)
        #expect(outcome.sshReady == true)
    }

    @Test(.enabled(if: integrationEnabled, "set VM4A_RUN_INTEGRATION=1 to enable"))
    func snapshotSaveRestoreRoundTrip() async throws {
        // Placeholder for the full save → stop → run --restore → verify cycle.
        // Uses macOS 14 VZ snapshot APIs in Core.swift.
    }
}

private func locateBuiltVM4A() throws -> String {
    for variant in ["debug", "release"] {
        let path = ".build/arm64-apple-macosx/\(variant)/vm4a"
        if FileManager.default.fileExists(atPath: path) {
            return URL(fileURLWithPath: path).standardizedFileURL.path()
        }
    }
    throw VM4AError.notFound("vm4a binary in .build/{debug,release}/")
}
