// MFluxImageRuntime — the concrete LOCAL IMAGE `MediaRuntime`, backed by FLUX.2 Klein 4B (Apache-2.0)
// running in-process via MLX through the `flux-2-swift-mlx` package (`Flux2Core` / `FluxTextEncoders`).
// (`ai-local-image-generation` §4, design D1/D2/D6/D7.)
//
// FLAGGED: user xcodebuild + stable-signed build.
//
// This is the SECOND media seam's FIRST concrete backend (parallel to how `GemmaMLXRuntime` is the chat
// seam's backend) — a `MediaRuntime` conformer, NOT a new seam (design D1). It links MLX and runs the
// FLUX.2 diffusion graph IN-PROCESS (design D2), so it is `xcodebuild` COMPILE-VERIFY ONLY here: the agent
// never builds/signs/installs the `.app` (ad-hoc signing breaks TCC; the metallib `*.bundle` copy in
// `build-app.sh` must not regress — no GPU use without it, task 4.4). REAL correctness — actual image
// output, the step preview, latency, seed reproducibility, Q4 co-residency / FP16 evict-chat — is the
// USER's stable-signed run-verify (tasks 4.x / 6.3).
//
// THE MODEL (real, Apache-2.0): both catalog variants are **FLUX.2 Klein 4B** — the OPEN FLUX.2 variant
// (`black-forest-labs/FLUX.2-klein-4B`, ungated, commercial-use OK), with the Qwen3-4B text encoder
// (Apache 2.0) and the small-decoder VAE (Apache 2.0). Q4 = the package's on-the-fly int4 quantization
// (~7 GB resident, co-resides with chat); FP16 = bf16 weights (~24 GB, evicts chat). We DELIBERATELY do
// NOT ship FLUX.2-dev (BFL non-commercial) or Klein 9B (non-commercial). The pipeline is built from
// `Flux2Pipeline(model: .klein4B, …)` and its multi-file weights are downloaded by the package's own HF
// downloader into our model-cache dir (`ModelRegistry.customModelsDirectory = weightsURL`).
//
// IN-PROCESS, ONE BUDGET (design D2): the diffusion weights are resident under the SAME fleet 48 GB
// unified-memory budget as chat — Q4 (~7 GB) co-resides, FP16 (~24 GB) evicts chat. Residency is the
// fleet's DECISION (`ModelRegistry.ensureResident`) consumed via the existing `ModelProvisioner` /
// `runtimeFactory` lifecycle (task 4.4); this runtime does NOT add a second resident-weights path.
//
// ERROR TAXONOMY (design D7): every vendor/OS failure (`Flux2Error` load/OOM/Metal fault, denoise failure,
// PNG-write IO, capability mismatch) is mapped INTO `MediaError` AT THIS BOUNDARY — Core stays MLX-free.
// Feature/UI code only ever sees `MediaError`, surfaced through `AIError.message(for:)` as a clean bounded
// headline (raw vendor text only in logs / opt-in copyable details — never a headline, never an `NSAlert`).
// A gen that fails to land is `.failed`; CANCELLATION is a stopped stream, NOT a failure (design D10): the
// stream finishes WITHOUT a `.finished` and WITHOUT throwing.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import os
import ThreeFingerSwitcherCore
import Flux2Core

public final class MFluxImageRuntime: MediaRuntime, @unchecked Sendable {

    static let log = Logger(subsystem: "ThreeFingerSwitcher", category: "MFluxImageRuntime")

    /// This backend produces IMAGES only (design D1 / spec "capabilities advertise image only"). Video is
    /// `ai-video-animation-generation`'s backend — never advertised here, so the router never routes a
    /// video gen to this runtime.
    public let capabilities: Set<MediaKind> = [.image]

    /// The chosen image descriptor (Q4 / FP16, selected by `imageModelID` upstream). Its
    /// `ImageModelCatalog` capability tags gate the seed (img2img) branch; its `residencyBytes` is the
    /// fleet's budget input (consumed, not re-derived). Its `quantization` selects int4 vs bf16 below.
    private let descriptor: ModelDescriptor
    /// On-disk path to the diffusion weights (the package's multi-file HF cache root for this variant).
    private let weightsURL: URL
    /// Where finished PNGs are written (the gallery root — becomes a Files-band `.fileEntry`).
    private let outputDirectory: URL
    /// The resident FLUX.2 pipeline, set ONLY once `loadResident()` actually builds it. While the pipeline
    /// is unbuilt this stays `nil`, so `isPrepared`/`preparedSnapshot()` read false and `generate`
    /// short-circuits to a clean `MediaError` — a "prepared" runtime can NEVER have a missing pipeline, so
    /// the unbuilt-pipeline path can never paint a fake/blank result. Typed `Flux2Pipeline?` now that the
    /// concrete backend is wired.
    private var pipeline: Flux2Pipeline?
    /// True once the diffusion graph is loaded resident AND the pipeline is built. Gated on `pipeline`,
    /// so a missing-model / unbuilt-pipeline `prepare()` never reports a false "ready".
    private var isPrepared: Bool { pipeline != nil }
    private let lock = NSLock()

    public init(descriptor: ModelDescriptor,
                weightsURL: URL,
                outputDirectory: URL) {
        self.descriptor = descriptor
        self.weightsURL = weightsURL
        self.outputDirectory = outputDirectory
    }

    // MARK: - Quantization mapping (descriptor → Flux2 config)

    /// Map the catalog descriptor's `quantization` to a `Flux2QuantizationConfig` for Klein 4B:
    ///   - Q4 (`.qat4bit`) → int4 transformer (on-the-fly) + 8-bit Qwen3 encoder ≈ ~7 GB resident.
    ///   - FP16 (`.fp16`)  → bf16 transformer + bf16-class encoder ≈ ~24 GB resident.
    /// Any other descriptor (shouldn't happen — only the two image variants reach here) defaults to int4.
    private var fluxQuantization: Flux2QuantizationConfig {
        switch descriptor.quantization {
        case .fp16:
            return Flux2QuantizationConfig(textEncoder: .bf16, transformer: .bf16)
        default:
            return Flux2QuantizationConfig(textEncoder: .mlx8bit, transformer: .int4)
        }
    }

    // MARK: - Preparation (resident load via the fleet lifecycle — task 4.4)

    /// Load the diffusion graph resident on the GPU lane. The actual residency/eviction DECISION is the
    /// fleet's (`ModelRegistry.ensureResident(descriptor.id)`, run by the sink BEFORE this) — this only
    /// brings THIS runtime's weights up through the existing `ModelProvisioner` / `runtimeFactory` seam
    /// (no second resident-weights path). Maps any native load failure into `MediaError` at the boundary.
    public func prepare() async throws {
        lock.lock(); let already = isPrepared; lock.unlock()
        if already { return }
        do {
            // Build the resident pipeline (download the multi-file FLUX.2 weights if missing, then ready
            // the pipeline). On success `pipeline` is non-nil and `isPrepared` reads true; on any failure
            // `loadResident` throws (mapped below) and `pipeline` stays nil — a "prepared" runtime is NEVER
            // one with a missing pipeline (the honest-failure invariant). A subsequent `generate` then
            // short-circuits to a clean `MediaError`, never a blank PNG.
            let built = try await loadResident()
            lock.lock(); pipeline = built; lock.unlock()
        } catch let e as MediaError {
            throw e
        } catch is CancellationError {
            // Cancellation is NOT a failure — leave `pipeline` nil and rethrow so the caller treats it as a
            // stopped preparation, not a `.failed`.
            throw CancellationError()
        } catch {
            // Flux2/MLX init / Metal / download / file-IO failure → mapped at THIS boundary (design D7).
            // Raw text rides only into logs / copyable details, never a headline.
            Self.log.error("image model load failed: \(String(describing: error), privacy: .public)")
            throw Self.mediaError(for: error, fallbackHeadline: "The image model couldn't be loaded.")
        }
    }

    /// The real resident load — point the FLUX.2 package's model cache at our weights dir, build the
    /// `Flux2Pipeline` for the chosen Klein 4B variant, and download/ready its multi-file weights. Returns
    /// the built pipeline (any thrown `Flux2Error`/`URLError`/IO error is mapped into `MediaError` by
    /// `prepare()`). Native-only; the agent compile-verifies the seam. Requires the metallib `*.bundle` in
    /// `Contents/Resources/` (task 4.4) — no GPU use without it.
    private func loadResident() async throws -> Flux2Pipeline {
        try Task.checkCancellation()

        // Route the package's multi-file model cache (transformer + Qwen3 encoder + small-decoder VAE) to
        // OUR per-variant weights dir — the same cache root the chat path uses (`makeImageRuntime` derives
        // it from the descriptor's HF repo path). This is the SINGLE on-disk weights location for both the
        // download and the `isFullyDownloaded` probe — no second resident-weights path.
        try FileManager.default.createDirectory(at: weightsURL, withIntermediateDirectories: true)
        ModelRegistry.customModelsDirectory = weightsURL

        // FLUX.2 Klein 4B (Apache-2.0). small-decoder VAE (Apache-2.0). Memory optimization is auto-detected
        // from system RAM by the pipeline's own init default.
        let pipeline = Flux2Pipeline(
            model: .klein4B,
            quantization: fluxQuantization,
            vaeVariant: .smallDecoder
        )

        // `loadModels()` downloads the missing weight/config files (the package's HF downloader handles the
        // full multi-file set) and readies the pipeline; weights materialize on the GPU lazily at first
        // generate. A network/HF failure throws here and is mapped at the boundary by `prepare()`.
        Self.log.notice("loadResident: readying FLUX.2 Klein 4B pipeline (download if needed)…")
        try await pipeline.loadModels(progressCallback: nil)
        try Task.checkCancellation()
        Self.log.notice("loadResident: pipeline ready ✓")
        return pipeline
    }

    // MARK: - Generation (the denoise loop — tasks 4.1 / 4.2)

    public func generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error> {
        let descriptor = self.descriptor
        let outputDirectory = self.outputDirectory
        return AsyncThrowingStream { continuation in
            let task = Task {
                // (1) BOUNDARY VALIDATION — the SAME pure gate the stub runs (Core): kind, seed capability
                // (a seed against a non-`img2img` descriptor → clean `MediaError`, never a silent t2i
                // fallback, design D6), and param bounds. A bad request throws a clean `MediaError` and
                // NEVER paints.
                if let err = ImageRequestValidator.validate(request, descriptor: descriptor) {
                    continuation.finish(throwing: err)
                    return
                }
                // (1b) READY THE MODEL — lazily build (download + load) the FLUX.2 pipeline on FIRST use.
                // The `MediaRuntime` protocol has no `prepare()`, and the sink's residency pass only makes
                // ROOM (the fleet's eviction decision) — it never readies THIS runtime. So `generate` self-
                // prepares: the first generation downloads the multi-file weights + builds the diffusion
                // graph (slow once, then resident), later ones reuse it. A load/download failure → a clean
                // mapped `MediaError` (never a silent "isn't ready" with no attempt); cancellation → a
                // stopped stream, never a `.failed`.
                let pipeline: Flux2Pipeline
                do {
                    pipeline = try await self.ensurePrepared()
                } catch is CancellationError {
                    continuation.finish()
                    return
                } catch let e as MediaError {
                    continuation.finish(throwing: e)
                    return
                } catch let flux as Flux2Error where Self.isCancellation(flux) {
                    continuation.finish()
                    return
                } catch {
                    Self.log.error("image model load failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: Self.mediaError(for: error, fallbackHeadline: "The image model couldn't be loaded."))
                    return
                }

                do {
                    // (2) SEED → img2img (task 4.2). When `request.seed` is present it is the PNG first
                    // frame: run conditioning-mode image-to-image. Absent → text-to-image. The numeric
                    // `parameters.seedNumber` drives reproducible RNG.
                    let asset = try await self.denoise(request,
                                                       pipeline: pipeline,
                                                       into: continuation,
                                                       outputDirectory: outputDirectory)
                    continuation.yield(.finished(asset))
                    continuation.finish()
                } catch is CancellationError {
                    // CANCELLATION is a stopped stream, NOT a failure (design D10): finish WITHOUT a
                    // `.finished` and WITHOUT throwing.
                    continuation.finish()
                } catch let e as MediaError {
                    continuation.finish(throwing: e)
                } catch let flux as Flux2Error where Self.isCancellation(flux) {
                    continuation.finish()
                } catch {
                    // Flux2/MLX denoise / OOM / Metal fault → mapped at the boundary into a clean headline.
                    Self.log.error("image denoise failed: \(String(describing: error), privacy: .public)")
                    continuation.finish(throwing: Self.mediaError(for: error, fallbackHeadline: "The image couldn't be generated."))
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The real FLUX.2 denoise. It drives the pipeline's `generate*WithResult` call, streaming `.step`
    /// progress from the pipeline's `onProgress` callback and an OPTIONAL intermediate `preview` from its
    /// `onCheckpoint` callback (gated to ~every Nth step so it never dominates step time — design D1). It
    /// honors cancellation at the boundaries (`try Task.checkCancellation()` before the call and after the
    /// result, plus a flag the callbacks read). After the pipeline returns the final `CGImage` it encodes
    /// it to PNG, WRITES it to `outputDirectory`, and returns the `MediaAsset` (dimensions = the request
    /// size). A PNG-write IO failure maps to `MediaError.outputWriteFailed` (raw OS reason → copyable
    /// details, never a headline). Native-only.
    ///
    /// img2img branch (task 4.2): when `request.seed != nil`, decode the seed PNG and run conditioning-mode
    /// image-to-image with it as the single reference (`generateImageToImageWithResult(imageData:)`).
    /// `parameters.seedNumber` seeds the RNG for reproducibility (a fixed seedNumber + identical
    /// prompt/params reproduces an image).
    ///
    /// NOTE on cancellation: `Flux2Pipeline.generate*` does NOT poll Task cancellation inside its denoise
    /// loop (same limitation as the chat `chatStream` path), so a discard cannot stop the in-flight GPU
    /// work mid-step — but we never yield a `.finished` after a cancel: the post-call
    /// `Task.checkCancellation()` throws and the stream ends as a stopped stream (no false "Done").
    private func denoise(_ request: MediaRequest,
                         pipeline: Flux2Pipeline,
                         into continuation: AsyncThrowingStream<MediaProgress, Error>.Continuation,
                         outputDirectory: URL) async throws -> MediaAsset {
        try Task.checkCancellation()

        let params = request.parameters
        let width = params.size.width
        let height = params.size.height
        let steps = params.steps
        // Klein 4B is CFG-distilled at guidance 1.0; honor an explicit guidance if the route supplied one,
        // else fall back to the model's recommended default.
        let guidance = params.guidance.map { Float($0) } ?? Flux2Model.klein4B.defaultGuidance

        // Gate the intermediate preview: decode a checkpoint image roughly every quarter of the run (at
        // least every step for very short runs), but never more than ~6 previews total — so the VAE decode
        // for the preview never dominates step time (design D1). `nil` interval → no checkpoint callback.
        let checkpointInterval: Int? = steps >= 4 ? max(1, steps / 4) : nil

        // The pipeline callbacks are `@Sendable` and fire from the generation task; the continuation is
        // Sendable, so streaming step/preview progress from inside them is safe. `nonisolated(unsafe)` to
        // carry the non-Sendable nothing here — the continuation itself is Sendable.
        let sink = continuation
        let onProgress: Flux2ProgressCallback = { current, total in
            // `current` is 1-based from the pipeline; the seam's `.step` index is 0-based.
            sink.yield(.step(index: max(0, current - 1), total: total, preview: nil))
        }
        let onCheckpoint: Flux2CheckpointCallback = { step, image in
            // A REAL intermediate frame — encode the checkpoint CGImage to PNG and ride it as the optional
            // `preview` on a `.step`. If PNG encoding fails we simply omit the preview (never fake one).
            let preview = MFluxImageRuntime.pngData(from: image)
            sink.yield(.step(index: max(0, step - 1), total: steps, preview: preview))
        }

        let image: CGImage
        if let seed = request.seed {
            // img2img: the seed PNG is the conditioning reference. A non-decodable capture → `.seedInvalid`.
            guard Self.cgImage(fromPNG: seed) != nil else {
                throw MediaError.seedInvalid
            }
            Self.log.notice("denoise: img2img (\(width)x\(height), \(steps) steps)…")
            let result = try await pipeline.generateImageToImageWithResult(
                prompt: request.prompt,
                imageData: [seed],
                height: height,
                width: width,
                steps: steps,
                guidance: guidance,
                seed: params.seedNumber,
                upsamplePrompt: false,
                checkpointInterval: checkpointInterval,
                onProgress: onProgress,
                onCheckpoint: onCheckpoint
            )
            image = result.image
        } else {
            Self.log.notice("denoise: text-to-image (\(width)x\(height), \(steps) steps)…")
            let result = try await pipeline.generateTextToImageWithResult(
                prompt: request.prompt,
                height: height,
                width: width,
                steps: steps,
                guidance: guidance,
                seed: params.seedNumber,
                upsamplePrompt: false,
                checkpointInterval: checkpointInterval,
                onProgress: onProgress,
                onCheckpoint: onCheckpoint
            )
            image = result.image
        }

        // A discard during the (uncancellable) denoise → end as a stopped stream, never a false `.finished`.
        try Task.checkCancellation()

        // Encode the final image to PNG and write it into the gallery. The asset dimensions are the actual
        // produced image's (the pipeline may clamp/round the request size to a valid latent grid).
        let url = try writePNG(image, into: outputDirectory)
        Self.log.notice("denoise: wrote \(url.lastPathComponent, privacy: .public) (\(image.width)x\(image.height)) ✓")
        return MediaAsset(url: url,
                          kind: .image,
                          width: image.width,
                          height: image.height)
    }

    // MARK: - PNG IO

    /// Encode a `CGImage` to PNG `Data` (nil on failure). Used both for the final asset and the optional
    /// intermediate preview frame.
    static func pngData(from image: CGImage) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    /// Decode PNG `Data` to a `CGImage` (nil if undecodable) — the img2img seed-validity check.
    static func cgImage(fromPNG data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }

    /// Write the final image as a PNG into `directory`, returning the file URL. Maps any encode/IO failure
    /// to `MediaError.outputWriteFailed` (raw OS reason → copyable detail, never the headline).
    private func writePNG(_ image: CGImage, into directory: URL) throws -> URL {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw MediaError.outputWriteFailed(detail: String(describing: error))
        }
        guard let data = Self.pngData(from: image) else {
            throw MediaError.outputWriteFailed(detail: "Could not encode the generated image to PNG.")
        }
        let name = "image-\(ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-"))-\(UUID().uuidString.prefix(8)).png"
        let url = directory.appendingPathComponent(name)
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw MediaError.outputWriteFailed(detail: String(describing: error))
        }
        return url
    }

    // MARK: - Error mapping (vendor/OS → MediaError, at THIS boundary)

    /// Whether a `Flux2Error` represents a user-driven cancellation (NOT a failure — design D10).
    static func isCancellation(_ error: Flux2Error) -> Bool {
        if case .generationCancelled = error { return true }
        return false
    }

    /// Map a vendor/OS error into the `MediaError` taxonomy. The Flux2 cases carry user-actionable meaning
    /// (insufficient memory, model-not-loaded) that we translate to a CLEAN headline; everything else falls
    /// back to the supplied generic headline. Raw vendor text rides ONLY into logs / `copyableDetails`,
    /// never a headline (the ban on raw interpolation in UI strings).
    static func mediaError(for error: Error, fallbackHeadline: String) -> MediaError {
        if let flux = error as? Flux2Error {
            switch flux {
            case .insufficientMemory:
                return .generationFailed(headline: "Not enough memory to run the image model right now.")
            case .modelNotLoaded, .weightLoadingFailed:
                return .generationFailed(headline: "The image model isn't installed yet.")
            case .generationCancelled:
                // Caller should have treated this as cancellation; defensively map to a clean headline.
                return .generationFailed(headline: fallbackHeadline)
            case .invalidConfiguration, .imageProcessingFailed, .generationFailed:
                return .generationFailed(headline: fallbackHeadline)
            }
        }
        return .generationFailed(headline: fallbackHeadline)
    }

    // MARK: - Resident snapshot

    private func preparedPipeline() -> Flux2Pipeline? {
        lock.lock(); defer { lock.unlock() }; return pipeline
    }

    /// Return the resident pipeline, BUILDING it (download + load) on first use. The single readiness path
    /// `generate` uses: a built pipeline is reused; otherwise `prepare()` downloads the multi-file FLUX.2
    /// weights + builds the diffusion graph (its lock + `already` short-circuit serialize a concurrent
    /// first call). A load/download failure propagates as a mapped `MediaError`/`CancellationError` (handled
    /// by `generate`), never a fake result.
    private func ensurePrepared() async throws -> Flux2Pipeline {
        if let ready = preparedPipeline() { return ready }
        try await prepare()
        guard let built = preparedPipeline() else {
            throw MediaError.generationFailed(headline: "The image model isn't ready yet.")
        }
        return built
    }
}
