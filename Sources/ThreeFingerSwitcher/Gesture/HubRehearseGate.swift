import CoreGraphics

/// The pure decision behind the Hub gesture preview's **rehearse** state (§2.3 / §2.4 of
/// `add-gesture-previews-and-bindings`): a single, side-effect-free verdict the `AppCoordinator`
/// consults on every touch frame to decide whether the user's real fingers should drive a live
/// preview AND whether the real gesture recognizer must be suppressed for that frame.
///
/// Two facts decide everything:
///   - **`isActiveTarget`** — is a `HubGesturePreview` currently on screen and focused, having
///     registered itself as the rehearse target? (Only one preview is the target at a time.)
///   - **`fingerCount`** — how many fingers are on the trackpad this frame.
///
/// The gate opens only when **a preview is the active target AND ≥2 fingers are down**. While open:
///   - the preview renders the user's real fingertips (the `liveDots` seam) instead of the ghost loop, and
///   - the live recognizer is **suppressed** — the frame is routed to the preview and NOT fed to
///     `GestureRecognizer.feed(_:)`, so rehearsing never opens the launcher / switches a window / fires
///     an AI command (the `wizardOwnsGestures` precedent, mirrored).
///
/// A **single-finger** move is ignored entirely (`fingerCount < 2`): no dots, no suppression — the
/// trackpad behaves normally, so a one-finger cursor move can never drive the preview or be mistaken for
/// a gesture. The instant the fingers lift (`fingerCount == 0`) or the preview stops being the active
/// target, the gate closes and normal recognizer feeding resumes.
///
/// Pure / value-typed, so the ≥2-finger gate and the ownership verdict are unit-testable without a real
/// trackpad, the Hub, or the coordinator.
enum HubRehearseGate {
    /// The minimum fingers that keep an ARMED rehearsal driving. One finger is never a gesture (no
    /// cursor-as-gesture); two or more is the in-surface vocabulary the previews rehearse (the post-trigger
    /// relax-to-two).
    static let minimumFingers = 2

    /// The finger count that ARMS a rehearsal. Every feature opens with a ≥3-finger contact (three opens
    /// the switcher, four the launcher and its bands), so a gesture that never reaches three fingers is NOT
    /// a feature trigger — it is an ordinary **two-finger scroll**, which must pass through untouched (so the
    /// Hub page scrolls normally). The gate therefore arms only once a ≥3-finger trigger occurs, and only
    /// THEN starts swallowing the relaxed two-finger movement.
    static let armThreshold = 3

    /// True when a frame should ARM the gate — a feature-opening contact count (≥`armThreshold`) is down.
    /// The controller latches this for the rest of the touch sequence (until a full lift), mirroring the
    /// recognizer's "three to trigger, relax to two" grammar.
    static func shouldArm(fingerCount: Int) -> Bool {
        fingerCount >= armThreshold
    }

    /// True when the user's real fingers should drive the active preview this frame — a preview is the
    /// active rehearse target, the gate is **armed** (a ≥3-finger trigger happened this sequence), AND at
    /// least `minimumFingers` remain down. Before arming, a one/two-finger move drives nothing (the ghost
    /// loop keeps running and the scroll passes through).
    static func shouldDriveDots(isActiveTarget: Bool, armed: Bool, fingerCount: Int) -> Bool {
        isActiveTarget && armed && fingerCount >= minimumFingers
    }

    /// True when real gesture handling (and scroll) must be swallowed for this frame — the Hub-preview
    /// analogue of `wizardOwnsGestures`. Identical condition to `shouldDriveDots`: the Hub owns the gesture
    /// for exactly the frames it is driving an ARMED rehearsed preview, so the recognizer/scroll are skipped
    /// only then and resume the instant the gate disarms (a full lift) or the preview loses focus.
    static func ownsGestures(isActiveTarget: Bool, armed: Bool, fingerCount: Int) -> Bool {
        shouldDriveDots(isActiveTarget: isActiveTarget, armed: armed, fingerCount: fingerCount)
    }
}
