import CoreGraphics

/// The pure, MLX-free **launcher tour brain** (§13 / design D12) — one settings-driven odometer that turns a
/// stream of trackpad frames (finger count + normalized centroid) into discrete launcher intents, so the Hub
/// launcher/band previews navigate exactly like the real launcher and the wizard tour. It folds the three
/// today-triplicated copies of this logic (`GestureRecognizer`'s launcher activation/step math, the wizard's
/// `handleTourTouch` + hardcoded `tourStepX`/`tourStepY`, and the Hub's ad-hoc stepping) into a single,
/// unit-testable value type whose distances come from the user's live `AppSettings` — so what the preview
/// demonstrates is what the real launcher does (the wizard's fixed constants did *not* reflect settings).
///
/// ## The model
///   - **Activation gate.** Until activated, four-finger horizontal travel accumulates; once it crosses
///     `activationThreshold` (`launcherActivationThreshold`) the tour fires `.activate` and re-baselines —
///     exactly the real four-finger open distance.
///   - **Odometer-with-carry navigation.** Once activated, two-finger travel accumulates per axis and emits a
///     step each time it crosses the per-axis distance, **with carry** (`while |Δ| ≥ step { emit; anchor ∓= step }`),
///     so a long fast scrub emits several steps and a fractional remainder carries into the next frame. The
///     horizontal step is `itemStep` (`launcherStepDistance`); the vertical step is `bandStep`
///     (`launcherContextStepDistance`) **on the band list** and `itemStep` **in the grid** (`onBandList`,
///     supplied per frame), matching `GestureRecognizer`'s `onBandList ? contextStep : itemStep` rule.
///   - **Re-baseline on every contact-count change.** When the finger count changes (including the four→two
///     hand-off of the real grammar, and a leaving/landing finger) the anchor resets to the current centroid so
///     no phantom step is emitted across the change — the launcher/Files odometer landmine.
///   - **End on lift.** A drop to zero fingers emits `.end` (once, only if activated) and resets, so the tour
///     never carries state across a full lift. The tour **never fires an item** — `.end` is the holder's cue to
///     recede + disarm, never to launch (the onboarding `launcherTourEnd` contract).
///
/// Pure / value-typed and frame-by-frame deterministic: feed it the same frames and it emits the same intents,
/// so the activation gate, the odometer carry, the axis/step selection, and the re-baseline are all
/// `swift test`-able without a trackpad, the Hub, or the coordinator. The SAME engine drives the idle ghost
/// demo (fed the pose loop's frames) and a real rehearsal (fed the user's frames), so both honour the live
/// tunables identically.
struct LauncherTourEngine {
    /// The four-finger horizontal travel needed to open the launcher (`launcherActivationThreshold`).
    var activationThreshold: CGFloat
    /// The two-finger travel per item step (`launcherStepDistance`) — horizontal items and in-grid rows.
    var itemStep: CGFloat
    /// The two-finger vertical travel per band step on the band list (`launcherContextStepDistance`).
    var bandStep: CGFloat

    /// One discrete launcher intent emitted from the frame stream. Mirrors the `LauncherModel` step API so the
    /// holder applies it directly (`stepHorizontal` / `stepVertical`); `.activate` / `.end` bracket a tour.
    enum Intent: Equatable {
        /// The open gesture completed (four-finger travel crossed `activationThreshold`) — show / grow the
        /// launcher and snap it to a clean starting state. Never fires an item.
        case activate
        /// Step the selection horizontally by `±1` (`> 0` = right; crosses the band list → grid, then moves
        /// across items) — `launcherStepDistance` of two-finger horizontal travel per step.
        case stepHorizontal(Int)
        /// Step the selection vertically by `±1` (`> 0` = up — previous band on the list / a row up in the
        /// grid), matching `LauncherModel.stepVertical`'s convention.
        case stepVertical(Int)
        /// The fingers lifted (count hit zero) after an activation — recede + disarm. NEVER fires an item.
        case end
    }

    /// The travel anchor the odometer measures against; `nil` until the first contact of a touch.
    private var anchor: CGPoint?
    /// The finger count of the previous frame — a change re-baselines the anchor (no phantom step).
    private var lastCount: Int = 0
    /// True between an `.activate` and the matching `.end`: the navigation odometer runs only while activated.
    private var activated = false

    init(activationThreshold: CGFloat, itemStep: CGFloat, bandStep: CGFloat) {
        self.activationThreshold = max(0.001, activationThreshold)
        self.itemStep = max(0.005, itemStep)
        self.bandStep = max(0.005, bandStep)
    }

    /// Update the live distances from settings without disturbing the in-flight odometer state (anchor /
    /// activated), so dragging a Tuning slider mid-demo retargets future steps but never emits a phantom one.
    mutating func updateDistances(activationThreshold: CGFloat, itemStep: CGFloat, bandStep: CGFloat) {
        self.activationThreshold = max(0.001, activationThreshold)
        self.itemStep = max(0.005, itemStep)
        self.bandStep = max(0.005, bandStep)
    }

    /// True while a tour is live (activated and not yet ended) — the holder reads this to know whether a
    /// frame is mid-navigation (so it keeps the launcher grown / shown).
    var isActive: Bool { activated }

    /// Feed one frame and get the intents it produces, in order. `fingerCount` and `centroid` come from the
    /// touch frame (the ghost pose loop for the idle demo, the real trackpad for a rehearsal); `onBandList`
    /// is the model's current focus (the band list vs. the grid), which selects the vertical step distance.
    mutating func feed(fingerCount: Int, centroid: CGPoint, onBandList: Bool) -> [Intent] {
        var intents: [Intent] = []

        // Re-baseline on any contact-count change (the odometer landmine): a leaving/landing finger — and the
        // real four→two open→navigate hand-off — must not emit a step. Emit `.end` only when the hand fully
        // lifts after having activated.
        if fingerCount != lastCount {
            lastCount = fingerCount
            if fingerCount == 0 {
                if activated { intents.append(.end) }
                activated = false
                anchor = nil
            } else {
                anchor = centroid
            }
            return intents
        }

        guard fingerCount > 0 else { return intents }
        guard var a = anchor else { anchor = centroid; return intents }

        if !activated {
            // The open gesture is four-finger horizontal travel; ignore sub-four contacts until it fires.
            guard fingerCount >= 4 else { anchor = centroid; return intents }
            if abs(centroid.x - a.x) >= activationThreshold {
                activated = true
                intents.append(.activate)
                anchor = centroid              // re-baseline so navigation measures from the open's end
            }
            return intents
        }

        // Navigation odometer (activated): accumulate per-axis travel and emit one step per crossing, with
        // carry. Horizontal = items; vertical = bands on the list, rows in the grid.
        let verticalStep = onBandList ? bandStep : itemStep
        while abs(centroid.x - a.x) >= itemStep {
            let dir = centroid.x > a.x ? 1 : -1
            intents.append(.stepHorizontal(dir))
            a.x += CGFloat(dir) * itemStep
        }
        while abs(centroid.y - a.y) >= verticalStep {
            // Up on the pad (y decreasing) = `stepVertical(+1)` (previous band / a row up), matching the model.
            let up = centroid.y < a.y
            intents.append(.stepVertical(up ? 1 : -1))
            a.y += (up ? -verticalStep : verticalStep)
        }
        anchor = a
        return intents
    }

    /// Forget all in-flight state (anchor / activated / last count) — the holder calls this when a rehearsal
    /// starts or ends so the idle-ghost odometer and the real-finger odometer never bleed into each other.
    mutating func reset() {
        anchor = nil
        lastCount = 0
        activated = false
    }

    /// Enter the navigation phase directly, without going through the four-finger activation gate — the idle
    /// ghost demo uses this (its open stroke IS the activation, signalled separately) so the two-finger ghost
    /// strokes that follow step the model at the configured distances. The next `feed` re-baselines the anchor,
    /// so no phantom step is emitted on entry.
    mutating func beginNavigation() {
        activated = true
        anchor = nil
        lastCount = 0
    }
}
