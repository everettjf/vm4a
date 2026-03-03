//
//  VMModel.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/6.
//

import Foundation
import SwiftUI
import EasyVMCore

#if arch(arm64)
struct VMConfigModel : Decodable, Encodable {
    let type: VMOSType
    let name: String
    let remark: String
    
    let cpu: VMModelFieldCPU
    let memory: VMModelFieldMemory
    let graphicsDevices: [VMModelFieldGraphicDevice]
    let storageDevices: [VMModelFieldStorageDevice]
    let networkDevices: [VMModelFieldNetworkDevice]
    let pointingDevices: [VMModelFieldPointingDevice]
    let audioDevices: [VMModelFieldAudioDevice]
    let directorySharingDevices: [VMModelFieldDirectorySharingDevice]
    
    static func createWithDefaultValues(osType: VMOSType) -> VMConfigModel {
        let defaultName = osType == .macOS ? "Easy Virtual Machine (macOS)" : "Easy Virtual Machine (Linux)"
        let coreConfig = EasyVMCore.VMConfigModel.defaults(
            osType: osType.toCore(),
            name: defaultName,
            cpu: nil,
            memoryBytes: nil,
            diskBytes: nil
        )
        return .fromCore(coreConfig)
    }
    
    
    func writeConfigToFile(path: URL) -> VMOSResultVoid {
        do {
            try EasyVMCore.writeJSON(toCore(), to: path)
            return .success
        } catch {
            return .failure("\(error)")
        }
    }
    
    func writeConfigToFile(path: URL) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let result = writeConfigToFile(path: path)
            if case let .failure(error) = result {
                continuation.resume(throwing: VMOSError.regularFailure(error))
                return
            }
            continuation.resume(returning: ())
        })
    }
}


struct VMStateModel : Decodable, Encodable  {
    let imagePath: URL
    
    
    func writeStateToFile(path: URL) -> VMOSResultVoid {
        do {
            try EasyVMCore.writeJSON(toCore(), to: path)
            return .success
        } catch {
            return .failure("\(error)")
        }
    }
    
    func writeStateToFile(path: URL) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            let result = writeStateToFile(path: path)
            if case let .failure(error) = result {
                continuation.resume(throwing: VMOSError.regularFailure(error))
                return
            }
            continuation.resume(returning: ())
        })
    }
}

struct VMModel: Identifiable {
    let id = UUID()
    let rootPath: URL
    let state: VMStateModel
    let config: VMConfigModel
    
    func getRootPath() -> URL {
        return rootPath
    }
    
    var auxiliaryStorageURL: URL {
        rootPath.appending(path: "AuxiliaryStorage")
    }
    var machineIdentifierURL: URL {
        rootPath.appending(path: "MachineIdentifier")
    }
    var hardwareModelURL: URL {
        rootPath.appending(path: "HardwareModel")
    }
    var efiVariableStoreURL : URL {
        rootPath.appending(path: "NVRAM")
    }
    
    var stateURL: URL {
        Self.getStateURL(rootPath: rootPath)
    }
    static func getStateURL(rootPath: URL) -> URL {
        rootPath.appending(path: "state.json")
    }
    var configURL: URL {
        Self.getConfigURL(rootPath: rootPath)
    }

    static func getConfigURL(rootPath: URL) -> URL {
        rootPath.appending(path: "config.json")
    }
    
    var displayDiskInfo: String {
        config.storageDevices.map({$0.shortDescription}).joined(separator: " ")
    }
    
    var displayMemoryInfo: String {
        "\(config.memory)"
    }
    
    var displayAttributeInfo: String {
        var info = ""
        info += "Graphics : " + config.graphicsDevices.map({$0.description}).joined(separator: " , ")
        info += " | "
        info += "Network : " + config.networkDevices.map({$0.description}).joined(separator: " , ")
        info += " | "
        info += "Audio : " + config.audioDevices.map({$0.description}).joined(separator: " , ")
        return info
    }
    
    static func loadConfigFromFile(rootPath: URL) -> VMOSResult<VMModel, String> {
        do {
            let coreModel = try EasyVMCore.loadModel(rootPath: rootPath)
            let model = VMModel(rootPath: rootPath, state: .fromCore(coreModel.state), config: .fromCore(coreModel.config))
            return .success(model)
        } catch {
            return .failure("\(error)")
        }
    }
    

}

#endif
