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
}
