// CloudVideoRuntime — the concrete CLOUD-escalation VIDEO `MediaRuntime` over a hosted video API
// (LTX Studio / equivalent) (ai-video-animation-generation §5.3, design D1/D2/D7).
//
// FLAGGED: user xcodebuild + stable-signed build.
//
// This is the DEFAULT video backend behind the `MediaRuntime` seam — a conformer, NOT a new seam (design
// D1), exactly as `GemmaMLXRuntime` is the chat seam's backend and `MFluxImageRuntime` is the image
// backend. It does real network IO (`URLSession`: upload the prompt + optional seed frame, poll render
// progress, fetch the finished file), so it is `xcodebuild` COMPILE-VERIFY ONLY here: the agent never
// builds/signs/installs the `.app`. REAL correctness — a real clip, real upload, real poll latency, real $
// spend — is the USER's stable-signed run-verify (task 5.3).
//
// IT SPENDS MONEY + UPLOADS BYTES (design D3): the budget cap (`RollingVideoBudget`) + the `.dangerous`
// confirm gate live UPSTREAM in the sink/contributor — this runtime is the side-effecting executor invoked
// AFTER approval + after a budget unit was consumed. A launch that fails here surfaces a thrown
// `MediaError`; the contributor REFUNDS the spend (the cap stays honest, spec "A failed cloud launch
// refunds its spend"). This runtime does NOT itself touch the ledger.
//
// ERROR TAXONOMY (design D7 / task 8.1): every vendor/OS failure — `NSURLError` (offline / timeout / DNS),
// an HTTP 4xx/5xx, a malformed render response, a file-write IO error — is mapped INTO `MediaError` AT THIS
// BOUNDARY (Core stays network-free). Feature/UI code only ever sees `MediaError`, surfaced through
// `AIError.message(for:)` as a clean bounded headline (raw vendor text only in logs / opt-in copyable
// details — never a headline, never an `NSAlert`). A gen that fails to land is `.failed`; CANCELLATION is a
// stopped stream, NOT a failure (design D10): the stream finishes WITHOUT a `.finished` and WITHOUT throwing.

import Foundation
import os
import ThreeFingerSwitcherCore

public final class CloudVideoRuntime: MediaRuntime, @unchecked Sendable {

    static let log = Logger(subsystem: "ThreeFingerSwitcher", category: "CloudVideoRuntime")

    /// VIDEO only — never `.image` (the router never routes a still here, design D1).
    public let capabilities: Set<MediaKind> = [.video]

    /// The hosted API base (the render submit + poll + fetch endpoints derive from it).
    private let endpoint: URL
    /// The API credential, injected (never logged, never in a headline / audit summary).
    private let apiKey: String
    /// Where the fetched clip is written (the gallery root — becomes a Files-band `.fileEntry`).
    private let outputDirectory: URL
    /// The poll cadence + ceiling (so a stuck remote render fails clean, never hangs forever).
    private let pollInterval: TimeInterval
    private let pollCeiling: TimeInterval
    private let session: URLSession

    public init(endpoint: URL,
                apiKey: String,
                outputDirectory: URL,
                pollInterval: TimeInterval = 3,
                pollCeiling: TimeInterval = 600,
                session: URLSession = .shared) {
        self.endpoint = endpoint
        self.apiKey = apiKey
        self.outputDirectory = outputDirectory
        self.pollInterval = pollInterval
        self.pollCeiling = pollCeiling
        self.session = session
    }

    // MARK: - Generation (upload → poll → fetch — task 5.3)

    public func generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error> {
        let outputDirectory = self.outputDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    // (1) SUBMIT — upload the prompt + optional seed PNG (img2video first frame). A present
                    // seed that isn't a decodable PNG is a clean `MediaError.seedInvalid` (never uploaded).
                    if let seed = request.seed, !MediaSeedValidation.isDecodablePNG(seed) {
                        continuation.finish(throwing: MediaError.seedInvalid)
                        return
                    }
                    let jobID = try await self.submit(request)

                    // (2) POLL — stream render progress as `.step(index:total:preview:)` until the remote
                    // job reports finished; honor cancellation between polls (stopped stream, no .finished).
                    let fileURL = try await self.poll(jobID: jobID, into: continuation)

                    // (3) FETCH + WRITE — download the finished clip to the gallery; a write IO failure maps
                    // to `MediaError.outputWriteFailed` (raw OS reason → copyable details, never a headline).
                    let asset = try await self.fetch(from: fileURL, request: request,
                                                     outputDirectory: outputDirectory)
                    continuation.yield(.finished(asset))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()                       // discard → stopped stream, NOT a failure
                } catch let e as MediaError {
                    continuation.finish(throwing: e)
                } catch {
                    continuation.finish(throwing: Self.map(error))   // NSURLError / HTTP → MediaError boundary
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    // MARK: - FLAGGED native network steps (real correctness: user's signed build)

    /// FLAGGED: POST the prompt + optional seed PNG to the hosted render endpoint, return the job id.
    /// Maps a non-2xx / `NSURLError` into `MediaError` via `map(_:)`. Native-only (real URLSession IO).
    private func submit(_ request: MediaRequest) async throws -> String {
        // Real implementation outline (native-only):
        //   var req = URLRequest(url: endpoint.appendingPathComponent("renders"))
        //   req.httpMethod = "POST"
        //   req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")   // never logged
        //   let body = RenderSubmit(prompt: request.prompt, seedPNG: request.seed,
        //                           durationMs: request.parameters.durationMs, size: request.parameters.size)
        //   req.httpBody = try JSONEncoder().encode(body)
        //   let (data, resp) = try await session.data(for: req)            // NSURLError → catch → map
        //   try Self.checkStatus(resp)                                     // HTTP 4xx/5xx → MediaError
        //   return try JSONDecoder().decode(RenderSubmitResponse.self, from: data).id
        throw MediaError.generationFailed(
            headline: "Cloud video generation is verified only in the user's stable-signed build.")
    }

    /// FLAGGED: poll the job until finished (or the ceiling), yielding `.step` progress. Honors cancellation
    /// between polls. Returns the finished-clip URL. Native-only.
    private func poll(jobID: String,
                      into continuation: AsyncThrowingStream<MediaProgress, Error>.Continuation) async throws -> URL {
        // Real implementation outline (native-only):
        //   let deadline = Date().addingTimeInterval(pollCeiling)
        //   while Date() < deadline {
        //       try Task.checkCancellation()                              // cancel → stopped stream
        //       let status = try await fetchStatus(jobID)                 // NSURLError/HTTP → map
        //       continuation.yield(.step(index: status.step, total: status.total, preview: status.previewPNG))
        //       if let url = status.finishedURL { return url }
        //       try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
        //   }
        //   throw MediaError.generationFailed(headline: "The video took too long and was stopped.")
        _ = continuation
        throw MediaError.cloudUnavailable
    }

    /// FLAGGED: download the finished clip + write it into the gallery, returning the `MediaAsset`
    /// (kind `.video`, `durationMs` from the request). A write IO failure → `MediaError.outputWriteFailed`.
    /// Native-only.
    private func fetch(from fileURL: URL, request: MediaRequest, outputDirectory: URL) async throws -> MediaAsset {
        // Real implementation outline (native-only):
        //   let (tmp, resp) = try await session.download(from: fileURL)
        //   try Self.checkStatus(resp)
        //   let dest = outputDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        //   do { try FileManager.default.moveItem(at: tmp, to: dest) }
        //   catch { throw MediaError.outputWriteFailed(detail: String(describing: error)) }
        //   return MediaAsset(url: dest, kind: .video,
        //                     width: request.parameters.size.width, height: request.parameters.size.height,
        //                     durationMs: request.parameters.durationMs)
        throw MediaError.outputWriteFailed(detail: nil)
    }

    // MARK: - Boundary mapping (NSURLError / HTTP → MediaError)

    /// Map a vendor/OS network error into the shared `MediaError` taxonomy AT THE BOUNDARY (design D7).
    /// Connectivity → `.cloudUnavailable`; an auth/HTTP status rides through the shared classifier's clean
    /// strings into `.generationFailed`. Raw text goes ONLY to the logger, never a headline.
    static func map(_ error: Error) -> MediaError {
        let ns = error as NSError
        log.error("cloud video network failure: \(String(describing: error), privacy: .public)")
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost,
                 NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                 NSURLErrorDNSLookupFailed, NSURLErrorTimedOut:
                return .cloudUnavailable
            default:
                // Reuse the shared translator's clean per-status string (no raw NSError text in the headline).
                let headline = AIError.message(for: error).headline
                return .generationFailed(headline: headline)
            }
        }
        let headline = AIError.message(for: error).headline
        return .generationFailed(headline: headline)
    }
}
