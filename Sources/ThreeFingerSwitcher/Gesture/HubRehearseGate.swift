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
    /// The minimum fingers that engage the gate. One finger is never a gesture (no cursor-as-gesture);
    /// two or more is the in-surface vocabulary the previews rehearse.
    static let minimumFingers = 2

    /// True when the user's real fingers should drive the active preview this frame — i.e. a preview is
    /// the active rehearse target AND at least `minimumFingers` are down. The coordinator feeds the
    /// frame's contacts into the preview's `liveDots` seam exactly when this is true (and clears them
    /// when it is false, so the ghost loop resumes).
    static func shouldDriveDots(isActiveTarget: Bool, fingerCount: Int) -> Bool {
        isActiveTarget && fingerCount >= minimumFingers
    }

    /// True when real gesture handling must be suppressed for this frame — the Hub-preview analogue of
    /// `wizardOwnsGestures`. Identical condition to `shouldDriveDots`: the Hub owns the gesture for
    /// exactly the frames it is driving a rehearsed preview, so the recognizer is skipped only then and
    /// resumes the instant the fingers drop below two or the preview is no longer the target.
    static func ownsGestures(isActiveTarget: Bool, fingerCount: Int) -> Bool {
        shouldDriveDots(isActiveTarget: isActiveTarget, fingerCount: fingerCount)
    }
}
