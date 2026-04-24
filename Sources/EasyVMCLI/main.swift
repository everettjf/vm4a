import ArgumentParser
import EasyVMCore
import Foundation
import Virtualization

extension VMOSType: ExpressibleByArgument {}

func normalizePath(_ rawPath: String) -> String {
    let expanded = (rawPath as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path()
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL.path()
}

func bytesFromGB(_ gigabytes: Int, fieldName: String) throws -> UInt64 {
    guard gigabytes > 0 else {
        throw EasyVMError.message("\(fieldName) must be greater than 0")
    }
    guard let gbValue = UInt64(exactly: gigabytes) else {
        throw EasyVMError.message("Invalid \(fieldName): \(gigabytes)")
    }
    let (bytes, overflow) = gbValue.multipliedReportingOverflow(by: 1024 * 1024 * 1024)
    guard !overflow else {
        throw EasyVMError.message("\(fieldName) is too large: \(gigabytes) GB")
    }
    return bytes
}

struct EasyVMCLI: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "easyvm",
        abstract: "EasyVM standalone CLI",
        subcommands: [
            CreateCommand.self,
            ListCommand.self,
            RunCommand.self,
            StopCommand.self,
            CloneCommand.self,
            NetworkCommand.self,
            ImageCommand.self,
            RunWorkerCommand.self
        ]
    )
}

struct CreateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "create", abstract: "Create a VM bundle")

    @Argument(help: "VM name")
    var name: String

    @Option(name: .long, help: "OS type: macOS or linux")
    var os: VMOSType

    @Option(name: .long, help: "Parent directory to store VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    @Option(name: .long, help: "Initial image path (ISO/IPSW). Optional.")
    var image: String?

    @Option(name: .long, help: "vCPU count")
    var cpu: Int?

    @Option(name: .long, help: "Memory size in GB")
    var memoryGB: Int?

    @Option(name: .long, help: "Disk size in GB")
    var diskGB: Int?

    @Option(name: .long, help: "Bridged interface bsdName (enables bridged networking). Use 'easyvm network list' to enumerate.")
    var bridgedInterface: String?

    @Flag(name: .long, help: "Enable Rosetta translation share (Linux only, macOS 13+).")
    var rosetta: Bool = false

    mutating func run() throws {
        if let cpu, cpu <= 0 {
            throw EasyVMError.message("cpu must be greater than 0")
        }
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        let rootPath = storageURL.appending(path: name, directoryHint: .isDirectory)

        if FileManager.default.fileExists(atPath: rootPath.path(percentEncoded: false)) {
            throw EasyVMError.message("VM already exists at \(rootPath.path())")
        }

        let memoryBytes = try memoryGB.map { try bytesFromGB($0, fieldName: "memory-gb") }
        let diskBytes = try diskGB.map { try bytesFromGB($0, fieldName: "disk-gb") }
        var config = VMConfigModel.defaults(osType: os, name: name, cpu: cpu, memoryBytes: memoryBytes, diskBytes: diskBytes)
        let normalizedImagePath = image.map(normalizePath)

        let network: [VMModelFieldNetworkDevice]
        if let bridgedInterface {
            let interfaces = availableBridgedInterfaces()
            if interfaces.first(where: { $0.identifier == bridgedInterface }) == nil {
                let available = interfaces.map { $0.identifier }.joined(separator: ", ")
                throw EasyVMError.message("Bridged interface '\(bridgedInterface)' not found. Available: \(available)")
            }
            network = [.init(type: .Bridged, identifier: bridgedInterface)]
        } else {
            network = config.networkDevices
        }

        let rosettaField: VMModelFieldRosetta?
        if rosetta {
            if os != .linux {
                throw EasyVMError.message("--rosetta only applies to Linux guests")
            }
            switch VMModelFieldRosetta.hostAvailability {
            case .notSupported:
                throw EasyVMError.message("Rosetta is not supported on this host")
            case .notInstalled:
                FileHandle.standardError.write(Data("warning: Rosetta is not installed. Install with: softwareupdate --install-rosetta --agree-to-license\n".utf8))
            case .installed:
                break
            }
            rosettaField = .init(enabled: true)
        } else {
            rosettaField = nil
        }

        let storageDevices: [VMModelFieldStorageDevice]
        if os == .linux, let normalizedImagePath, !normalizedImagePath.isEmpty {
            storageDevices = config.storageDevices + [.init(type: .USB, size: 0, imagePath: normalizedImagePath)]
        } else {
            storageDevices = config.storageDevices
        }

        if bridgedInterface != nil || rosettaField != nil || storageDevices.count != config.storageDevices.count {
            config = VMConfigModel(
                type: config.type,
                name: config.name,
                remark: config.remark,
                cpu: config.cpu,
                memory: config.memory,
                graphicsDevices: config.graphicsDevices,
                storageDevices: storageDevices,
                networkDevices: network,
                pointingDevices: config.pointingDevices,
                audioDevices: config.audioDevices,
                directorySharingDevices: config.directorySharingDevices,
                rosetta: rosettaField
            )
        }

        try FileManager.default.createDirectory(at: rootPath, withIntermediateDirectories: true)

        let stateImagePath = normalizedImagePath ?? rootPath.path()
        let state = VMStateModel(imagePath: URL(fileURLWithPath: stateImagePath))
        let model = VMModel(rootPath: rootPath, config: config, state: state)
        try writeJSON(config, to: model.configURL)
        try writeJSON(state, to: model.stateURL)
        try ensureDiskImagesExist(model: model)

        if os == .linux {
            let machineIdentifier = VZGenericMachineIdentifier()
            try machineIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
            _ = try VZEFIVariableStore(creatingVariableStoreAt: model.efiVariableStoreURL)
        } else {
            print("Created macOS VM skeleton. Complete installation using GUI flow to generate HardwareModel/AuxiliaryStorage.")
        }

        print("Created VM: \(rootPath.path())")
    }
}

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List VM bundles in a directory")

    @Option(name: .long, help: "Parent directory that contains VM bundles")
    var storage: String = FileManager.default.currentDirectoryPath

    mutating func run() throws {
        let storageURL = URL(fileURLWithPath: storage, isDirectory: true)
        let entries = try FileManager.default.contentsOfDirectory(
            at: storageURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )

        var found = false
        for entry in entries {
            guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
                continue
            }
            let configURL = entry.appending(path: "config.json")
            guard FileManager.default.fileExists(atPath: configURL.path(percentEncoded: false)),
                  let model = try? loadModel(rootPath: entry) else {
                continue
            }
            found = true
            let pid = readPID(from: model.runPIDURL)
            let running = pid.map(isProcessRunning(pid:)) ?? false
            if pid != nil, !running {
                clearPID(at: model.runPIDURL)
                print("\(model.config.name)\t\(model.config.type.rawValue)\tstopped\t\(entry.path())")
            } else {
                let status = running ? "running(pid:\(pid!))" : "stopped"
                print("\(model.config.name)\t\(model.config.type.rawValue)\t\(status)\t\(entry.path())")
            }
        }

        if !found {
            print("No VM bundles found in \(storageURL.path())")
        }
    }
}

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "run", abstract: "Run a VM")

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Flag(name: .long, help: "Start macOS VM in recovery mode")
    var recovery = false

    @Flag(name: .long, help: "Run in foreground")
    var foreground = false

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)

        if let pid = readPID(from: model.runPIDURL), isProcessRunning(pid: pid) {
            throw EasyVMError.message("VM is already running (pid \(pid))")
        }
        clearPID(at: model.runPIDURL)

        if foreground {
            try writePID(getpid(), to: model.runPIDURL)
            defer { clearPID(at: model.runPIDURL) }
            try runVM(model: model, recoveryMode: recovery)
            return
        }

        guard let executable = Bundle.main.executablePath else {
            throw EasyVMError.message("Cannot locate executable path")
        }

        FileManager.default.createFile(atPath: model.runLogURL.path(percentEncoded: false), contents: nil)
        let logHandle = try FileHandle(forWritingTo: model.runLogURL)
        try logHandle.truncate(atOffset: 0)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["_run-worker", vmPath] + (recovery ? ["--recovery"] : [])

        let null = FileHandle.nullDevice
        process.standardInput = null
        process.standardOutput = logHandle
        process.standardError = logHandle

        try process.run()
        Thread.sleep(forTimeInterval: 1.0)

        if let pid = readPID(from: model.runPIDURL), isProcessRunning(pid: pid) {
            print("Started VM worker pid \(pid)")
            return
        }

        let logText = (try? String(contentsOf: model.runLogURL)) ?? ""
        let nonEmptyLog = logText.trimmingCharacters(in: .whitespacesAndNewlines)
        if nonEmptyLog.isEmpty {
            throw EasyVMError.message("VM worker exited early. Check \(model.runLogURL.path())")
        }
        throw EasyVMError.message("VM worker failed to start:\n\(nonEmptyLog)")
    }
}

struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "stop", abstract: "Stop a running VM")

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Option(name: .long, help: "Wait timeout in seconds")
    var timeout: Int = 20

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)

        guard let pid = readPID(from: model.runPIDURL) else {
            throw EasyVMError.message("No run pid found for \(vmPath)")
        }
        guard isProcessRunning(pid: pid) else {
            clearPID(at: model.runPIDURL)
            throw EasyVMError.message("Process \(pid) is not running")
        }

        guard kill(pid, SIGTERM) == 0 else {
            throw EasyVMError.message("Failed to send SIGTERM to pid \(pid)")
        }

        let deadline = Date().addingTimeInterval(TimeInterval(timeout))
        while Date() < deadline {
            if !isProcessRunning(pid: pid) {
                clearPID(at: model.runPIDURL)
                print("Stopped VM process \(pid)")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        _ = kill(pid, SIGKILL)
        let killDeadline = Date().addingTimeInterval(5)
        while Date() < killDeadline {
            if !isProcessRunning(pid: pid) {
                clearPID(at: model.runPIDURL)
                print("Stopped VM process \(pid) (forced)")
                return
            }
            Thread.sleep(forTimeInterval: 0.25)
        }

        throw EasyVMError.message("Timed out waiting for pid \(pid) to stop, even after SIGKILL")
    }
}

struct CloneCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "clone", abstract: "Clone a VM bundle")

    @Argument(help: "Source VM root path")
    var sourcePath: String

    @Argument(help: "Destination VM root path")
    var destinationPath: String

    mutating func run() throws {
        let src = URL(fileURLWithPath: sourcePath, isDirectory: true)
        let dst = URL(fileURLWithPath: destinationPath, isDirectory: true)

        guard FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else {
            throw EasyVMError.message("Source VM does not exist: \(src.path())")
        }
        guard !FileManager.default.fileExists(atPath: dst.path(percentEncoded: false)) else {
            throw EasyVMError.message("Destination already exists: \(dst.path())")
        }

        try FileManager.default.copyItem(at: src, to: dst)
        let model = try loadModel(rootPath: dst)
        clearPID(at: model.runPIDURL)

        switch model.config.type {
        case .linux:
            let newIdentifier = VZGenericMachineIdentifier()
            try newIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
        case .macOS:
            let newIdentifier = VZMacMachineIdentifier()
            try newIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
        }

        print("Cloned VM to \(dst.path())")
    }
}

struct NetworkCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "network",
        abstract: "Inspect host network interfaces",
        subcommands: [ListBridgedCommand.self],
        defaultSubcommand: ListBridgedCommand.self
    )
}

struct ListBridgedCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List bridged interfaces available to VMs")

    mutating func run() throws {
        let interfaces = availableBridgedInterfaces()
        if interfaces.isEmpty {
            print("No bridged interfaces available. Ensure the CLI is signed with com.apple.vm.networking entitlement.")
            return
        }
        for iface in interfaces {
            if let name = iface.displayName {
                print("\(iface.identifier)\t\(name)")
            } else {
                print(iface.identifier)
            }
        }
    }
}

struct ImageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "image",
        abstract: "Linux image catalog and local operations",
        subcommands: [ImageListCommand.self],
        defaultSubcommand: ImageListCommand.self
    )
}

struct ImageListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "List curated Linux ARM64 images")

    mutating func run() throws {
        for entry in linuxImageCatalog() {
            print("\(entry.id)\t\(entry.displayName)")
            print("  \(entry.url)")
        }
    }
}

struct RunWorkerCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "_run-worker",
        abstract: "Internal worker command"
    )

    @Argument(help: "Path to VM root directory")
    var vmPath: String

    @Flag(name: .long, help: "Start macOS VM in recovery mode")
    var recovery = false

    mutating func run() throws {
        let rootURL = URL(fileURLWithPath: vmPath, isDirectory: true)
        let model = try loadModel(rootPath: rootURL)
        try writePID(getpid(), to: model.runPIDURL)
        defer { clearPID(at: model.runPIDURL) }
        try runVM(model: model, recoveryMode: recovery)
    }
}

EasyVMCLI.main()
