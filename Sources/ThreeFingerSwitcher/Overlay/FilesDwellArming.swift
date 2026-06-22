/// The pure decision behind the Files-band dwell-to-arm: given the identity of the currently-highlighted
/// Files "thing" — a folder row (its standardized path) or, when a sub-column is open, that popup's
/// highlighted-row key — and the last identity that began charging, decide whether to **restart** the dwell,
/// **keep** the running one, or **disarm**.
///
/// It is identity-keyed on purpose. The `+1`-finger morph that opens the action menu moves no highlight (the
/// recognizer re-baselines the contact-count change without emitting a step), so the identity is unchanged and
/// the decision is `.keep` — the arm the user charged on that row survives into the menu-open gate. Any real
/// move (a highlight step, a depth descend/ascend, a sub-column scrub, an async re-list that shifts the row,
/// entering/leaving a sub-column) changes the identity → `.restart`. An empty column (`identity == nil`)
/// after having been on something → `.disarm`.
///
/// Pure (no timer, no haptic, no `@MainActor`) so the restart logic is unit-tested directly; the controller
/// owns the `DwellArmDriver` timer + the arm haptic and just acts on the decision.
struct FilesDwellArming {
    enum Decision: Equatable {
        /// The highlighted thing changed and is real → cancel any running charge and begin a fresh dwell.
        case restart
        /// The same thing is still highlighted → leave the running charge (or settled arm) untouched.
        case keep
        /// The highlight moved onto nothing (an empty column) → cancel and disarm.
        case disarm
    }

    private(set) var lastIdentity: String?

    /// Feed the current identity (nil = empty column / nothing to arm); returns the decision and records the
    /// new identity. Calling repeatedly with the same identity yields `.keep` — so it is safe to call after
    /// every Files move and on async landings.
    mutating func update(identity: String?) -> Decision {
        guard identity != lastIdentity else { return .keep }
        lastIdentity = identity
        return identity == nil ? .disarm : .restart
    }

    /// Forget the last identity so the next `update` treats even an unchanged highlight as a fresh charge —
    /// for the re-arm seams where the drill is restarted in place (a delivery that failed but kept the
    /// navigator open) and the user must re-dwell before another committing lift fires.
    mutating func reset() { lastIdentity = nil }
}
