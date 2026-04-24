//
//  VMModelFieldNetworkDevice.swift
//  EasyVM
//
//  Created by everettjf on 2022/8/24.
//

import Foundation

#if arch(arm64)
struct VMModelFieldNetworkDevice : Decodable, Encodable, CustomStringConvertible {
    
    enum DeviceType : String, CaseIterable, Identifiable, Decodable, Encodable {
        case NAT, Bridged, FileHandle
        var id: Self { self }
    }
    
    let type: DeviceType
    let identifier: String?

    init(type: DeviceType, identifier: String? = nil) {
        self.type = type
        self.identifier = identifier
    }

    var description: String {
        if let identifier {
            return "\(type)(\(identifier))"
        }
        return "\(type)"
    }

    enum CodingKeys: String, CodingKey { case type, identifier }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.type = try c.decode(DeviceType.self, forKey: .type)
        self.identifier = try c.decodeIfPresent(String.self, forKey: .identifier)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(identifier, forKey: .identifier)
    }

    static func `default`() -> VMModelFieldNetworkDevice {
        return VMModelFieldNetworkDevice(type: .NAT)
    }

}

#endif
