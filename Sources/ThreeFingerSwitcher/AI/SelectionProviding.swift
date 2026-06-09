import Foundation

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

    /// Capture a screen region as encoded image bytes (e.g. PNG) for a vision command, or nil when
    /// capture is unavailable (e.g. Screen Recording not granted / user cancelled).
    func captureScreenRegion() async -> Data?

    /// Replace the front app's selected text with `text` (AX set when settable, else paste-on-fire).
    /// Returns whether the replace was applied.
    @discardableResult
    func replaceSelection(_ text: String) async -> Bool

    /// Paste `text` at the insertion point of the front app.
    func pasteAtCursor(_ text: String) async
}
