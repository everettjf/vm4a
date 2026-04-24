import Foundation

public struct DHCPLease: Sendable, Equatable {
    public let ipAddress: String
    public let hardwareAddress: String
    public let name: String?

    public init(ipAddress: String, hardwareAddress: String, name: String?) {
        self.ipAddress = ipAddress
        self.hardwareAddress = hardwareAddress
        self.name = name
    }
}

public func parseDHCPLeases(_ contents: String) -> [DHCPLease] {
    var leases: [DHCPLease] = []
    var current: (ip: String?, hw: String?, name: String?) = (nil, nil, nil)
    var inBlock = false

    for rawLine in contents.split(whereSeparator: \.isNewline) {
        let line = rawLine.trimmingCharacters(in: .whitespaces)
        if line == "{" {
            inBlock = true
            current = (nil, nil, nil)
        } else if line == "}" {
            if inBlock, let ip = current.ip, let hw = current.hw {
                leases.append(.init(ipAddress: ip, hardwareAddress: normalizeMAC(hw), name: current.name))
            }
            inBlock = false
        } else if inBlock, let eq = line.firstIndex(of: "=") {
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            switch key {
            case "ip_address": current.ip = value
            case "hw_address":
                if let colon = value.firstIndex(of: ",") {
                    current.hw = String(value[value.index(after: colon)...])
                } else {
                    current.hw = value
                }
            case "name": current.name = value
            default: break
            }
        }
    }
    return leases
}

public func normalizeMAC(_ raw: String) -> String {
    raw.split(separator: ":").map { part -> String in
        let s = String(part).uppercased()
        return s.count < 2 ? String(repeating: "0", count: 2 - s.count) + s : s
    }.joined(separator: ":")
}

public func readDHCPLeasesFile() -> [DHCPLease] {
    let candidates = [
        "/var/db/dhcpd_leases",
        "/private/var/db/dhcpd_leases",
    ]
    for path in candidates {
        if let contents = try? String(contentsOfFile: path, encoding: .utf8) {
            return parseDHCPLeases(contents)
        }
    }
    return []
}

public func findLeasesForBundle(_ model: VMModel) -> [DHCPLease] {
    let leases = readDHCPLeasesFile()
    let needle = model.config.name
    let matches = leases.filter { $0.name == needle }
    if !matches.isEmpty { return matches }
    return leases
}
