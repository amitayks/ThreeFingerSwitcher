import SwiftUI
import CoreGraphics

/// The Hub side of the gesture-preview **rehearse** seam (§2.3 / §2.4). A single shared observable that
/// the live `HubGesturePreview`s register with: at most one preview is the **active rehearse target** at
/// a time (the one currently on screen and focused). While a target is registered, the coordinator's
/// `onHubPreviewTouchFrame` feed flows in here; this controller applies the pure `HubRehearseGate`
/// (≥2-finger) verdict and publishes `liveDots` — the normalized fingertips the active preview renders in
/// place of its ghost loop.
///
/// The coordinator also reads `ownsGestures` to **suppress the real recognizer** for exactly the frames a
/// rehearsal is driving the preview (mirroring `wizardOwnsGestures`), so rehearsing in the Hub never opens
/// the launcher / switches a window / fires a command. The instant the fingers lift, the active target
/// blurs/disappears, or the count drops below two, the gate closes: `liveDots` clears (the ghost loop
/// resumes) and `ownsGestures` goes false (normal handling resumes).
///
/// Pure-ish: all the decisions live in `HubRehearseGate`; this type only holds the `@Published` state and
/// owns the register/unregister lifecycle a preview drives from `.onAppear`/focus → `.onDisappear`/blur.
@MainActor
final class HubRehearseController: ObservableObject {
    /// A stable token identifying which preview is currently the active rehearse target. `nil` ⇒ no
    /// preview is focused/on-screen, so no rehearsal can run (the gate is closed regardless of fingers).
    @Published private(set) var activeTarget: UUID?

    /// The user's real fingertips for the active rehearse target this frame, normalized 0..1 (trackpad
    /// space). `nil` ⇒ the ghost loop drives the pad (no rehearsal: no target, <2 fingers, or lifted).
    @Published private(set) var liveDots: [CGPoint]?

    /// Most recent finger count from the touch feed — drives the ≥2-finger gate. Reset to 0 whenever the
    /// target changes so a stale count can never hold the gate open across a focus change.
    private var fingerCount = 0

    init() {}

    // MARK: - Registration (driven by the preview's appear/focus lifecycle)

    /// Make `token`'s preview the active rehearse target (call on appear / focus). Registering a new
    /// target supersedes any previous one and clears stale rehearse state — only one preview rehearses at
    /// a time, and the freshly focused one starts from the ghost loop (no carried-over dots).
    func register(_ token: UUID) {
        guard activeTarget != token else { return }
        activeTarget = token
        fingerCount = 0
        liveDots = nil
    }

    /// Stop rehearsing for `token` (call on disappear / blur). A no-op if some other preview already took
    /// over (its register already cleared this one). Closes the gate: clears dots and ownership so the
    /// real recognizer resumes immediately.
    func unregister(_ token: UUID) {
        guard activeTarget == token else { return }
        activeTarget = nil
        fingerCount = 0
        liveDots = nil
    }

    /// Fully close the gate — called when the Hub leaves the screen (close / miniaturize). Forgets the
    /// active target and any in-flight rehearse state so nothing lingers once the Hub is gone, regardless
    /// of whether the preview's `.onDisappear` fired (it is unreliable on an NSWindow close).
    func reset() {
        activeTarget = nil
        fingerCount = 0
        liveDots = nil
    }

    // MARK: - Touch feed (driven by the coordinator's `onHubPreviewTouchFrame`)

    /// Apply one frame's worth of touch. `contacts` are the normalized fingertip points already extracted
    /// from the `TouchFrame` (the coordinator does the `OMSTouchData` → point mapping at the boundary so
    /// this stays Core-pure). The ≥2-finger `HubRehearseGate` decides whether they become `liveDots`.
    func ingest(fingerCount: Int, contacts: [CGPoint]) {
        self.fingerCount = fingerCount
        guard activeTarget != nil else { liveDots = nil; return }
        if HubRehearseGate.shouldDriveDots(isActiveTarget: true, fingerCount: fingerCount) {
            liveDots = contacts
        } else {
            // <2 fingers (incl. a full lift): the ghost loop drives the pad; no rehearsal this frame.
            liveDots = nil
        }
    }

    // MARK: - Ownership gate (read by the coordinator each frame)

    /// True while the Hub owns the gesture — a preview is the active target AND ≥2 fingers are down. The
    /// coordinator routes the frame to the preview and SKIPS `recognizer.feed(_:)` exactly when this is
    /// true (the `wizardOwnsGestures` mirror), so a rehearsal never fires the real feature.
    var ownsGestures: Bool {
        HubRehearseGate.ownsGestures(isActiveTarget: activeTarget != nil, fingerCount: fingerCount)
    }
}

// MARK: - Rehearsable preview wrapper

/// The drop-in §2.3 wrapper a previewed feature page uses: it observes a `HubRehearseController`, feeds
/// the active rehearse target's live fingertips into the wrapped `HubGesturePreview`'s `liveDots` seam,
/// and registers/unregisters this preview as the target across its on-screen lifetime (appear → register,
/// disappear → unregister, so the gate can never leak past the page).
///
/// A page builds its `HubGesturePreview` once (its miniature + attract/hover axes) and wraps it here with
/// the page's stable `token` and the shared controller (from `HubContext.rehearse`). While this preview is
/// the active target and ≥2 fingers are down, the controller publishes `liveDots`; this view re-renders
/// the preview with those dots so the real fingertips replace the ghost loop. When no rehearsal is
/// running (`liveDots == nil`) the preview falls back to its ghost loop unchanged.
///
/// If the controller is absent (e.g. a SwiftUI `#Preview` with no coordinator) the wrapped preview simply
/// renders its ghost loop — the rehearse seam is inert, never a crash.
struct RehearsablePreview<Miniature: View>: View {
    /// A stable identity for this page's preview, so the controller knows which one is focused.
    let token: UUID
    /// The shared rehearse controller (from `HubContext.rehearse`); `nil` ⇒ ghost-only, inert seam.
    let controller: HubRehearseController?
    /// The page's fully configured preview (miniature + attract / hover axes). `liveDots` is supplied here.
    let preview: HubGesturePreview<Miniature>

    init(token: UUID,
         controller: HubRehearseController?,
         preview: HubGesturePreview<Miniature>) {
        self.token = token
        self.controller = controller
        self.preview = preview
    }

    var body: some View {
        Group {
            if let controller {
                Bound(token: token, controller: controller, preview: preview)
            } else {
                preview   // no coordinator (e.g. Xcode preview): ghost loop only, seam inert.
            }
        }
    }

    /// The observing inner view — split out so the `@ObservedObject` only exists when a controller is
    /// present (a `@ObservedObject` can't be optional). Re-renders on every published `liveDots` change.
    private struct Bound: View {
        let token: UUID
        @ObservedObject var controller: HubRehearseController
        var preview: HubGesturePreview<Miniature>

        var body: some View {
            var configured = preview
            // Drive the rehearse seam only when THIS preview is the active target — a stale `liveDots`
            // from a different focused preview must never bleed in.
            configured.liveDots = (controller.activeTarget == token) ? controller.liveDots : nil
            return configured
                .onAppear { controller.register(token) }
                .onDisappear { controller.unregister(token) }
        }
    }
}
