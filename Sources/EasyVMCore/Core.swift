import Foundation
import Virtualization

public enum EasyVMError: Error, CustomStringConvertible {
    case message(String)

    public var description: String {
        switch self {
        case .message(let text):
            return text
        }
    }
}

public enum VMOSType: String, Codable {
    case macOS = "macOS"
    case linux = "linux"
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

    public init(type: DeviceType, size: UInt64, imagePath: String) {
        self.type = type
        self.size = size
        self.imagePath = imagePath
    }

    public static func defaultDiskSize() -> UInt64 {
        64 * 1024 * 1024 * 1024
    }

    public static func `default`() -> Self {
        .init(type: .Block, size: defaultDiskSize(), imagePath: "Disk.img")
    }
}

public struct VMModelFieldNetworkDevice: Codable {
    public enum DeviceType: String, Codable {
        case NAT
        case Bridged
        case FileHandle
    }

    public let type: DeviceType

    public init(type: DeviceType) {
        self.type = type
    }

    public static func `default`() -> Self {
        .init(type: .NAT)
    }

    func createConfiguration() -> VZNetworkDeviceConfiguration {
        let networkDevice = VZVirtioNetworkDeviceConfiguration()
        networkDevice.attachment = VZNATNetworkDeviceAttachment()
        return networkDevice
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

    public init(
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
        directorySharingDevices: [VMModelFieldDirectorySharingDevice]
    ) {
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
    public var runPIDURL: URL { rootPath.appending(path: ".easyvm-run.pid") }
    public var runLogURL: URL { rootPath.appending(path: ".easyvm-run.log") }
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

public func createEmptyDiskImage(filePath: URL, size: UInt64) throws {
    let fd = open(filePath.path(percentEncoded: false), O_RDWR | O_CREAT, S_IRUSR | S_IWUSR)
    guard fd != -1 else {
        throw EasyVMError.message("Failed to create disk image at \(filePath.path())")
    }
    defer { close(fd) }
    guard ftruncate(fd, off_t(size)) == 0 else {
        throw EasyVMError.message("Failed to allocate disk image at \(filePath.path())")
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
        throw EasyVMError.message("Failed to decode MachineIdentifier")
    }
    platform.machineIdentifier = machineIdentifier
    return platform
}

func createMacPlatformConfiguration(model: VMModel) throws -> VZMacPlatformConfiguration {
    let platform = VZMacPlatformConfiguration()
    platform.auxiliaryStorage = VZMacAuxiliaryStorage(contentsOf: model.auxiliaryStorageURL)

    let hardwareData = try Data(contentsOf: model.hardwareModelURL)
    guard let hardwareModel = VZMacHardwareModel(dataRepresentation: hardwareData) else {
        throw EasyVMError.message("Failed to decode HardwareModel")
    }
    guard hardwareModel.isSupported else {
        throw EasyVMError.message("HardwareModel is not supported on this host")
    }
    platform.hardwareModel = hardwareModel

    let machineData = try Data(contentsOf: model.machineIdentifierURL)
    guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: machineData) else {
        throw EasyVMError.message("Failed to decode MachineIdentifier")
    }
    platform.machineIdentifier = machineIdentifier
    return platform
}

func createStorageConfiguration(model: VMModel) throws -> [VZStorageDeviceConfiguration] {
    try model.config.storageDevices.map { item in
        switch item.type {
        case .USB:
            let attachment = try VZDiskImageStorageDeviceAttachment(
                url: resolveStoragePath(item.imagePath, rootPath: model.rootPath),
                readOnly: false
            )
            return VZUSBMassStorageDeviceConfiguration(attachment: attachment)
        case .Block:
            let fullPath = model.rootPath.appending(path: item.imagePath)
            if !FileManager.default.fileExists(atPath: fullPath.path(percentEncoded: false)) {
                try createEmptyDiskImage(filePath: fullPath, size: item.size)
            }
            let attachment = try VZDiskImageStorageDeviceAttachment(url: fullPath, readOnly: false)
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
            throw EasyVMError.message("Missing NVRAM file at \(model.efiVariableStoreURL.path())")
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
    }

    vmConfiguration.cpuCount = model.config.cpu.count
    vmConfiguration.memorySize = model.config.memory.size
    vmConfiguration.graphicsDevices = model.config.graphicsDevices.map { $0.createConfiguration() }
    vmConfiguration.storageDevices = try createStorageConfiguration(model: model)
    vmConfiguration.networkDevices = model.config.networkDevices.map { $0.createConfiguration() }
    vmConfiguration.pointingDevices = model.config.pointingDevices.map { $0.createConfiguration() }
    vmConfiguration.audioDevices = model.config.audioDevices.map { $0.createConfiguration() }
    vmConfiguration.keyboards = [VZUSBKeyboardConfiguration()]
    vmConfiguration.directorySharingDevices = model.config.directorySharingDevices.compactMap { $0.createConfiguration() }

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
    nonisolated(unsafe) var didStop = false
    nonisolated(unsafe) var stopError: Error?

    nonisolated func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        didStop = true
    }

    nonisolated func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        didStop = true
        stopError = error
    }
}

nonisolated(unsafe) private var stopRequestedFlag: sig_atomic_t = 0

final class ErrorBox: @unchecked Sendable {
    nonisolated(unsafe) var error: Error?
}

@_cdecl("easyvm_signal_handler")
func easyvm_signal_handler(_: Int32) {
    stopRequestedFlag = 1
}

public func runVM(model: VMModel, recoveryMode: Bool) throws {
    stopRequestedFlag = 0
    signal(SIGINT, easyvm_signal_handler)
    signal(SIGTERM, easyvm_signal_handler)

    try ensureDiskImagesExist(model: model)
    let configuration = try createConfiguration(model: model)
    let virtualMachine = VZVirtualMachine(configuration: configuration)
    let delegate = VMDelegate()
    virtualMachine.delegate = delegate

    if recoveryMode && model.config.type == .macOS {
        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = true
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()
        virtualMachine.start(options: options) { error in
            errorBox.error = error
            semaphore.signal()
        }
        semaphore.wait()
        if let startError = errorBox.error {
            throw startError
        }
    } else {
        let semaphore = DispatchSemaphore(value: 0)
        let errorBox = ErrorBox()
        virtualMachine.start { result in
            switch result {
            case .success:
                errorBox.error = nil
            case .failure(let error):
                errorBox.error = error
            }
            semaphore.signal()
        }
        semaphore.wait()
        if let startError = errorBox.error {
            throw startError
        }
    }

    while true {
        if stopRequestedFlag != 0 {
            exit(0)
        }
        if delegate.didStop {
            if let error = delegate.stopError {
                throw error
            }
            return
        }
        Thread.sleep(forTimeInterval: 1.0)
    }
}
