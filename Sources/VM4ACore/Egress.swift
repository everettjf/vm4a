import Foundation

// MARK: - Egress allow-list (Linux guests, nftables)
//
// A best-effort outbound firewall applied *inside* a Linux guest over SSH.
// VZ's NAT attachment has no host-side domain filter, so the policy is
// enforced in-guest with nftables: loopback, established/related, and DNS are
// always allowed; everything else outbound is dropped except the resolved
// addresses of an explicit domain allow-list. Persisted to <bundle>/egress.json
// so it can be re-applied with `vm4a network guard`.

public struct EgressPolicy: Codable, Sendable {
    public let allowDomains: [String]

    public init(allowDomains: [String]) {
        self.allowDomains = allowDomains
    }
}

extension VMModel {
    public var egressPolicyURL: URL { rootPath.appending(path: "egress.json") }
}

public func writeEgressPolicy(_ policy: EgressPolicy, to url: URL) throws {
    try writeJSON(policy, to: url)
}

public func readEgressPolicy(at url: URL) -> EgressPolicy? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(EgressPolicy.self, from: data)
}

/// Accept either a JSON array of strings or a comma-separated string for an
/// allow-domains field, returning a trimmed, non-empty list.
public func parseAllowDomains(_ value: JSONValue?) -> [String] {
    guard let value else { return [] }
    if let arr = value.arrayValue {
        return arr.compactMap { $0.stringValue }
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    if let s = value.stringValue {
        return s.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    return []
}

/// Validate a domain for safe interpolation into a shell loop. Conservative:
/// letters, digits, dots and hyphens only (no wildcards, no whitespace).
public func isValidEgressDomain(_ domain: String) -> Bool {
    guard !domain.isEmpty, domain.count <= 253 else { return false }
    return domain.allSatisfy { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
}

/// Build the nftables provisioning script. Pure (no I/O) so the rule shape can
/// be unit-tested. Assumes every domain has already passed
/// `isValidEgressDomain`; each is still shell-quoted defensively.
public func egressNftablesScript(allowDomains: [String]) -> String {
    let domainList = allowDomains.map(shellSingleQuote).joined(separator: " ")
    return """
    set -e
    if ! command -v nft >/dev/null 2>&1; then
      echo "vm4a: nft (nftables) not found in guest; cannot apply egress policy" >&2
      exit 127
    fi
    nft delete table inet vm4a_egress 2>/dev/null || true
    nft add table inet vm4a_egress
    nft add chain inet vm4a_egress out '{ type filter hook output priority 0 ; policy drop ; }'
    nft add rule inet vm4a_egress out oifname lo accept
    nft add rule inet vm4a_egress out ct state established,related accept
    nft add rule inet vm4a_egress out udp dport 53 accept
    nft add rule inet vm4a_egress out tcp dport 53 accept
    for d in \(domainList); do
      for ip in $(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u); do
        nft add rule inet vm4a_egress out ip daddr "$ip" accept
      done
    done
    echo "vm4a: egress policy applied for: \(allowDomains.joined(separator: " "))"
    """
}

/// Apply the egress allow-list inside a reachable Linux guest over SSH.
/// Requires `nft` in the guest and a root-capable SSH user.
@discardableResult
public func applyEgressPolicy(
    host: String,
    sshOptions: SSHOptions,
    allowDomains: [String],
    timeout: TimeInterval = 60
) throws -> ExecResult {
    let invalid = allowDomains.filter { !isValidEgressDomain($0) }
    guard invalid.isEmpty else {
        throw VM4AError.message("Invalid domain(s) for --allow-domains: \(invalid.joined(separator: ", "))")
    }
    guard !allowDomains.isEmpty else {
        throw VM4AError.message("No domains given for egress policy")
    }
    let script = egressNftablesScript(allowDomains: allowDomains)
    let command = ["sh", "-c", shellSingleQuote(script)]
    return sshExec(host: host, options: sshOptions, command: command, timeout: timeout)
}
