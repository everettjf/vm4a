import CryptoKit
import Foundation

public enum OCIMediaType {
    public static let manifestV1 = "application/vnd.oci.image.manifest.v1+json"
    public static let imageConfigV1 = "application/vnd.oci.image.config.v1+json"
    public static let vm4aConfigV1 = "application/vnd.vm4a.config.v1+json"
    public static let vm4aBundleV1 = "application/vnd.vm4a.bundle.v1.tar+gzip"
}

public struct OCIReference: Sendable, Equatable {
    public let registry: String
    public let repository: String
    public let tag: String

    public init(registry: String, repository: String, tag: String) {
        self.registry = registry
        self.repository = repository
        self.tag = tag
    }

    public static func parse(_ raw: String) throws -> OCIReference {
        let image: String
        let tag: String
        if let colon = raw.lastIndex(of: ":"),
           raw[raw.index(after: colon)...].contains("/") == false,
           raw.lastIndex(of: "/").map({ $0 < colon }) ?? true {
            image = String(raw[..<colon])
            tag = String(raw[raw.index(after: colon)...])
        } else {
            image = raw
            tag = "latest"
        }
        guard let firstSlash = image.firstIndex(of: "/") else {
            throw VM4AError.message("Registry reference must be fully qualified: <host>/<repo>[:<tag>] (got '\(raw)')")
        }
        let host = String(image[..<firstSlash])
        guard host.contains(".") || host.contains(":") || host == "localhost" else {
            throw VM4AError.message("Registry reference must start with a host containing '.' (e.g. ghcr.io, docker.io). Got '\(raw)'.")
        }
        let repo = String(image[image.index(after: firstSlash)...])
        guard !repo.isEmpty, !tag.isEmpty else {
            throw VM4AError.message("Malformed reference '\(raw)'")
        }
        return .init(registry: host, repository: repo, tag: tag)
    }

    public var manifestURL: URL {
        URL(string: "https://\(registry)/v2/\(repository)/manifests/\(tag)")!
    }
    public func blobURL(digest: String) -> URL {
        URL(string: "https://\(registry)/v2/\(repository)/blobs/\(digest)")!
    }
    public var uploadInitURL: URL {
        URL(string: "https://\(registry)/v2/\(repository)/blobs/uploads/")!
    }
    public var baseV2URL: URL {
        URL(string: "https://\(registry)/v2/")!
    }
}

public struct OCIDescriptor: Codable, Sendable {
    public let mediaType: String
    public let digest: String
    public let size: Int64
    public var annotations: [String: String]?

    public init(mediaType: String, digest: String, size: Int64, annotations: [String: String]? = nil) {
        self.mediaType = mediaType
        self.digest = digest
        self.size = size
        self.annotations = annotations
    }
}

public struct OCIManifest: Codable, Sendable {
    public let schemaVersion: Int
    public let mediaType: String
    public let config: OCIDescriptor
    public let layers: [OCIDescriptor]
    public var annotations: [String: String]?

    public init(config: OCIDescriptor, layers: [OCIDescriptor], annotations: [String: String]? = nil) {
        self.schemaVersion = 2
        self.mediaType = OCIMediaType.manifestV1
        self.config = config
        self.layers = layers
        self.annotations = annotations
    }
}

public struct VM4ABundleConfig: Codable, Sendable {
    public let schemaVersion: Int
    public let name: String
    public let createdAt: String
    public let annotations: [String: String]

    public init(schemaVersion: Int, name: String, createdAt: String, annotations: [String: String] = [:]) {
        self.schemaVersion = schemaVersion
        self.name = name
        self.createdAt = createdAt
        self.annotations = annotations
    }
}

public enum OCIAuth: Sendable {
    case anonymous
    case basic(user: String, password: String)

    public static func fromEnvironment() -> OCIAuth {
        let env = ProcessInfo.processInfo.environment
        if let user = env["VM4A_REGISTRY_USER"], let pw = env["VM4A_REGISTRY_PASSWORD"], !user.isEmpty {
            return .basic(user: user, password: pw)
        }
        return .anonymous
    }
}

public final class OCIClient: @unchecked Sendable {
    private let ref: OCIReference
    private let auth: OCIAuth
    private let session: URLSession
    private var token: String?
    private let lock = NSLock()

    public init(ref: OCIReference, auth: OCIAuth = .anonymous) {
        self.ref = ref
        self.auth = auth
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 120
        config.timeoutIntervalForResource = 3600
        self.session = URLSession(configuration: config)
    }

    public var reference: OCIReference { ref }

    private func applyAuth(_ request: inout URLRequest) {
        lock.lock()
        let t = token
        lock.unlock()
        if let t { request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization") }
    }

    private func storeToken(_ t: String) {
        lock.lock(); defer { lock.unlock() }
        token = t
    }

    private func parseChallenge(_ header: String) -> [String: String] {
        var params: [String: String] = [:]
        var remaining = header
        if remaining.lowercased().hasPrefix("bearer ") {
            remaining = String(remaining.dropFirst("bearer ".count))
        }
        var i = remaining.startIndex
        while i < remaining.endIndex {
            guard let eq = remaining[i...].firstIndex(of: "=") else { break }
            let key = remaining[i..<eq].trimmingCharacters(in: .whitespaces)
            var valStart = remaining.index(after: eq)
            var valEnd: String.Index
            if remaining[valStart] == "\"" {
                valStart = remaining.index(after: valStart)
                guard let close = remaining[valStart...].firstIndex(of: "\"") else { break }
                valEnd = close
            } else {
                valEnd = remaining[valStart...].firstIndex(of: ",") ?? remaining.endIndex
            }
            let value = remaining[valStart..<valEnd].trimmingCharacters(in: .whitespaces)
            params[key.lowercased()] = value
            var next = valEnd
            if next < remaining.endIndex, remaining[next] == "\"" { next = remaining.index(after: next) }
            if next < remaining.endIndex, remaining[next] == "," { next = remaining.index(after: next) }
            while next < remaining.endIndex, remaining[next] == " " { next = remaining.index(after: next) }
            i = next
        }
        return params
    }

    private func acquireToken(challenge: String) async throws {
        let params = parseChallenge(challenge)
        guard let realm = params["realm"], var comp = URLComponents(string: realm) else {
            throw VM4AError.message("Malformed registry auth challenge: \(challenge)")
        }
        var items = comp.queryItems ?? []
        if let s = params["service"] { items.append(.init(name: "service", value: s)) }
        if let s = params["scope"] { items.append(.init(name: "scope", value: s)) }
        comp.queryItems = items
        var req = URLRequest(url: comp.url!)
        req.httpMethod = "GET"
        if case let .basic(user, pw) = auth {
            let creds = Data("\(user):\(pw)".utf8).base64EncodedString()
            req.setValue("Basic \(creds)", forHTTPHeaderField: "Authorization")
        }
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
            throw VM4AError.message("Registry auth failed (HTTP \(code)). Set VM4A_REGISTRY_USER / VM4A_REGISTRY_PASSWORD if this registry requires credentials.")
        }
        struct TokenResp: Decodable { let token: String?; let access_token: String? }
        let t = try JSONDecoder().decode(TokenResp.self, from: data)
        guard let value = t.token ?? t.access_token else {
            throw VM4AError.message("Registry returned no token")
        }
        storeToken(value)
    }

    private func perform(_ builder: () -> URLRequest) async throws -> (Data, HTTPURLResponse) {
        var req = builder()
        applyAuth(&req)
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw VM4AError.message("Non-HTTP response from \(req.url?.absoluteString ?? "?")")
        }
        if http.statusCode == 401, let challenge = http.value(forHTTPHeaderField: "Www-Authenticate") {
            try await acquireToken(challenge: challenge)
            var retry = builder()
            applyAuth(&retry)
            let (d2, r2) = try await session.data(for: retry)
            return (d2, r2 as! HTTPURLResponse)
        }
        return (data, http)
    }

    public func fetchManifest() async throws -> OCIManifest {
        let (data, http) = try await perform {
            var r = URLRequest(url: ref.manifestURL)
            r.httpMethod = "GET"
            r.setValue(OCIMediaType.manifestV1, forHTTPHeaderField: "Accept")
            return r
        }
        guard http.statusCode == 200 else {
            throw VM4AError.message("Failed to fetch manifest for \(ref.repository):\(ref.tag): HTTP \(http.statusCode) \(String(data: data, encoding: .utf8) ?? "")")
        }
        return try JSONDecoder().decode(OCIManifest.self, from: data)
    }

    public func putManifest(_ manifest: OCIManifest) async throws {
        let body = try JSONEncoder().encode(manifest)
        let (data, http) = try await perform {
            var r = URLRequest(url: ref.manifestURL)
            r.httpMethod = "PUT"
            r.setValue(OCIMediaType.manifestV1, forHTTPHeaderField: "Content-Type")
            r.httpBody = body
            return r
        }
        guard (200..<300).contains(http.statusCode) else {
            throw VM4AError.message("Failed to push manifest: HTTP \(http.statusCode) \(String(data: data, encoding: .utf8) ?? "")")
        }
    }

    public func downloadBlob(descriptor: OCIDescriptor, to fileURL: URL, progress: ((Int64, Int64) -> Void)? = nil) async throws {
        var req = URLRequest(url: ref.blobURL(digest: descriptor.digest))
        req.httpMethod = "GET"
        applyAuth(&req)
        let (asyncBytes, resp) = try await session.bytes(for: req)
        var http = resp as? HTTPURLResponse
        if http?.statusCode == 401, let challenge = http?.value(forHTTPHeaderField: "Www-Authenticate") {
            try await acquireToken(challenge: challenge)
            var retry = URLRequest(url: ref.blobURL(digest: descriptor.digest))
            retry.httpMethod = "GET"
            applyAuth(&retry)
            let (bytes2, resp2) = try await session.bytes(for: retry)
            http = resp2 as? HTTPURLResponse
            guard let http2 = http, (200..<300).contains(http2.statusCode) else {
                throw VM4AError.message("Blob fetch failed: HTTP \(http?.statusCode ?? -1)")
            }
            try await streamToFile(asyncBytes: bytes2, expected: descriptor.size, fileURL: fileURL, progress: progress)
            return
        }
        guard let http, (200..<300).contains(http.statusCode) else {
            throw VM4AError.message("Blob fetch failed: HTTP \(http?.statusCode ?? -1)")
        }
        try await streamToFile(asyncBytes: asyncBytes, expected: descriptor.size, fileURL: fileURL, progress: progress)
    }

    private func streamToFile(asyncBytes: URLSession.AsyncBytes, expected: Int64, fileURL: URL, progress: ((Int64, Int64) -> Void)?) async throws {
        FileManager.default.createFile(atPath: fileURL.path(percentEncoded: false), contents: nil)
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        var received: Int64 = 0
        var buffer = Data()
        buffer.reserveCapacity(1024 * 1024)
        for try await byte in asyncBytes {
            buffer.append(byte)
            if buffer.count >= 1024 * 1024 {
                try handle.write(contentsOf: buffer)
                received += Int64(buffer.count)
                progress?(received, expected)
                buffer.removeAll(keepingCapacity: true)
            }
        }
        if !buffer.isEmpty {
            try handle.write(contentsOf: buffer)
            received += Int64(buffer.count)
            progress?(received, expected)
        }
    }

    public func uploadBlob(fileURL: URL, mediaType: String, progress: ((Int64, Int64) -> Void)? = nil) async throws -> OCIDescriptor {
        let attrs = try FileManager.default.attributesOfItem(atPath: fileURL.path(percentEncoded: false))
        let size = (attrs[.size] as? NSNumber)?.int64Value ?? 0
        let digest = try sha256Digest(of: fileURL)

        let (locData, locResp) = try await perform {
            var r = URLRequest(url: ref.uploadInitURL)
            r.httpMethod = "POST"
            r.setValue("0", forHTTPHeaderField: "Content-Length")
            return r
        }
        guard locResp.statusCode == 202, let location = locResp.value(forHTTPHeaderField: "Location") else {
            throw VM4AError.message("Blob upload init failed: HTTP \(locResp.statusCode) \(String(data: locData, encoding: .utf8) ?? "")")
        }
        let finalURL = try appendQuery(to: absoluteLocation(location), name: "digest", value: "sha256:\(digest)")
        var putReq = URLRequest(url: finalURL)
        putReq.httpMethod = "PUT"
        putReq.setValue(mediaType, forHTTPHeaderField: "Content-Type")
        putReq.setValue("\(size)", forHTTPHeaderField: "Content-Length")
        applyAuth(&putReq)

        let (uData, uResp) = try await session.upload(for: putReq, fromFile: fileURL)
        progress?(size, size)
        guard let http = uResp as? HTTPURLResponse else {
            throw VM4AError.message("Non-HTTP response during blob PUT")
        }
        if http.statusCode == 401, let challenge = http.value(forHTTPHeaderField: "Www-Authenticate") {
            try await acquireToken(challenge: challenge)
            applyAuth(&putReq)
            let (uData2, uResp2) = try await session.upload(for: putReq, fromFile: fileURL)
            guard let http2 = uResp2 as? HTTPURLResponse, (200..<300).contains(http2.statusCode) else {
                throw VM4AError.message("Blob upload failed after re-auth: HTTP \((uResp2 as? HTTPURLResponse)?.statusCode ?? -1) \(String(data: uData2, encoding: .utf8) ?? "")")
            }
        } else if !(200..<300).contains(http.statusCode) {
            throw VM4AError.message("Blob upload failed: HTTP \(http.statusCode) \(String(data: uData, encoding: .utf8) ?? "")")
        }

        return OCIDescriptor(mediaType: mediaType, digest: "sha256:\(digest)", size: size)
    }

    public func uploadInlineBlob(data: Data, mediaType: String) async throws -> OCIDescriptor {
        let digest = SHA256.hash(data: data).hex

        let (locData, locResp) = try await perform {
            var r = URLRequest(url: ref.uploadInitURL)
            r.httpMethod = "POST"
            r.setValue("0", forHTTPHeaderField: "Content-Length")
            return r
        }
        guard locResp.statusCode == 202, let location = locResp.value(forHTTPHeaderField: "Location") else {
            throw VM4AError.message("Inline blob init failed: HTTP \(locResp.statusCode) \(String(data: locData, encoding: .utf8) ?? "")")
        }
        let finalURL = try appendQuery(to: absoluteLocation(location), name: "digest", value: "sha256:\(digest)")
        let (uData, uResp) = try await perform {
            var r = URLRequest(url: finalURL)
            r.httpMethod = "PUT"
            r.setValue(mediaType, forHTTPHeaderField: "Content-Type")
            r.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
            r.httpBody = data
            return r
        }
        guard (200..<300).contains(uResp.statusCode) else {
            throw VM4AError.message("Inline blob upload failed: HTTP \(uResp.statusCode) \(String(data: uData, encoding: .utf8) ?? "")")
        }
        return OCIDescriptor(mediaType: mediaType, digest: "sha256:\(digest)", size: Int64(data.count))
    }

    private func absoluteLocation(_ loc: String) -> URL {
        if let url = URL(string: loc), url.scheme != nil { return url }
        return URL(string: loc, relativeTo: ref.baseV2URL)!.absoluteURL
    }

    private func appendQuery(to url: URL, name: String, value: String) throws -> URL {
        guard var comp = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw VM4AError.message("Invalid URL: \(url)")
        }
        var items = comp.queryItems ?? []
        items.append(.init(name: name, value: value))
        comp.queryItems = items
        guard let out = comp.url else {
            throw VM4AError.message("Failed to build URL from \(url)")
        }
        return out
    }
}

public func sha256Digest(of fileURL: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer { try? handle.close() }
    var hasher = SHA256()
    while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
        hasher.update(data: chunk)
    }
    return hasher.finalize().hex
}

extension Digest {
    var hex: String {
        self.map { String(format: "%02x", $0) }.joined()
    }
}

public func packBundleTarball(bundleDir: URL, outputTarGz: URL) throws {
    let parent = bundleDir.deletingLastPathComponent()
    let name = bundleDir.lastPathComponent
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    task.currentDirectoryURL = parent
    task.arguments = ["-czf", outputTarGz.path(percentEncoded: false), "--exclude", ".vm4a-run.pid", "--exclude", ".vm4a-run.log", name]
    let errPipe = Pipe()
    task.standardError = errPipe
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw VM4AError.message("tar failed (\(task.terminationStatus)): \(err)")
    }
}

public func extractBundleTarball(tarGz: URL, into parentDir: URL) throws {
    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
    task.currentDirectoryURL = parentDir
    task.arguments = ["-xzf", tarGz.path(percentEncoded: false)]
    let errPipe = Pipe()
    task.standardError = errPipe
    try task.run()
    task.waitUntilExit()
    if task.terminationStatus != 0 {
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        throw VM4AError.message("tar extract failed (\(task.terminationStatus)): \(err)")
    }
}

public func ociPush(bundleDir: URL, reference: String, progress: ((String) -> Void)? = nil) async throws {
    let ref = try OCIReference.parse(reference)
    guard FileManager.default.fileExists(atPath: bundleDir.appending(path: "config.json").path(percentEncoded: false)) else {
        throw VM4AError.message("Not a VM bundle (missing config.json): \(bundleDir.path())")
    }
    let client = OCIClient(ref: ref, auth: .fromEnvironment())

    let tmpDir = FileManager.default.temporaryDirectory.appending(path: "vm4a-push-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let tarURL = tmpDir.appending(path: "bundle.tar.gz")
    progress?("Packing \(bundleDir.lastPathComponent) -> \(tarURL.lastPathComponent)")
    try packBundleTarball(bundleDir: bundleDir, outputTarGz: tarURL)

    progress?("Uploading layer to \(ref.registry)/\(ref.repository):\(ref.tag)")
    let layerDesc = try await client.uploadBlob(fileURL: tarURL, mediaType: OCIMediaType.vm4aBundleV1) { rx, tot in
        if tot > 0 { progress?("  layer: \(rx)/\(tot) bytes") }
    }

    let configBlob = VM4ABundleConfig(
        schemaVersion: VMConfigModel.currentSchemaVersion,
        name: bundleDir.lastPathComponent,
        createdAt: ISO8601DateFormatter().string(from: Date())
    )
    let configData = try JSONEncoder().encode(configBlob)
    let configDesc = try await client.uploadInlineBlob(data: configData, mediaType: OCIMediaType.vm4aConfigV1)

    let manifest = OCIManifest(
        config: configDesc,
        layers: [layerDesc],
        annotations: ["org.opencontainers.image.title": bundleDir.lastPathComponent]
    )
    progress?("Pushing manifest")
    try await client.putManifest(manifest)
    progress?("Pushed \(reference)")
}

public func ociPull(reference: String, into parentDir: URL, progress: ((String) -> Void)? = nil) async throws -> URL {
    let ref = try OCIReference.parse(reference)
    let client = OCIClient(ref: ref, auth: .fromEnvironment())

    progress?("Fetching manifest")
    let manifest = try await client.fetchManifest()
    guard let layer = manifest.layers.first(where: { $0.mediaType == OCIMediaType.vm4aBundleV1 }) ?? manifest.layers.first else {
        throw VM4AError.message("Manifest has no layers")
    }

    try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
    let tmpDir = FileManager.default.temporaryDirectory.appending(path: "vm4a-pull-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmpDir) }

    let tarURL = tmpDir.appending(path: "bundle.tar.gz")
    progress?("Downloading layer \(layer.digest)")
    try await client.downloadBlob(descriptor: layer, to: tarURL) { rx, tot in
        if tot > 0 { progress?("  layer: \(rx)/\(tot) bytes") }
    }

    progress?("Extracting into \(parentDir.path())")
    try extractBundleTarball(tarGz: tarURL, into: parentDir)

    let entries = try FileManager.default.contentsOfDirectory(at: parentDir, includingPropertiesForKeys: [.isDirectoryKey])
    for entry in entries {
        if FileManager.default.fileExists(atPath: entry.appending(path: "config.json").path(percentEncoded: false)) {
            progress?("Extracted bundle: \(entry.path())")
            return entry
        }
    }
    throw VM4AError.message("Pull succeeded but no VM bundle found in \(parentDir.path())")
}
