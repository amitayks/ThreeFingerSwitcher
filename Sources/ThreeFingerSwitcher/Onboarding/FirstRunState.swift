import Foundation

/// The First Touch wizard's acts, in performance order. The wizard is a persisted state machine:
/// every stage survives the two restarts the flow choreographs (the app relaunch that makes a
/// Screen Recording grant effective, and the re-login that makes trackpad relocations effective)
/// and plain mid-flow quits (closing the wizard is "later", never abandonment).
enum FirstRunStage: String, Codable, CaseIterable, Sendable {
    /// Brand-new install; nothing shown yet.
    case fresh
    /// Act 0 — brand frame, menu-bar pulse, nothing asked.
    case overture
    /// Act I — the live-touch demo (attract mode that hands over to the user's fingers).
    case hand
    /// Act II — Accessibility: "let it see your windows".
    case permAX
    /// Act II — Screen Recording: "give the windows their faces".
    case permSR
    /// The user chose Relaunch-now on the Screen Recording act; the grant needs a fresh process.
    case awaitingRelaunch
    /// Act III — feature selection + the single consent + unified relocation apply.
    case lanes
    /// Relocations applied; the one re-login moment ("Log out now / Later").
    case awaitingRelogin
    /// Act IV — launcher tour, first favorite, optional features.
    case playground
    /// Act V — Open at Login, Ready seal, where things live.
    case curtain
    /// The wizard has run its course (or an existing install was migrated past it).
    case completed
}

/// Pure transition logic — no I/O, fully unit-tested. The store below persists the results.
enum FirstRunMachine {
    /// The linear act order (restart stages are entered explicitly, not linearly).
    static func next(after stage: FirstRunStage) -> FirstRunStage {
        switch stage {
        case .fresh:            return .overture
        case .overture:         return .hand
        case .hand:             return .permAX
        case .permAX:           return .permSR
        case .permSR:           return .lanes
        case .awaitingRelaunch: return .lanes        // the post-relaunch reveal continues to lanes
        case .lanes:            return .playground   // no relocation applied → no re-login moment
        case .awaitingRelogin:  return .playground
        case .playground:       return .curtain
        case .curtain:          return .completed
        case .completed:        return .completed
        }
    }

    /// Where a launch resumes the wizard, given the persisted stage and whether trackpad
    /// relocations are still pending a re-login.
    ///
    /// - `awaitingRelaunch` resumes ON the Screen Recording act — the relaunch IS that act's
    ///   payoff (the demo strip now renders live thumbnails).
    /// - `awaitingRelogin` resumes on itself while the markers still read pending (the user chose
    ///   "Log out now" but didn't, or merely relaunched the app) and rolls forward to the
    ///   playground once a real re-login cleared them (the lanes-are-live celebration).
    static func resumeStage(persisted: FirstRunStage, relocationsStillPending: Bool) -> FirstRunStage {
        switch persisted {
        case .fresh:            return .overture
        case .awaitingRelaunch: return .permSR
        case .awaitingRelogin:  return relocationsStillPending ? .awaitingRelogin : .playground
        default:                return persisted
        }
    }

    /// Whether the wizard should be presented at launch.
    static func shouldShowAtLaunch(stage: FirstRunStage) -> Bool {
        stage != .completed
    }

    /// Existing-install migration: a user who already answered any legacy first-run prompt, or who
    /// already granted everything the app needs, must never see the wizard uninvited.
    static func migratedStage(current: FirstRunStage,
                              anyLegacyPromptFlag: Bool,
                              allRequiredPermissionsGranted: Bool) -> FirstRunStage {
        guard current == .fresh, anyLegacyPromptFlag || allRequiredPermissionsGranted else { return current }
        return .completed
    }

    /// While first-run onboarding is incomplete, a committed switch with Accessibility missing is
    /// inert — the wizard owns first contact; the OS prompt must never fire mid-gesture. After
    /// completion the prompt path returns as the safety net for the granted-then-revoked case.
    static func shouldPromptAccessibilityOnCommit(firstRunCompleted: Bool) -> Bool {
        firstRunCompleted
    }
}

/// Persistence for the wizard's progress, plus the legacy-flag bridge. Stateless over its backing
/// defaults (injectable for tests).
final class FirstRunStore {
    /// The four one-shot prompt flags of the retired NSAlert flow. Completion sets them all so the
    /// legacy startup alerts can never fire (even on a downgrade); any of them already set marks an
    /// existing install for silent migration.
    static let legacyPromptKeys = [
        "didPromptNativeGesture",
        "didPromptSpacesRearrange",
        "didPromptVerticalGesture",
        "didPromptLauncher"
    ]

    private static let stageKey = "firstRunStage"
    /// Set when the wizard completes with relocations still pending a re-login ("Later"): the next
    /// launch in a NEW session should acknowledge that the lanes are now live.
    private static let pendingLanesAcknowledgmentKey = "firstRunPendingLanesAcknowledgment"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var stage: FirstRunStage {
        get {
            guard let raw = defaults.string(forKey: Self.stageKey),
                  let stage = FirstRunStage(rawValue: raw) else { return .fresh }
            return stage
        }
        set { defaults.set(newValue.rawValue, forKey: Self.stageKey) }
    }

    var isCompleted: Bool { stage == .completed }

    var anyLegacyPromptFlag: Bool {
        Self.legacyPromptKeys.contains { defaults.bool(forKey: $0) }
    }

    /// Silent migration for existing installs (see `FirstRunMachine.migratedStage`). Call once at
    /// launch before deciding whether to show the wizard.
    func migrateExistingInstallIfNeeded(allRequiredPermissionsGranted: Bool) {
        let migrated = FirstRunMachine.migratedStage(current: stage,
                                                     anyLegacyPromptFlag: anyLegacyPromptFlag,
                                                     allRequiredPermissionsGranted: allRequiredPermissionsGranted)
        if migrated != stage {
            stage = migrated
            setLegacyFlags()
        }
    }

    /// Completion: one flag for the wizard, all four for the legacy flow it retired.
    func complete(relocationsStillPending: Bool) {
        stage = .completed
        setLegacyFlags()
        if relocationsStillPending {
            defaults.set(true, forKey: Self.pendingLanesAcknowledgmentKey)
        }
    }

    /// Replay (from the Hub's Setup page): the same machine from the top. Acts render done states
    /// from live detection and never re-write a setting without a fresh user action.
    func beginReplay() {
        stage = .overture
    }

    /// One-time "the lanes are live" acknowledgment after the post-completion re-login. Returns
    /// true exactly once: when completion left relocations pending and they no longer are.
    func consumeLanesAcknowledgment(relocationsStillPending: Bool) -> Bool {
        guard defaults.bool(forKey: Self.pendingLanesAcknowledgmentKey) else { return false }
        guard !relocationsStillPending else { return false }   // still pending: keep it for the real re-login
        defaults.removeObject(forKey: Self.pendingLanesAcknowledgmentKey)
        return true
    }

    private func setLegacyFlags() {
        for key in Self.legacyPromptKeys { defaults.set(true, forKey: key) }
    }
}
