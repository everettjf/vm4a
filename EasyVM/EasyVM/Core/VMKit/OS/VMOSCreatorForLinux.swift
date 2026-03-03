//
//  VMOSCreatorForLinux.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/4.
//

import Foundation
import Virtualization
import EasyVMCore


#if arch(arm64)
class VMOSCreatorForLinux: VMOSCreator {
    
    
    private var virtualMachine: VZVirtualMachine!

    
    func create(model: VMModel, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async -> VMOSResultVoid {
        
        do {
            progress(.progress(0.1))
            
            // create bundle
            let rootPath = model.getRootPath()
            progress(.info("Begin create bundle path : \(rootPath.path(percentEncoded: false))"))
            try await VMOSCreatorUtil.createVMBundle(path: rootPath)
            progress(.info("Succeed create bundle path"))
            
            // write json
            progress(.info("Begin write config : \(model.configURL.path(percentEncoded: false))"))
            try await model.config.writeConfigToFile(path: model.configURL)
            try await model.state.writeStateToFile(path: model.stateURL)
            progress(.info("Succeed write config"))
            
            progress(.progress(0.3))

            // setup
            progress(.info("Begin setup virtual machine"))
            try await setupVirtualMachine(model: model, progress: progress)
            progress(.info("Succeed setup virtual machine"))
            
            progress(.progress(1.0))
            
        } catch {
            progress(.error("\(error)"))
            return .failure("\(error)")
        }
        
        progress(.info("Succeed created virtual machine"))
        return .success
    }
    
    
    private func setupVirtualMachine(model: VMModel, progress: @escaping (VMOSCreatorProgressInfo) -> Void) async throws {
        return try await withCheckedThrowingContinuation({ continuation in
            do {
                let machineIdentifier = VZGenericMachineIdentifier()
                try machineIdentifier.dataRepresentation.write(to: model.machineIdentifierURL)
                _ = try VZEFIVariableStore(creatingVariableStoreAt: model.efiVariableStoreURL)
            } catch {
                continuation.resume(throwing: error)
                return
            }
            progress(.info("- Platform OK"))

            do {
                let configuration = try EasyVMCore.createConfiguration(model: model.toCoreModel())
                virtualMachine = VZVirtualMachine(configuration: configuration)
            } catch {
                continuation.resume(throwing: error)
                return
            }
            progress(.info("Succeed create virtual machine instance"))

            continuation.resume(returning: ())
        })
    }
}

#endif
