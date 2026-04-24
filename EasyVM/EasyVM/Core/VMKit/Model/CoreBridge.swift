//
//  CoreBridge.swift
//  EasyVM
//

import Foundation
import EasyVMCore

#if arch(arm64)
extension VMConfigModel {
    func toCore() -> EasyVMCore.VMConfigModel {
        EasyVMCore.VMConfigModel(
            schemaVersion: schemaVersion,
            type: type.toCore(),
            name: name,
            remark: remark,
            cpu: .init(count: cpu.count),
            memory: .init(size: memory.size),
            graphicsDevices: graphicsDevices.map { .init(type: $0.type.toCore(), width: $0.width, height: $0.height, pixelsPerInch: $0.pixelsPerInch) },
            storageDevices: storageDevices.map { .init(type: $0.type.toCore(), size: $0.size, imagePath: $0.imagePath) },
            networkDevices: networkDevices.map { .init(type: $0.type.toCore(), identifier: $0.identifier) },
            pointingDevices: pointingDevices.map { .init(type: $0.type.toCore()) },
            audioDevices: audioDevices.map { .init(type: $0.type.toCore()) },
            directorySharingDevices: directorySharingDevices.map {
                .init(
                    tag: $0.tag,
                    items: $0.items.map {
                        .init(name: $0.name, path: $0.path, readOnly: $0.readOnly)
                    }
                )
            },
            rosetta: rosetta.map { .init(enabled: $0.enabled, tag: $0.tag) }
        )
    }

    static func fromCore(_ value: EasyVMCore.VMConfigModel) -> Self {
        VMConfigModel(
            schemaVersion: value.schemaVersion,
            type: .fromCore(value.type),
            name: value.name,
            remark: value.remark,
            cpu: .init(count: value.cpu.count),
            memory: .init(size: value.memory.size),
            graphicsDevices: value.graphicsDevices.map {
                .init(type: .fromCore($0.type), width: $0.width, height: $0.height, pixelsPerInch: $0.pixelsPerInch)
            },
            storageDevices: value.storageDevices.map {
                .init(type: .fromCore($0.type), size: $0.size, imagePath: $0.imagePath)
            },
            networkDevices: value.networkDevices.map { .init(type: .fromCore($0.type), identifier: $0.identifier) },
            pointingDevices: value.pointingDevices.map { .init(type: .fromCore($0.type)) },
            audioDevices: value.audioDevices.map { .init(type: .fromCore($0.type)) },
            directorySharingDevices: value.directorySharingDevices.map {
                .init(
                    tag: $0.tag,
                    items: $0.items.map {
                        .init(name: $0.name, path: $0.path, readOnly: $0.readOnly)
                    }
                )
            },
            rosetta: value.rosetta.map { .init(enabled: $0.enabled, tag: $0.tag) }
        )
    }
}

extension VMStateModel {
    func toCore() -> EasyVMCore.VMStateModel {
        .init(imagePath: imagePath)
    }

    static func fromCore(_ value: EasyVMCore.VMStateModel) -> Self {
        .init(imagePath: value.imagePath)
    }
}

extension VMModel {
    func toCoreModel() -> EasyVMCore.VMModel {
        .init(rootPath: rootPath, config: config.toCore(), state: state.toCore())
    }
}

extension VMOSType {
    func toCore() -> EasyVMCore.VMOSType {
        switch self {
        case .macOS:
            return .macOS
        case .linux:
            return .linux
        }
    }

    static func fromCore(_ value: EasyVMCore.VMOSType) -> VMOSType {
        switch value {
        case .macOS:
            return .macOS
        case .linux:
            return .linux
        }
    }
}

extension VMModelFieldGraphicDevice.DeviceType {
    func toCore() -> EasyVMCore.VMModelFieldGraphicDevice.DeviceType {
        switch self {
        case .Mac:
            return .Mac
        case .Virtio:
            return .Virtio
        }
    }

    static func fromCore(_ value: EasyVMCore.VMModelFieldGraphicDevice.DeviceType) -> Self {
        switch value {
        case .Mac:
            return .Mac
        case .Virtio:
            return .Virtio
        }
    }
}

extension VMModelFieldStorageDevice.DeviceType {
    func toCore() -> EasyVMCore.VMModelFieldStorageDevice.DeviceType {
        switch self {
        case .Block:
            return .Block
        case .USB:
            return .USB
        }
    }

    static func fromCore(_ value: EasyVMCore.VMModelFieldStorageDevice.DeviceType) -> Self {
        switch value {
        case .Block:
            return .Block
        case .USB:
            return .USB
        }
    }
}

extension VMModelFieldNetworkDevice.DeviceType {
    func toCore() -> EasyVMCore.VMModelFieldNetworkDevice.DeviceType {
        switch self {
        case .NAT:
            return .NAT
        case .Bridged:
            return .Bridged
        case .FileHandle:
            return .FileHandle
        }
    }

    static func fromCore(_ value: EasyVMCore.VMModelFieldNetworkDevice.DeviceType) -> Self {
        switch value {
        case .NAT:
            return .NAT
        case .Bridged:
            return .Bridged
        case .FileHandle:
            return .FileHandle
        }
    }
}

extension VMModelFieldPointingDevice.DeviceType {
    func toCore() -> EasyVMCore.VMModelFieldPointingDevice.DeviceType {
        switch self {
        case .USBScreenCoordinatePointing:
            return .USBScreenCoordinatePointing
        case .MacTrackpad:
            return .MacTrackpad
        }
    }

    static func fromCore(_ value: EasyVMCore.VMModelFieldPointingDevice.DeviceType) -> Self {
        switch value {
        case .USBScreenCoordinatePointing:
            return .USBScreenCoordinatePointing
        case .MacTrackpad:
            return .MacTrackpad
        }
    }
}

extension VMModelFieldAudioDevice.DeviceType {
    func toCore() -> EasyVMCore.VMModelFieldAudioDevice.DeviceType {
        switch self {
        case .InputOutputStream:
            return .InputOutputStream
        case .InputStream:
            return .InputStream
        case .OutputStream:
            return .OutputStream
        }
    }

    static func fromCore(_ value: EasyVMCore.VMModelFieldAudioDevice.DeviceType) -> Self {
        switch value {
        case .InputOutputStream:
            return .InputOutputStream
        case .InputStream:
            return .InputStream
        case .OutputStream:
            return .OutputStream
        }
    }
}
#endif
