import Foundation

/// A scripted `MediaRuntime` for `swift test` (design: the stub makes the whole slice verifiable without
/// weights). It plays a fixed `Script` as a deterministic `AsyncThrowingStream<MediaProgress>` — the same
/// shape the real diffusion backends will emit — so the contributor, sink, seed path, gallery writer,
/// parked feed, and `MediaError` mapping are all exercised end-to-end with no MLX and no GPU.
///
/// Scripts cover every terminal shape the sink must handle:
///  - `.success(asset)`                 — straight to `.finished` (no intermediate previews).
///  - `.successWithPreviews(...)`       — a run of `.step` (with preview frames) then `.finished`.
///  - `.failMidFlight(steps:headline:)` — some `.step`s then a thrown `MediaError.generationFailed`.
///  - `.cancelImmediately`              — yields nothing and never finishes (the consumer cancels it; the
///                                        stream just stops — cancellation is observed as a stopped stream,
///                                        never a thrown failure, per design D10).
///
/// MLX-free Core (test support — `public` so the test target can build scripts).
public final class StubMediaRuntime: MediaRuntime, @unchecked Sendable {

    /// What the next `generate(_:)` call plays.
    public enum Script: Sendable {
        /// Emit `.finished(asset)` immediately.
        case success(MediaAsset)
        /// Emit `count` `.step`s (each carrying `preview`) then `.finished(asset)`.
        case successWithPreviews(count: Int, total: Int, preview: Data?, asset: MediaAsset)
        /// Emit `steps` `.step`s then THROW `MediaError.generationFailed(headline:)`.
        case failMidFlight(steps: Int, headline: String)
        /// Yield nothing and hold open until cancelled — models a discarded gen.
        case cancelImmediately
    }

    public let capabilities: Set<MediaKind>
    private let script: Script
    /// Records each request the sink drove (so tests assert the seed / kind / parameters wired through).
    public private(set) var receivedRequests: [MediaRequest] = []
    private let lock = NSLock()

    public init(capabilities: Set<MediaKind> = [.image], script: Script) {
        self.capabilities = capabilities
        self.script = script
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
                    // Hold open until the consumer cancels; never finish on our own. The consumer's
                    // cancellation stops the stream — observed as a stopped stream, not a thrown failure.
                    while !Task.isCancelled {
                        await Task.yield()
                    }
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
