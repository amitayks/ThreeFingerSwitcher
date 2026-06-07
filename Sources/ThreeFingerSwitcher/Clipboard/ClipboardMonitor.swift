import AppKit

/// The background clipboard recorder. macOS has no clipboard-change event, so this polls
/// `NSPasteboard.general.changeCount` on a tunable interval and snapshots the pasteboard when it
/// advances. Runs only while started and not paused. Capture honors the concealed/transient markers
/// and the app-exclusion list (see `ClipboardCapture`). Needs no special permission to read the
/// general pasteboard.
@MainActor
final class ClipboardMonitor {
    private let store: ClipboardStore
    private let pasteboard: NSPasteboard
    private let sourceAppProvider: () -> NSRunningApplication?

    /// Seconds between change-count checks. Tunable from settings.
    var pollInterval: TimeInterval {
        didSet { if timer != nil { restartTimer() } }
    }
    /// Pause recording without tearing down the timer (the poll early-returns).
    var isPaused = false
    /// Bundle ids whose copies are never recorded.
    var excludedBundleIDs: Set<String> = []

    private var timer: Timer?
    private var lastChangeCount: Int

    init(store: ClipboardStore,
         pasteboard: NSPasteboard = .general,
         pollInterval: TimeInterval = 0.5,
         sourceAppProvider: @escaping () -> NSRunningApplication? = { NSWorkspace.shared.frontmostApplication }) {
        self.store = store
        self.pasteboard = pasteboard
        self.pollInterval = pollInterval
        self.sourceAppProvider = sourceAppProvider
        self.lastChangeCount = pasteboard.changeCount   // don't capture whatever is already on the board at start
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = pasteboard.changeCount
        restartTimer()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func restartTimer() {
        timer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: max(0.1, pollInterval), repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        timer = t
    }

    private func poll() {
        guard !isPaused else { return }
        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current
        capture()
    }

    /// Snapshot the current pasteboard into a `ClipboardEntry` (best-effort) and record it.
    func capture() {
        guard let item = pasteboard.pasteboardItems?.first else { return }
        let types = item.types.map(\.rawValue)
        guard !ClipboardCapture.isConcealed(types: types) else { return }
        let sourceID = sourceAppProvider()?.bundleIdentifier
        guard ClipboardCapture.shouldRecord(sourceBundleID: sourceID, excluded: excludedBundleIDs) else { return }
        guard let kind = ClipboardCapture.classify(types: types),
              let entry = makeEntry(kind: kind, item: item, sourceID: sourceID) else { return }
        store.insert(entry)
    }

    // MARK: - Entry construction

    private func makeEntry(kind: ClipboardKind, item: NSPasteboardItem, sourceID: String?) -> ClipboardEntry? {
        var reps: [String: ClipboardPayload] = [:]
        let key: String
        let fingerprint: String

        switch kind {
        case .file:
            guard let data = item.data(forType: .init(ClipboardUTI.fileURL)),
                  let str = String(data: data, encoding: .utf8),
                  let url = URL(string: str) else { return nil }
            reps[ClipboardUTI.fileURL] = .inline(data)
            key = ClipboardKey.fromFile(url)
            fingerprint = "file:\(url.path)"

        case .image:
            guard let data = item.data(forType: .init(ClipboardUTI.png))
                    ?? item.data(forType: .init(ClipboardUTI.tiff)) else { return nil }
            let uti = item.data(forType: .init(ClipboardUTI.png)) != nil ? ClipboardUTI.png : ClipboardUTI.tiff
            reps[uti] = .inline(data)
            let rep = NSBitmapImageRep(data: data)
            key = ClipboardKey.fromImage(width: rep?.pixelsWide ?? 0, height: rep?.pixelsHigh ?? 0)
            fingerprint = "image:\(Self.hash(data))"

        case .color:
            guard let data = item.data(forType: .init(ClipboardUTI.color)) else { return nil }
            reps[ClipboardUTI.color] = .inline(data)
            key = "Color"
            fingerprint = "color:\(Self.hash(data))"

        case .richText:
            guard let rtf = item.data(forType: .init(ClipboardUTI.rtf)) else { return nil }
            reps[ClipboardUTI.rtf] = .inline(rtf)
            let plain = item.string(forType: .init(ClipboardUTI.plainText)) ?? ""
            if let pdata = plain.data(using: .utf8) { reps[ClipboardUTI.plainText] = .inline(pdata) }
            key = ClipboardKey.fromText(plain.isEmpty ? "Rich text" : plain)
            fingerprint = "rich:\(Self.hash(rtf))"

        case .url:
            let str = item.string(forType: .init(ClipboardUTI.url))
                ?? item.string(forType: .init(ClipboardUTI.plainText)) ?? ""
            guard !str.isEmpty, let data = str.data(using: .utf8) else { return nil }
            reps[ClipboardUTI.url] = .inline(data)
            reps[ClipboardUTI.plainText] = .inline(data)
            key = ClipboardKey.fromText(str)
            fingerprint = "url:\(str)"

        case .text:
            guard let str = item.string(forType: .init(ClipboardUTI.plainText)),
                  !str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let data = str.data(using: .utf8) else { return nil }
            reps[ClipboardUTI.plainText] = .inline(data)
            key = ClipboardKey.fromText(str)
            fingerprint = "text:\(str)"
        }

        return ClipboardEntry(capturedAt: Date(), kind: kind, key: key,
                              sourceApp: sourceID, representations: reps, fingerprint: fingerprint)
    }

    /// Cheap content hash (FNV-1a 64-bit) for image/color/rtf fingerprints.
    private static func hash(_ data: Data) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in data { h ^= UInt64(byte); h = h &* 0x100000001b3 }
        return String(h, radix: 16)
    }
}
