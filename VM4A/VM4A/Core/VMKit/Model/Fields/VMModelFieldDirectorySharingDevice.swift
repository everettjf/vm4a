//
//  VMModelFieldDirectorySharingDevice.swift
//  VM4A
//
//  Created by everettjf on 2022/10/5.
//

import Foundation

#if arch(arm64)
struct VMModelFieldDirectorySharingDevice : Decodable, Encodable, CustomStringConvertible {
    struct SharingItem:  Decodable, Encodable, CustomStringConvertible {
        let name: String
        let path: URL
        let readOnly: Bool
        
        var description: String {
            "\(name)(\(readOnly ? "ReadOnly" : "ReadWrite")) \(path.path(percentEncoded: false))"
        }
    }
    
    let tag: String
    let items: [SharingItem]
    
    static let autoMoundTag = "AutoMount"
    
    var description: String {
        "Tag: \(tag) Directories: \(items.map({$0.description}).joined(separator: " , "))"
    }
    
}


#endif
