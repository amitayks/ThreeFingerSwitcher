import Foundation

/// The user's gesture-feature choices on the wizard's "Claim the Lanes" act. The core switcher is
/// always included (it is the product) — and every other lane defaults ON: together they are the
/// app at its best, and the act says so plainly. Opting out is one flick of a switch; everything
/// is backed up first and restorable from Setup, so the generous default costs nothing.
struct LaneChoices: Equatable {
    var spaceRows = true
    var launcher = true
    var fixedSpaces = true
}

/// What the unified apply did, for in-act (non-fatal, non-modal) reporting.
struct LanesApplyOutcome: Equatable {
    /// Trackpad features whose writes failed (e.g. a managed preference). Reported in place;
    /// the feature stays gated off.
    var failed: GestureFeatures = []
    /// Whether any trackpad relocation was actually written (⇒ the one re-login moment is due).
    var appliedAny = false
    /// The Spaces fixed-order write/Dock restart failed (managed preference).
    var spacesFailed = false
}

/// References and callbacks the First Touch wizard needs, wired once by `AppCoordinator` —
/// the same closure-wiring pattern as `HubContext`, so the wizard never reaches into the
/// coordinator.
///
/// CONTRACT: the gesture-state closures (`trackpadClaimed`, `spacesAutoRearrangeOn`,
/// `launcherLive`, `relocationsPending`) shell out to `/usr/bin/defaults` and block on
/// `waitUntilExit`, which pumps a NESTED RUN LOOP. They must only be called from event handlers
/// or the model's `prepareStage` — never from a SwiftUI `body` (re-entering the AppKit update
/// cycle mid-render segfaults). The acts render from the model's published snapshots instead.
@MainActor
final class WizardContext {
    let settings: AppSettings
    let permissions: PermissionsService

    // Act II — permissions as upgrades.
    var requestAccessibility: () -> Void = {}
    var requestScreenRecording: () -> Void = {}
    /// Quit-and-reopen (the Screen Recording grant needs a fresh process). Wizard state is
    /// persisted before this is invoked.
    var relaunchNow: () -> Void = {}
    /// The user's real windows (one row per Space-row), for the post-Accessibility demo upgrade.
    var realWindowRows: () -> [[WindowInfo]] = { [] }
    /// Seed/prefetch live thumbnails into the demo strip (post-Screen-Recording reveal).
    var seedThumbnails: (SwitcherModel) -> Void = { _ in }

    // Act III — the lanes.
    var trackpadClaimed: () -> Bool = { false }
    var spacesAutoRearrangeOn: () -> Bool = { false }
    /// The unified relocation apply (one consent, pristine backups, one re-login).
    var applyLanes: (LaneChoices) -> LanesApplyOutcome = { _ in LanesApplyOutcome() }
    /// Whether any trackpad relocation is still pending its re-login (the persisted markers).
    var relocationsPending: () -> Bool = { false }
    /// Trigger the OS logout (held-Accessibility keystroke; the act shows manual guidance too).
    var logOutNow: () -> Void = {}

    // Act IV — the playground. The tour mirrors what the real launcher will contain for the given
    // toggles: the favorites bands, the seeded AI band when AI is on but no AI command survives in
    // the favorites, and the Clipboard band when history is on (with example entries while the
    // store is still empty, so the user sees what to expect).
    var launcherBands: (_ clipboardOn: Bool, _ aiOn: Bool) -> [ContextBand] = { _, _ in [] }
    /// Whether the four-finger lanes are already effective — the recognizer then drives the tour;
    /// until they are, the wizard's raw touch feed does.
    var launcherLive: () -> Bool = { false }
    /// The playground lane toggle's OFF side: quietly restore the backed-up four-finger setting
    /// (no modal — the row's caption reflects the result).
    var restoreLauncherLane: () -> Void = {}

    // Act V — the curtain.
    var isOpenAtLogin: () -> Bool = { false }
    var toggleOpenAtLogin: () -> Void = {}
    /// Completion: records the flag (+ legacy flags) and closes the wizard window.
    var finish: () -> Void = {}

    /// Pulse the real menu-bar mark — fired on the overture (the brand moment) and the curtain
    /// ("the app lives in your menu bar"), so the wizard points at the actual pixel the user will
    /// come back to. Best-effort; a no-op when no status item exists.
    var pulseMenuBarMark: () -> Void = {}

    // The live-touch feed for Act I (read-only frames; the recognizer path is untouched).
    var subscribeTouch: (@escaping (TouchFrame) -> Void) -> Void = { _ in }
    var unsubscribeTouch: () -> Void = {}

    init(settings: AppSettings, permissions: PermissionsService) {
        self.settings = settings
        self.permissions = permissions
    }
}

/// Sample content for the tour's Clipboard band while the store is still empty — honest examples
/// (labeled as such) so the user sees what the band will hold before they've copied anything.
enum WizardSampleContent {
    static func clipboardEntries() -> [ClipboardEntry] {
        func text(_ s: String, minutesAgo: Double) -> ClipboardEntry {
            ClipboardEntry(capturedAt: Date().addingTimeInterval(-60 * minutesAgo),
                           kind: .text, key: s,
                           representations: [ClipboardUTI.plainText: .inline(Data(s.utf8))],
                           fingerprint: "wizard-sample-\(s.hashValue)")
        }
        let link = "https://example.com"
        return [
            text("Everything you copy lands here (example)", minutesAgo: 2),
            ClipboardEntry(capturedAt: Date().addingTimeInterval(-60 * 7),
                           kind: .url, key: link,
                           representations: [ClipboardUTI.url: .inline(Data(link.utf8)),
                                             ClipboardUTI.plainText: .inline(Data(link.utf8))],
                           fingerprint: "wizard-sample-url"),
            text("Scrub the list, lift to paste (example)", minutesAgo: 14)
        ]
    }
}
