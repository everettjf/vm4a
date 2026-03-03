import EasyVMCore
import Foundation
import Testing
import Virtualization

struct CoreTests {
    @Test
    func defaultLinuxConfigUsesExpectedFields() throws {
        let config = VMConfigModel.defaults(
            osType: .linux,
            name: "unit-linux",
            cpu: nil,
            memoryBytes: nil,
            diskBytes: nil
        )

        #expect(config.type == .linux)
        #expect(config.name == "unit-linux")
        #expect(config.storageDevices.count == 1)
        #expect(config.storageDevices[0].type == .Block)
        #expect(config.storageDevices[0].imagePath == "Disk.img")
        #expect(config.cpu.count >= 1)
        #expect(config.memory.size > 0)
    }

    @Test
    func modelRoundTripPreservesConfigAndState() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "easyvm-core-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let config = VMConfigModel.defaults(
            osType: .linux,
            name: "roundtrip",
            cpu: 4,
            memoryBytes: 8 * 1024 * 1024 * 1024,
            diskBytes: 16 * 1024 * 1024 * 1024
        )
        let state = VMStateModel(imagePath: URL(fileURLWithPath: "/tmp/image.iso"))
        let model = VMModel(rootPath: testRoot, config: config, state: state)

        try writeJSON(config, to: model.configURL)
        try writeJSON(state, to: model.stateURL)

        let loaded = try loadModel(rootPath: testRoot)
        #expect(loaded.config.type == .linux)
        #expect(loaded.config.name == "roundtrip")
        #expect(loaded.config.cpu.count == 4)
        #expect(loaded.config.storageDevices[0].size == 16 * 1024 * 1024 * 1024)
        #expect(loaded.state.imagePath.path() == "/tmp/image.iso")
    }

    @Test
    func pidHelpersReadWriteAndClear() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "easyvm-core-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let pidURL = testRoot.appending(path: ".easyvm-run.pid")
        try writePID(12345, to: pidURL)
        #expect(readPID(from: pidURL) == 12345)

        clearPID(at: pidURL)
        #expect(readPID(from: pidURL) == nil)
    }

    @Test
    func processHelperRecognizesCurrentAndInvalidPID() throws {
        #expect(isProcessRunning(pid: getpid()))
        #expect(!isProcessRunning(pid: -1))
    }

    @Test
    func defaultConfigClampsOutOfRangeResourceValues() throws {
        let config = VMConfigModel.defaults(
            osType: .linux,
            name: "clamp",
            cpu: Int.max,
            memoryBytes: UInt64.max,
            diskBytes: nil
        )

        #expect(config.cpu.count == VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        #expect(config.memory.size == VZVirtualMachineConfiguration.maximumAllowedMemorySize)
    }

    @Test
    func loadModelFallsBackToEmptyStateWhenStateFileMissing() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "easyvm-core-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let config = VMConfigModel.defaults(
            osType: .linux,
            name: "fallback-state",
            cpu: nil,
            memoryBytes: nil,
            diskBytes: nil
        )
        try writeJSON(config, to: testRoot.appending(path: "config.json"))

        let loaded = try loadModel(rootPath: testRoot)
        #expect(loaded.state.imagePath.path() == testRoot.path())
    }
}
