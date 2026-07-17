import Foundation

/// The image-role `ModelDescriptor` variant table this slice supplies (`ai-local-image-generation`,
/// design D3 / tasks 1.1–1.3). It does NOT redefine `ModelDescriptor` — it CONSUMES the §C1 type
/// (`AI/ModelRegistry.swift`, the live `ModelDescriptor`) and the fleet's `ModelRegistry` (`AI/Fleet/`),
/// supplying two honest variants the fleet registers + budgets:
///   - **Q4 (default, ~7 GB resident)** — CO-RESIDES with chat + ternary + KV under the 48 GB budget.
///   - **FP16 (opt-in, ~24 GB resident)** — EVICTS chat (above the planner's FP16 threshold).
/// Each carries `role: .image`, `lane: .gpu`, `provider: .onDevice`, and the supported capability TAGS
/// (`"image"`, `"img2img"`).
///
/// REAL MODEL (Wave 2 / `MFluxImageRuntime`): both variants are **FLUX.2 Klein 4B** — the OPEN,
/// **Apache-2.0** FLUX.2 variant (`black-forest-labs/FLUX.2-klein-4B`, ungated, commercial-use OK),
/// served by `flux-2-swift-mlx`'s `Flux2Pipeline(model: .klein4B)`. Q4 is the package's on-the-fly
/// int4 quantization (~7 GB resident), FP16 is the bf16 weights (~24 GB resident). We DELIBERATELY do
/// NOT use FLUX.2-dev (BFL non-commercial) or Klein 9B (non-commercial) — only the Apache-2.0 Klein 4B
/// ships here. The text encoder is Qwen3-4B (Apache 2.0) and the VAE is the small-decoder (Apache 2.0).
///
/// CAPABILITY TAGS (REAL): Klein 4B supports text-to-image (`.image`) and **conditioning-mode
/// image-to-image** (`.img2img`, 1–4 reference images via `generateImageToImage`). It is NOT wired for
/// `.inpaint`: FLUX.2 I2I is attention-conditioning (it does not consume a per-pixel mask), and the
/// package's mask-based path (`Flux2MaskedInpaintingChain`) needs a first-class mask the `MediaRequest`
/// seam does not carry (`seed: Data?` only — no mask field, by design D6). So `.inpaint` is DROPPED so a
/// seed-with-alpha request fails cleanly at the validator rather than silently ignoring the mask.
///
/// NB on the capability shape: §C1 sketches `capabilities: Set<String>` (image/video TAGS). The live
/// `ModelDescriptor.capabilities` is `Set<Modality>` (the project's already-shipped capability set). So
/// the descriptor's `Modality` set advertises what the chat layer needs (`.text`/`.vision` for the seed),
/// and the STRING tags (`"image"`/`"img2img"`/`"inpaint"`) — which the seam's seed-capability gate reads
/// — live on `ImageModelDescriptorTags` keyed by descriptor id (kept here so we add NO field to the
/// pinned `ModelDescriptor` and NO field to the pinned `MediaRequest`/`MediaParameters`).
///
/// The persisted `imageModelID` (addendum §1 key, OWNED by `ai-full-potential-toggle` — consumed, never
/// redefined here) selects which variant is used; the default is the Q4 id. An unknown id is REJECTED,
/// never silently coerced to a default (design D3 / spec scenario).
///
/// MLX-free Core — `swift test`-verified (the byte/role/lane/provider/capabilities assertions + selection).
public enum ImageModelCatalog {

    // MARK: - Stable ids

    /// The default Q4 image model id (matches the fleet roster's `image-q4` so the same descriptor is the
    /// one the registry already budgets — this slice does not fork the roster's ids).
    public static let q4ID = "image-q4"
    /// The opt-in FP16 image model id (matches the fleet roster's `image-fp16`).
    public static let fp16ID = "image-fp16"

    /// The id selected when `imageModelID` is unset (the co-resident default — design D3).
    public static let defaultID = q4ID

    // MARK: - Honest resident footprints

    public static let q4ResidencyBytes: UInt64 = 7 * 1024 * 1024 * 1024    // ~7 GB — co-resides
    public static let fp16ResidencyBytes: UInt64 = 24 * 1024 * 1024 * 1024 // ~24 GB — evicts chat

    // MARK: - Capability tags (§C1 string tags, kept off the pinned ModelDescriptor)

    /// The image capability tags a variant supports — what `ai-media-runtime`'s seed gate reads to decide
    /// img2img is allowed. Both Klein 4B variants support t2i + conditioning-mode i2i (`.image`,
    /// `.img2img`); a hypothetical t2i-only variant would advertise only `.image` (and a seed against it
    /// would be an error, not a degrade). `.inpaint` is intentionally absent — see the type doc (the FLUX.2
    /// I2I path is attention-conditioning, not mask-based, and the seam carries no mask field).
    public enum ImageCapabilityTag: String, Codable, Sendable, CaseIterable {
        case image
        case img2img
    }

    /// The supported tags per descriptor id. Both shipped Klein 4B variants are text-to-image AND
    /// conditioning-mode image-to-image capable (`.img2img`), but NOT inpaint.
    public static let capabilityTags: [String: Set<ImageCapabilityTag>] = [
        q4ID: [.image, .img2img],
        fp16ID: [.image, .img2img]
    ]

    /// The supported tags for `id` (empty for an id this catalog does not own — a non-image descriptor).
    public static func tags(for id: String) -> Set<ImageCapabilityTag> {
        capabilityTags[id] ?? []
    }

    /// Whether `id` is a seed-capable image descriptor (advertises `img2img`). The seed/inpaint static
    /// gate (task 3.1, design D6) reads this — a seed against a non-`img2img` id is a `MediaError`, never
    /// a silent text-to-image fallback.
    public static func isSeedCapable(_ id: String) -> Bool {
        tags(for: id).contains(.img2img)
    }

    // MARK: - The descriptor variants (§C1 type, verbatim fields)

    /// The Q4 default descriptor — **FLUX.2 Klein 4B, on-the-fly int4** (~7 GB resident, co-resident).
    /// `role: .image`, `lane: .gpu`, `provider: .onDevice`. The `downloadURL` is the REAL Apache-2.0 Klein
    /// 4B repo (`black-forest-labs/FLUX.2-klein-4B`, ungated) — `MFluxImageRuntime` serves it through
    /// `flux-2-swift-mlx` (`Flux2Pipeline(model: .klein4B)` + the package's own multi-file HF download).
    public static let q4Descriptor = ModelDescriptor(
        id: q4ID,
        displayName: "FLUX.2 Klein 4B (4-bit, ~7 GB) — co-resides with chat",
        sizeBytes: 7 * 1024 * 1024 * 1024,
        integritySHA: "hub-verified",
        downloadURL: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B")!,
        capabilities: [.text, .vision],   // text prompt + a vision seed frame
        quantization: .qat4bit,
        maxContextTokens: 8_192,
        role: .image,
        lane: .gpu,
        provider: .onDevice,
        residencyBytes: q4ResidencyBytes
    )

    /// The FP16 opt-in descriptor — **FLUX.2 Klein 4B, bf16** (~24 GB resident, evicts chat). Same
    /// role/lane/provider + repo as Q4; heavier resident bytes because the transformer + Qwen3 encoder load
    /// un-quantized. Apache-2.0, ungated — NOT FLUX.2-dev (non-commercial) and NOT Klein 9B (non-commercial).
    public static let fp16Descriptor = ModelDescriptor(
        id: fp16ID,
        displayName: "FLUX.2 Klein 4B (bf16, ~24 GB) — pauses chat while it paints",
        sizeBytes: 24 * 1024 * 1024 * 1024,
        integritySHA: "hub-verified",
        downloadURL: URL(string: "https://huggingface.co/black-forest-labs/FLUX.2-klein-4B")!,
        capabilities: [.text, .vision],
        quantization: .fp16,
        maxContextTokens: 8_192,
        role: .image,
        lane: .gpu,
        provider: .onDevice,
        residencyBytes: fp16ResidencyBytes
    )

    /// Both variants, Q4 first (the default). These are the descriptors the fleet's `ModelRegistry`
    /// registers (the `FleetRoster.standard` already lists them by the SAME ids — task 1.3).
    public static let descriptors: [ModelDescriptor] = [q4Descriptor, fp16Descriptor]

    // MARK: - Selection (task 1.2)

    /// Resolve the selected image descriptor for a persisted `imageModelID`.
    ///   - `nil`/empty → the Q4 default (co-resident).
    ///   - the FP16 id → the FP16 descriptor.
    ///   - any id this catalog does not own → REJECTED (`nil`), never silently coerced to a default
    ///     (design D3 / spec "imageModelID selects the variant" scenario). The caller surfaces the
    ///     rejection (a clean failure), it does not fall back.
    public static func selected(imageModelID: String?) -> ModelDescriptor? {
        guard let id = imageModelID, !id.isEmpty else { return q4Descriptor }
        return descriptors.first { $0.id == id }
    }

    /// True iff `id` names a known image variant (a valid selection). An unknown id → false (rejected).
    public static func isKnown(_ id: String) -> Bool {
        descriptors.contains { $0.id == id }
    }
}
