import AppKit
import AVKit
import SwiftUI

// FLAGGED: user xcodebuild + stable-signed build.
//
// Output #2's NATIVE surface (design D7, §6.2): the canvas media preview/player. It renders the pure
// `MediaJobState` (Core, `swift test`-verified) and is resolved by the pure `MediaCanvasResolver` (Core).
// This file is the AppKit/SwiftUI shell that displays it. It compiles under `swift build` (the Overlay
// layer lives in `ThreeFingerSwitcherCore`, which may import AppKit/SwiftUI — it just stays MLX-free), but
// its REAL behavior — a `.nonactivatingPanel` that never becomes key/main, a synchronous `orderOut`
// teardown, the `BubbleMorph` bud-in, and AVKit video playback — is only verifiable in the user's
// stable-signed build (an agent never builds/signs the `.app`).
//
// Pattern: the `DockPreviewOverlay` species (the project's non-activating, synchronous-teardown overlay).
// It NEVER becomes key/main (no keyboard, never steals focus — the foreground app stays the extract
// target), and teardown is synchronous `orderOut` (the files-band / dock ghost-on-Space-switch landmine
// applies here too).

@MainActor
final class MediaCanvasPlayerController {
    /// The live job state the view renders (generating preview → finished image / video player).
    let model = MediaCanvasPlayerModel()
    private var panel: SwitcherPanel?

    /// The user resolved the finished preview by the compass: extract (DOWN-at-top) or discard (RIGHT).
    /// The owner turns `.extract` into the chosen `MediaExtractIntent` side effect; `.discard` just
    /// dismisses (the asset is already durable in the gallery, so the file is never lost).
    var onResolve: ((MediaCanvasResolution) -> Void)?

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 520),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        // Read-only preview: it never takes the pointer (unlike the Dock popup) and never becomes key/main.
        panel.ignoresMouseEvents = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.contentView = NSHostingView(rootView: MediaCanvasPlayerView(model: model))
        return panel
    }

    var isVisible: Bool { panel?.isVisible ?? false }

    /// Show the preview at `rect` (the canvas region). Buds in with `BubbleMorph` via the view's transition.
    func show(at rect: CGRect) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    /// Synchronous teardown (no deferred close — Space-switch ghost landmine). The asset stays in the
    /// gallery; this only dismisses the preview.
    func hide() {
        panel?.orderOut(nil)
    }
}

/// The observable bridge from the pure `MediaJobState` to the SwiftUI view (FLAGGED). The Core sink's
/// `MediaJobObserving` callbacks drive `state`; the view re-renders. Conforms to `MediaJobObserving` so the
/// sink can target it directly in the live app.
@MainActor
final class MediaCanvasPlayerModel: ObservableObject {
    @Published var state: MediaJobState = .idle
    @Published var busyHeadline: String?

    func apply(_ progress: MediaProgress) { state.advance(progress) }
    func finish(_ asset: MediaAsset) { state = .finished(asset) }
    func fail(headline: String) { state = .failed(headline: headline) }
    func cancel() { state = .cancelled }
}

/// The preview/player view (FLAGGED). Generating → the latest intermediate preview frame + a step caption;
/// finished image → the image; finished video → an `AVPlayer` view; failed → a bounded, non-blocking error
/// card (clean headline + opt-in copyable details, NEVER an `NSAlert`). Buds in with `BubbleMorph`.
struct MediaCanvasPlayerView: View {
    @ObservedObject var model: MediaCanvasPlayerModel

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
            .transition(.bubbleMorph())
    }

    @ViewBuilder private var content: some View {
        switch model.state {
        case .idle:
            Color.clear
        case let .generating(index, total, preview):
            VStack(spacing: 10) {
                previewImage(preview)
                Text("Painting… step \(index + 1)/\(max(total, index + 1))")
                    .font(.callout).foregroundStyle(.secondary)
                if let busy = model.busyHeadline {
                    Text(busy).font(.caption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding()
        case let .finished(asset):
            finishedView(asset)
        case let .failed(headline):
            errorCard(headline)
        case .cancelled:
            Color.clear   // a discard just dismisses; no failed indicator (design D10)
        }
    }

    @ViewBuilder private func previewImage(_ data: Data?) -> some View {
        if let data, let img = NSImage(data: data) {
            Image(nsImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
        } else {
            RoundedRectangle(cornerRadius: 12).fill(.quaternary).frame(minHeight: 160)
        }
    }

    @ViewBuilder private func finishedView(_ asset: MediaAsset) -> some View {
        switch asset.kind {
        case .image:
            if let img = NSImage(contentsOf: asset.url) {
                Image(nsImage: img).resizable().scaledToFit().clipShape(RoundedRectangle(cornerRadius: 12))
                    .padding()
            } else {
                errorCard("The generated image couldn't be loaded.")
            }
        case .video:
            // A finished clip plays from its FILE (no continuous screen-record / SCStream — design D7).
            VideoPlayer(player: AVPlayer(url: asset.url))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding()
        }
    }

    /// Bounded, non-blocking error card — clean headline, capped, never an `NSAlert`.
    @ViewBuilder private func errorCard(_ headline: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary)
            Text(headline)
                .font(.callout)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .truncationMode(.middle)
        }
        .padding()
    }
}
