//
//  VMOSRunnerForLinux.swift
//  EasyVM
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization
import EasyVMCore

#if arch(arm64)
class VMOSRunnerForLinux : VMOSRunner {
    
    
    func createConfiguration(model: VMModel) -> VMOSResult<VZVirtualMachineConfiguration, String> {
        do {
            let configuration = try EasyVMCore.createConfiguration(model: model.toCoreModel())
            return .success(configuration)
        } catch {
            return .failure("\(error)")
        }
    }
}

#endif
