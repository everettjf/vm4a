import VM4ACore
import Foundation
import Testing

struct RunCodeTests {
    @Test
    func interpreterMapping() throws {
        #expect(try interpreterForLanguage("python") == "python3")
        #expect(try interpreterForLanguage("PY") == "python3")
        #expect(try interpreterForLanguage("node") == "node")
        #expect(try interpreterForLanguage("javascript") == "node")
        #expect(try interpreterForLanguage("bash") == "bash")
        #expect(try interpreterForLanguage("ruby") == "ruby")
    }

    @Test
    func unknownLanguageThrows() {
        #expect(throws: (any Error).self) {
            _ = try interpreterForLanguage("brainfuck")
        }
    }

    @Test
    func shellSingleQuoteEscapesQuotes() {
        #expect(shellSingleQuote("abc") == "'abc'")
        // a'b -> 'a'\''b'
        #expect(shellSingleQuote("a'b") == "'a'\\''b'")
    }

    @Test
    func runCodeCommandWrapsAsSingleShellToken() {
        let cmd = runCodeRemoteCommand(interpreter: "python3", base64Code: "cHJpbnQoMSk=")
        #expect(cmd.count == 3)
        #expect(cmd[0] == "sh")
        #expect(cmd[1] == "-c")
        // The script token is single-quoted so the remote shell re-parses it
        // as exactly one argument.
        #expect(cmd[2].hasPrefix("'"))
        #expect(cmd[2].hasSuffix("'"))
        #expect(cmd[2].contains("base64 -d"))
        #expect(cmd[2].contains("python3"))
        #expect(cmd[2].contains("cHJpbnQoMSk="))
    }
}

struct EgressTests {
    @Test
    func domainValidation() {
        #expect(isValidEgressDomain("pypi.org"))
        #expect(isValidEgressDomain("files.pythonhosted.org"))
        #expect(isValidEgressDomain("a-b.example-1.com"))
        #expect(!isValidEgressDomain(""))
        #expect(!isValidEgressDomain("evil.com; rm -rf /"))
        #expect(!isValidEgressDomain("a b.com"))
        #expect(!isValidEgressDomain("foo/bar"))
    }

    @Test
    func nftablesScriptShape() {
        let script = egressNftablesScript(allowDomains: ["pypi.org", "github.com"])
        #expect(script.contains("nft add table inet vm4a_egress"))
        #expect(script.contains("policy drop"))
        #expect(script.contains("ct state established,related accept"))
        #expect(script.contains("dport 53 accept"))
        #expect(script.contains("'pypi.org'"))
        #expect(script.contains("'github.com'"))
        #expect(script.contains("getent ahostsv4"))
    }

    @Test
    func policyRoundTrips() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appending(path: "vm4a-egress-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appending(path: "egress.json")
        try writeEgressPolicy(EgressPolicy(allowDomains: ["a.com", "b.com"]), to: url)
        let loaded = readEgressPolicy(at: url)
        #expect(loaded?.allowDomains == ["a.com", "b.com"])
    }

    @Test
    func parseAllowDomainsAcceptsArrayAndCSV() {
        #expect(parseAllowDomains(.array([.string("a.com"), .string(" b.com ")])) == ["a.com", "b.com"])
        #expect(parseAllowDomains(.string("a.com, b.com ,")) == ["a.com", "b.com"])
        #expect(parseAllowDomains(nil) == [])
        #expect(parseAllowDomains(.string("")) == [])
    }
}

struct ClusterTests {
    @Test
    func leastLoaded() {
        #expect(leastLoadedIndex(counts: []) == nil)
        #expect(leastLoadedIndex(counts: [3, 1, 2]) == 1)
        #expect(leastLoadedIndex(counts: [0, 0, 0]) == 0)
        #expect(leastLoadedIndex(counts: [5, 5, 2]) == 2)
    }

    @Test
    func nodeJSONRoundTrips() throws {
        let node = ClusterNode(name: "studio", url: "http://10.0.0.5:7777/", token: "tok")
        let data = try JSONEncoder().encode(node)
        let decoded = try JSONDecoder().decode(ClusterNode.self, from: data)
        #expect(decoded == node)
        // Trailing slash trimmed by baseURL.
        #expect(decoded.baseURL == "http://10.0.0.5:7777")
    }
}

struct ExposeTests {
    @Test
    func exposeResultEncodes() throws {
        let r = ExposeResult(url: "http://192.168.64.7:8000", host: "192.168.64.7", port: 8000, scheme: "http")
        let data = try JSONEncoder().encode(r)
        let obj = try JSONDecoder().decode(ExposeResult.self, from: data)
        #expect(obj.url == "http://192.168.64.7:8000")
        #expect(obj.port == 8000)
    }
}
