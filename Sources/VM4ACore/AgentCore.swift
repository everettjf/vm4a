import Foundation
@preconcurrency import Virtualization

// MARK: - Path / size helpers

/// Expand `~` and resolve relative paths against the current working
/// directory. Output is an absolute, standardised path.
public func normalizePath(_ rawPath: String) -> String {
    let expanded = (rawPath as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") {
        return URL(fileURLWithPath: expanded).standardizedFileURL.path()
    }
    let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    return URL(fileURLWithPath: expanded, relativeTo: cwd).standardizedFileURL.path()
}

public func bytesFromGB(_ gigabytes: Int, fieldName: String) throws -> UInt64 {
    guard gigabytes > 0 else {
        throw VM4AError.message("\(fieldName) must be greater than 0")
    }
    guard let gbValue = UInt64(exactly: gigabytes) else {
        throw VM4AError.message("Invalid \(fieldName): \(gigabytes)")
    }
    let (bytes, overflow) = gbValue.multipliedReportingOverflow(by: 1024 * 1024 * 1024)
    guard !overflow else {
        throw VM4AError.message("\(fieldName) is too large: \(gigabytes) GB")
    }
    return bytes
}

// MARK: - Network mode

/// User-facing network mode. `bridged` may carry an interface identifier
/// (otherwise the first available interface is used).
public enum NetworkMode: String, Codable, Sendable {
    case none      // no NIC attached
    case nat       // default NAT (192.168.64.0/24)
    case bridged   // VZ bridged — requires com.apple.vm.networking entitlement

    /// Parse a user-supplied string into a NetworkMode. Case-insensitive.
    /// Accepts "host" as an alias for "bridged" since VZ has no separate
    /// host-networking mode.
    public static func parse(_ raw: String) -> NetworkMode? {
        let lower = raw.lowercased()
        if let v = NetworkMode(rawValue: lower) { return v }
        if lower == "host" { return .bridged }
        return nil
    }
}

// MARK: - Create

public struct CreateBundleOptions: Sendable {
    public var name: String
    public var os: VMOSType
    public var storage: URL
    public var imagePath: String?
    public var cpu: Int?
    public var memoryBytes: UInt64?
    public var diskBytes: UInt64?
    public var networkMode: NetworkMode
    public var bridgedInterface: String?
    public var rosetta: Bool

    public init(
        name: String,
        os: VMOSType,
        storage: URL,
        imagePath: String? = nil,
        cpu: Int? = nil,
        memoryBytes: UInt64? = nil,
        diskBytes: UInt64? = nil,
        networkMode: NetworkMode = .nat,
        bridgedInterface: String? = nil,
        rosetta: Bool = false
    ) {
        self.name = name
        self.os = os
        self.storage = storage
        self.imagePath = imagePath
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        // bridgedInterface implies bridged mode (back-compat with --bridged-interface)
        if bridgedInterface != nil, networkMode == .nat {
            self.networkMode = .bridged
        } else {
            self.networkMode = networkMode
        }
        self.bridgedInterface = bridgedInterface
        self.rosetta = rosetta
    }
}

public struct CreateBundleOutcome: Codable, Sendable {
    public let path: String
    public let name: String
    public let os: String
    public let rosettaWarning: String?

    public init(path: String, name: String, os: String, rosettaWarning: String? = nil) {
        self.path = path
        self.name = name
        self.os = os
        self.rosettaWarning = rosettaWarning
    }
}

/// Build a fresh VM bundle on disk. Caller must ensure the destination
/// (`<storage>/<name>`) does not yet exist.
///
/// For Linux, this is a quick filesystem-only operation: directories,
/// JSON, NVRAM, and (if --image was given) an attached USB ISO.
///
/// For macOS, if `imagePath` is provided (an `.ipsw`), this drives the
/// full Apple `VZMacOSInstaller` flow synchronously through `await`,
/// taking 10–20 minutes depending on the IPSW size. Without `imagePath`
/// the macOS bundle is just a config skeleton — useful only when you're
/// going to populate it from `vm4a pull`.
@discardableResult
public func createBundle(
    options: CreateBundleOptions,
    progress: (@Sendable (String) -> Void)? = nil
) async throws -> CreateBundleOutcome {
    if let cpu = options.cpu, cpu <= 0 {
        throw VM4AError.message("cpu must be greater than 0")
    }
    let rootPath = options.storage.appending(path: options.name, directoryHint: .isDirectory)

    if FileManager.default.fileExists(atPath: rootPath.path(percentEncoded: false)) {
        throw VM4AError.alreadyExists(rootPath.path())
    }

    var config = VMConfigModel.defaults(
        osType: options.os,
        name: options.name,
        cpu: options.cpu,
        memoryBytes: options.memoryBytes,
        diskBytes: options.diskBytes
    )
    let normalizedImagePath = options.imagePath.map(normalizePath)

    let network: [VMModelFieldNetworkDevice]
    switch options.networkMode {
    case .none:
        network = []
    case .nat:
        network = config.networkDevices  // default NAT from VMConfigModel.defaults
    case .bridged:
        let interfaces = availableBridgedInterfaces()
        if interfaces.isEmpty {
            throw VM4AError.message("No bridged interfaces available. Ensure the CLI is signed with com.apple.vm.networking entitlement.")
        }
        if let bridged = options.bridgedInterface {
            if interfaces.first(where: { $0.identifier == bridged }) == nil {
                let available = interfaces.map { $0.identifier }.joined(separator: ", ")
                throw VM4AError.notFound("Bridged interface '\(bridged)'. Available: \(available)")
            }
            network = [.init(type: .Bridged, identifier: bridged)]
        } else {
            // auto-pick the first interface
            network = [.init(type: .Bridged, identifier: interfaces[0].identifier)]
        }
    }

    var rosettaWarning: String?
    let rosettaField: VMModelFieldRosetta?
    if options.rosetta {
        if options.os != .linux {
            throw VM4AError.message("--rosetta only applies to Linux guests")
        }
        switch VMModelFieldRosetta.hostAvailability {
        case .notSupported:
            throw VM4AError.hostUnsupported("Rosetta is not supported on this host")
        case .notInstalled:
            rosettaWarning = "Rosetta is not installed. Install with: softwareupdate --install-rosetta --agree-to-license"
        case .installed:
            break
        }
        rosettaField = .init(enabled: true)
    } else {
        rosettaField = nil
    }

    let storageDevices: [VMModelFieldStorageDevice]
    if options.os == .linux, let path = normalizedImagePath, !path.isEmpty {
        storageDevices = config.storageDevices + [.init(type: .USB, size: 0, imagePath: path)]
    } else {
        storageDevices = config.storageDevices
    }

    if options.networkMode != .nat || rosettaField != nil || storageDevices.count != config.storageDevices.count {
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

    switch options.os {
    case .linux:
        let machineIdentifier = VZGenericMachineIdentifier()
        try machineIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
        _ = try VZEFIVariableStore(creatingVariableStoreAt: model.efiVariableStoreURL)
    case .macOS:
        // For macOS, only the IPSW restore image flow produces a bootable bundle.
        // Without an image, we leave HardwareModel/AuxiliaryStorage absent and
        // the caller is expected to populate them via `vm4a pull` from a
        // pre-installed bundle.
        if let imagePath = normalizedImagePath, !imagePath.isEmpty {
            progress?("Running VZMacOSInstaller (this takes 10–20 minutes)…")
            try await runMacOSInstall(
                model: model,
                ipswPath: URL(fileURLWithPath: imagePath),
                progress: { p in
                    if let frac = p.fraction {
                        progress?(String(format: "  install %.0f%% — %@", frac * 100, p.message))
                    } else {
                        progress?("  \(p.stage.rawValue): \(p.message)")
                    }
                }
            )
        }
    }

    return CreateBundleOutcome(
        path: rootPath.path(),
        name: options.name,
        os: options.os.rawValue,
        rosettaWarning: rosettaWarning
    )
}

// MARK: - Spawn

public struct SpawnOptions: Sendable {
    public var name: String
    public var os: VMOSType
    public var storage: URL
    public var from: String?
    public var imagePath: String?
    public var cpu: Int?
    public var memoryBytes: UInt64?
    public var diskBytes: UInt64?
    public var networkMode: NetworkMode
    public var bridgedInterface: String?
    public var rosetta: Bool
    public var restoreStateAt: String?
    public var saveOnStopAt: String?
    public var waitIP: Bool
    public var waitSSH: Bool
    public var sshUser: String?
    public var sshKey: String?
    public var hostOverride: String?
    public var waitTimeout: TimeInterval

    public init(
        name: String,
        os: VMOSType = .linux,
        storage: URL,
        from: String? = nil,
        imagePath: String? = nil,
        cpu: Int? = nil,
        memoryBytes: UInt64? = nil,
        diskBytes: UInt64? = nil,
        networkMode: NetworkMode = .nat,
        bridgedInterface: String? = nil,
        rosetta: Bool = false,
        restoreStateAt: String? = nil,
        saveOnStopAt: String? = nil,
        waitIP: Bool = false,
        waitSSH: Bool = false,
        sshUser: String? = nil,
        sshKey: String? = nil,
        hostOverride: String? = nil,
        waitTimeout: TimeInterval = 90
    ) {
        self.name = name
        self.os = os
        self.storage = storage
        self.from = from
        self.imagePath = imagePath
        self.cpu = cpu
        self.memoryBytes = memoryBytes
        self.diskBytes = diskBytes
        if bridgedInterface != nil, networkMode == .nat {
            self.networkMode = .bridged
        } else {
            self.networkMode = networkMode
        }
        self.bridgedInterface = bridgedInterface
        self.rosetta = rosetta
        self.restoreStateAt = restoreStateAt
        self.saveOnStopAt = saveOnStopAt
        self.waitIP = waitIP
        self.waitSSH = waitSSH
        self.sshUser = sshUser
        self.sshKey = sshKey
        self.hostOverride = hostOverride
        self.waitTimeout = waitTimeout
    }
}

private func defaultSSHUser(for os: VMOSType) -> String {
    switch os {
    case .linux:  return "root"
    case .macOS:  return NSUserName()
    }
}

private func bundleExists(at url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.appending(path: "config.json").path(percentEncoded: false))
}

/// Create-or-restart-and-wait. The single highest-level entry point used by
/// agent flows: pulls/creates if needed, starts the worker, optionally
/// waits for IP / SSH. `executable` is the path to the running `vm4a`
/// binary (we re-exec it as the run worker).
public func runSpawn(
    options: SpawnOptions,
    executable: String,
    progress: (@Sendable (String) -> Void)? = nil
) async throws -> SpawnOutcome {
    try FileManager.default.createDirectory(at: options.storage, withIntermediateDirectories: true)
    let bundleURL = options.storage.appending(path: options.name, directoryHint: .isDirectory)

    if !bundleExists(at: bundleURL) {
        if let ref = options.from {
            progress?("Pulling \(ref) → \(bundleURL.path())")
            let pulled = try await ociPull(reference: ref, into: options.storage) { line in
                progress?(line)
            }
            if pulled.path() != bundleURL.path() {
                try FileManager.default.moveItem(at: pulled, to: bundleURL)
            }
        } else if options.imagePath != nil || options.os == .macOS {
            // Resolve the image spec (catalog id / URL / local path / nil-for-macOS-latest)
            // into a real cached file before building the bundle.
            let resolved = try await resolveImage(
                spec: options.imagePath,
                os: options.os,
                progress: progress
            )
            try await createBundle(options: CreateBundleOptions(
                name: options.name,
                os: options.os,
                storage: options.storage,
                imagePath: resolved.path(),
                cpu: options.cpu,
                memoryBytes: options.memoryBytes,
                diskBytes: options.diskBytes,
                networkMode: options.networkMode,
                bridgedInterface: options.bridgedInterface,
                rosetta: options.rosetta
            ), progress: progress)
        } else {
            throw VM4AError.message("Bundle '\(bundleURL.path())' not found. Pass --from <oci-ref> or --image <spec>.")
        }
    }

    let model = try loadModel(rootPath: bundleURL)
    let pid = try startVMWorker(
        executable: executable,
        vmPath: bundleURL.path(),
        recovery: false,
        restoreStateAt: options.restoreStateAt.map { normalizePath($0) },
        saveOnStopAt: options.saveOnStopAt.map { normalizePath($0) }
    )

    var resolvedIP: String? = options.hostOverride
    var sshReady = false

    if options.waitIP || options.waitSSH {
        if resolvedIP == nil {
            resolvedIP = waitForVMIP(model: model, timeout: options.waitTimeout)
        }
    }

    if options.waitSSH, let ip = resolvedIP {
        let user = options.sshUser ?? defaultSSHUser(for: model.config.type)
        let opts = SSHOptions(user: user, keyPath: options.sshKey)
        sshReady = waitForSSHReady(host: ip, options: opts, timeout: options.waitTimeout)
    }

    return SpawnOutcome(
        id: vmShortID(forPath: bundleURL),
        name: model.config.name,
        path: bundleURL.path(),
        os: model.config.type.rawValue,
        pid: pid,
        ip: resolvedIP,
        sshReady: sshReady
    )
}

// MARK: - Exec

public struct ExecOptions: Sendable {
    public var vmPath: String
    public var user: String?
    public var key: String?
    public var hostOverride: String?
    public var timeout: TimeInterval
    public var command: [String]

    public init(
        vmPath: String,
        user: String? = nil,
        key: String? = nil,
        hostOverride: String? = nil,
        timeout: TimeInterval = 60,
        command: [String]
    ) {
        self.vmPath = vmPath
        self.user = user
        self.key = key
        self.hostOverride = hostOverride
        self.timeout = timeout
        self.command = command
    }
}

private func resolveHost(model: VMModel, override: String?) throws -> String {
    if let override, !override.isEmpty { return override }
    if let lease = findLeasesForBundle(model).first { return lease.ipAddress }
    throw VM4AError.notFound("DHCP lease for \(model.config.name); pass host override if bridged.")
}

public func runExec(options: ExecOptions) throws -> ExecResult {
    guard !options.command.isEmpty else {
        throw VM4AError.message("Provide a command to exec.")
    }
    let rootURL = URL(fileURLWithPath: options.vmPath, isDirectory: true)
    let model = try loadModel(rootPath: rootURL)
    let target = try resolveHost(model: model, override: options.hostOverride)
    let user = options.user ?? defaultSSHUser(for: model.config.type)
    let sshOpts = SSHOptions(user: user, keyPath: options.key)
    return sshExec(host: target, options: sshOpts, command: options.command, timeout: options.timeout)
}

// MARK: - Cp

public struct CpOptions: Sendable {
    public var vmPath: String
    public var source: String
    public var destination: String
    public var recursive: Bool
    public var user: String?
    public var key: String?
    public var hostOverride: String?
    public var timeout: TimeInterval

    public init(
        vmPath: String,
        source: String,
        destination: String,
        recursive: Bool = false,
        user: String? = nil,
        key: String? = nil,
        hostOverride: String? = nil,
        timeout: TimeInterval = 300
    ) {
        self.vmPath = vmPath
        self.source = source
        self.destination = destination
        self.recursive = recursive
        self.user = user
        self.key = key
        self.hostOverride = hostOverride
        self.timeout = timeout
    }
}

public func runCp(options: CpOptions) throws -> ExecResult {
    let rootURL = URL(fileURLWithPath: options.vmPath, isDirectory: true)
    let model = try loadModel(rootPath: rootURL)
    let target = try resolveHost(model: model, override: options.hostOverride)
    let user = options.user ?? defaultSSHUser(for: model.config.type)

    let src = parseCopyEndpoint(options.source)
    let dst = parseCopyEndpoint(options.destination)
    let scpSource: String
    let scpDestination: String
    switch (src, dst) {
    case (.host(let s), .guest(let g)):
        scpSource = s
        scpDestination = "\(user)@\(target):\(g)"
    case (.guest(let g), .host(let s)):
        scpSource = "\(user)@\(target):\(g)"
        scpDestination = s
    case (.host, .host):
        throw VM4AError.message("cp: at least one side must be a guest path (prefix it with ':')")
    case (.guest, .guest):
        throw VM4AError.message("cp: copying between two guest paths is not supported in one call")
    }

    let sshOpts = SSHOptions(user: user, keyPath: options.key)
    return scpCopy(options: sshOpts, source: scpSource, destination: scpDestination, recursive: options.recursive, timeout: options.timeout)
}

// MARK: - Fork

public struct ForkOptions: Sendable {
    public var sourcePath: String
    public var destinationPath: String
    public var fromSnapshot: String?
    public var autoStart: Bool
    public var waitIP: Bool
    public var waitSSH: Bool
    public var sshUser: String?
    public var sshKey: String?
    public var waitTimeout: TimeInterval
    /// When true, skip re-randomising MachineIdentifier on the fork.
    /// Required when restoring `.vzstate` from the source bundle, since
    /// VZ matches saved state against the platform identity. Default
    /// false (each fork gets a unique identity).
    public var keepIdentity: Bool

    public init(
        sourcePath: String,
        destinationPath: String,
        fromSnapshot: String? = nil,
        autoStart: Bool = false,
        waitIP: Bool = false,
        waitSSH: Bool = false,
        sshUser: String? = nil,
        sshKey: String? = nil,
        waitTimeout: TimeInterval = 90,
        keepIdentity: Bool = false
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.fromSnapshot = fromSnapshot
        self.autoStart = autoStart
        self.waitIP = waitIP
        self.waitSSH = waitSSH
        self.sshUser = sshUser
        self.sshKey = sshKey
        self.waitTimeout = waitTimeout
        self.keepIdentity = keepIdentity
    }
}

public func runFork(options: ForkOptions, executable: String) throws -> ForkOutcome {
    let src = URL(fileURLWithPath: options.sourcePath, isDirectory: true)
    let dst = URL(fileURLWithPath: options.destinationPath, isDirectory: true)
    guard FileManager.default.fileExists(atPath: src.path(percentEncoded: false)) else {
        throw VM4AError.notFound("Source VM: \(src.path())")
    }
    _ = try cloneDirectory(from: src, to: dst)
    let model = try loadModel(rootPath: dst)
    clearPID(at: model.runPIDURL)
    try? FileManager.default.removeItem(at: model.runLogURL)
    if !options.keepIdentity {
        try reidentifyVM(model: model)
    }

    var pid: Int32?
    var ip: String?

    if options.autoStart {
        pid = try startVMWorker(
            executable: executable,
            vmPath: dst.path(),
            restoreStateAt: options.fromSnapshot.map { normalizePath($0) }
        )
        if options.waitIP || options.waitSSH {
            ip = waitForVMIP(model: model, timeout: options.waitTimeout)
        }
        if options.waitSSH, let ip {
            let user = options.sshUser ?? defaultSSHUser(for: model.config.type)
            let sshOpts = SSHOptions(user: user, keyPath: options.sshKey)
            _ = waitForSSHReady(host: ip, options: sshOpts, timeout: options.waitTimeout)
        }
    }

    return ForkOutcome(
        path: dst.path(),
        name: model.config.name,
        started: options.autoStart,
        pid: pid,
        ip: ip
    )
}

// MARK: - Reset

public struct ResetOptions: Sendable {
    public var vmPath: String
    public var fromSnapshot: String
    public var waitIP: Bool
    public var stopTimeout: TimeInterval
    public var waitTimeout: TimeInterval

    public init(
        vmPath: String,
        fromSnapshot: String,
        waitIP: Bool = false,
        stopTimeout: TimeInterval = 20,
        waitTimeout: TimeInterval = 60
    ) {
        self.vmPath = vmPath
        self.fromSnapshot = fromSnapshot
        self.waitIP = waitIP
        self.stopTimeout = stopTimeout
        self.waitTimeout = waitTimeout
    }
}

public struct ResetOutcome: Codable, Sendable {
    public let path: String
    public let restored: String
    public let pid: Int32?
    public let ip: String?

    public init(path: String, restored: String, pid: Int32?, ip: String?) {
        self.path = path
        self.restored = restored
        self.pid = pid
        self.ip = ip
    }
}

public func runReset(options: ResetOptions, executable: String) throws -> ResetOutcome {
    let rootURL = URL(fileURLWithPath: options.vmPath, isDirectory: true)
    let model = try loadModel(rootPath: rootURL)

    if let pid = readPID(from: model.runPIDURL), isProcessRunning(pid: pid) {
        _ = kill(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(options.stopTimeout)
        while Date() < deadline {
            if !isProcessRunning(pid: pid) { break }
            Thread.sleep(forTimeInterval: 0.25)
        }
        if isProcessRunning(pid: pid) {
            _ = kill(pid, SIGKILL)
            Thread.sleep(forTimeInterval: 0.5)
        }
        clearPID(at: model.runPIDURL)
    }

    let snapshotPath = normalizePath(options.fromSnapshot)
    guard FileManager.default.fileExists(atPath: snapshotPath) else {
        throw VM4AError.notFound("Snapshot file: \(snapshotPath)")
    }

    let pid = try startVMWorker(
        executable: executable,
        vmPath: options.vmPath,
        restoreStateAt: snapshotPath
    )
    var ip: String?
    if options.waitIP {
        ip = waitForVMIP(model: model, timeout: options.waitTimeout)
    }

    return ResetOutcome(path: rootURL.path(), restored: snapshotPath, pid: pid, ip: ip)
}
