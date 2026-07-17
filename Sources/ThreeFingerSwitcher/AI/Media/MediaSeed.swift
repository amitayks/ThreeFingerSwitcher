import Foundation

/// The seed (img2img / img2video) path (design D5). A `MediaRequest.seed: Data?` (PNG) is the first
/// frame, sourced from the EXISTING capture inputs — the interactive screen-region picker
/// (`.screenRegion`) and the on-demand live clipboard image (`.clipboardImage`, normalized to PNG) — the
/// same inputs the vision path already uses. NO new media-only picker; copying an image NEVER auto-fires a
/// gen (the clipboard read stays on-demand — the sink pulls it, nothing pushes).
///
/// This seam is pure orchestration over a captured/clipboard image; the concrete capture lives behind the
/// existing `SelectionProviding.readClipboardImage()` / the region picker (`ScreenCaptureOutcome`), which
/// the app wires in. MLX-free Core.
public protocol MediaSeedResolving: Sendable {
    /// The seed image (PNG) to use as the first frame, or `nil` when none is available. Pulled ON DEMAND
    /// (never pushed) — a clipboard image present here does NOT auto-fire a gen; the sink decides whether
    /// the routed tool actually requires it.
    func resolveSeed() -> Data?
}

/// A seed provider backed by a captured image (the screen-region `ScreenCaptureOutcome` or a clipboard
/// PNG already in hand). The app constructs it from whichever capture the user supplied. A pure value:
/// it just hands back the bytes it was given (the capture happened upstream, behind the existing seams).
public struct CapturedSeed: MediaSeedResolving {
    private let bytes: Data?

    /// Seed from raw PNG bytes (a clipboard image or a region capture already encoded to PNG).
    public init(png bytes: Data?) {
        self.bytes = bytes
    }

    /// Seed from a `ScreenCaptureOutcome`: a `.captured` carries bytes; `.permissionDenied`/`.unavailable`
    /// resolve to no seed (the sink turns a missing-but-required seed into `MediaError.seedRequired`).
    /// (Internal: `ScreenCaptureOutcome` is an internal capture type.)
    init(screenCapture: ScreenCaptureOutcome) {
        switch screenCapture {
        case let .captured(data): self.bytes = data
        case .permissionDenied, .unavailable: self.bytes = nil
        }
    }

    public func resolveSeed() -> Data? { bytes }
}

/// The no-seed default (a text-to-media run with no capture supplied). A tool authored as img2img/img2video
/// with this resolver yields `MediaError.seedRequired` at the sink — never a fabricated blank frame.
public struct NoSeed: MediaSeedResolving {
    public init() {}
    public func resolveSeed() -> Data? { nil }
}

// MARK: - PNG validation (boundary)

public enum MediaSeedValidation {
    /// The PNG 8-byte magic. A seed that is present but not a decodable PNG is `MediaError.seedInvalid`
    /// (design D5) — never silently passed to the backend. We validate the signature here (Core, no
    /// ImageIO) rather than a deep decode: the capture seams already normalize to PNG, so the magic is the
    /// honest, dependency-free "is this a real PNG" gate at this layer.
    static let pngMagic: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    /// True iff `data` begins with the PNG signature (a present, decodable-shaped seed).
    public static func isDecodablePNG(_ data: Data) -> Bool {
        guard data.count >= pngMagic.count else { return false }
        return Array(data.prefix(pngMagic.count)) == pngMagic
    }
}
