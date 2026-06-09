import XCTest
import AppKit
import CoreGraphics
@testable import ThreeFingerSwitcherCore

/// Tests for `SelectionService` (spec: `selection-io`; tasks phase 6) covering the parts that run
/// headless: the pasteboard save→mutate→restore round-trip (clipboard left as it was after a paste),
/// the "empty/whitespace = no selection" normalization, the settable→AX-else-paste branch decision,
/// the clipboard read, and PNG encoding. The AX read/replace, ⌘C/⌘V synthesis, and ScreenCaptureKit
/// paths can't run deterministically headless — they're in the MANUAL-TEST CHECKLIST for the signed
/// build, not faked here.
@MainActor
final class SelectionServiceTests: XCTestCase {

    // MARK: - Fake pasteboard

    /// An in-memory `PasteboardAccess` mimicking `NSPasteboard` semantics: `changeCount` advances on
    /// every write (set/restore), so the ⌘C poll and the save/restore round-trip are testable without
    /// the real system pasteboard. `setStringExternally` simulates a copy landing on the board between
    /// snapshot and restore (what a synthesized ⌘C would do).
    private final class FakePasteboard: PasteboardAccess {
        private(set) var changeCount = 0
        private var current: PasteboardSnapshot = PasteboardSnapshot(items: [])

        private(set) var setStrings: [String] = []
        private(set) var restoreCount = 0

        var stringValue: String? {
            current.items.first?[NSPasteboard.PasteboardType.string.rawValue]
                .flatMap { String(data: $0, encoding: .utf8) }
        }

        func string() -> String? { stringValue }

        func setString(_ text: String) {
            setStrings.append(text)
            current = PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]])
            changeCount += 1
        }

        func snapshot() -> PasteboardSnapshot { current }

        func restore(_ snapshot: PasteboardSnapshot) {
            restoreCount += 1
            current = snapshot
            changeCount += 1
        }

        /// Seed the board with a raw snapshot (e.g. a "password" or image item) for restore tests.
        /// Distinct from `setString` so `setStrings` records ONLY service-driven writes.
        func seed(_ snapshot: PasteboardSnapshot) {
            current = snapshot
            changeCount += 1
        }

        /// Seed a plain-text string without polluting `setStrings`.
        func seedString(_ text: String) {
            seed(PasteboardSnapshot(items: [[NSPasteboard.PasteboardType.string.rawValue: Data(text.utf8)]]))
        }
    }

    /// A front app that is never our own pid, so `frontApp()` resolves it.
    private func realFrontApp() -> NSRunningApplication? {
        // Any running app whose pid isn't ours. The current process's frontmost may BE us under test,
        // so synthesize from another running app when possible; nil is fine for the pure-logic tests.
        NSWorkspace.shared.runningApplications.first { $0.processIdentifier != getpid() }
    }

    /// A `SelectionService` whose paste keystroke is intercepted (no real app activation / no real
    /// ⌘V) so the paste pasteboard round-trip is exercised headless and side-effect-free. `fired`
    /// records which app the paste targeted.
    private func makeService(pasteboard: FakePasteboard,
                             frontApp: NSRunningApplication?,
                             fired: @escaping (NSRunningApplication) -> Void = { _ in }) -> SelectionService {
        SelectionService(frontAppProvider: { frontApp },
                         pasteboard: pasteboard,
                         pasteKeystroke: fired)
    }

    // MARK: - normalized() — empty/whitespace = no selection

    func testNormalizedTreatsNilAsNoSelection() {
        XCTAssertNil(SelectionService.normalized(nil))
    }

    func testNormalizedTreatsEmptyAsNoSelection() {
        XCTAssertNil(SelectionService.normalized(""))
    }

    func testNormalizedTreatsWhitespaceOnlyAsNoSelection() {
        XCTAssertNil(SelectionService.normalized("   \n\t  "))
    }

    func testNormalizedKeepsRealTextVerbatim() {
        // Non-whitespace content is kept UNtrimmed so deliberate surrounding spacing reaches the model.
        XCTAssertEqual(SelectionService.normalized("  hello world  "), "  hello world  ")
    }

    // MARK: - shouldUseAX() — settable→AX else paste branch

    func testShouldUseAXWhenSettable() {
        XCTAssertTrue(SelectionService.shouldUseAX(focusedElementSettable: true))
    }

    func testShouldFallBackToPasteWhenNotSettable() {
        XCTAssertFalse(SelectionService.shouldUseAX(focusedElementSettable: false))
    }

    // MARK: - readClipboardText() — current clipboard, normalized

    func testReadClipboardReturnsCurrentString() {
        let pb = FakePasteboard()
        pb.seedString("on the board")
        let svc = SelectionService(frontAppProvider: { nil }, pasteboard: pb)
        XCTAssertEqual(svc.readClipboardText(), "on the board")
    }

    func testReadClipboardTreatsWhitespaceAsEmpty() {
        let pb = FakePasteboard()
        pb.seedString("   \n  ")
        let svc = SelectionService(frontAppProvider: { nil }, pasteboard: pb)
        XCTAssertNil(svc.readClipboardText(), "whitespace-only clipboard is not input")
    }

    func testReadClipboardNilWhenEmpty() {
        let pb = FakePasteboard()
        let svc = SelectionService(frontAppProvider: { nil }, pasteboard: pb)
        XCTAssertNil(svc.readClipboardText())
    }

    // MARK: - Paste round-trip — clipboard restored after a paste

    func testPasteAtCursorRestoresPriorClipboard() async throws {
        let front = realFrontApp()
        try XCTSkipIf(front == nil, "needs another running process to resolve a front app to paste into")
        let pb = FakePasteboard()
        pb.seedString("user's original clipboard")
        let priorSnapshot = pb.snapshot()
        var firedInto: NSRunningApplication?
        let svc = makeService(pasteboard: pb, frontApp: front) { firedInto = $0 }

        await svc.pasteAtCursor("pasted result")

        XCTAssertEqual(pb.setStrings, ["pasted result"], "the result is put on the board for ⌘V")
        XCTAssertNotNil(firedInto, "the ⌘V keystroke is fired into the captured front app")
        XCTAssertEqual(pb.restoreCount, 1, "the prior clipboard is restored exactly once")
        XCTAssertEqual(pb.snapshot(), priorSnapshot, "clipboard ends as the user's original contents")
        XCTAssertEqual(pb.stringValue, "user's original clipboard")
    }

    func testPasteRestoresNonTextClipboardUnchanged() async throws {
        let front = realFrontApp()
        try XCTSkipIf(front == nil, "needs another running process to resolve a front app to paste into")
        // A non-text clipboard (e.g. a copied password stored under a sensitive type, or image bytes)
        // must survive the paste fallback byte-for-byte (spec: "does not clobber a password").
        let secret = PasteboardSnapshot(items: [[
            "org.nspasteboard.ConcealedType": Data("hunter2".utf8),
            NSPasteboard.PasteboardType.string.rawValue: Data("hunter2".utf8)
        ]])
        let pb = FakePasteboard()
        pb.seed(secret)
        let svc = makeService(pasteboard: pb, frontApp: front)

        await svc.pasteAtCursor("some output")

        XCTAssertEqual(pb.snapshot(), secret, "the sensitive clipboard is restored unchanged")
        XCTAssertEqual(pb.restoreCount, 1)
    }

    func testPasteOfEmptyTextDoesNothing() async {
        let pb = FakePasteboard()
        pb.seedString("keep me")
        var fired = false
        let svc = makeService(pasteboard: pb, frontApp: realFrontApp()) { _ in fired = true }

        await svc.pasteAtCursor("")

        XCTAssertTrue(pb.setStrings.isEmpty, "empty text is never written to the board")
        XCTAssertFalse(fired, "empty text never fires a paste keystroke")
        XCTAssertEqual(pb.restoreCount, 0, "nothing to restore when nothing was pasted")
        XCTAssertEqual(pb.stringValue, "keep me")
    }

    func testPasteNoOpWithoutFrontApp() async {
        let pb = FakePasteboard()
        pb.seedString("untouched")
        var fired = false
        let svc = makeService(pasteboard: pb, frontApp: nil) { _ in fired = true }

        await svc.pasteAtCursor("would-be result")

        XCTAssertTrue(pb.setStrings.isEmpty, "no front app ⇒ no write/paste at all")
        XCTAssertFalse(fired, "no front app ⇒ no keystroke")
        XCTAssertEqual(pb.stringValue, "untouched")
    }

    // MARK: - replaceSelection() — no-front-app guard

    func testReplaceSelectionFailsWithoutFrontApp() async {
        let pb = FakePasteboard()
        let svc = SelectionService(frontAppProvider: { nil }, pasteboard: pb)
        let applied = await svc.replaceSelection("new text")
        XCTAssertFalse(applied, "no front app ⇒ replace reports not applied")
    }

    // MARK: - captureScreenRegion() — Screen Recording gate

    func testScreenCaptureReturnsNilWhenNotGranted() async {
        let pb = FakePasteboard()
        let svc = SelectionService(frontAppProvider: { self.realFrontApp() },
                                   pasteboard: pb,
                                   screenRecordingGranted: { false })
        let data = await svc.captureScreenRegion()
        XCTAssertNil(data, "no Screen Recording ⇒ no capture (executor reports no-input)")
    }

    // MARK: - pngData() — encoding step

    func testPNGDataEncodesImage() {
        // A 2×2 opaque image → non-empty PNG bytes with the PNG signature.
        let width = 2, height = 2
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = ctx.makeImage()!

        let png = SelectionService.pngData(from: cgImage)
        XCTAssertNotNil(png)
        // PNG magic number: 89 50 4E 47.
        XCTAssertEqual(Array(png!.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    // MARK: - SystemPasteboard snapshot/restore against a real (non-general) NSPasteboard

    func testSystemPasteboardRoundTripsItems() {
        // Use a uniquely-named pasteboard (not .general) so the test never disturbs the user's
        // clipboard, while still exercising the real NSPasteboard snapshot/restore code path.
        let raw = NSPasteboard(name: NSPasteboard.Name("tfs-selection-test-\(UUID().uuidString)"))
        defer { raw.releaseGlobally() }
        raw.clearContents()
        raw.setString("original", forType: .string)

        let board = SystemPasteboard(raw)
        let snapshot = board.snapshot()
        XCTAssertEqual(board.string(), "original")

        board.setString("temporary")
        XCTAssertEqual(board.string(), "temporary")

        board.restore(snapshot)
        XCTAssertEqual(board.string(), "original", "restore returns the captured contents")
    }
}
