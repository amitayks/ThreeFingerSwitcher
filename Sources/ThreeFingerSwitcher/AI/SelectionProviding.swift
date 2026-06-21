import Foundation

/// The result of a screen-region capture (spec: "Failure is never silent" + "A permission failure
/// points to the fix"). Distinguishes a NAMED Screen-Recording permission gap — so the canvas can tell
/// the user which permission to grant — from an ordinary unavailable (no display / cancelled), which
/// the executor treats as plain "no input". A successful capture carries the encoded bytes.
enum ScreenCaptureOutcome: Equatable {
    /// Encoded image bytes (e.g. PNG) ready for a vision request.
    case captured(Data)
    /// Screen Recording is not granted — the user must enable it; surfaced as a clear `.failed`, not
    /// silently as "no input".
    case permissionDenied
    /// No display / capture failed / cancelled — treated as "no input" (not a permission problem).
    case unavailable
}

/// The seam the executor uses to read input from, and write output into, the captured front app
/// (design D3). The concrete `SelectionService` — AX selected-text read/replace with a ⌘C-restore
/// fallback, and ScreenCaptureKit for screen regions — is a LATER slice; the executor depends only
/// on this protocol so the slices stay decoupled and the pipeline is testable with a fake.
///
/// `@MainActor` because the real implementation touches AppKit (`NSPasteboard`, AX, capture); the
/// executor that drives it is main-actor too, so this keeps the hop count down.
@MainActor
protocol SelectionProviding {
    /// The front app's currently selected text (AX, no clipboard clobber), or nil when none is
    /// readable. The executor applies the selection→clipboard fallback itself.
    func readSelectedText() async -> String?

    /// The current clipboard text, or nil when the clipboard holds no text.
    func readClipboardText() -> String?

    /// The current clipboard IMAGE as PNG bytes for a vision command, or nil when the clipboard holds
    /// no image (or undecodable image data). Reads the LIVE pasteboard — symmetric with
    /// `readClipboardText()`, not the stored clipboard history — and reuses already-held access (no new
    /// permission). A nil here is a "no input" state, never a permission gap.
    func readClipboardImage() -> Data?

    // NOTE: screen-region capture is NOT on this executor seam. A `screenRegion` command's image is
    // captured by the interactive region picker BEFORE the canvas opens, and handed to the executor as a
    // pre-supplied `ScreenCaptureOutcome` via `fire(_:screenCapture:)` — the executor never captures the
    // screen itself. The region capture lives on the concrete `SelectionService.captureScreenRegion(_:)`,
    // called by the picker orchestration.

    /// Replace the front app's selected text with `text` (AX set when settable, else paste-on-fire).
    /// Returns whether the replace actually LANDED (not merely whether it was attempted) — a `false`
    /// means the executor must report failure, never a false "Done" (spec: "Failure is never silent").
    @discardableResult
    func replaceSelection(_ text: String) async -> Bool

    /// Paste `text` at the insertion point of the front app. Returns whether the paste landed (same
    /// honesty contract as `replaceSelection`).
    @discardableResult
    func pasteAtCursor(_ text: String) async -> Bool
}
