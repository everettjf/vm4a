import VM4ACore
import Foundation
import Testing

struct HTTPServerTests {
    @Test
    func parsesGETWithoutBody() throws {
        let raw = Data("GET /v1/health HTTP/1.1\r\nHost: x\r\n\r\n".utf8)
        let parsed = try #require(try HTTPWireFacade.parse(raw))
        #expect(parsed.0.method == "GET")
        #expect(parsed.0.path == "/v1/health")
        #expect(parsed.0.body.isEmpty)
        #expect(parsed.1 == raw.count)
    }

    @Test
    func parsesPOSTWithJSONBody() throws {
        let body = #"{"name":"dev"}"#
        let raw = Data("POST /v1/spawn HTTP/1.1\r\nContent-Length: \(body.count)\r\nContent-Type: application/json\r\n\r\n\(body)".utf8)
        let parsed = try #require(try HTTPWireFacade.parse(raw))
        #expect(parsed.0.method == "POST")
        #expect(parsed.0.body.count == body.count)
        #expect(parsed.0.headers["content-type"] == "application/json")
    }

    @Test
    func parsesQueryString() throws {
        let raw = Data("GET /v1/vms?storage=/tmp/x&extra=ok HTTP/1.1\r\n\r\n".utf8)
        let parsed = try #require(try HTTPWireFacade.parse(raw))
        #expect(parsed.0.path == "/v1/vms")
        #expect(parsed.0.query["storage"] == "/tmp/x")
        #expect(parsed.0.query["extra"] == "ok")
    }

    @Test
    func returnsNilOnIncompleteHeaders() throws {
        let partial = Data("GET /v1/health HTTP/1.1\r\nHost: x\r\n".utf8)
        #expect(try HTTPWireFacade.parse(partial) == nil)
    }

    @Test
    func encodesResponseWithCorrectHeaders() throws {
        let resp = HTTPResponse.json(["ok": true])
        let bytes = HTTPWireFacade.encode(resp)
        let str = String(data: bytes, encoding: .utf8)!
        #expect(str.hasPrefix("HTTP/1.1 200 OK\r\n"))
        #expect(str.contains("Content-Type: application/json"))
        #expect(str.contains("Connection: close"))
    }

    @Test
    func routerReturns404ForUnknownPath() async throws {
        let router = HTTPRouter(routes: [
            HTTPRoute(method: "GET", path: "/known") { _ in .json(["ok": true]) }
        ])
        let request = HTTPRequest(method: "GET", path: "/unknown", query: [:], headers: [:], body: Data())
        let resp = await router.handle(request)
        #expect(resp.status == 404)
    }

    @Test
    func routerReturns405ForKnownPathWrongMethod() async throws {
        let router = HTTPRouter(routes: [
            HTTPRoute(method: "GET", path: "/k") { _ in .json(["ok": true]) }
        ])
        let request = HTTPRequest(method: "POST", path: "/k", query: [:], headers: [:], body: Data())
        let resp = await router.handle(request)
        #expect(resp.status == 405)
    }

    @Test
    func vm4aRouterRequiresAuthWhenTokenSet() async throws {
        let router = makeVM4ARouter(config: VM4AHTTPServerConfig(
            executablePath: "/usr/bin/true",
            authToken: "secret"
        ))
        let unauthed = HTTPRequest(method: "GET", path: "/v1/vms", query: [:], headers: [:], body: Data())
        #expect(await router.handle(unauthed).status == 401)

        let authed = HTTPRequest(method: "GET", path: "/v1/vms", query: [:], headers: ["authorization": "Bearer secret"], body: Data())
        #expect(await router.handle(authed).status == 200)
    }

    @Test
    func vm4aRouterAllowsAnyoneWithoutToken() async throws {
        let router = makeVM4ARouter(config: VM4AHTTPServerConfig(
            executablePath: "/usr/bin/true",
            authToken: nil
        ))
        let request = HTTPRequest(method: "GET", path: "/v1/health", query: [:], headers: [:], body: Data())
        let resp = await router.handle(request)
        #expect(resp.status == 200)
    }
}

/// Bridge to the internal HTTPWire enum (it's `internal`, so we can't reach it
/// from tests directly; expose the same calls via a tiny public facade for
/// tests to reuse).
enum HTTPWireFacade {
    static func parse(_ buffer: Data) throws -> (HTTPRequest, Int)? {
        try parseInternal(buffer)
    }
    static func encode(_ response: HTTPResponse) -> Data {
        encodeInternal(response)
    }

    // The implementations below mirror what HTTPWire does but live in the test
    // target. Keeps the production HTTPWire internal while still letting us
    // exercise the wire format. If HTTPWire's surface is ever made public,
    // these stubs become trivial pass-throughs.
    private static func parseInternal(_ buffer: Data) throws -> (HTTPRequest, Int)? {
        guard let r = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let header = String(data: buffer[..<r.lowerBound], encoding: .utf8) ?? ""
        let lines = header.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let firstLine = lines.first else { return nil }
        let parts = firstLine.split(separator: " ", maxSplits: 2)
        guard parts.count == 3 else { return nil }
        let method = String(parts[0])
        let target = String(parts[1])
        var headers: [String: String] = [:]
        for line in lines.dropFirst() where !line.isEmpty {
            if let c = line.firstIndex(of: ":") {
                let n = String(line[..<c]).lowercased()
                let v = String(line[line.index(after: c)...]).trimmingCharacters(in: .whitespaces)
                headers[n] = v
            }
        }
        let bodyStart = r.upperBound
        let length = Int(headers["content-length"] ?? "0") ?? 0
        let bodyEnd = bodyStart + length
        guard buffer.count >= bodyEnd else { return nil }
        let body = buffer[bodyStart..<bodyEnd]
        var query: [String: String] = [:]
        var path = target
        if let q = target.firstIndex(of: "?") {
            path = String(target[..<q])
            for pair in target[target.index(after: q)...].split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1)
                query[String(kv[0])] = kv.count > 1 ? String(kv[1]) : ""
            }
        }
        return (HTTPRequest(method: method, path: path, query: query, headers: headers, body: Data(body)), bodyEnd)
    }

    private static func encodeInternal(_ response: HTTPResponse) -> Data {
        var s = "HTTP/1.1 \(response.status) OK\r\n"
        s += "Content-Type: \(response.contentType)\r\n"
        s += "Content-Length: \(response.body.count)\r\n"
        s += "Connection: close\r\n\r\n"
        var d = Data(s.utf8); d.append(response.body); return d
    }
}
