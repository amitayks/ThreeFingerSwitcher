import XCTest
import AppKit
@testable import ThreeFingerSwitcherCore

/// Integration tests for the capture path end-to-end against an isolated named pasteboard (not the
/// system pasteboard): a copied string is recorded, a concealed item is skipped, and an excluded app
/// is skipped. Guards the `NSPasteboardItem` reading that the pure `ClipboardCapture` tests can't.
@MainActor
final class ClipboardMonitorTests: XCTestCase {

    private func tempDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-monitor-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func pasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name("tfs-test-\(UUID().uuidString)"))
        pb.clearContents()
        return pb
    }

    func testCapturesCopiedText() {
        let pb = pasteboard()
        pb.setString("hello clip", forType: .string)
        let store = ClipboardStore(directory: tempDir())
        let monitor = ClipboardMonitor(store: store, pasteboard: pb, sourceAppProvider: { nil })

        monitor.capture()

        let entry = store.recentWindow(limit: 10).first
        XCTAssertEqual(entry?.kind, .text)
        XCTAssertEqual(entry?.key, "hello clip")
        XCTAssertEqual(entry?.data(for: ClipboardUTI.plainText), Data("hello clip".utf8))
    }

    func testSkipsConcealedItem() {
        let pb = pasteboard()
        let item = NSPasteboardItem()
        item.setString("s3cr3t", forType: .string)
        item.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pb.writeObjects([item])
        let store = ClipboardStore(directory: tempDir())
        let monitor = ClipboardMonitor(store: store, pasteboard: pb, sourceAppProvider: { nil })

        monitor.capture()

        XCTAssertTrue(store.isEmpty, "concealed content is never recorded")
    }

    func testDeDuplicatesOnRecapture() {
        let pb = pasteboard()
        pb.setString("same", forType: .string)
        let store = ClipboardStore(directory: tempDir())
        let monitor = ClipboardMonitor(store: store, pasteboard: pb, sourceAppProvider: { nil })

        monitor.capture()
        monitor.capture()   // identical content again

        XCTAssertEqual(store.count, 1, "re-capturing identical content does not duplicate")
    }

    // MARK: - Self-write suppression (auto-paste of a received item)

    /// A peer entry already in the store + our own pasteboard write (suppressed by its `changeCount`) is
    /// NOT re-captured on the next poll, and the peer entry keeps its `.peer` origin.
    func testSuppressedSelfWriteIsNotRecaptured() {
        let pb = pasteboard()
        let store = ClipboardStore(directory: tempDir())
        let monitor = ClipboardMonitor(store: store, pasteboard: pb, sourceAppProvider: { nil })

        // Simulate the receive path: a `.peer` entry is inserted, then we write it to the board.
        let peer = ClipboardEntry(capturedAt: Date(timeIntervalSince1970: 1000),
                                  kind: .text, key: "from iPhone",
                                  representations: [ClipboardUTI.plainText: .inline(Data("from iPhone".utf8))],
                                  fingerprint: "text:from iPhone",
                                  origin: .peer(deviceName: "iPhone"))
        store.insert(peer)
        pb.clearContents()
        pb.setString("from iPhone", forType: .string)   // our own write

        monitor.suppressSelfWrite(changeCount: pb.changeCount)
        monitor.poll()

        XCTAssertEqual(store.count, 1, "the self-write is not captured as a second entry")
        XCTAssertEqual(store.recentWindow(limit: 1).first?.origin, .peer(deviceName: "iPhone"),
                       "the peer entry keeps its origin/capturedAt (no self-capture overwrote it)")
        XCTAssertEqual(store.recentWindow(limit: 1).first?.capturedAt, Date(timeIntervalSince1970: 1000))
    }

    /// Suppression matches exactly ONE `changeCount`: if a *newer* (real user) copy lands before the
    /// poll, the suppression doesn't match and that copy IS captured (no lost captures).
    func testNewerChangeBeforePollIsStillCaptured() {
        let pb = pasteboard()
        let store = ClipboardStore(directory: tempDir())
        let monitor = ClipboardMonitor(store: store, pasteboard: pb, sourceAppProvider: { nil })

        pb.setString("our write", forType: .string)
        let suppressed = pb.changeCount
        monitor.suppressSelfWrite(changeCount: suppressed)

        // A real user copy lands before the poll → newer changeCount.
        pb.clearContents()
        pb.setString("user copy", forType: .string)
        XCTAssertNotEqual(pb.changeCount, suppressed)

        monitor.poll()

        XCTAssertEqual(store.recentWindow(limit: 1).first?.key, "user copy",
                       "a real copy that superseded the suppressed change is still captured")
    }

    /// Suppression is one-shot: after consuming it, the very next genuine change is captured normally.
    func testSuppressionIsOneShot() {
        let pb = pasteboard()
        let store = ClipboardStore(directory: tempDir())
        let monitor = ClipboardMonitor(store: store, pasteboard: pb, sourceAppProvider: { nil })

        pb.setString("self write", forType: .string)
        monitor.suppressSelfWrite(changeCount: pb.changeCount)
        monitor.poll()                       // consumes (skips) the suppression
        XCTAssertTrue(store.isEmpty)

        pb.clearContents()
        pb.setString("real copy", forType: .string)
        monitor.poll()                       // next change is captured

        XCTAssertEqual(store.recentWindow(limit: 1).first?.key, "real copy")
    }
}
