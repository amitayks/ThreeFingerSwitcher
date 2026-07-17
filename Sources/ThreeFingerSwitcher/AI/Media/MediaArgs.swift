import Foundation

/// Parses a routed media call's `argumentsJSON` into a `MediaRequest` (design D2). The router's JSON is a
/// HINT — it is parsed tolerantly (missing fields fall back to defaults), then the SINK re-resolves the
/// seed through the existing capture seams (the JSON only names WHICH capture, never carries bytes). A
/// well-formed args object validates; a malformed one falls back to a prompt-only request rather than
/// failing the whole route (the model still gets to paint something it can refine). Pure. MLX-free Core.
public struct MediaArgs: Sendable, Equatable {
    public var prompt: String
    public var width: Int?
    public var height: Int?
    public var steps: Int?
    public var durationMs: Int?
    /// The named capture the seed image should come from (`screenRegion` / `clipboardImage`), or nil for
    /// text-to-media. The sink resolves the actual bytes through the existing capture seams.
    public var seedImage: SeedHandle?

    public enum SeedHandle: String, Sendable, Equatable {
        case screenRegion
        case clipboardImage
    }

    public init(prompt: String, width: Int? = nil, height: Int? = nil, steps: Int? = nil,
                durationMs: Int? = nil, seedImage: SeedHandle? = nil) {
        self.prompt = prompt
        self.width = width
        self.height = height
        self.steps = steps
        self.durationMs = durationMs
        self.seedImage = seedImage
    }

    /// Parse a route's `argumentsJSON` + the user's text. The prompt prefers the args' `prompt`, falling
    /// back to the user text when the args omit it (so a bare "draw a cat" still paints). Never throws —
    /// malformed JSON yields a prompt-only `MediaArgs`.
    public static func parse(argumentsJSON: String, userText: String) -> MediaArgs {
        let fallbackPrompt = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = argumentsJSON.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return MediaArgs(prompt: fallbackPrompt)
        }
        let prompt = (obj["prompt"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedPrompt = (prompt?.isEmpty == false ? prompt! : fallbackPrompt)
        return MediaArgs(
            prompt: resolvedPrompt,
            width: intValue(obj["width"]),
            height: intValue(obj["height"]),
            steps: intValue(obj["steps"]),
            durationMs: intValue(obj["durationMs"]),
            seedImage: (obj["seedImage"] as? String).flatMap(SeedHandle.init(rawValue:))
        )
    }

    /// Build a `MediaRequest` for `kind`, folding in a resolved seed (PNG bytes) when one was supplied.
    /// `durationMs` is honored only for `.video`.
    public func request(kind: MediaKind, seed: Data?) -> MediaRequest {
        let size: MediaSize
        if let w = width, let h = height { size = MediaSize(width: w, height: h) }
        else { size = .square1024 }
        var params = MediaParameters(size: size, steps: steps ?? 28)
        if kind == .video { params.durationMs = durationMs }
        return MediaRequest(prompt: prompt, seed: seed, kind: kind, parameters: params)
    }

    /// True when the route NAMED a seed image (so a tool is being used as img2img/img2video) — the sink
    /// then requires that capture to resolve, else `MediaError.seedRequired`.
    public var requiresSeed: Bool { seedImage != nil }

    // Accept an Int or a JSON number that decoded as Double/NSNumber.
    private static func intValue(_ any: Any?) -> Int? {
        if let i = any as? Int { return i }
        if let d = any as? Double { return Int(d) }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }
}
