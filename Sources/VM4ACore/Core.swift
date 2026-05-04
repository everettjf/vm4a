import Foundation
@preconcurrency import Virtualization

public enum VM4AError: Error, CustomStringConvertible {
    case message(String)
    case notFound(String)
    case alreadyExists(String)
    case invalidState(String)
    case hostUnsupported(String)
    case rosettaNotInstalled

    public var description: String {
        switch self {
        case .message(let text): return text
        case .notFound(let what): return "Not found: \(what)"
        case .alreadyExists(let what): return "Already exists: \(what)"
        case .invalidState(let text): return "Invalid state: \(text)"
        case .hostUnsupported(let what): return "Host unsupported: \(what)"
        case .rosettaNotInstalled:
            return "Rosetta is not installed. Run: softwareupdate --install-rosetta --agree-to-license"
        }
    }

    public var exitCode: Int32 {
        switch self {
        case .notFound: return 2
        case .alreadyExists: return 3
        case .invalidState: return 4
        case .hostUnsupported, .rosettaNotInstalled: return 5
        case .message: return 1
        }
    }
}

public enum VMOSType: String, Codable, Sendable {
    case macOS = "macOS"
    case linux = "linux"
}

public struct VMModelFieldRosetta: Codable {
    public let enabled: Bool
    public let tag: String

    public init(enabled: Bool, tag: String = "rosetta") {
        self.enabled = enabled
        self.tag = tag
    }

    public static func `default`() -> Self { .init(enabled: false) }

    public enum HostAvailability: String, Sendable {
        case notSupported
        case notInstalled
        case installed
    }

    public static var hostAvailability: HostAvailability {
        if #available(macOS 13.0, *) {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .notSupported:
                return .notSupported
            case .notInstalled:
                return .notInstalled
            case .installed:
                return .installed
            @unknown default:
                return .notSupported
            }
        }
        return .notSupported
    }
}

public struct BridgedNetworkInterfaceInfo: Codable, Sendable {
    public let identifier: String
    public let displayName: String?

    public init(identifier: String, displayName: String?) {
        self.identifier = identifier
        self.displayName = displayName
    }
}

public func availableBridgedInterfaces() -> [BridgedNetworkInterfaceInfo] {
    VZBridgedNetworkInterface.networkInterfaces.map {
        .init(identifier: $0.identifier, displayName: $0.localizedDisplayName)
    }
}

public struct LinuxImageCatalogEntry: Codable, Sendable {
    public let id: String
    public let displayName: String
    public let url: String
    public let sha256: String?

    public init(id: String, displayName: String, url: String, sha256: String?) {
        self.id = id
        self.displayName = displayName
        self.url = url
        self.sha256 = sha256
    }
}

public func linuxImageCatalog() -> [LinuxImageCatalogEntry] {
    [
        .init(
            id: "ubuntu-24.04-arm64",
            displayName: "Ubuntu 24.04 LTS Server (ARM64)",
            url: "https://cdimage.ubuntu.com/releases/24.04/release/ubuntu-24.04.1-live-server-arm64.iso",
            sha256: nil
        ),
        .init(
            id: "fedora-40-arm64",
            displayName: "Fedora 40 Server (ARM64)",
            url: "https://download.fedoraproject.org/pub/fedora/linux/releases/40/Server/aarch64/iso/Fedora-Server-dvd-aarch64-40-1.14.iso",
            sha256: nil
        ),
        .init(
            id: "debian-12-arm64",
            displayName: "Debian 12 (ARM64) DVD",
            url: "https://cdimage.debian.org/debian-cd/current/arm64/iso-dvd/debian-12.9.0-arm64-DVD-1.iso",
            sha256: nil
        ),
        .init(
            id: "alpine-3.20-arm64",
            displayName: "Alpine Linux 3.20 Virt (ARM64)",
            url: "https://dl-cdn.alpinelinux.org/alpine/v3.20/releases/aarch64/alpine-virt-3.20.3-aarch64.iso",
            sha256: nil
        ),
    ]
}

public struct VMModelFieldCPU: Codable {
    public let count: Int

    public init(count: Int) {
        self.count = count
    }

    public static func `default`() -> Self {
        let total = ProcessInfo.processInfo.processorCount
        let value = max(
            VZVirtualMachineConfiguration.minimumAllowedCPUCount,
            min(max(total - 1, 1), VZVirtualMachineConfiguration.maximumAllowedCPUCount)
        )
        return .init(count: value)
    }
}

public struct VMModelFieldMemory: Codable {
    public let size: UInt64

    public init(size: UInt64) {
        self.size = size
    }

    public static func `default`() -> Self {
        let defaultBytes = UInt64(4 * 1024 * 1024 * 1024)
        let value = max(
            VZVirtualMachineConfiguration.minimumAllowedMemorySize,
            min(defaultBytes, VZVirtualMachineConfiguration.maximumAllowedMemorySize)
        )
        return .init(size: value)
    }
}

public struct VMModelFieldGraphicDevice: Codable {
    public enum DeviceType: String, Codable {
        case Mac
        case Virtio
    }

    public let type: DeviceType
    public let width: Int
    public let height: Int
    public let pixelsPerInch: Int

    public init(type: DeviceType, width: Int, height: Int, pixelsPerInch: Int) {
        self.type = type
        self.width = width
        self.height = height
        self.pixelsPerInch = pixelsPerInch
    }

    public static func `default`(osType: VMOSType) -> Self {
        switch osType {
        case .macOS:
            return .init(type: .Mac, width: 1920, height: 1200, pixelsPerInch: 80)
        case .linux:
            return .init(type: .Virtio, width: 1280, height: 720, pixelsPerInch: 0)
        }
    }

    func createConfiguration() -> VZGraphicsDeviceConfiguration {
        switch type {
        case .Virtio:
            let cfg = VZVirtioGraphicsDeviceConfiguration()
            cfg.scanouts = [
                VZVirtioGraphicsScanoutConfiguration(widthInPixels: width, heightInPixels: height)
            ]
            return cfg
        case .Mac:
            let cfg = VZMacGraphicsDeviceConfiguration()
            cfg.displays = [
                VZMacGraphicsDisplayConfiguration(
                    widthInPixels: width,
                    heightInPixels: height,
                    pixelsPerInch: pixelsPerInch
                )
            ]
            return cfg
        }
    }
}

public struct VMModelFieldStorageDevice: Codable {
    public enum DeviceType: String, Codable {
        case Block
        case USB
    }

    public let type: DeviceType
    public let size: UInt64
    public let imagePath: String
    /// When true, the disk is mounted read-only. Useful for ISO images
    /// (which are read-only on disk anyway) and for sharing a base
    /// bundle without risking accidental writes to its disk image.
    public let readOnly: Bool

    public init(type: DeviceType, size: UInt64, imagePath: String, readOnly: Bool = false) {
        self.type = type
        self.size = size
        self.imagePath = imagePath
        // ISOs / USB attachments are read-only on the host anyway; default to true
        // unless the caller explicitly sets it, so existing call sites that pass
        // `readOnly: false` keep their behavior.
        self.readOnly = readOnly
    }

    public static func defaultDiskSize() -> UInt64 {
        64 * 1024 * 1024 * 1024
    }

    public static func `default`() -> Self {
        .init(type: .Block, size: defaultDiskSize(), imagePath: "Disk.img")
    }

    enum CodingKeys: String, CodingKey { case type, size, imagePath, readOnly }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(DeviceType.self, forKey: .type)
        self.size = try c.decode(UInt64.self, forKey: .size)
        self.imagePath = try c.decode(String.self, forKey: .imagePath)
        // Older bundles don't have this field. USB attachments (ISOs) default
        // to read-only since that's how they were always actually attached.
        let decoded = try c.decodeIfPresent(Bool.self, forKey: .readOnly)
        if let decoded {
            self.readOnly = decoded
        } else {
            self.readOnly = (self.type == .USB)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encode(size, forKey: .size)
        try c.encode(imagePath, forKey: .imagePath)
        try c.encode(readOnly, forKey: .readOnly)
    }
}

public struct VMModelFieldNetworkDevice: Codable {
    public enum DeviceType: String, Codable {
        case NAT
        case Bridged
        case FileHandle
    }

    public let type: DeviceType
    public let identifier: String?

    public init(type: DeviceType, identifier: String? = nil) {
        self.type = type
        self.identifier = identifier
    }

    public static func `default`() -> Self {
        .init(type: .NAT)
    }

    enum CodingKeys: String, CodingKey { case type, identifier }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(DeviceType.self, forKey: .type)
        self.identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(identifier, forKey: .identifier)
    }

    func createConfiguration() throws -> VZNetworkDeviceConfiguration? {
        let dev = VZVirtioNetworkDeviceConfiguration()
        switch type {
        case .NAT:
            dev.attachment = VZNATNetworkDeviceAttachment()
        case .Bridged:
            let interfaces = VZBridgedNetworkInterface.networkInterfaces
            guard !interfaces.isEmpty else {
                throw VM4AError.message("No bridged interfaces available. Ensure the CLI is signed with com.apple.vm.networking entitlement.")
            }
            let iface: VZBridgedNetworkInterface
            if let id = identifier, let match = interfaces.first(where: { $0.identifier == id }) {
                iface = match
            } else if identifier == nil {
                iface = interfaces[0]
            } else {
                let available = interfaces.map { $0.identifier }.joined(separator: ", ")
                throw VM4AError.message("Bridged interface '\(identifier ?? "?")' not found. Available: \(available)")
            }
            dev.attachment = VZBridgedNetworkDeviceAttachment(interface: iface)
        case .FileHandle:
            return nil
        }
        return dev
    }
}

public struct VMModelFieldPointingDevice: Codable {
    public enum DeviceType: String, Codable {
        case USBScreenCoordinatePointing
        case MacTrackpad
    }

    public let type: DeviceType

    public init(type: DeviceType) {
        self.type = type
    }

    public static func `default`() -> Self {
        .init(type: .USBScreenCoordinatePointing)
    }

    func createConfiguration() -> VZPointingDeviceConfiguration {
        switch type {
        case .USBScreenCoordinatePointing:
            return VZUSBScreenCoordinatePointingDeviceConfiguration()
        case .MacTrackpad:
            return VZMacTrackpadConfiguration()
        }
    }
}

public struct VMModelFieldAudioDevice: Codable {
    public enum DeviceType: String, Codable {
        case InputOutputStream
        case InputStream
        case OutputStream
    }

    public let type: DeviceType

    public init(type: DeviceType) {
        self.type = type
    }

    public static func `default`() -> Self {
        .init(type: .InputOutputStream)
    }

    func createConfiguration() -> VZAudioDeviceConfiguration {
        let cfg = VZVirtioSoundDeviceConfiguration()
        switch type {
        case .InputStream:
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            cfg.streams = [input]
        case .OutputStream:
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            cfg.streams = [output]
        case .InputOutputStream:
            let input = VZVirtioSoundDeviceInputStreamConfiguration()
            input.source = VZHostAudioInputStreamSource()
            let output = VZVirtioSoundDeviceOutputStreamConfiguration()
            output.sink = VZHostAudioOutputStreamSink()
            cfg.streams = [input, output]
        }
        return cfg
    }
}

public struct VMModelFieldDirectorySharingDevice: Codable {
    public struct SharingItem: Codable {
        public let name: String
        public let path: URL
        public let readOnly: Bool

        public init(name: String, path: URL, readOnly: Bool) {
            self.name = name
            self.path = path
            self.readOnly = readOnly
        }
    }

    public let tag: String
    public let items: [SharingItem]

    public init(tag: String, items: [SharingItem]) {
        self.tag = tag
        self.items = items
    }

    func createConfiguration() -> VZVirtioFileSystemDeviceConfiguration? {
        guard !items.isEmpty else {
            return nil
        }

        if items.count == 1, let item = items.first {
            let sharedDirectory = VZSharedDirectory(url: item.path, readOnly: item.readOnly)
            let singleShare = VZSingleDirectoryShare(directory: sharedDirectory)
            let cfg = VZVirtioFileSystemDeviceConfiguration(tag: tag)
            cfg.share = singleShare
            return cfg
        }

        var directories: [String: VZSharedDirectory] = [:]
        for item in items {
            directories[item.name] = VZSharedDirectory(url: item.path, readOnly: item.readOnly)
        }
        let share = VZMultipleDirectoryShare(directories: directories)
        let cfg = VZVirtioFileSystemDeviceConfiguration(tag: tag)
        cfg.share = share
        return cfg
    }
}

public struct VMConfigModel: Codable {
    public static let currentSchemaVersion: Int = 1

    public let schemaVersion: Int
    public let type: VMOSType
    public let name: String
    public let remark: String
    public let cpu: VMModelFieldCPU
    public let memory: VMModelFieldMemory
    public let graphicsDevices: [VMModelFieldGraphicDevice]
    public let storageDevices: [VMModelFieldStorageDevice]
    public let networkDevices: [VMModelFieldNetworkDevice]
    public let pointingDevices: [VMModelFieldPointingDevice]
    public let audioDevices: [VMModelFieldAudioDevice]
    public let directorySharingDevices: [VMModelFieldDirectorySharingDevice]
    public let rosetta: VMModelFieldRosetta?

    public init(
        schemaVersion: Int = VMConfigModel.currentSchemaVersion,
        type: VMOSType,
        name: String,
        remark: String,
        cpu: VMModelFieldCPU,
        memory: VMModelFieldMemory,
        graphicsDevices: [VMModelFieldGraphicDevice],
        storageDevices: [VMModelFieldStorageDevice],
        networkDevices: [VMModelFieldNetworkDevice],
        pointingDevices: [VMModelFieldPointingDevice],
        audioDevices: [VMModelFieldAudioDevice],
        directorySharingDevices: [VMModelFieldDirectorySharingDevice],
        rosetta: VMModelFieldRosetta? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.type = type
        self.name = name
        self.remark = remark
        self.cpu = cpu
        self.memory = memory
        self.graphicsDevices = graphicsDevices
        self.storageDevices = storageDevices
        self.networkDevices = networkDevices
        self.pointingDevices = pointingDevices
        self.audioDevices = audioDevices
        self.directorySharingDevices = directorySharingDevices
        self.rosetta = rosetta
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion, type, name, remark, cpu, memory
        case graphicsDevices, storageDevices, networkDevices
        case pointingDevices, audioDevices, directorySharingDevices, rosetta
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.schemaVersion = (try c.decodeIfPresent(Int.self, forKey: .schemaVersion)) ?? 1
        self.type = try c.decode(VMOSType.self, forKey: .type)
        self.name = try c.decode(String.self, forKey: .name)
        self.remark = (try c.decodeIfPresent(String.self, forKey: .remark)) ?? ""
        self.cpu = try c.decode(VMModelFieldCPU.self, forKey: .cpu)
        self.memory = try c.decode(VMModelFieldMemory.self, forKey: .memory)
        self.graphicsDevices = try c.decode([VMModelFieldGraphicDevice].self, forKey: .graphicsDevices)
        self.storageDevices = try c.decode([VMModelFieldStorageDevice].self, forKey: .storageDevices)
        self.networkDevices = try c.decode([VMModelFieldNetworkDevice].self, forKey: .networkDevices)
        self.pointingDevices = try c.decode([VMModelFieldPointingDevice].self, forKey: .pointingDevices)
        self.audioDevices = try c.decode([VMModelFieldAudioDevice].self, forKey: .audioDevices)
        self.directorySharingDevices = try c.decode([VMModelFieldDirectorySharingDevice].self, forKey: .directorySharingDevices)
        self.rosetta = try c.decodeIfPresent(VMModelFieldRosetta.self, forKey: .rosetta)
    }

    public static func defaults(
        osType: VMOSType,
        name: String,
        cpu: Int?,
        memoryBytes: UInt64?,
        diskBytes: UInt64?
    ) -> Self {
        let defaultCPU = VMModelFieldCPU.default().count
        let defaultMemory = VMModelFieldMemory.default().size
        let defaultDisk = VMModelFieldStorageDevice.defaultDiskSize()
        let requestedCPU = cpu ?? defaultCPU
        let cpuValue = min(
            VZVirtualMachineConfiguration.maximumAllowedCPUCount,
            max(VZVirtualMachineConfiguration.minimumAllowedCPUCount, requestedCPU)
        )
        let requestedMemory = memoryBytes ?? defaultMemory
        let memoryValue = min(
            VZVirtualMachineConfiguration.maximumAllowedMemorySize,
            max(VZVirtualMachineConfiguration.minimumAllowedMemorySize, requestedMemory)
        )
        let diskValue = diskBytes ?? defaultDisk

        return .init(
            type: osType,
            name: name,
            remark: "",
            cpu: .init(count: cpuValue),
            memory: .init(size: memoryValue),
            graphicsDevices: [.default(osType: osType)],
            storageDevices: [.init(type: .Block, size: diskValue, imagePath: "Disk.img")],
            networkDevices: [.default()],
            pointingDevices: [.default()],
            audioDevices: [.default()],
            directorySharingDevices: []
        )
    }
}

func resolveStoragePath(_ path: String, rootPath: URL) -> URL {
    let candidate = URL(fileURLWithPath: path)
    if candidate.path().hasPrefix("/") {
        return candidate
    }
    return rootPath.appending(path: path)
}

public struct VMStateModel: Codable {
    public let imagePath: URL

    public init(imagePath: URL) {
        self.imagePath = imagePath
    }
}

public struct VMModel {
    public let rootPath: URL
    public let config: VMConfigModel
    public let state: VMStateModel

    public init(rootPath: URL, config: VMConfigModel, state: VMStateModel) {
        self.rootPath = rootPath
        self.config = config
        self.state = state
    }

    public var configURL: URL { rootPath.appending(path: "config.json") }
    public var stateURL: URL { rootPath.appending(path: "state.json") }
    public var runPIDURL: URL { rootPath.appending(path: ".vm4a-run.pid") }
    public var runLogURL: URL { rootPath.appending(path: ".vm4a-run.log") }
    public var machineIdentifierURL: URL { rootPath.appending(path: "MachineIdentifier") }
    public var hardwareModelURL: URL { rootPath.appending(path: "HardwareModel") }
    public var auxiliaryStorageURL: URL { rootPath.appending(path: "AuxiliaryStorage") }
    public var efiVariableStoreURL: URL { rootPath.appending(path: "NVRAM") }
}

func jsonEncoder() -> JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}

public func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let data = try jsonEncoder().encode(value)
    try data.write(to: url)
}

public func loadModel(rootPath: URL) throws -> VMModel {
    let configURL = rootPath.appending(path: "config.json")
    let stateURL = rootPath.appending(path: "state.json")

    let configData = try Data(contentsOf: configURL)
    let config = try JSONDecoder().decode(VMConfigModel.self, from: configData)

    let state: VMStateModel
    if let stateData = try? Data(contentsOf: stateURL),
       let decoded = try? JSONDecoder().decode(VMStateModel.self, from: stateData) {
        state = decoded
    } else {
        state = .init(imagePath: rootPath)
    }

    return VMModel(rootPath: rootPath, config: config, state: state)
}

func makeAppendOnlySerialAttachment(fileURL: URL) throws -> VZFileHandleSerialPortAttachment {
    if !FileManager.default.fileExists(atPath: fileURL.path(percentEncoded: false)) {
        FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
    }
    let handle = try FileHandle(forWritingTo: fileURL)
    try handle.seekToEnd()
    return VZFileHandleSerialPortAttachment(fileHandleForReading: nil, fileHandleForWriting: handle)
}

/// Fast directory copy using APFS clonefile(2) when possible, with a
/// FileManager fallback for cross-volume copies. Returns `true` when
/// the destination was created via clonefile, `false` via byte copy.
@discardableResult
public func cloneDirectory(from src: URL, to dst: URL) throws -> Bool {
    if FileManager.default.fileExists(atPath: dst.path(percentEncoded: false)) {
        throw VM4AError.alreadyExists(dst.path())
    }
    let rc = clonefile(
        src.path(percentEncoded: false),
        dst.path(percentEncoded: false),
        0
    )
    if rc == 0 { return true }
    try FileManager.default.copyItem(at: src, to: dst)
    return false
}

public func createEmptyDiskImage(filePath: URL, size: UInt64) throws {
    let fd = open(filePath.path(percentEncoded: false), O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    guard fd != -1 else {
        throw VM4AError.message("Failed to create disk image at \(filePath.path())")
    }
    defer { close(fd) }
    guard ftruncate(fd, off_t(size)) == 0 else {
        throw VM4AError.message("Failed to allocate disk image at \(filePath.path())")
    }
}

public func ensureDiskImagesExist(model: VMModel) throws {
    for device in model.config.storageDevices where device.type == .Block {
        let diskPath = model.rootPath.appending(path: device.imagePath)
        if !FileManager.default.fileExists(atPath: diskPath.path(percentEncoded: false)) {
            try createEmptyDiskImage(filePath: diskPath, size: device.size)
        }
    }
}

func createLinuxPlatformConfiguration(model: VMModel) throws -> VZGenericPlatformConfiguration {
    let platform = VZGenericPlatformConfiguration()
    let machineIdentifierData = try Data(contentsOf: model.machineIdentifierURL)
    guard let machineIdentifier = VZGenericMachineIdentifier(dataRepresentation: machineIdentifierData) else {
        throw VM4AError.message("Failed to decode MachineIdentifier")
    }
    platform.machineIdentifier = machineIdentifier
    return platform
}

func createMacPlatformConfiguration(model: VMModel) throws -> VZMacPlatformConfiguration {
    let platform = VZMacPlatformConfiguration()
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: model.auxiliaryStorageURL)

    let hardwareData = try Data(contentsOf: model.hardwareModelURL)
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
        throw VM4AError.message("Failed to decode HardwareModel")
    }
    guard hardwareModel.isSupported else {
        throw VM4AError.message("HardwareModel is not supported on this host")
    }
    platform.hardwareModel = hardwareModel

    let machineData = try Data(contentsOf: model.machineIdentifierURL)
    guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineData) else {
        throw VM4AError.message("Failed to decode MachineIdentifier")
    }
    platform.machineIdentifier = machineIdentifier
    return platform
}

func createStorageConfiguration(model: VMModel) throws -> [VZStorageDeviceConfiguration] {
    try model.config.storageDevices.map { item in
        switch item.type {
        case .USB:
            // USB-attached ISOs are read-only on the wire regardless of the
            // attachment flag, but we still pass through item.readOnly so
            // VZ enforces it explicitly.
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: resolveStoragePath(item.imagePath, rootPath: model.rootPath),
                readOnly: item.readOnly || true
            )
            return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        case .Block:
            let fullPath = model.rootPath.appending(path: item.imagePath)
            if !FileManager.default.fileExists(atPath: fullPath.path(percentEncoded: false)) {
                try createEmptyDiskImage(filePath: fullPath, size: item.size)
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: fullPath, readOnly: item.readOnly)
            return VZVirtioBlockDeviceConfiguration(attachment: attachment)
        }
    }
}

public func createConfiguration(model: VMModel) throws -> VZVirtualMachineConfiguration {
    let vmConfiguration = VZVirtualMachineConfiguration()

    switch model.config.type {
    case .macOS:
        vmConfiguration.platform = try createMacPlatformConfiguration(model: model)
        vmConfiguration.bootLoader = VZMacOSBootLoader()
    case .linux:
        vmConfiguration.platform = try createLinuxPlatformConfiguration(model: model)
        guard FileManager.default.fileExists(atPath: model.efiVariableStoreURL.path(percentEncoded: false)) else {
            throw VM4AError.message("Missing NVRAM file at \(model.efiVariableStoreURL.path())")
        }
        let variableStore = VZEFIVariableStore(url: model.efiVariableStoreURL)
        let bootLoader = VZEFIBootLoader()
        bootLoader.variableStore = variableStore
        vmConfiguration.bootLoader = bootLoader

        let consoleDevice = VZVirtioConsoleDeviceConfiguration()
        let spicePort = VZVirtioConsolePortConfiguration()
        spicePort.name = VZSpiceAgentPortAttachment.spiceAgentPortName
        spicePort.attachment = VZSpiceAgentPortAttachment()
        consoleDevice.ports[0] = spicePort
        vmConfiguration.consoleDevices = [consoleDevice]

        let consoleLogURL = model.rootPath.appending(path: "console.log")
        if let attachment = try? makeAppendOnlySerialAttachment(fileURL: consoleLogURL) {
            let serial = VZVirtioConsoleDeviceSerialPortConfiguration()
            serial.attachment = attachment
            vmConfiguration.serialPorts = [serial]
        }
    }

    vmConfiguration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    vmConfiguration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]

    vmConfiguration.cpuCount = model.config.cpu.count
    vmConfiguration.memorySize = model.config.memory.size
    vmConfiguration.graphicsDevices = model.config.graphicsDevices.map { $0.createConfiguration() }
    vmConfiguration.storageDevices = try createStorageConfiguration(model: model)
    vmConfiguration.networkDevices = try model.config.networkDevices.compactMap { try $0.createConfiguration() }
    vmConfiguration.pointingDevices = model.config.pointingDevices.map { $0.createConfiguration() }
    vmConfiguration.audioDevices = model.config.audioDevices.map { $0.createConfiguration() }
    vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]

    var dirShares = model.config.directorySharingDevices.compactMap { $0.createConfiguration() }
    if let rosetta = model.config.rosetta, rosetta.enabled {
        if #available(macOS 13.0, *) {
            switch VZLinuxRosettaDirectoryShare.availability {
            case .installed:
                let share = try VZLinuxRosettaDirectoryShare()
                let dev = VZVirtioFileSystemDeviceConfiguration(tag: rosetta.tag)
                dev.share = share
                dirShares.append(dev)
            case .notInstalled:
                throw VM4AError.message("Rosetta is not installed. Run: softwareupdate --install-rosetta --agree-to-license")
            case .notSupported:
                throw VM4AError.message("Rosetta is not supported on this host")
            @unknown default:
                throw VM4AError.message("Rosetta availability is unknown on this host")
            }
        } else {
            throw VM4AError.message("Rosetta requires macOS 13 or later")
        }
    }
    vmConfiguration.directorySharingDevices = dirShares

    try vmConfiguration.validate()
    return vmConfiguration
}

public func isProcessRunning(pid: Int32) -> Bool {
    guard pid > 0 else { return false }
    guard kill(pid, 0) == 0 else { return false }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/ps")
    process.arguments = ["-o", "stat=", "-p", "\(pid)"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let status = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if status.isEmpty { return false }
        if status.contains("Z") { return false }
        return true
    } catch {
        return true
    }
}

public func readPID(from url: URL) -> Int32? {
    guard let text = try? String(contentsOf: url).trimmingCharacters(in: .whitespacesAndNewlines),
          let value = Int32(text) else {
        return nil
    }
    return value
}

public func writePID(_ pid: Int32, to url: URL) throws {
    try "\(pid)\n".write(to: url, atomically: true, encoding: .utf8)
}

public func clearPID(at url: URL) {
    try? FileManager.default.removeItem(at: url)
}

final class VMDelegate: NSObject, VZVirtualMachineDelegate {
    let onStop: @Sendable (Error?) -> Void

    init(onStop: @escaping @Sendable (Error?) -> Void) {
        self.onStop = onStop
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        onStop(nil)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        onStop(error)
    }
}

public struct RunOptions: Sendable {
    public var recoveryMode: Bool
    public var restoreStateAt: URL?
    public var saveStateOnStopAt: URL?

    public init(recoveryMode: Bool = false, restoreStateAt: URL? = nil, saveStateOnStopAt: URL? = nil) {
        self.recoveryMode = recoveryMode
        self.restoreStateAt = restoreStateAt
        self.saveStateOnStopAt = saveStateOnStopAt
    }
}

public func runVM(model: VMModel, recoveryMode: Bool) throws {
    try runVM(model: model, options: RunOptions(recoveryMode: recoveryMode))
}

public func runVM(model: VMModel, options: RunOptions) throws {
    try ensureDiskImagesExist(model: model)
    let configuration = try createConfiguration(model: model)

    let vmQueue = DispatchQueue(label: "vm4a.vm")
    let virtualMachine = VZVirtualMachine(configuration: configuration, queue: vmQueue)

    let stopLatch = DispatchSemaphore(value: 0)
    let stopBox = _StopBox()
    let delegate = VMDelegate { error in
        stopBox.setError(error)
        stopLatch.signal()
    }
    vmQueue.sync {
        virtualMachine.delegate = delegate
    }

    signal(SIGINT, SIG_IGN)
    signal(SIGTERM, SIG_IGN)
    let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: vmQueue)
    let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: vmQueue)
    let requestStop: @Sendable () -> Void = {
        if let saveURL = options.saveStateOnStopAt, #available(macOS 14.0, *) {
            virtualMachine.pause { _ in
                virtualMachine.saveMachineStateTo(url: saveURL) { saveError in
                    if let saveError {
                        stopBox.setError(saveError)
                    }
                    virtualMachine.stop { _ in }
                }
            }
        } else {
            virtualMachine.stop { _ in }
        }
    }
    sigintSource.setEventHandler(handler: requestStop)
    sigtermSource.setEventHandler(handler: requestStop)
    sigintSource.resume()
    sigtermSource.resume()

    try vmQueueStart(virtualMachine: virtualMachine, queue: vmQueue, options: options, osType: model.config.type)

    stopLatch.wait()

    if let error = stopBox.error {
        throw error
    }
}

final class _StopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _error: Error?
    var error: Error? { lock.lock(); defer { lock.unlock() }; return _error }
    func setError(_ error: Error?) {
        lock.lock(); defer { lock.unlock() }
        if _error == nil { _error = error }
    }
}

private func vmQueueStart(virtualMachine: VZVirtualMachine, queue: DispatchQueue, options: RunOptions, osType: VMOSType) throws {
    let start = DispatchSemaphore(value: 0)
    let errBox = _StopBox()

    queue.async {
        if let restoreURL = options.restoreStateAt {
            if #available(macOS 14.0, *) {
                virtualMachine.restoreMachineStateFrom(url: restoreURL) { restoreError in
                    if let restoreError {
                        errBox.setError(restoreError)
                        start.signal()
                        return
                    }
                    virtualMachine.resume { result in
                        if case let .failure(error) = result { errBox.setError(error) }
                        start.signal()
                    }
                }
            } else {
                errBox.setError(VM4AError.hostUnsupported("Snapshot restore requires macOS 14 or later"))
                start.signal()
            }
            return
        }

        if options.recoveryMode && osType == .macOS {
            let startOpts = VZMacOSVirtualMachineStartOptions()
            startOpts.startUpFromMacOSRecovery = true
            virtualMachine.start(options: startOpts) { error in
                if let error { errBox.setError(error) }
                start.signal()
            }
        } else {
            virtualMachine.start { result in
                if case let .failure(error) = result { errBox.setError(error) }
                start.signal()
            }
        }
    }

    start.wait()
    if let error = errBox.error { throw error }
}
