//
//  VMOSRunnerForMacOS.swift
//  VM4A
//
//  Created by everettjf on 2022/10/5.
//

import Foundation
import Virtualization
import VM4ACore

#if arch(arm64)

class VMOSRunnerForMacOS : VMOSRunner {
    
    
    func createConfiguration(model: VMModel) -> VMOSResult<VZVirtualMachineConfiguration, String> {
        do {
            let configuration = try VM4ACore.createConfiguration(model: model.toCoreModel())
            return .success(configuration)
        } catch {
            return .failure("\(error)")
        }
    }

}

#endif
