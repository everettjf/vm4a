import Foundation
@preconcurrency import Virtualization

// MARK: - macOS guest install (Apple's VZMacOSInstaller)

public struct MacOSInstallProgress: Sendable {
    public enum Stage: String, Sendable {
        case loadingImage
        case validating
        case settingUpPlatform
        case installing
        case finalising
    }
    public let stage: Stage
    public let message: String
    /// 0.0 to 1.0 during `.installing`, nil otherwise.
    public let fraction: Double?
}

/// Run a full macOS guest install from an `.ipsw` into the bundle at
/// `model.rootPath`. Caller is responsible for having created the bundle
/// directory + writing config.json/state.json (createBundle does this).
///
/// This populates `HardwareModel`, `MachineIdentifier`, `AuxiliaryStorage`,
/// and `Disk.img` so the bundle becomes bootable. After this returns, the
/// VM boots into Apple's Setup Assistant on first run; that step is not
/// scriptable from Apple's public APIs and requires either the GUI app's
/// framebuffer or the host running the VM with a console attached. Once
/// the user creates an account and enables Remote Login, the rest of the
/// vm4a CLI / MCP / HTTP / SDK works on the bundle just like a Linux one.
public func runMacOSInstall(
    model: VMModel,
    ipswPath: URL,
    progress: (@Sendable (MacOSInstallProgress) -> Void)? = nil
) async throws {
    progress?(.init(stage: .loadingImage, message: "Loading restore image", fraction: nil))
    let restoreImage = try await loadRestoreImage(ipswURL: ipswPath)

    progress?(.init(stage: .validating, message: "Validating image vs host", fraction: nil))
    let requirements = try resolveConfigurationRequirements(restoreImage: restoreImage)

    progress?(.init(stage: .settingUpPlatform, message: "Writing HardwareModel + AuxiliaryStorage", fraction: nil))
    try ensureDiskImagesExist(model: model)
    try writeMacOSPlatformFiles(model: model, requirements: requirements)

    progress?(.init(stage: .installing, message: "Running VZMacOSInstaller", fraction: 0))
    let configuration = try createConfiguration(model: model)
    try configuration.validate()

    try await runInstallation(
        configuration: configuration,
        ipswURL: ipswPath,
        progress: progress
    )

    progress?(.init(stage: .finalising, message: "Install complete", fraction: 1.0))
}

private func loadRestoreImage(ipswURL: URL) async throws -> VZMacOSRestoreImage {
    try await withCheckedThrowingContinuation { continuation in
        VZMacOSRestoreImage.load(from: ipswURL) { result in
            switch result {
            case .failure(let err): continuation.resume(throwing: err)
            case .success(let image): continuation.resume(returning: image)
            }
        }
    }
}

private func resolveConfigurationRequirements(restoreImage: VZMacOSRestoreImage) throws -> VZMacOSConfigurationRequirements {
    guard let configuration = restoreImage.mostFeaturefulSupportedConfiguration else {
        throw VM4AError.hostUnsupported("Restore image has no supported configuration on this host")
    }
    if !configuration.hardwareModel.isSupported {
        throw VM4AError.hostUnsupported("Restore image's hardware model isn't supported on this host")
    }
    return configuration
}

private func writeMacOSPlatformFiles(
    model: VMModel,
    requirements: VZMacOSConfigurationRequirements
) throws {
    // Validate that the bundle's CPU + memory meet the image's minimums.
    if model.config.cpu.count < requirements.minimumSupportedCPUCount {
        throw VM4AError.message(
            "cpu.count (\(model.config.cpu.count)) is below the IPSW's minimum (\(requirements.minimumSupportedCPUCount))"
        )
    }
    if model.config.memory.size < requirements.minimumSupportedMemorySize {
        throw VM4AError.message(
            "memory.size (\(model.config.memory.size)) is below the IPSW's minimum (\(requirements.minimumSupportedMemorySize))"
        )
    }

    // HardwareModel + AuxiliaryStorage are derived from the restore image.
    try requirements.hardwareModel.dataRepresentation.write(to: model.hardwareModelURL)
    let machineID = VZMacMachineIdentifier()
    try machineID.dataRepresentation.write(to: model.machineIdentifierURL)
    _ = try VZMacAuxiliaryStorage(
        creatingStorageAt: model.auxiliaryStorageURL,
        hardwareModel: requirements.hardwareModel,
        options: []
    )
}

/// Holder for VZ install observation. VZ APIs are main-actor-bound for some
/// state, but install() and progress observation just need to live on a
/// stable run-loop. We use the main queue and bridge into async via
/// withCheckedThrowingContinuation. Mirror of the GUI app's flow.
private final class InstallationBox: @unchecked Sendable {
    var observer: NSKeyValueObservation?
    var virtualMachine: VZVirtualMachine?
}

private func runInstallation(
    configuration: VZVirtualMachineConfiguration,
    ipswURL: URL,
    progress: (@Sendable (MacOSInstallProgress) -> Void)?
) async throws {
    let box = InstallationBox()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        DispatchQueue.main.async {
            let vm = VZVirtualMachine(configuration: configuration)
            box.virtualMachine = vm
            let installer = VZMacOSInstaller(virtualMachine: vm, restoringFromImageAt: ipswURL)

            box.observer = installer.progress.observe(\.fractionCompleted, options: [.initial, .new]) { _, change in
                if let value = change.newValue {
                    progress?(.init(stage: .installing, message: "Installing macOS", fraction: value))
                }
            }

            installer.install { result in
                box.observer?.invalidate()
                box.observer = nil
                switch result {
                case .failure(let err): continuation.resume(throwing: err)
                case .success: continuation.resume(returning: ())
                }
            }
        }
    }
}
