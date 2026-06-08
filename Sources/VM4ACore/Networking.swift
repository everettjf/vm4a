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

/// Pick the lease(s) belonging to a bundle, given all host leases plus the
/// bundle's persisted NIC MACs and DHCP-visible name. Pure (no I/O) so it can
/// be unit-tested. Matching order:
///   1. By MAC — the lease's hardware/client id either equals the fixed MAC
///      (type-1 hw_address) or ends in it (DUID-LL / DUID-LLT carry the MAC as
///      their trailing 6 bytes).
///   2. By DHCP hostname (legacy bundles created before MACs were persisted).
///   3. Nothing — an identifiable bundle (has a MAC) with no lease yet returns
///      []; a MAC-less legacy bundle keeps the old "return everything" behavior
///      so its callers don't regress.
public func selectLeases(_ leases: [DHCPLease], macs: [String], name: String) -> [DHCPLease] {
    let normalizedMACs = macs.map(normalizeMAC)
    if !normalizedMACs.isEmpty {
        let byMAC = leases.filter { lease in
            normalizedMACs.contains { mac in
                lease.hardwareAddress == mac || lease.hardwareAddress.hasSuffix(":" + mac)
            }
        }
        if !byMAC.isEmpty { return byMAC }
    }

    let byName = leases.filter { $0.name == name }
    if !byName.isEmpty { return byName }

    return normalizedMACs.isEmpty ? leases : []
}

public func findLeasesForBundle(_ model: VMModel) -> [DHCPLease] {
    selectLeases(
        readDHCPLeasesFile(),
        macs: model.config.networkDevices.compactMap { $0.macAddress },
        name: model.config.name
    )
}
