import Foundation

/// Identity of the current login session. The audit session ID (ASID) is unique per login session
/// — it survives app relaunches within a session and changes on logout/login — which makes it the
/// durable signal the in-memory `changedThisSession` flag never was.
protocol LoginSessionProviding {
    func currentSessionID() -> Int32?
}

/// Reads the ASID via `getaudit_addr` (public BSM API).
struct AuditSessionProvider: LoginSessionProviding {
    func currentSessionID() -> Int32? {
        var info = auditinfo_addr_t()
        guard getaudit_addr(&info, Int32(MemoryLayout<auditinfo_addr_t>.size)) == 0 else { return nil }
        return Int32(info.ai_asid)
    }
}

/// Persisted "relocation pending re-login" markers, one per gesture feature. A marker records the
/// login session in which the trackpad keys were written; the relocation stays *pending* for the
/// rest of that session (across app relaunches — fixing the historic false-positive where a mere
/// app relaunch made a not-yet-effective relocation read as effective) and clears once the app
/// runs in a different session (a real re-login happened, so the keys are now live).
///
/// Stateless over its backing store (UserDefaults is thread-safe), so independently-constructed
/// instances observing the same defaults agree. Degradation: if the session ID cannot be read at
/// write time, the marker stores a sentinel that behaves like the old in-memory flag (pending now,
/// cleared by the next launch sweep) — pending-side within the session, never a permanent brick.
final class ReloginMarkers {
    private static let unknownSession: Int32 = -1

    private let defaults: UserDefaults
    private let session: LoginSessionProviding

    init(defaults: UserDefaults = .standard, session: LoginSessionProviding = AuditSessionProvider()) {
        self.defaults = defaults
        self.session = session
    }

    private func key(_ feature: GestureFeatures) -> String? {
        switch feature {
        case .horizontal: return "relocationPendingSession.horizontal"
        case .spaceRows:  return "relocationPendingSession.spaceRows"
        case .launcher:   return "relocationPendingSession.launcher"
        default:          return nil
        }
    }

    /// Record that the given features' trackpad keys were written in the current session.
    func markPending(_ features: GestureFeatures) {
        let sid = session.currentSessionID() ?? Self.unknownSession
        for feature in features.individualFeatures {
            guard let key = key(feature) else { continue }
            defaults.set(Int(sid), forKey: key)
        }
    }

    /// Whether the feature's relocation is still awaiting a re-login. A marker from a *different*
    /// session means the re-login happened — it is cleared on sight.
    func isPending(_ feature: GestureFeatures) -> Bool {
        guard let key = key(feature), let stored = defaults.object(forKey: key) as? Int else { return false }
        if Int32(stored) == Self.unknownSession { return true }     // unknown writer session: pending until next launch sweep
        guard let current = session.currentSessionID() else { return true }  // can't verify: err pending-side
        if Int32(stored) == current { return true }
        defaults.removeObject(forKey: key)                          // different session ⇒ re-login happened
        return false
    }

    /// Forget a feature's pending state (used when its relocation is restored).
    func clear(_ features: GestureFeatures) {
        for feature in features.individualFeatures {
            guard let key = key(feature) else { continue }
            defaults.removeObject(forKey: key)
        }
    }

    /// Launch sweep: clear every marker that no longer belongs to the current session (a re-login
    /// happened), including sentinel markers whose writer session was unknown.
    func sweepAtLaunch() {
        let current = session.currentSessionID()
        for feature in GestureFeatures.all.individualFeatures {
            guard let key = key(feature), let stored = defaults.object(forKey: key) as? Int else { continue }
            if Int32(stored) == Self.unknownSession {
                defaults.removeObject(forKey: key)                  // legacy/unknown writer: a launch boundary clears it
            } else if let current, Int32(stored) != current {
                defaults.removeObject(forKey: key)                  // new session ⇒ relocation is live
            }
            // stored == current (or current unreadable): still the writing session — keep pending.
        }
    }
}
