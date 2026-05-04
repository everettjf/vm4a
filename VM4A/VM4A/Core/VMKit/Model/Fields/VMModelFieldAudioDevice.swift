//
//  VMModelFieldAudioDevice.swift
//  VM4A
//
//  Created by everettjf on 2022/8/24.
//

import Foundation

#if arch(arm64)
struct VMModelFieldAudioDevice: Decodable, Encodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case InputOutputStream, InputStream, OutputStream
        var id: Self { self }
    }
    let type: DeviceType
    
    var description: String {
        return "\(type)"
    }
    
    static func `default`() -> VMModelFieldAudioDevice {
        return VMModelFieldAudioDevice(type:.InputOutputStream)
    }
    
}

#endif
