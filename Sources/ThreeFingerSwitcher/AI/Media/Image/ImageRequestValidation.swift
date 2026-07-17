import Foundation

/// Pure validation of a `MediaRequest` for the LOCAL IMAGE backend (design D6, task 3.1). The image
/// runtime (native-linked) and the stub both run this at the boundary BEFORE any compute, so a malformed
/// request, an out-of-range parameter, or a seed against a non-seed-capable descriptor is a `MediaError`
/// VALUE — never a silent text-only fallback, never compute on a bad request.
///
/// It validates against the supported ranges of the CHOSEN image descriptor (selected via `imageModelID`,
/// resolved by `ImageModelCatalog`), and the descriptor's seed CAPABILITY TAGS (`ImageModelCatalog.tags`):
/// a non-nil `seed` (img2img) statically REQUIRES a descriptor advertising `img2img`. This mirrors the
/// chat runtime's vision-required static rule (no degrade): a seed against a t2i-only selection maps to a
/// `MediaError` at the boundary and is surfaced as a bounded, non-blocking failure (the seam carries only
/// `MediaRequest.seed: Data?` — this slice does NOT add a mask field; design D6).
///
/// MLX-free Core — `swift test`-verified (valid t2i passes; valid img2img w/ seed-capable descriptor
/// passes; seed vs non-seed descriptor → mismatch error; out-of-range params rejected).
public enum ImageRequestValidator {

    /// The supported parameter ranges for an image generation. Aligned with the seam's `generate_image`
    /// args schema (`MediaToolContributor.imageArgsSchemaJSON`: width/height 64…2048, steps 1…100) so a
    /// route the schema admitted validates here too; guidance is an open positive range (nil → backend
    /// default). These are the image-backend bounds — the descriptor's "supported ranges" the spec names.
    public struct Bounds: Sendable, Equatable {
        public var minDimension: Int
        public var maxDimension: Int
        public var minSteps: Int
        public var maxSteps: Int
        public var maxGuidance: Double

        public init(minDimension: Int = 64, maxDimension: Int = 2048,
                    minSteps: Int = 1, maxSteps: Int = 100,
                    maxGuidance: Double = 50) {
            self.minDimension = minDimension
            self.maxDimension = maxDimension
            self.minSteps = minSteps
            self.maxSteps = maxSteps
            self.maxGuidance = maxGuidance
        }

        public static let `default` = Bounds()
    }

    /// Validate `request` against `descriptor` (the chosen image variant) and `bounds`.
    ///
    /// Returns `nil` on success; a `MediaError` VALUE on the first failure (the caller maps it through
    /// `AIError.message(for:)` → a clean bounded headline, never a degrade). Order: kind → seed capability
    /// → param bounds. A seed-bearing request against a non-`img2img` descriptor is the mismatch case.
    public static func validate(_ request: MediaRequest,
                                descriptor: ModelDescriptor,
                                bounds: Bounds = .default) -> MediaError? {

        // (1) KIND — this backend serves images only. A non-image request here is a routing bug (the
        // contributor only routes `.image` to the image runtime) — surface it, don't paint.
        guard request.kind == .image else {
            return .noCapableBackend(kind: request.kind)
        }

        // (2) SEED CAPABILITY — a non-nil seed (img2img / inpaint) STATICALLY requires a seed-capable
        // descriptor (advertises `img2img`). Mismatch → a clean `MediaError`, NEVER a silent t2i fallback
        // (design D6). A nil seed is plain text-to-image and needs no seed capability.
        if request.seed != nil, !ImageModelCatalog.isSeedCapable(descriptor.id) {
            // The seed cannot be honored by this selection; surface it as a generation failure carrying a
            // clean headline (the boundary's job is to refuse, not degrade). `.seedRequired` would imply a
            // missing seed; here the seed is PRESENT but the descriptor can't use it — a capability
            // mismatch, surfaced as a clean generationFailed headline.
            return .generationFailed(headline: "This image model can't generate from a source image. Choose a model that supports image-to-image.")
        }

        // (3) PARAM BOUNDS — size + steps within the descriptor's supported ranges. Out-of-range → reject
        // (a route the schema let through with absurd values, or a programmatic request, never paints
        // garbage). Guidance, when present, must be a sane positive scale.
        let size = request.parameters.size
        if size.width < bounds.minDimension || size.width > bounds.maxDimension
            || size.height < bounds.minDimension || size.height > bounds.maxDimension {
            return .generationFailed(headline: "That image size is out of range (\(bounds.minDimension)–\(bounds.maxDimension) px per side).")
        }
        let steps = request.parameters.steps
        if steps < bounds.minSteps || steps > bounds.maxSteps {
            return .generationFailed(headline: "That step count is out of range (\(bounds.minSteps)–\(bounds.maxSteps)).")
        }
        if let g = request.parameters.guidance, (g < 0 || g > bounds.maxGuidance) {
            return .generationFailed(headline: "That guidance value is out of range (0–\(Int(bounds.maxGuidance))).")
        }

        return nil
    }

    /// Convenience: validate the request against the descriptor selected by `imageModelID`. An UNKNOWN
    /// `imageModelID` is a rejected selection (design D3) — surfaced as `.noCapableBackend(.image)` rather
    /// than silently coerced to the default.
    public static func validate(_ request: MediaRequest,
                                imageModelID: String?,
                                bounds: Bounds = .default) -> MediaError? {
        if let id = imageModelID, !id.isEmpty, !ImageModelCatalog.isKnown(id) {
            return .noCapableBackend(kind: .image)   // unknown selection → no usable image backend
        }
        guard let descriptor = ImageModelCatalog.selected(imageModelID: imageModelID) else {
            return .noCapableBackend(kind: .image)
        }
        return validate(request, descriptor: descriptor, bounds: bounds)
    }
}
