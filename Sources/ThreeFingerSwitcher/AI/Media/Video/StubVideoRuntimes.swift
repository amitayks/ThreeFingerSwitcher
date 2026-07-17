import Foundation

/// Scripted VIDEO `MediaRuntime` conformers for `swift test` (`ai-video-animation-generation`, tasks 5.1,
/// 5.2). They make the WHOLE slice — gating, budget, disclosure, parking, progress plumbing, error mapping
/// — verifiable without weights, network, or a hosted API key. Both advertise `capabilities = [.video]`
/// (so the contributor offers `generate_video` and the router never routes a video gen to the image
/// runtime), play a scripted `MediaProgress.step` run → `.finished(MediaAsset kind: .video, durationMs:)`,
/// and CONSUME the optional `MediaRequest.seed` (PNG) as the first frame for img2video — recording each
/// request so a test asserts the seed / kind / duration threaded through and that a seed-present run sets
/// the upload-disclosure flag.
///
/// `StubCloudVideoRuntime` models the hosted-API backend (bytes-leave path); `StubLocalVideoRuntime` models
/// the frontier local LTXV backend (no upload). They are byte-for-byte interchangeable at the seam — which
/// is exactly the swap contract (task 9.1). MLX-free Core.

// MARK: - Shared scripted base

/// A scripted video runtime base. `provider` only tags which disclosure a seed-present run builds (the
/// progress/asset shape is identical — that IS the point of the swap contract).
public final class ScriptedVideoRuntime: MediaRuntime, @unchecked Sendable {

    /// What the next `generate(_:)` plays — the terminal shapes the sink must handle for VIDEO.
    public enum Script: Sendable {
        /// Emit `.finished(asset)` immediately (a degenerate zero-step clip).
        case success(MediaAsset)
        /// Emit `count` render `.step`s (each carrying `preview`) then `.finished(asset)`.
        case successWithPreviews(count: Int, total: Int, preview: Data?, asset: MediaAsset)
        /// Emit `steps` `.step`s then THROW `MediaError.generationFailed(headline:)` (a failed render /
        /// failed upload, already mapped to a clean headline at the boundary).
        case failMidFlight(steps: Int, headline: String)
        /// Yield nothing and hold open until cancelled — models a discarded gen (a stopped stream, NOT a
        /// thrown failure — design D10).
        case cancelImmediately
    }

    /// Always video — never advertise `.image` (the router never routes a still to a video backend).
    public let capabilities: Set<MediaKind> = [.video]
    /// Which backend this stub models (only affects the disclosure flag for a seed-present run).
    public let provider: VideoProvider
    private let script: Script
    /// Records each request the sink drove (so tests assert the seed / kind / duration wired through).
    public private(set) var receivedRequests: [MediaRequest] = []
    private let lock = NSLock()

    public init(provider: VideoProvider, script: Script) {
        self.provider = provider
        self.script = script
    }

    /// The upload disclosure a routed request WOULD build for this provider — the stub exposes it so a test
    /// pins that a seed-present cloud run flags `bytesLeaveDevice && seedPresent` and a local run flags
    /// neither (task 5.2 / 7.x). Pure; no side effect.
    public func disclosure(for request: MediaRequest) -> VideoUploadDisclosure {
        VideoUploadDisclosure.make(provider: provider,
                                   prompt: request.prompt,
                                   seedPresent: request.seed != nil)
    }

    public func generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error> {
        lock.lock(); receivedRequests.append(request); lock.unlock()
        let script = self.script
        return AsyncThrowingStream { continuation in
            let task = Task {
                switch script {
                case let .success(asset):
                    continuation.yield(.finished(asset))
                    continuation.finish()
                case let .successWithPreviews(count, total, preview, asset):
                    for i in 0..<max(0, count) {
                        if Task.isCancelled { continuation.finish(); return }
                        continuation.yield(.step(index: i, total: total, preview: preview))
                    }
                    if Task.isCancelled { continuation.finish(); return }
                    continuation.yield(.finished(asset))
                    continuation.finish()
                case let .failMidFlight(steps, headline):
                    for i in 0..<max(0, steps) {
                        if Task.isCancelled { continuation.finish(); return }
                        continuation.yield(.step(index: i, total: steps, preview: nil))
                    }
                    continuation.finish(throwing: MediaError.generationFailed(headline: headline))
                case .cancelImmediately:
                    while !Task.isCancelled { await Task.yield() }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

// MARK: - The two named stubs (cloud default / local frontier)

/// The scripted CLOUD-escalation video backend (bytes leave the device). A thin alias-constructor over
/// `ScriptedVideoRuntime(provider: .cloud, …)` so tests + the wiring read intent-fully.
public enum StubCloudVideoRuntime {
    public static func make(script: ScriptedVideoRuntime.Script) -> ScriptedVideoRuntime {
        ScriptedVideoRuntime(provider: .cloud, script: script)
    }
}

/// The scripted LOCAL-LTXV frontier video backend (nothing uploaded). Same seam, same shapes — the swap
/// contract (task 9.1) means feature code can't tell them apart except via the disclosure flag.
public enum StubLocalVideoRuntime {
    public static func make(script: ScriptedVideoRuntime.Script) -> ScriptedVideoRuntime {
        ScriptedVideoRuntime(provider: .localLTXV, script: script)
    }
}

// MARK: - A finished-video asset helper

public extension MediaAsset {
    /// Build a finished VIDEO asset (kind `.video`, `durationMs` set) — the terminal shape both video
    /// backends emit. Convenience for scripts + tests so the `durationMs != nil` invariant is upheld.
    static func video(url: URL, width: Int, height: Int, durationMs: Int) -> MediaAsset {
        MediaAsset(url: url, kind: .video, width: width, height: height, durationMs: durationMs)
    }
}
