import VM4ACore
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
            .appending(path: "vm4a-core-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
            .appending(path: "vm4a-core-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: testRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: testRoot) }

        let pidURL = testRoot.appending(path: ".vm4a-run.pid")
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
    func decodesLegacyConfigWithoutSchemaVersion() throws {
        let legacyJSON = """
        {
          "type": "linux",
          "name": "legacy",
          "remark": "",
          "cpu": { "count": 2 },
          "memory": { "size": 2147483648 },
          "graphicsDevices": [{ "type": "Virtio", "width": 1280, "height": 720, "pixelsPerInch": 0 }],
          "storageDevices": [{ "type": "Block", "size": 10737418240, "imagePath": "Disk.img" }],
          "networkDevices": [{ "type": "NAT" }],
          "pointingDevices": [{ "type": "USBScreenCoordinatePointing" }],
          "audioDevices": [{ "type": "InputOutputStream" }],
          "directorySharingDevices": []
        }
        """
        let data = Data(legacyJSON.utf8)
        let config = try JSONDecoder().decode(VMConfigModel.self, from: data)
        #expect(config.schemaVersion == 1)
        #expect(config.rosetta == nil)
        #expect(config.networkDevices[0].type == .NAT)
        #expect(config.networkDevices[0].identifier == nil)
    }

    @Test
    func bridgedNetworkIdentifierRoundTrips() throws {
        let config = VMConfigModel(
            type: .linux,
            name: "bridge",
            remark: "",
            cpu: .init(count: 2),
            memory: .init(size: 2 * 1024 * 1024 * 1024),
            graphicsDevices: [.default(osType: .linux)],
            storageDevices: [.default()],
            networkDevices: [.init(type: .Bridged, identifier: "en0")],
            pointingDevices: [.default()],
            audioDevices: [.default()],
            directorySharingDevices: [],
            rosetta: .init(enabled: true)
        )
        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(VMConfigModel.self, from: data)
        #expect(decoded.schemaVersion == VMConfigModel.currentSchemaVersion)
        #expect(decoded.networkDevices[0].type == .Bridged)
        #expect(decoded.networkDevices[0].identifier == "en0")
        #expect(decoded.rosetta?.enabled == true)
        #expect(decoded.rosetta?.tag == "rosetta")
    }

    @Test
    func linuxImageCatalogHasEntries() throws {
        let catalog = linuxImageCatalog()
        #expect(!catalog.isEmpty)
        #expect(catalog.allSatisfy { $0.url.hasPrefix("http") })
        #expect(catalog.allSatisfy { !$0.id.isEmpty })
    }

    @Test
    func typedErrorsExposeDistinctExitCodes() throws {
        #expect(VM4AError.notFound("x").exitCode == 2)
        #expect(VM4AError.alreadyExists("x").exitCode == 3)
        #expect(VM4AError.invalidState("x").exitCode == 4)
        #expect(VM4AError.hostUnsupported("x").exitCode == 5)
        #expect(VM4AError.rosettaNotInstalled.exitCode == 5)
        #expect(VM4AError.message("x").exitCode == 1)
    }

    @Test
    func cloneDirectoryPreservesContentsAndBlocksExisting() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-clone-\(UUID().uuidString)", directoryHint: .isDirectory)
        let src = root.appending(path: "src", directoryHint: .isDirectory)
        let dst = root.appending(path: "dst", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let payload = Data("hello".utf8)
        try payload.write(to: src.appending(path: "file.txt"))

        _ = try cloneDirectory(from: src, to: dst)
        let readBack = try Data(contentsOf: dst.appending(path: "file.txt"))
        #expect(readBack == payload)

        #expect(throws: (any Error).self) { _ = try cloneDirectory(from: src, to: dst) }
    }

    @Test
    func ociReferenceParserAcceptsCommonForms() throws {
        let a = try OCIReference.parse("ghcr.io/foo/bar:v1")
        #expect(a.registry == "ghcr.io")
        #expect(a.repository == "foo/bar")
        #expect(a.tag == "v1")

        let b = try OCIReference.parse("registry.example.com/team/project")
        #expect(b.tag == "latest")
        #expect(b.repository == "team/project")

        let c = try OCIReference.parse("localhost:5000/x/y:z")
        #expect(c.registry == "localhost:5000")
        #expect(c.repository == "x/y")
        #expect(c.tag == "z")
    }

    @Test
    func ociReferenceParserRejectsShortForms() throws {
        #expect(throws: (any Error).self) { _ = try OCIReference.parse("justname") }
        #expect(throws: (any Error).self) { _ = try OCIReference.parse("nohost/repo:tag") }
    }

    @Test
    func guestAgentCommandAndHeartbeatRoundTrip() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-agent-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let command = GuestAgentCommand(kind: .ping, payload: "hello")
        try writeGuestAgentCommand(bundleRoot: root, command: command)
        let cmdPath = guestAgentDirectory(bundleRoot: root).appending(path: GuestAgentTag.commandFile)
        let readBack = try JSONDecoder().decode(GuestAgentCommand.self, from: Data(contentsOf: cmdPath))
        #expect(readBack.kind == .ping)
        #expect(readBack.payload == "hello")

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let beat = GuestAgentHeartbeat(
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            version: "0.1.0",
            hostname: "test-vm",
            uptimeSeconds: 42
        )
        let beatData = try encoder.encode(beat)
        try atomicWrite(
            data: beatData,
            to: guestAgentDirectory(bundleRoot: root).appending(path: GuestAgentTag.heartbeatFile)
        )
        let loaded = readGuestAgentHeartbeat(bundleRoot: root)
        #expect(loaded?.hostname == "test-vm")
        #expect(loaded?.version == "0.1.0")
    }

    @Test
    func parsesDHCPLeasesFormat() throws {
        let text = """
        {
        \tname=demo
        \tip_address=192.168.64.12
        \thw_address=1,52:54:0:ab:cd:ef
        \tidentifier=1,52:54:0:ab:cd:ef
        \tlease=0x6500abcd
        }
        {
        \tname=other
        \tip_address=192.168.64.13
        \thw_address=1,aa:bb:cc:dd:ee:ff
        }
        """
        let leases = parseDHCPLeases(text)
        #expect(leases.count == 2)
        #expect(leases[0].ipAddress == "192.168.64.12")
        #expect(leases[0].hardwareAddress == "52:54:00:AB:CD:EF")
        #expect(leases[0].name == "demo")
        #expect(leases[1].name == "other")
    }

    @Test
    func networkModeParsesAliases() throws {
        #expect(NetworkMode.parse("none") == NetworkMode.none)
        #expect(NetworkMode.parse("nat") == .nat)
        #expect(NetworkMode.parse("NAT") == .nat)
        #expect(NetworkMode.parse("bridged") == .bridged)
        #expect(NetworkMode.parse("host") == .bridged)        // alias
        #expect(NetworkMode.parse("nope") == nil)
    }

    @Test
    func bridgedInterfaceImpliesBridgedMode() throws {
        // Back-compat: passing --bridged-interface without --network should still mean bridged.
        let opts = CreateBundleOptions(
            name: "x", os: .linux,
            storage: URL(fileURLWithPath: "/tmp"),
            bridgedInterface: "en0"
        )
        #expect(opts.networkMode == .bridged)
        #expect(opts.bridgedInterface == "en0")
    }

    @Test
    func explicitNetworkModeWins() throws {
        let opts = CreateBundleOptions(
            name: "x", os: .linux,
            storage: URL(fileURLWithPath: "/tmp"),
            networkMode: NetworkMode.none
        )
        #expect(opts.networkMode == NetworkMode.none)
    }

    @Test
    func parseCopyEndpointDistinguishesGuestAndHost() throws {
        #expect(parseCopyEndpoint("/tmp/local.txt") == .host("/tmp/local.txt"))
        #expect(parseCopyEndpoint("./relative") == .host("./relative"))
        #expect(parseCopyEndpoint(":/etc/hostname") == .guest("/etc/hostname"))
        #expect(parseCopyEndpoint(":relative/path") == .guest("relative/path"))
        #expect(parseCopyEndpoint(":") == .guest(""))
    }

    @Test
    func vmShortIDIsStableAndPathSensitive() throws {
        let a = URL(fileURLWithPath: "/tmp/vm4a/demo")
        let b = URL(fileURLWithPath: "/tmp/vm4a/demo/")
        let c = URL(fileURLWithPath: "/tmp/vm4a/other")

        let idA = vmShortID(forPath: a)
        let idB = vmShortID(forPath: b)
        let idC = vmShortID(forPath: c)

        #expect(idA.hasPrefix("vm-"))
        #expect(idA.count == 3 + 12)
        #expect(idA == idB)             // trailing slash should not change identity
        #expect(idA != idC)
    }

    @Test
    func runProcessRespectsTimeoutAndKillsChild() throws {
        let started = Date()
        let result = runProcess(executable: "/bin/sleep", arguments: ["10"], timeout: 0.5)
        let elapsed = Date().timeIntervalSince(started)

        #expect(result.timedOut == true)
        #expect(elapsed < 4.0)          // SIGTERM, then SIGKILL ~1s later
        #expect(result.exitCode != 0)
    }

    @Test
    func runProcessReturnsExitZeroForTrue() throws {
        let result = runProcess(executable: "/usr/bin/true", arguments: [], timeout: 5)
        #expect(result.exitCode == 0)
        #expect(!result.timedOut)
    }

    @Test
    func loadModelFallsBackToEmptyStateWhenStateFileMissing() throws {
        let testRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-core-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
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
