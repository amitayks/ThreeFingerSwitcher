import Foundation

// MARK: - Contextual delivery (pure, MLX-free Core)

/// What the Files band writes to the pasteboard when **delivering** a highlighted entry to the captured
/// front app (`files-contextual-delivery`). Dual-representation **by design**: the same item carries the
/// file's reference (`fileURL`) AND its absolute path as text, and the *receiver* picks the form it
/// understands — a text field / terminal / editor consumes the path string, a Finder window consumes the
/// file reference (copying it in). The app never inspects the front context to choose which to send;
/// macOS's paste contract does the routing. Pure value — the actual `NSPasteboard` write happens at the
/// boundary (`SystemPasteboard.setFileDelivery`).
struct FilesDeliveryPayload: Equatable {
    /// The file reference a Finder window consumes (a standardized `fileURL`).
    let url: URL
    /// The standardized absolute path a text target consumes.
    let path: String
}

/// Builds the dual-representation delivery payload for an entry. Pure and testable.
enum FilesDelivery {
    /// The payload for delivering `entry`. The path is the entry's **standardized** absolute path (equal to
    /// `FileEntry.id`), so a delivered path is canonical regardless of how the root was configured.
    static func payload(for entry: FileEntry) -> FilesDeliveryPayload {
        let standardized = entry.url.standardizedFileURL
        return FilesDeliveryPayload(url: standardized, path: standardized.path)
    }
}

// MARK: - Lift action

/// What the Files-band **lift** (the drill's primary resolve excursion — by default the plain lift) does
/// when committed (`files-band`, `tunable-settings`). `deliver` (the default) pastes the highlighted entry
/// into the captured front app; `open` opens it (file → default app, folder → Finder window).
///
/// This is **orthogonal** to the gesture *binding* (`GestureBindings.FilesDrillBinding`, which decides
/// *which excursion* is the primary resolve vs. the menu vs. discard): the binding says which physical move
/// is "the primary resolve," and this says what that move's commit performs. Keeping it separate avoids
/// restructuring the already-shipped one-to-one drill binding.
enum FilesLiftAction: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Deliver the entry to the captured front app (the default — `files-contextual-delivery`).
    case deliver
    /// Open the entry (file → default app, folder → Finder window) on the current Space.
    case open
    public var id: String { rawValue }
}
