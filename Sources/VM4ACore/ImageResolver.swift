import Foundation
@preconcurrency import Virtualization

// MARK: - macOS catalog

/// A symbolic spec for "the latest macOS IPSW Apple says is supported on
/// this host". `vm4a image list` shows it; `vm4a create --os macOS` with no
/// --image resolves to it.
public let macOSLatestImageID = "macos-latest"

public func macOSCatalog() -> [LinuxImageCatalogEntry] {
    [
        .init(
            id: macOSLatestImageID,
            displayName: "macOS — latest supported on this host (Apple)",
            url: "vz://latest-supported",   // sentinel resolved at fetch time
            sha256: nil
        )
    ]
}

// MARK: - Cache layout

public enum ImageCache {
    /// `~/.cache/vm4a/images/`
    public static func directory() throws -> URL {
        let env = ProcessInfo.processInfo.environment
        let base: URL
        if let xdg = env["XDG_CACHE_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appending(path: ".cache", directoryHint: .isDirectory)
        }
        let dir = base.appending(path: "vm4a/images", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Filename in the cache for a catalog id + extension.
    public static func cachedURL(forID id: String, ext: String) throws -> URL {
        try directory().appending(path: "\(id).\(ext)")
    }

    /// Filename in the cache for a free-form remote URL — keyed by SHA256
    /// of the URL string so distinct URLs land in distinct files.
    public static func cachedURL(forRemote remote: URL, ext: String) throws -> URL {
        let hash = sha256Hex(of: Data(remote.absoluteString.utf8))
        let short = String(hash.prefix(16))
        return try directory().appending(path: "remote-\(short).\(ext)")
    }
}

// MARK: - Image spec resolution

/// Resolves a user-supplied `--image` spec to a local file path, downloading
/// to the cache if needed. Accepts:
/// - An absolute or relative path that exists on disk
/// - A catalog id from `linuxImageCatalog()` or `macOSCatalog()`
/// - "macos-latest" (or nil-with-macOS) → Apple's latest supported IPSW
/// - An http(s):// URL
public func resolveImage(
    spec: String?,
    os: VMOSType,
    progress: (@Sendable (String) -> Void)? = nil
) async throws -> URL {
    let raw = spec?.trimmingCharacters(in: .whitespaces)

    // Implicit macOS-latest when --image is omitted for a macOS create.
    if raw == nil || raw?.isEmpty == true {
        switch os {
        case .macOS:
            return try await resolveMacOSLatest(progress: progress)
        case .linux:
            throw VM4AError.message("Linux create requires --image (a catalog id, a local ISO path, or an https URL). See `vm4a image list`.")
        }
    }
    let s = raw!

    // 1. Local path that exists?
    let normalized = normalizePath(s)
    if FileManager.default.fileExists(atPath: normalized) {
        return URL(fileURLWithPath: normalized)
    }

    // 2. Catalog id?
    if let entry = linuxImageCatalog().first(where: { $0.id == s }) {
        return try await fetchToCache(
            id: entry.id,
            remoteURL: URL(string: entry.url)!,
            ext: "iso",
            sha256: entry.sha256,
            progress: progress
        )
    }
    if let entry = macOSCatalog().first(where: { $0.id == s }) {
        if entry.id == macOSLatestImageID {
            return try await resolveMacOSLatest(progress: progress)
        }
        return try await fetchToCache(
            id: entry.id,
            remoteURL: URL(string: entry.url)!,
            ext: "ipsw",
            sha256: entry.sha256,
            progress: progress
        )
    }

    // 3. http(s) URL?
    if let u = URL(string: s), u.scheme == "http" || u.scheme == "https" {
        let ext = (os == .macOS) ? "ipsw" : "iso"
        return try await fetchToCacheByRemoteURL(remoteURL: u, ext: ext, progress: progress)
    }

    throw VM4AError.notFound("Image spec '\(s)'. Not a local path, catalog id, or URL. Try `vm4a image list`.")
}

// MARK: - Apple's "latest supported" IPSW lookup

private func resolveMacOSLatest(progress: (@Sendable (String) -> Void)?) async throws -> URL {
    progress?("Asking Apple for the latest supported macOS IPSW…")
    let remote = try await fetchLatestSupportedIPSWURL()
    return try await fetchToCacheByRemoteURL(remoteURL: remote, ext: "ipsw", progress: progress)
}

private func fetchLatestSupportedIPSWURL() async throws -> URL {
    try await withCheckedThrowingContinuation { continuation in
        VZMacOSRestoreImage.fetchLatestSupported { result in
            switch result {
            case .failure(let err): continuation.resume(throwing: err)
            case .success(let image): continuation.resume(returning: image.url)
            }
        }
    }
}

// MARK: - Download + verify + cache

private func fetchToCache(
    id: String,
    remoteURL: URL,
    ext: String,
    sha256: String?,
    progress: (@Sendable (String) -> Void)?
) async throws -> URL {
    let dst = try ImageCache.cachedURL(forID: id, ext: ext)
    if FileManager.default.fileExists(atPath: dst.path(percentEncoded: false)) {
        progress?("Using cached image: \(dst.path())")
        if let sha = sha256 {
            try verifySHA256(file: dst, expected: sha)
        }
        return dst
    }
    progress?("Downloading \(id) from \(remoteURL.absoluteString)")
    try await downloadWithProgress(from: remoteURL, to: dst, progress: progress)
    if let sha = sha256 {
        try verifySHA256(file: dst, expected: sha)
    }
    return dst
}

private func fetchToCacheByRemoteURL(
    remoteURL: URL,
    ext: String,
    progress: (@Sendable (String) -> Void)?
) async throws -> URL {
    let dst = try ImageCache.cachedURL(forRemote: remoteURL, ext: ext)
    if FileManager.default.fileExists(atPath: dst.path(percentEncoded: false)) {
        progress?("Using cached image: \(dst.path())")
        return dst
    }
    progress?("Downloading from \(remoteURL.absoluteString)")
    try await downloadWithProgress(from: remoteURL, to: dst, progress: progress)
    return dst
}

private final class DownloadBox: @unchecked Sendable {
    var observer: NSKeyValueObservation?
    var lastReport: Date = .distantPast
}

private func downloadWithProgress(
    from remoteURL: URL,
    to destination: URL,
    progress: (@Sendable (String) -> Void)?
) async throws {
    let partial = destination.deletingPathExtension().appendingPathExtension("partial")
    try? FileManager.default.removeItem(at: partial)

    let box = DownloadBox()

    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        let task = URLSession.shared.downloadTask(with: remoteURL) { tmpURL, response, error in
            box.observer?.invalidate()
            box.observer = nil
            if let error = error {
                continuation.resume(throwing: VM4AError.message("Download failed: \(error.localizedDescription)"))
                return
            }
            guard let tmpURL else {
                continuation.resume(throwing: VM4AError.message("Download produced no file"))
                return
            }
            if let httpResp = response as? HTTPURLResponse, !(200..<300).contains(httpResp.statusCode) {
                continuation.resume(throwing: VM4AError.message("HTTP \(httpResp.statusCode) for \(remoteURL.absoluteString)"))
                return
            }
            do {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: tmpURL, to: destination)
                continuation.resume()
            } catch {
                continuation.resume(throwing: VM4AError.message("Failed to install download: \(error.localizedDescription)"))
            }
        }
        box.observer = task.progress.observe(\.fractionCompleted, options: [.initial, .new]) { p, _ in
            // Throttle progress prints to once a second.
            let now = Date()
            if now.timeIntervalSince(box.lastReport) < 1.0 { return }
            box.lastReport = now
            let pct = Int((p.fractionCompleted * 100).rounded())
            let total = p.totalUnitCount
            let done = p.completedUnitCount
            if total > 0 {
                let mb = Double(done) / 1_048_576.0
                let totalMB = Double(total) / 1_048_576.0
                progress?(String(format: "  %3d%%  %.1f MB / %.1f MB", pct, mb, totalMB))
            } else {
                progress?(String(format: "  %3d%%", pct))
            }
        }
        task.resume()
    }
}

// MARK: - SHA256 helpers (kept zero-deps; uses Foundation's SHA256 via CC)

import CommonCrypto

public func sha256Hex(of data: Data) -> String {
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes { _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash) }
    return hash.map { String(format: "%02x", $0) }.joined()
}

public func sha256Hex(file url: URL) throws -> String {
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var ctx = CC_SHA256_CTX()
    CC_SHA256_Init(&ctx)
    while true {
        let chunk = handle.readData(ofLength: 1 << 20)
        if chunk.isEmpty { break }
        chunk.withUnsafeBytes { _ = CC_SHA256_Update(&ctx, $0.baseAddress, CC_LONG(chunk.count)) }
    }
    var digest = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    CC_SHA256_Final(&digest, &ctx)
    return digest.map { String(format: "%02x", $0) }.joined()
}

private func verifySHA256(file url: URL, expected: String) throws {
    let actual = try sha256Hex(file: url)
    if actual.lowercased() != expected.lowercased() {
        throw VM4AError.message("SHA256 mismatch for \(url.path()): expected \(expected), got \(actual)")
    }
}
