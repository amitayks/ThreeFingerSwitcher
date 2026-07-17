// LocalLTXVRuntime — the concrete FRONTIER LOCAL VIDEO `MediaRuntime` over a ComfyUI/MPS LTXV graph
// (ai-video-animation-generation §5.4, design D1/D2/D6/D7).
//
// FLAGGED: user xcodebuild + stable-signed build.
//
// This is the SECOND video backend behind the SAME `MediaRuntime` seam (the swap contract, design D8 /
// task 9.1) — a conformer selected by `videoProvider == .localLTXV`, NOT a new seam. It is the FRONTIER
// option behind the master `fullPotentialEnabled` toggle, and it is HONEST about its cost: an LTXV ComfyUI
// graph is 35 GB+ of weights (NOT in-process MLX — a `Process` bridge to a ComfyUI/MPS pipeline), it runs
// MINUTES PER CLIP, it EVICTS chat under the 48 GB budget (the assistant goes quiet while it paints — the
// fleet residency decision §C1, consumed by the sink), and it runs the Mac HOT. None of that is hidden:
// the selection disclosure (`VideoUploadDisclosure.localCostLine`) states it in the same breath it is
// offered.
//
// It SPENDS NO MONEY + UPLOADS NOTHING (design D6): off the cloud budget/ledger path entirely. It is still
// AUDITED (every attempt → one record) and still PARKS (it is slow). The gating (`fullPotentialEnabled &&
// mediaGenEnabled`) lives UPSTREAM (the contributor / `VideoTierResolver`); this runtime is the executor.
//
// `xcodebuild` COMPILE-VERIFY ONLY here: the agent never builds/signs/installs the `.app`. REAL
// correctness — 35 GB residency, minutes-per-clip latency, real chat eviction, real thermals, a real clip
// — is the USER's stable-signed run-verify (task 5.4).
//
// ERROR TAXONOMY (design D7 / task 8.1): every `Process` / ComfyUI / MPS / file-IO failure is mapped INTO
// `MediaError` AT THIS BOUNDARY (Core stays MLX-/process-free). Feature/UI code only ever sees `MediaError`,
// surfaced through `AIError.message(for:)` (clean headline; raw text only in logs / copyable details —
// never a headline, never an `NSAlert`). A render that fails to land is `.failed` (never a false Done);
// CANCELLATION is a stopped stream, NOT a failure (design D10).

import Foundation
import os
import ThreeFingerSwitcherCore

public final class LocalLTXVRuntime: MediaRuntime, @unchecked Sendable {

    static let log = Logger(subsystem: "ThreeFingerSwitcher", category: "LocalLTXVRuntime")

    /// VIDEO only — never `.image` (the router never routes a still here, design D1).
    public let capabilities: Set<MediaKind> = [.video]

    /// The chosen LTXV descriptor (its `residencyBytes` — tens of GB — is the fleet's eviction-budget input,
    /// consumed not re-derived; admitting it EVICTS chat).
    private let descriptor: ModelDescriptor
    /// On-disk path to the 35 GB+ LTXV ComfyUI graph weights (downloaded once, behind the master toggle).
    private let weightsURL: URL
    /// The ComfyUI server / python entrypoint the `Process` bridge drives.
    private let comfyExecutableURL: URL
    /// Where finished clips are written (the gallery root — becomes a Files-band `.fileEntry`).
    private let outputDirectory: URL
    private var isPrepared = false
    private let lock = NSLock()

    public init(descriptor: ModelDescriptor,
                weightsURL: URL,
                comfyExecutableURL: URL,
                outputDirectory: URL) {
        self.descriptor = descriptor
        self.weightsURL = weightsURL
        self.comfyExecutableURL = comfyExecutableURL
        self.outputDirectory = outputDirectory
    }

    // MARK: - Preparation (resident graph via the fleet lifecycle)

    /// Bring the LTXV ComfyUI graph up. The residency/EVICTION decision is the fleet's
    /// (`ModelRegistry.ensureResident(descriptor.id)`, run by the sink BEFORE this — it evicts chat) — this
    /// only starts THIS runtime's graph through the `Process` bridge. Maps any native failure into
    /// `MediaError` at the boundary.
    public func prepare() async throws {
        lock.lock(); let already = isPrepared; lock.unlock()
        if already { return }
        guard FileManager.default.fileExists(atPath: weightsURL.path) else {
            throw MediaError.generationFailed(headline: "The local video model isn't installed yet.")
        }
        do {
            try await startComfy()
            lock.lock(); isPrepared = true; lock.unlock()
        } catch let e as MediaError {
            throw e
        } catch {
            Self.log.error("LTXV graph start failed: \(String(describing: error), privacy: .public)")
            throw MediaError.generationFailed(headline: "The local video model couldn't be started.")
        }
    }

    /// FLAGGED: launch the ComfyUI/MPS server (`Process` over `comfyExecutableURL`), load the LTXV graph
    /// from `weightsURL`, wait for ready. Native-only; the agent compile-verifies the seam.
    private func startComfy() async throws {
        // Real implementation: spawn the ComfyUI server Process, POST the graph, await /system_stats ready.
        // Any thrown `Process`/socket error is caught by `prepare()` and mapped into `MediaError`.
    }

    // MARK: - Generation (queue the graph → poll render → write clip — task 5.4)

    public func generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error> {
        let outputDirectory = self.outputDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                // A present-but-undecodable seed is a clean `MediaError.seedInvalid` (never fed to the graph).
                if let seed = request.seed, !MediaSeedValidation.isDecodablePNG(seed) {
                    continuation.finish(throwing: MediaError.seedInvalid)
                    return
                }
                guard self.preparedSnapshot() else {
                    continuation.finish(throwing: MediaError.generationFailed(
                        headline: "The local video model isn't ready yet."))
                    return
                }
                do {
                    let asset = try await self.render(request, into: continuation, outputDirectory: outputDirectory)
                    continuation.yield(.finished(asset))
                    continuation.finish()
                } catch is CancellationError {
                    continuation.finish()                       // discard → stopped stream, NOT a failure
                } catch let e as MediaError {
                    continuation.finish(throwing: e)
                } catch {
                    Self.log.error("LTXV render failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: MediaError.generationFailed(
                        headline: "The video couldn't be generated."))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// FLAGGED: queue the LTXV graph (prompt + optional seed PNG as the first frame for img2video), poll the
    /// ComfyUI render progress yielding `.step(index:total:preview:)`, honor cancellation between steps, then
    /// move the finished clip into `outputDirectory` and return the `MediaAsset` (kind `.video`, `durationMs`
    /// from the request). A `Process`/ComfyUI error maps to `.generationFailed`; a write IO error to
    /// `.outputWriteFailed`. Native-only (real residency / latency / heat is the user's signed build).
    private func render(_ request: MediaRequest,
                        into continuation: AsyncThrowingStream<MediaProgress, Error>.Continuation,
                        outputDirectory: URL) async throws -> MediaAsset {
        // Real implementation outline (native-only):
        //   let promptID = try await queue(graph: buildGraph(request))      // Process/ComfyUI → MediaError
        //   let total = request.parameters.steps
        //   while true {
        //       try Task.checkCancellation()                                // cancel → stopped stream
        //       let p = try await progress(promptID)
        //       continuation.yield(.step(index: p.step, total: total, preview: p.previewPNG))
        //       if let clip = p.finishedClipURL {
        //           let dest = outputDirectory.appendingPathComponent("\(UUID().uuidString).mp4")
        //           do { try FileManager.default.moveItem(at: clip, to: dest) }
        //           catch { throw MediaError.outputWriteFailed(detail: String(describing: error)) }
        //           return MediaAsset(url: dest, kind: .video,
        //                             width: request.parameters.size.width, height: request.parameters.size.height,
        //                             durationMs: request.parameters.durationMs)
        //       }
        //   }
        _ = continuation
        throw MediaError.generationFailed(
            headline: "Local video generation is verified only in the user's stable-signed build.")
    }

    private func preparedSnapshot() -> Bool {
        lock.lock(); defer { lock.unlock() }; return isPrepared
    }
}
