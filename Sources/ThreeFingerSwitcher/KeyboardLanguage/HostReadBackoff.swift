import Foundation

/// The pure negative-result backoff behind a browser host read — the per-site poll's cost guard.
///
/// `BrowserContextMonitor` re-resolves the context every 0.5 s while a supported browser is front, and
/// each resolution asks the `HostProvider` for the active host. When that read comes back empty for a
/// reason that will not change from one tick to the next — the AX walk finds no address bar in this
/// window (full-screen video, presentation mode, an unmatched toolbar layout), the Apple Event errors
/// (Automation denied, a browser that isn't answering) — repeating the full read twice a second is pure
/// main-thread waste: the AX walk is up to `maxElementsVisited` synchronous IPC round-trips, each
/// subject to the 0.5 s AX timeout (the main-thread-starvation class `CLAUDE.md` warns about).
///
/// So a miss is remembered under a **key** (the process + focused window for AX, the bundle id for
/// Apple Events) and the read is skipped for an exponentially growing hold: `initialDelay`, doubling
/// per consecutive miss on the same key, capped at `maxDelay`. It is single-slot — a miss on a
/// DIFFERENT key starts a fresh ladder, so a focused-window change resets the backoff by construction
/// (another window may well expose its bar). A hit clears it; `reset()` is the app-activation reset
/// (`HostProvider.noteAppSwitch`). While a key is held the provider resolves nil exactly as it did on
/// the miss — the app-level context — so the caller's behavior is unchanged, only cheaper.
///
/// Pure and clock-free: time is an INPUT (`now:`), so the ladder is unit-tested deterministically.
struct HostReadBackoff: Equatable {
    /// The hold after a first miss on a key.
    var initialDelay: TimeInterval
    /// The ceiling a run of consecutive misses climbs to.
    var maxDelay: TimeInterval

    /// The key the current miss streak belongs to; nil ⇒ nothing is held.
    private(set) var missedKey: String?
    /// The hold the latest miss applied (doubles per consecutive miss on `missedKey`, up to `maxDelay`).
    private(set) var currentDelay: TimeInterval = 0
    /// Reads of `missedKey` are skipped until this instant.
    private(set) var holdUntil: Date = .distantPast

    init(initialDelay: TimeInterval = 2, maxDelay: TimeInterval = 30) {
        self.initialDelay = max(0, initialDelay)
        self.maxDelay = max(self.initialDelay, maxDelay)
    }

    /// True while `key` is inside its hold — the caller skips the expensive read and resolves nil.
    func shouldSkip(_ key: String, now: Date) -> Bool {
        key == missedKey && now < holdUntil
    }

    /// The read for `key` found nothing. A consecutive miss on the same key doubles the hold (capped);
    /// a miss on another key starts over at `initialDelay` and drops the previous key's hold.
    mutating func recordMiss(_ key: String, now: Date) {
        currentDelay = (key == missedKey)
            ? min(maxDelay, max(initialDelay, currentDelay * 2))
            : initialDelay
        missedKey = key
        holdUntil = now.addingTimeInterval(currentDelay)
    }

    /// The read succeeded — nothing is held any more.
    mutating func recordHit() { reset() }

    /// Forget the streak entirely (the app-activation reset: a fresh visit re-tries the read once).
    mutating func reset() {
        missedKey = nil
        currentDelay = 0
        holdUntil = .distantPast
    }
}
