// GemmaResumableDownloader — a byte-resumable HuggingFace model downloader.
//
// WHY THIS EXISTS: the vendored `Gemma4ModelDownloader` skips already-COMPLETE shards on a retry, but
// it has no BYTE-level resume — a wifi drop mid-shard (`NSURLErrorDomain -1005`) discards the whole
// in-flight shard and, after enough drops, fails the download permanently. For a user on flaky wifi
// pulling a ~18 GB model in four shards, that's fatal. This downloader streams each file to a
// `{dest}.part` on disk, APPENDING bytes as they arrive, so a drop leaves partial progress on disk and
// the next attempt resumes from exactly where it left off via an HTTP `Range: bytes=N-` request (the
// `resolve/main` redirect target supports `206 Partial Content`). Completed files are still skipped.
//
// EFFICIENCY: it does NOT iterate `URLSession.AsyncBytes` byte-by-byte (orders of magnitude too slow
// for GBs). A `URLSessionDataDelegate` appends each received `Data` chunk straight to a `FileHandle`,
// and `didCompleteWithError` resumes a continuation. Delegate callbacks are serialized on a dedicated
// serial `OperationQueue`, so the file writes happen in order without extra locking on the hot path.

import Foundation
import Gemma4Swift

/// A robust, byte-resumable downloader for an `mlx-community` Gemma 4 model from the HuggingFace Hub.
///
/// These models are UNGATED, so no token is required; a token is accepted for parity / private repos.
public enum GemmaResumableDownloader {

    // MARK: - Public entry

    /// Ensure every weight/config file of `model` is present and complete under `modelDir`.
    ///
    /// Fetches the repo file list (with sizes) from the tree API, then for each file: if it already
    /// exists at the expected size it's counted done and skipped; otherwise it's downloaded RESUMABLY
    /// to `{dest}.part` and atomically moved into place. `progress` reports a clamped 0…1 byte fraction.
    /// Honors `Task` cancellation (throws `CancellationError`, cancelling the in-flight request).
    public static func ensureModel(
        _ model: Gemma4Pipeline.Model,
        into modelDir: URL,
        token: String? = nil,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws {
        let modelId = model.rawValue
        let fm = FileManager.default
        try fm.createDirectory(at: modelDir, withIntermediateDirectories: true)

        // 1) Discover the files to fetch (skip docs/attributes — not part of the loadable model).
        let files = try await fetchFileList(modelId: modelId, token: token)
            .filter { $0.type == "file" && !isSkippable($0.path) }
        let total = files.reduce(0) { $0 + max($1.size, 0) }

        // 2) Walk the files. `doneSoFar` accumulates the bytes of every fully-finished file so the
        //    per-file progress callback can report a global fraction.
        var doneSoFar = 0
        for file in files {
            try Task.checkCancellation()
            let dest = modelDir.appendingPathComponent(file.path)

            // Already complete on disk? Count it and move on.
            if let size = fileSize(at: dest), size == file.size {
                doneSoFar += file.size
                emit(progress, doneSoFar, total)
                continue
            }

            let baseline = doneSoFar
            try await downloadFileResumably(
                modelId: modelId,
                path: file.path,
                expectedSize: file.size,
                dest: dest,
                token: token,
                progress: { bytesThisFile in
                    emit(progress, baseline + bytesThisFile, total)
                }
            )
            doneSoFar += file.size
            emit(progress, doneSoFar, total)
        }

        emit(progress, total, total)
    }

    // MARK: - File list (tree API)

    /// One entry from the HF tree API.
    struct RepoFile: Sendable {
        let type: String   // "file" | "directory"
        let path: String
        let size: Int
    }

    /// Files that are part of the repo but NOT part of the loadable model — pure docs / VCS metadata.
    static func isSkippable(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        if name == ".gitattributes" || name == "README.md" { return true }
        if name.lowercased().hasSuffix(".md") { return true }
        return false
    }

    /// Fetch the model's file list (with sizes) from `GET /api/models/{id}/tree/main`.
    static func fetchFileList(modelId: String, token: String?) async throws -> [RepoFile] {
        guard let url = URL(string: "https://huggingface.co/api/models/\(modelId)/tree/main") else {
            throw Gemma4DownloadError.apiFailed(modelId)
        }
        var request = URLRequest(url: url)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw Gemma4DownloadError.networkError(modelId, error)
        }
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw Gemma4DownloadError.httpError(modelId, code)
        }

        guard let array = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw Gemma4DownloadError.parseError(modelId)
        }
        return array.compactMap { obj in
            guard let type = obj["type"] as? String, let path = obj["path"] as? String else { return nil }
            let size = (obj["size"] as? Int) ?? (obj["size"] as? NSNumber)?.intValue ?? 0
            return RepoFile(type: type, path: path, size: size)
        }
    }

    // MARK: - Per-file resumable download

    private static let maxAttempts = 10

    /// Download a single file to `{dest}.part` (appending across attempts) then move it into place.
    static func downloadFileResumably(
        modelId: String,
        path: String,
        expectedSize: Int,
        dest: URL,
        token: String?,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let part = dest.appendingPathExtension("part")

        guard let resolveURL = resolveURL(modelId: modelId, path: path) else {
            throw Gemma4DownloadError.httpError(path, -1)
        }

        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1

            var have = fileSize(at: part) ?? 0
            // Defensive: if `.part` somehow overshot the expected size, restart cleanly.
            if expectedSize > 0 && have > expectedSize {
                try? fm.removeItem(at: part)
                have = 0
            }
            // Already fully on disk in `.part`? Just move it.
            if expectedSize > 0 && have == expectedSize {
                try finalizeMove(part: part, dest: dest)
                progress(expectedSize)
                return
            }

            do {
                try await streamOneAttempt(
                    resolveURL: resolveURL,
                    part: part,
                    have: have,
                    expectedSize: expectedSize,
                    token: token,
                    progress: progress
                )
                // Success of one attempt means the stream completed without error. Re-check size and
                // either finalize or loop again (a short read loops back through Range resume).
                let now = fileSize(at: part) ?? 0
                if expectedSize <= 0 || now >= expectedSize {
                    try finalizeMove(part: part, dest: dest)
                    progress(expectedSize > 0 ? expectedSize : now)
                    return
                }
                // Short read but no error reported: treat as retryable so the next Range request resumes.
                if attempt >= maxAttempts {
                    throw Gemma4DownloadError.networkError(path, ShortReadError(have: now, want: expectedSize))
                }
                try await backoff(attempt)
            } catch is CancellationError {
                throw CancellationError()
            } catch let fatal as GemmaDownloadFatalHTTPError {
                // 4xx (bad token / gated / missing) — don't burn the retry budget.
                throw Gemma4DownloadError.httpError(path, fatal.statusCode)
            } catch {
                // Network drop / transient HTTP. Retry from the current `.part` size if attempts remain.
                if attempt >= maxAttempts {
                    throw Gemma4DownloadError.networkError(path, error)
                }
                try await backoff(attempt)
            }
        }
    }

    /// Run exactly ONE network attempt: request the file (Range when resuming), append the streamed
    /// bytes to `.part`, and resume when the request completes. Throws on any error/non-2xx-206 status.
    private static func streamOneAttempt(
        resolveURL: URL,
        part: URL,
        have: Int,
        expectedSize: Int,
        token: String?,
        progress: @escaping @Sendable (Int) -> Void
    ) async throws {
        let fm = FileManager.default

        // Ensure the `.part` exists so we can open a writing handle that seeks to end for appends.
        if !fm.fileExists(atPath: part.path) {
            fm.createFile(atPath: part.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: part)
        if have > 0 {
            try handle.seekToEnd()
        }

        var request = URLRequest(url: resolveURL)
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if have > 0 { request.setValue("bytes=\(have)-", forHTTPHeaderField: "Range") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }

        let collector = ResponseCollector(
            handle: handle,
            startOffset: have,
            requestedResume: have > 0,
            progress: progress
        )

        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.name = "GemmaResumableDownloader.delegate"
        let session = URLSession(configuration: .ephemeral, delegate: collector, delegateQueue: queue)
        defer { session.finishTasksAndInvalidate() }

        let task = session.dataTask(with: request)
        collector.attach(task: task)

        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                    collector.setContinuation(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        } catch {
            try? collector.closeHandle()
            throw error
        }
        try collector.closeHandle()
    }

    // MARK: - Helpers

    /// `https://huggingface.co/{modelId}/resolve/main/{path}` with each path component percent-encoded.
    static func resolveURL(modelId: String, path: String) -> URL? {
        let encodedModel = modelId
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { percentEncodePathSegment(String($0)) }
            .joined(separator: "/")
        let encodedPath = path
            .split(separator: "/", omittingEmptySubsequences: false)
            .map { percentEncodePathSegment(String($0)) }
            .joined(separator: "/")
        return URL(string: "https://huggingface.co/\(encodedModel)/resolve/main/\(encodedPath)")
    }

    private static func percentEncodePathSegment(_ segment: String) -> String {
        // `urlPathAllowed` keeps `/` allowed, so encode against a stricter set per-segment.
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    static func fileSize(at url: URL) -> Int? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber else { return nil }
        return size.intValue
    }

    /// Atomically place `.part` at `dest`, removing any stale `dest` first.
    private static func finalizeMove(part: URL, dest: URL) throws {
        let fm = FileManager.default
        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        try fm.moveItem(at: part, to: dest)
    }

    private static func backoff(_ attempt: Int) async throws {
        let seconds = min(Double(1 << min(attempt, 5)), 30) // 2,4,8,16,30,30… capped at 30s
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    private static func emit(_ progress: @escaping @Sendable (Double) -> Void, _ done: Int, _ total: Int) {
        guard total > 0 else { progress(0); return }
        progress(min(max(Double(done) / Double(total), 0), 1))
    }

    /// A short read that exhausted retries (the body ended before `expectedSize`).
    private struct ShortReadError: Error { let have: Int; let want: Int }
}

// MARK: - Shared error types (file-private to the downloader)

/// A non-retryable HTTP status (4xx) — fail fast rather than burning the retry budget.
struct GemmaDownloadFatalHTTPError: Error { let statusCode: Int }
/// A retryable non-2xx/206 status — the per-file loop backs off and retries from the `.part` size.
struct GemmaDownloadRetryableHTTPError: Error { let statusCode: Int }

// MARK: - URLSession delegate (chunk → FileHandle)

/// Streams a single HTTP response body to a `FileHandle`, appending each `Data` chunk as it arrives.
///
/// All `URLSessionDataDelegate` callbacks run serialized on the session's dedicated single-threaded
/// `delegateQueue`, so the ordered file writes and the continuation handoff need no further locking on
/// that path. The continuation/handle are guarded by a lock only because `closeHandle()` /
/// `setContinuation(_:)` may be touched from the awaiting task as well.
private final class ResponseCollector: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private let handle: FileHandle
    private let startOffset: Int
    private let requestedResume: Bool
    private let progress: @Sendable (Int) -> Void

    private var continuation: CheckedContinuation<Void, Error>?
    private var resumed = false
    private var handleClosed = false
    private var bytesWritten = 0
    private var truncatedForFullBody = false
    private weak var task: URLSessionTask?

    init(
        handle: FileHandle,
        startOffset: Int,
        requestedResume: Bool,
        progress: @escaping @Sendable (Int) -> Void
    ) {
        self.handle = handle
        self.startOffset = startOffset
        self.requestedResume = requestedResume
        self.progress = progress
    }

    func attach(task: URLSessionTask) { self.task = task }

    func setContinuation(_ c: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        continuation = c
    }

    func closeHandle() throws {
        lock.lock(); defer { lock.unlock() }
        guard !handleClosed else { return }
        handleClosed = true
        try handle.close()
    }

    private func finish(_ result: Result<Void, Error>) {
        lock.lock()
        guard !resumed, let c = continuation else { lock.unlock(); return }
        resumed = true
        continuation = nil
        lock.unlock()
        switch result {
        case .success: c.resume()
        case .failure(let e): c.resume(throwing: e)
        }
    }

    // Decide whether to accept the response and how to treat the body (206 append vs 200 restart).
    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let http = response as? HTTPURLResponse else {
            completionHandler(.cancel)
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        let code = http.statusCode

        // Fatal client errors: don't retry (bad token / gated / missing file).
        if code == 401 || code == 403 || code == 404 {
            completionHandler(.cancel)
            finish(.failure(GemmaDownloadFatalHTTPError(statusCode: code)))
            return
        }

        if code == 206 {
            // Server honored the Range — append from where we left off. Good.
            completionHandler(.allow)
            return
        }

        if code == 200 {
            // Range was ignored (or none was sent). If we had partial bytes, the body starts at 0, so
            // truncate `.part` to 0 and restart this file from the beginning.
            if requestedResume {
                lock.lock()
                if !truncatedForFullBody {
                    truncatedForFullBody = true
                    do {
                        try handle.seek(toOffset: 0)
                        try handle.truncate(atOffset: 0)
                    } catch {
                        lock.unlock()
                        completionHandler(.cancel)
                        finish(.failure(error))
                        return
                    }
                }
                lock.unlock()
            }
            completionHandler(.allow)
            return
        }

        // Any other status (5xx, 3xx-not-followed, etc.): retryable failure.
        completionHandler(.cancel)
        finish(.failure(GemmaDownloadRetryableHTTPError(statusCode: code)))
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        do {
            try handle.write(contentsOf: data)
        } catch {
            task?.cancel()
            finish(.failure(error))
            return
        }
        bytesWritten += data.count
        // Report bytes-this-file. When the server ignored Range and restarted at 0, `bytesWritten` is
        // the absolute file size; otherwise it's startOffset + what we appended.
        let absolute = truncatedForFullBody ? bytesWritten : (startOffset + bytesWritten)
        progress(absolute)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        // Flush to disk before finishing so the next attempt sees the true `.part` size.
        try? handle.synchronize()
        if let error {
            if (error as NSError).code == NSURLErrorCancelled {
                finish(.failure(CancellationError()))
            } else {
                finish(.failure(error))
            }
        } else {
            finish(.success(()))
        }
    }
}
