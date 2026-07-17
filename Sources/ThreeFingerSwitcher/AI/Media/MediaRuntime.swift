import Foundation

/// The generative-media seam + value types (addendum §B1, VERBATIM field shapes). A SECOND runtime seam,
/// parallel to `LLMRuntime` — NOT a token stream. A media generation is a LONG ASYNC JOB with step
/// progress that ends in a written file: `generate(_:)` returns an `AsyncThrowingStream<MediaProgress>`
/// that emits diffusion-step progress (with an optional intermediate preview frame) and terminates in a
/// `.finished(MediaAsset)` referencing the file on disk.
///
/// This slice (`ai-media-runtime`) OWNS the seam + the value types + the tools + the sink + the output;
/// it does NOT own the concrete backends. The concrete diffusion runtimes conform to `MediaRuntime` in
/// their own slices (`ai-local-image-generation`, `ai-video-animation-generation`) exactly as Gemma
/// conforms to `LLMRuntime` — and could be swapped without touching feature code. MLX-free Core: the
/// protocol + value types verify under `swift build`, and `StubMediaRuntime` drives the whole slice under
/// `swift test` without any weights.

// MARK: - Media kind

/// The kind of media a runtime produces (addendum §B1). Drives capability gating (a runtime advertises
/// the set it can serve) and the per-tool descriptor (`generate_image` vs `generate_video`).
public enum MediaKind: String, Codable, Sendable, CaseIterable {
    case image
    case video
}

// MARK: - Size

/// A pixel size (width × height) for a generation. Its own value type (addendum §B1 carries
/// `MediaParameters.size` as a `MediaSize`) so the size is a first-class, `Codable`, comparable value.
public struct MediaSize: Codable, Equatable, Sendable {
    public var width: Int
    public var height: Int

    public init(width: Int, height: Int) {
        self.width = width
        self.height = height
    }

    /// A reasonable square default for an image gen when the route omits a size.
    public static let square1024 = MediaSize(width: 1024, height: 1024)
}

// MARK: - Parameters

/// Generation parameters (addendum §B1 verbatim shape). `durationMs` is VIDEO-ONLY — an image request
/// carries it `nil`; a video request carries a positive value (the sink/backend ignores it for an image
/// kind). `seedNumber` is the RNG seed for reproducibility, DISTINCT from the seed IMAGE on the request.
public struct MediaParameters: Codable, Equatable, Sendable {
    /// width × height.
    public var size: MediaSize
    /// Diffusion steps.
    public var steps: Int
    /// RNG seed for reproducibility (nil → backend chooses).
    public var seedNumber: UInt64?
    /// Classifier-free guidance scale (nil → backend default).
    public var guidance: Double?
    /// Clip length in milliseconds — VIDEO ONLY (nil for images).
    public var durationMs: Int?

    public init(size: MediaSize = .square1024,
                steps: Int = 28,
                seedNumber: UInt64? = nil,
                guidance: Double? = nil,
                durationMs: Int? = nil) {
        self.size = size
        self.steps = steps
        self.seedNumber = seedNumber
        self.guidance = guidance
        self.durationMs = durationMs
    }
}

// MARK: - Request

/// A media generation request (addendum §B1 verbatim shape). `seed` is the optional SEED IMAGE (PNG)
/// for img2img / img2video — the screen-region / clipboard capture promoted to the first frame (design
/// D5). It is `Data?`, not a number: a `nil` seed is a text-to-media request; a present seed is
/// img2img/img2video. (The numeric RNG seed lives on `parameters.seedNumber`.)
public struct MediaRequest: Sendable {
    public var prompt: String
    /// Optional SEED IMAGE (PNG) for img2img / img2video — the existing screen-region / clipboard capture.
    public var seed: Data?
    public var kind: MediaKind
    public var parameters: MediaParameters

    public init(prompt: String,
                seed: Data? = nil,
                kind: MediaKind,
                parameters: MediaParameters = MediaParameters()) {
        self.prompt = prompt
        self.seed = seed
        self.kind = kind
        self.parameters = parameters
    }
}

// MARK: - Progress

/// Streamed progress of a generation (addendum §B1). `.step` carries the diffusion index/total plus an
/// OPTIONAL intermediate preview frame (PNG) the canvas paints live; `.finished` carries the terminal
/// asset. The stream THROWS on failure (mapped to `MediaError` at the boundary) and is cancelled on a
/// discard — cancellation is NOT a `.finished` and NOT a thrown failure (design D10).
public enum MediaProgress: Sendable {
    /// Streamed diffusion progress + an optional intermediate preview frame (PNG bytes).
    case step(index: Int, total: Int, preview: Data?)
    /// The terminal asset (a written file).
    case finished(MediaAsset)
}

// MARK: - Asset

/// A finished media asset (addendum §B1 verbatim shape). `url` is the written file — it becomes a
/// Files-band `.fileEntry` (the gallery, output #1) and the canvas preview/player source (output #2).
/// `durationMs` is video-only (nil for images). `Codable` so it can round-trip / be logged; `Identifiable`
/// so the canvas/rail can key on it.
public struct MediaAsset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    /// The written file (becomes a Files-band entry).
    public var url: URL
    public var kind: MediaKind
    public var width: Int
    public var height: Int
    /// Clip length in ms — VIDEO ONLY (nil for images).
    public var durationMs: Int?

    public init(id: UUID = UUID(),
                url: URL,
                kind: MediaKind,
                width: Int,
                height: Int,
                durationMs: Int? = nil) {
        self.id = id
        self.url = url
        self.kind = kind
        self.width = width
        self.height = height
        self.durationMs = durationMs
    }
}

// MARK: - The seam

/// The media runtime seam (addendum §B1 verbatim) — parallel to `LLMRuntime`, no extra methods. A
/// conformer advertises the kinds it can produce (`capabilities`) and runs a generation as an
/// `AsyncThrowingStream<MediaProgress, Error>`. The concrete backends live in their own native-linked
/// slices; this Core protocol is exercised in tests via `StubMediaRuntime`.
public protocol MediaRuntime: Sendable {
    /// The kinds this runtime can produce. The contributor advertises `generate_image`/`generate_video`
    /// only if a runtime advertises the matching kind (design D11) — the router never routes to a dead end.
    var capabilities: Set<MediaKind> { get }
    /// Run a generation. The stream emits `.step`/`.finished` and THROWS on failure; the consumer cancels
    /// it on a discard (cancellation is observed as a stopped stream, not a thrown failure).
    func generate(_ request: MediaRequest) -> AsyncThrowingStream<MediaProgress, Error>
}
