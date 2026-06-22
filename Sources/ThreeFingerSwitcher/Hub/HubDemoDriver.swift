import SwiftUI
import Combine
import CoreGraphics

extension Notification.Name {
    /// Posted by `AppCoordinator` the instant the Hub leaves the screen (close / miniaturize) and
    /// returns to it (reopen / deminiaturize). The Hub window + its SwiftUI tree are kept alive for
    /// reuse, so SwiftUI's `.onAppear` / `.onDisappear` are unreliable across those transitions
    /// (the very reason the rehearse-suppression gate carries an `isKeyWindow` fail-safe). Without an
    /// authoritative signal a `HubDemoDriver`'s 30 Hz loop keeps ticking after the Hub is closed —
    /// driving the demo models + re-rendering the offscreen overlay on the main run loop — which
    /// starves the real switcher/launcher gesture. Every driver listens for these for its whole
    /// lifetime so it pauses when the Hub is gone and re-arms when it comes back.
    static let hubPreviewsPause = Notification.Name("HubGesturePreviewsPause")
    static let hubPreviewsResume = Notification.Name("HubGesturePreviewsResume")
}

/// §11.4 — the **driven** preview's clock. Plays a `GesturePose.DemoGesture` (a sequence of directed
/// strokes, each with its own finger count) on a ~30 Hz loop and, *in sync with the strokes*, drives a
/// caller-supplied overlay model through three injected closures so the gesture and its effect read as
/// one body:
///
///   - `onOpen()`   — fired ONCE at the start of an **open** stroke (3-finger switcher open / 4-finger
///     launcher open). The launcher page flips a `launched` flag here so the real `LauncherView` morphs
///     in on the mini screen, exactly like the onboarding playground's four-finger launch.
///   - `onScrub(centroid)` — fired every frame of a **navigate** stroke (the 2-finger strokes between the
///     open and the dismiss). The page maps the centroid to its model — e.g. `centroid.x → setColumn`
///     for the switcher, or a band/grid step for the launcher — exactly as `FirstTouchWizardModel`'s
///     attract/tour ticks map `centroid.x → column`.
///   - `onDismiss()` — fired ONCE at the start of a **4-finger dismiss** stroke (the launcher's closing
///     swipe). The launcher page clears its `launched` flag here so the surface recedes.
///
/// The driver itself is presentation-only: it never touches the real app, never fires a feature. It only
/// advances `phase` and republishes `dots` (the ghost fingertips) + `fingerCount` (so the pad shows the
/// right number of fingers as the journey changes hand shape). Two overrides layer on top of the active
/// gesture, mirroring `HubGesturePreview`'s three states:
///
///   - **Hover-demo** (`hoverGesture`): set it to swap the looping demonstration to a *candidate* excursion
///     (the move a binding dropdown option would bind); clear it to return to the page's base gesture. The
///     scrub/open/dismiss closures keep driving the model, so the miniature reacts to the candidate too.
///   - **Rehearse** (`liveDots`): when the real ≥2-finger touch feed is bound here those contacts REPLACE
///     the ghost on the pad and the driver stops emitting ghost dots (the loop keeps running underneath so
///     the moment the fingers lift it resumes). The page still owns whether rehearse drives the model.
///
/// ## Usage (per-page wiring — what §11.5 page agents call)
/// ```swift
/// // 1. Build a real overlay model (HubPreviewModels) the preview will render + the driver will drive.
/// @StateObject private var launcher = … // models.makeLauncherModel(clipboardOn:aiOn:dwell:)
/// @State private var launched = false
/// @StateObject private var driver = HubDemoDriver(gesture: GesturePose.launcherOpen())
///
/// // 2. Render the real overlay + the driven pad; bind the model-driving closures.
/// HubGesturePreview(driver: driver,
///                   onOpen:   { launched = true },
///                   onScrub:  { c in /* map c.x → launcher.stepHorizontal / setColumn */ },
///                   onDismiss:{ launched = false }) {
///     LauncherView(model: launcher)
///         .opacity(launched ? 1 : 0)            // the "launch in" the open stroke triggers
/// }
/// ```
/// The page owns the centroid→model mapping (the driver is model-agnostic — it only knows strokes), and
/// the `launched` flag pattern is how the launcher "launches in" on `onOpen` / recedes on `onDismiss`.
@MainActor
final class HubDemoDriver: ObservableObject {
    /// The ghost fingertips for the current frame (normalized 0..1 trackpad space). Empty during a lift
    /// gap between strokes, or when rehearsing (the live contacts replace these on the pad). The preview
    /// renders `liveDots ?? dots`.
    @Published private(set) var dots: [CGPoint] = []
    /// How many fingertips the current stroke presses (2 navigate / 3 switcher-open / 4 launcher open/dismiss).
    /// `0` during a lift gap. The pad shows this many fingers so the demo's finger count tracks the grammar.
    @Published private(set) var fingerCount: Int = 0

    /// The page's base demonstration — the feature's currently-bound gesture (`switcherDemo`, `launcherOpen`,
    /// a `bandJourney`, or a `canvasResolve`). Reassign to retarget the loop (e.g. the AI page reflecting a
    /// changed canvas binding).
    var gesture: GesturePose.DemoGesture {
        didSet { if gesture != oldValue { resetLoop() } }
    }
    /// The **hover-demo** override: while non-nil the loop plays this candidate excursion instead of
    /// `gesture` (a binding dropdown option the user is hovering). Clearing it restores `gesture`.
    @Published var hoverGesture: GesturePose.DemoGesture? {
        didSet { if hoverGesture != oldValue { resetLoop() } }
    }
    /// The **rehearse** seam: when non-nil these normalized live contacts are what the preview renders in
    /// place of the ghost, and the driver suppresses its own ghost `dots`. `nil` ⇒ the ghost loop runs.
    @Published var liveDots: [CGPoint]? {
        didSet {
            // On entering rehearse, blank the ghost so the pad shows ONLY the live hand; on leaving, the
            // next tick repopulates the ghost from the running phase.
            if liveDots != nil { dots = [] }
        }
    }

    /// The gesture actually playing right now — the hover candidate if hovering, else the base gesture.
    private var activeGesture: GesturePose.DemoGesture { hoverGesture ?? gesture }

    /// True while the real fingers (rehearse) are driving the pad — the ghost loop is suppressed.
    var isRehearsing: Bool { liveDots != nil }

    // The model-driving closures (injected by the page). Default no-ops so a page can render the preview
    // without driving anything (e.g. a static abstract miniature).
    private let onScrub: (CGPoint) -> Void
    private let onOpen: () -> Void
    private let onDismiss: () -> Void

    /// The continuous phase advanced each tick; `GesturePose.pose(phase:gesture:)` turns it into a frame.
    private var phase: Double = 0
    private var timer: Timer?

    /// Authoritative Hub-window lifecycle observers (see `Notification.Name.hubPreviewsPause`). Held for
    /// the driver's whole lifetime — NOT tied to `start()`/`stop()`, since a *stopped* driver must still
    /// hear a later RESUME — and torn down in `deinit`. These guarantee the loop stops when the Hub leaves
    /// the screen and re-arms when it returns, independent of the unreliable SwiftUI appear/disappear.
    private var pauseObserver: NSObjectProtocol?
    private var resumeObserver: NSObjectProtocol?

    /// Which stroke fired its one-shot `onOpen` / `onDismiss` last — so each is fired exactly ONCE per
    /// entry into that stroke (re-fired only after the loop has moved on and come back).
    private var lastFiredStrokeIndex: Int = -1

    /// - Parameters:
    ///   - gesture: the base demonstration to loop (the page's currently-bound gesture).
    ///   - onScrub: called every navigate-stroke frame with the live centroid; the page maps it to its model.
    ///   - onOpen: called once at the start of an **open** stroke (the first stroke, fingers ≥ 3).
    ///   - onDismiss: called once at the start of a **4-finger dismiss** stroke (a later 4-finger stroke).
    init(gesture: GesturePose.DemoGesture,
         onScrub: @escaping (CGPoint) -> Void = { _ in },
         onOpen: @escaping () -> Void = {},
         onDismiss: @escaping () -> Void = {}) {
        self.gesture = gesture
        self.onScrub = onScrub
        self.onOpen = onOpen
        self.onDismiss = onDismiss
        installHubLifecycleObservers()
    }

    deinit {
        timer?.invalidate()
        if let pauseObserver { NotificationCenter.default.removeObserver(pauseObserver) }
        if let resumeObserver { NotificationCenter.default.removeObserver(resumeObserver) }
    }

    /// Listen for the Hub's authoritative on-screen/off-screen signals so the loop pauses the instant the
    /// Hub is closed/minimized (it would otherwise keep ticking on the main run loop — SwiftUI's
    /// `.onDisappear` does not fire on an NSWindow close while the window is reused) and re-arms when the
    /// Hub returns. `stop()`/`start()` are both idempotent, so these compose safely with the preview's own
    /// appear/disappear (which still handle page-to-page switches inside an open Hub).
    private func installHubLifecycleObservers() {
        let center = NotificationCenter.default
        pauseObserver = center.addObserver(forName: .hubPreviewsPause, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.stop() }
        }
        resumeObserver = center.addObserver(forName: .hubPreviewsResume, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.start() }
        }
    }

    // MARK: - Lifecycle (driven from the preview's onAppear/onDisappear)

    /// Begin the 30 Hz loop. Idempotent — safe to call on every `onAppear`. The preview starts it on appear
    /// and stops it on disappear so an off-screen page costs nothing.
    func start() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)   // keep ticking while a menu/scroll tracks
        timer = t
    }

    /// Stop the loop and blank the ghost. Called on the preview's `onDisappear`.
    func stop() {
        timer?.invalidate()
        timer = nil
        dots = []
        fingerCount = 0
    }

    /// Restart the loop from the top of the (new) active gesture, re-arming the one-shot open/dismiss fires.
    /// Called when the active gesture changes (a hover swap or a base-gesture retarget).
    private func resetLoop() {
        phase = 0
        lastFiredStrokeIndex = -1
    }

    // MARK: - The tick

    /// Advance the phase, publish the frame, and drive the model in sync with the playing stroke.
    private func tick() {
        phase += GesturePose.phaseStep
        let g = activeGesture
        let frame = GesturePose.pose(phase: phase, gesture: g)

        fingerCount = frame.lifted ? 0 : frame.fingerCount

        // Rehearse: the live hand owns the pad — suppress the ghost (the loop still drives the model below
        // so the miniature keeps demonstrating under the user's contacts, the wizard's takeover behavior).
        if !isRehearsing {
            dots = frame.lifted ? [] : frame.dots
        }

        guard !g.strokes.isEmpty else { return }
        let stroke = g.strokes[min(frame.strokeIndex, g.strokes.count - 1)]
        let isOpenStroke = (frame.strokeIndex == 0 && stroke.fingers >= 3)
        let isDismissStroke = (frame.strokeIndex > 0 && stroke.fingers >= 4)

        // One-shot edges: fire `onOpen` / `onDismiss` the first frame we ENTER that stroke (not lifted).
        if !frame.lifted && frame.strokeIndex != lastFiredStrokeIndex {
            lastFiredStrokeIndex = frame.strokeIndex
            if isOpenStroke { onOpen() }
            else if isDismissStroke { onDismiss() }
        }

        // Continuous navigate scrub: every frame of a 2-finger stroke that is neither the open nor a dismiss.
        if !frame.lifted && !isOpenStroke && !isDismissStroke && stroke.fingers <= 2 {
            onScrub(frame.centroid)
        }
    }
}
