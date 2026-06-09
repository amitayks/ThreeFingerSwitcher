import AppKit
import ApplicationServices
import CoreGraphics
import ScreenCaptureKit

/// The concrete `SelectionProviding` (design D3, spec `selection-io`): the AX / clipboard / screen
/// input-output primitive the `AICommandExecutor` drives. It reads the front app's selection via
/// Accessibility first (no clipboard clobber), with a ⌘C-with-restore fallback; it writes a result
/// back by setting `AXSelectedText` when settable, else by a ⌘V paste-with-restore; and it captures a
/// screen region as PNG bytes via ScreenCaptureKit for vision commands.
///
/// "Front app" is the app captured when the launcher opened (the overlay is non-activating, so it
/// still holds focus) — injected as `frontAppProvider`, mirroring `LaunchService`. The pasteboard is
/// injected behind `PasteboardAccess` so the save→mutate→restore round-trip is unit-testable headless
/// (the real AX, CGEvent synthesis, and ScreenCaptureKit paths are verified on-device — see the
/// manual-test checklist).
///
/// `@MainActor` to satisfy `SelectionProviding` and because it touches AppKit / AX throughout.
@MainActor
final class SelectionService: SelectionProviding {

    /// The app that was frontmost when the launcher opened. Returns nil when it resolves to our own
    /// process (the overlay), so we never act into ourselves — mirrors `LaunchService.frontApp()`.
    private let frontAppProvider: () -> NSRunningApplication?
    /// The pasteboard the read-fallback and paste paths save/mutate/restore. Injected for tests.
    private let pasteboard: PasteboardAccess
    /// Whether Screen Recording is granted (gates `captureScreenRegion`). Injected for tests; defaults
    /// to the same preflight `PermissionsService` / `ThumbnailService` use.
    private let screenRecordingGranted: () -> Bool
    /// How long the ⌘C fallback polls `changeCount` before giving up. Short and bounded so a missed
    /// copy never hangs the fire.
    private let copyTimeout: TimeInterval
    /// Re-assert the (non-activating) front app and synthesize ⌘V into it. Injected so the paste
    /// pasteboard round-trip is testable WITHOUT activating a real app or firing real keystrokes;
    /// defaults to the real activate-then-⌘V (mirrors `LaunchService.pasteEntry`).
    private let pasteKeystroke: (NSRunningApplication) -> Void

    init(frontAppProvider: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication },
         pasteboard: PasteboardAccess? = nil,
         screenRecordingGranted: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
         copyTimeout: TimeInterval = 0.5,
         pasteKeystroke: ((NSRunningApplication) -> Void)? = nil) {
        self.frontAppProvider = frontAppProvider
        // Built here (not as a default arg) so the main-actor `SystemPasteboard` init isn't evaluated
        // in the nonisolated default-argument context.
        self.pasteboard = pasteboard ?? SystemPasteboard()
        self.screenRecordingGranted = screenRecordingGranted
        self.copyTimeout = copyTimeout
        self.pasteKeystroke = pasteKeystroke ?? { app in
            app.activate(options: [])
            Self.synthesizeKey(0x09, flags: .maskCommand, toPid: app.processIdentifier)   // ⌘V
        }
    }

    // MARK: - Read selection

    /// The front app's selected text. Accessibility is tried FIRST (non-destructive, instant, no focus
    /// change, no clipboard clobber) — `AXFocusedUIElement → AXSelectedText`. When AX yields nothing,
    /// fall back to a ⌘C-with-restore capture. Returns nil (never "") when no selection can be read by
    /// either path, so the executor's "no input" handling fires rather than running the model on empty.
    func readSelectedText() async -> String? {
        guard let app = frontApp() else { return nil }

        if let ax = Self.normalized(axSelectedText(pid: app.processIdentifier)) {
            return ax   // AX exposed a real selection — return it without touching the clipboard.
        }
        // AX didn't expose the selection (many apps don't): synthesize ⌘C, read, then restore.
        return await copyWithRestore(pid: app.processIdentifier)
    }

    /// The CURRENT clipboard string (no synthesis). This is the executor's higher-level "empty
    /// selection → existing clipboard" fallback — deliberately distinct from the ⌘C capture in
    /// `readSelectedText`. nil when the clipboard holds no (non-empty) text.
    func readClipboardText() -> String? {
        Self.normalized(pasteboard.string())
    }

    // MARK: - Write output

    /// Replace the front app's selected text with `text`: set `AXSelectedText` on the focused element
    /// when it is settable (instant, in-place, no clipboard touch) and report true; otherwise fall
    /// back to a ⌘V paste-with-restore and report whether that was applied. Returns false when there
    /// is no front app to act into.
    @discardableResult
    func replaceSelection(_ text: String) async -> Bool {
        guard let app = frontApp() else { return false }
        let pid = app.processIdentifier

        if Self.shouldUseAX(focusedElementSettable: axSelectedTextIsSettable(pid: pid)) {
            if setAXSelectedText(text, pid: pid) { return true }
            // Settable check passed but the set failed (rare) — fall through to paste.
        }
        return await paste(text, into: app)
    }

    /// Paste `text` at the insertion point of the front app (set pasteboard → ⌘V → restore prior
    /// clipboard). No AX-set path: a caret with no selection isn't a settable `AXSelectedText`. Returns
    /// whether the paste was applied (false when there is no front app to act into, or `text` is empty).
    @discardableResult
    func pasteAtCursor(_ text: String) async -> Bool {
        guard let app = frontApp() else { return false }
        return await paste(text, into: app)
    }

    // MARK: - Screen capture

    /// Capture the screen as PNG bytes for a vision command (spec: "Screen-region capture for vision
    /// input"), reusing the held Screen Recording permission. Returns nil when Screen Recording is not
    /// granted or capture fails, so the executor reports "no input" rather than running the model on
    /// nothing.
    ///
    /// NOTE: the interactive region-PICKER overlay is a LATER slice (tasks phase 12). This captures the
    /// main display as a basic, working floor; the picker will refine *which* region without changing
    /// this seam.
    func captureScreenRegion() async -> ScreenCaptureOutcome {
        // A missing Screen-Recording grant is a NAMED permission gap, not "no input" — surface it so
        // the canvas can point the user at the right System Settings pane (spec: D5 / permission fix).
        guard screenRecordingGranted() else { return .permissionDenied }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first else { return .unavailable }
            let config = SCStreamConfiguration()
            config.width = display.width
            config.height = display.height
            config.showsCursor = false
            // Exclude our own non-activating overlay so it never appears in the captured region.
            let ours = content.windows.filter { $0.owningApplication?.processID == getpid() }
            let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: ours)
            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let png = Self.pngData(from: cgImage) else { return .unavailable }
            return .captured(png)
        } catch {
            return .unavailable   // no display, capture failed, or cancelled → plain "no input".
        }
    }

    // MARK: - Pure decision helpers (unit-tested; no system access)

    /// Normalize an optional read into "real text or nothing": trims, and treats empty / whitespace-
    /// only as no-selection (nil). Both AX and clipboard reads pass through this so a blank string is
    /// never mistaken for input. Returns the ORIGINAL (untrimmed) string when it has non-whitespace
    /// content, so leading/trailing spacing the user selected is preserved for the model.
    nonisolated static func normalized(_ raw: String?) -> String? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return raw
    }

    /// Pure branch decision for `replaceSelection`: use the AX set path when the focused element's
    /// selected-text attribute is settable, else fall back to paste. Factored out so the
    /// AX-else-paste choice is testable without an AX element.
    nonisolated static func shouldUseAX(focusedElementSettable: Bool) -> Bool {
        focusedElementSettable
    }

    /// Pure: PNG bytes from a captured `CGImage`, or nil if encoding fails. Kept separate from the
    /// effectful capture so the encode step is isolable.
    nonisolated static func pngData(from cgImage: CGImage) -> Data? {
        let rep = NSBitmapImageRep(cgImage: cgImage)
        return rep.representation(using: .png, properties: [:])
    }

    // MARK: - Accessibility (effectful; verified on-device)

    /// The selected text of the front app's focused UI element via Accessibility, or nil when AX can't
    /// resolve a focused element or a selected-text attribute. Reuses the held Accessibility grant; no
    /// clipboard touch.
    private func axSelectedText(pid: pid_t) -> String? {
        guard let focused = focusedElement(pid: pid) else { return nil }
        return axString(focused, kAXSelectedTextAttribute as String)
    }

    /// Whether the focused element's `AXSelectedText` is settable (⇒ the AX replace path will work).
    private func axSelectedTextIsSettable(pid: pid_t) -> Bool {
        guard let focused = focusedElement(pid: pid) else { return false }
        var settable: DarwinBoolean = false
        let err = AXUIElementIsAttributeSettable(focused, kAXSelectedTextAttribute as CFString, &settable)
        return err == .success && settable.boolValue
    }

    /// Set the focused element's `AXSelectedText` to `text`, replacing the selection in place. Returns
    /// whether the set succeeded.
    private func setAXSelectedText(_ text: String, pid: pid_t) -> Bool {
        guard let focused = focusedElement(pid: pid) else { return false }
        return AXUIElementSetAttributeValue(focused, kAXSelectedTextAttribute as CFString,
                                            text as CFString) == .success
    }

    /// The front app's focused UI element (`AXFocusedUIElement` on the AX application element), or nil.
    private func focusedElement(pid: pid_t) -> AXUIElement? {
        let appEl = AXUIElementCreateApplication(pid)
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appEl, kAXFocusedUIElementAttribute as CFString, &value) == .success,
              let v = value, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    // MARK: - Clipboard fallback / paste (effectful; verified on-device)

    /// ⌘C-with-restore capture of the selection: save the pasteboard, advance past the current change
    /// count, synthesize ⌘C to `pid`, poll `changeCount` until it advances (bounded by `copyTimeout`),
    /// read the resulting string, then RESTORE the saved contents so the user's clipboard is untouched
    /// (spec: "Fallback reads via copy and restores the clipboard"). nil when nothing was captured.
    private func copyWithRestore(pid: pid_t) async -> String? {
        let saved = pasteboard.snapshot()
        let before = pasteboard.changeCount
        Self.synthesizeKey(0x08, flags: .maskCommand, toPid: pid)   // ⌘C (C = 0x08)

        let captured = await pollForChange(after: before)
        let result = captured ? Self.normalized(pasteboard.string()) : nil

        pasteboard.restore(saved)   // ALWAYS restore — even on a missed copy — so we never clobber.
        return result
    }

    /// Paste `text` into `app` via the existing paste-on-fire mechanism: save the prior clipboard, put
    /// `text` on the pasteboard, re-assert the (non-activating) front app, synthesize ⌘V, then restore
    /// the prior clipboard. Returns whether a paste was attempted (false only with empty text). Mirrors
    /// `LaunchService.pasteEntry`'s write-then-⌘V approach.
    @discardableResult
    private func paste(_ text: String, into app: NSRunningApplication) async -> Bool {
        guard !text.isEmpty else { return false }
        let saved = pasteboard.snapshot()
        pasteboard.setString(text)
        // Give activation a beat to settle before the keystroke (matches LaunchService's 0.04s).
        try? await Task.sleep(nanoseconds: 40_000_000)
        pasteKeystroke(app)   // re-assert front app + synthesize ⌘V (injectable for tests)
        // Let the paste consume the pasteboard before we restore the prior contents.
        try? await Task.sleep(nanoseconds: 80_000_000)
        pasteboard.restore(saved)
        return true
    }

    /// Poll `changeCount` until it moves past `before`, bounded by `copyTimeout`. Returns whether it
    /// advanced (⇒ the copy produced something) within the budget.
    private func pollForChange(after before: Int) async -> Bool {
        let deadline = Date().addingTimeInterval(copyTimeout)
        while Date() < deadline {
            if pasteboard.changeCount != before { return true }
            try? await Task.sleep(nanoseconds: 15_000_000)   // 15ms between polls
        }
        return pasteboard.changeCount != before
    }

    // MARK: - Front app / key synthesis

    /// The captured front app, or nil when it resolves to our own process — never act into ourselves.
    private func frontApp() -> NSRunningApplication? {
        let app = frontAppProvider()
        return (app?.processIdentifier == getpid()) ? nil : app
    }

    /// Minimal CGEvent key synthesis to a specific process. A private copy rather than reaching into
    /// `LaunchService.postKey` (which is private) — keeps shared-file edits at zero (see the slice
    /// notes). Requires the held Accessibility permission. Mirrors `LaunchService.postKey(_:flags:toPid:)`.
    nonisolated static func synthesizeKey(_ keyCode: CGKeyCode, flags: CGEventFlags, toPid pid: pid_t) {
        let src = CGEventSource(stateID: .hidSystemState)
        guard let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else { return }
        down.flags = flags; up.flags = flags
        down.postToPid(pid); up.postToPid(pid)
    }
}

// MARK: - Pasteboard seam

/// The thin slice of `NSPasteboard` the read-fallback and paste paths need, abstracted so the
/// save→mutate→restore round-trip is unit-testable headless (the real `NSPasteboard` can't be
/// snapshotted deterministically in CI). `snapshot()`/`restore(_:)` capture and put back the full set
/// of items so a non-text clipboard (a copied image, a password) survives a ⌘C/⌘V fallback unchanged.
@MainActor
protocol PasteboardAccess {
    /// The current change count (advances on every write — the signal a ⌘C produced something).
    var changeCount: Int { get }
    /// The current plain-text string, or nil when none.
    func string() -> String?
    /// Replace the pasteboard with a single plain-text string (for the paste path).
    func setString(_ text: String)
    /// An opaque snapshot of the full pasteboard contents, for later restore.
    func snapshot() -> PasteboardSnapshot
    /// Restore a previously captured snapshot, leaving the user's clipboard as it was.
    func restore(_ snapshot: PasteboardSnapshot)
}

/// An opaque, replayable copy of every pasteboard item's typed representations. Holding the bytes (not
/// references) is what lets the fallback restore a clipboard that held, e.g., a password or an image.
struct PasteboardSnapshot: Equatable {
    /// One entry per pasteboard item; each maps a type identifier to its bytes.
    let items: [[String: Data]]
}

/// The production `PasteboardAccess`, backed by `NSPasteboard.general`. Snapshot/restore copy the
/// per-item typed bytes the same way `ClipboardMonitor` / `LaunchService` round-trip representations.
struct SystemPasteboard: PasteboardAccess {
    private let pb: NSPasteboard
    init(_ pb: NSPasteboard = .general) { self.pb = pb }

    var changeCount: Int { pb.changeCount }

    func string() -> String? { pb.string(forType: .string) }

    func setString(_ text: String) {
        pb.clearContents()
        pb.setString(text, forType: .string)
    }

    func snapshot() -> PasteboardSnapshot {
        let items: [[String: Data]] = (pb.pasteboardItems ?? []).map { item in
            var reps: [String: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { reps[type.rawValue] = data }
            }
            return reps
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(_ snapshot: PasteboardSnapshot) {
        pb.clearContents()
        guard !snapshot.items.isEmpty else { return }
        let objects: [NSPasteboardItem] = snapshot.items.map { reps in
            let item = NSPasteboardItem()
            for (uti, data) in reps {
                item.setData(data, forType: NSPasteboard.PasteboardType(uti))
            }
            return item
        }
        pb.writeObjects(objects)
    }
}
