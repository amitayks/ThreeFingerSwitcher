import SwiftUI

/// A reusable, presentation-only editor for a single remappable surface's gesture **bindings**, shown
/// beside that page's `HubGesturePreview`. It renders one row per surface *action* (e.g. the AI canvas's
/// `commit` / `dismiss` / `ignore`): a label and a `Picker` listing the surface's whole *excursion*
/// vocabulary. Choosing an excursion calls the page-supplied `assign` closure, which routes through the
/// pure `GestureBindings.…assigning(_:to:)` — so the model (not this view) enforces per-surface
/// mutual-exclusivity (assigning a taken excursion swaps it). This view holds no binding state itself.
///
/// It is generic over the action and excursion vocabularies so it serves all three surfaces (canvas,
/// Files drill, switcher direction) unchanged; a page supplies:
///   - `actions` — the surface's action cases (e.g. `GestureBindings.CanvasAction.allCases`);
///   - `excursions` — the surface's bindable excursion vocabulary;
///   - `actionLabel` / `excursionLabel` — human-readable strings for each (use `HubBindingLabels`);
///   - `current(action)` — the excursion the binding currently maps that action to (the picker's value);
///   - `assign(excursion, action)` — apply the user's pick (page closes over `settings.gestureBindings`);
///   - `demoAxis(excursion)` — the `GesturePose.Axis` a row should demo while hovered (drives the
///     preview's `demoAxis`); `onHover` calls `demo(axis)` on enter and `demo(nil)` on exit.
///
/// Nothing here touches `AppSettings`, persistence, or the recognizer — the page wires those in via the
/// closures, keeping this control reusable and `#Preview`-able in isolation.
struct HubBindingPicker<Action: Hashable & Identifiable, Excursion: Hashable & Identifiable>: View {
    /// The surface's action rows, in display order (one `Picker` per action).
    let actions: [Action]
    /// The surface's full excursion vocabulary — the options every row's `Picker` lists.
    let excursions: [Excursion]
    /// A human-readable label for an action (the row's leading title).
    let actionLabel: (Action) -> String
    /// A human-readable label for an excursion (each `Picker` option — see `HubBindingLabels`).
    let excursionLabel: (Excursion) -> String
    /// The excursion the binding currently maps `action` to — the picker's selected value.
    let current: (Action) -> Excursion
    /// Apply the user's pick: the page closes over `settings.gestureBindings.…assigning(excursion, to: action)`.
    let assign: (Excursion, Action) -> Void
    /// The axis a row demos while hovered — fed to the preview's `demoAxis`; `nil` clears the demo.
    let demoAxis: (Excursion) -> GesturePose.Axis?
    /// Called on hover enter/exit with the axis to demo (enter) or `nil` (exit).
    let demo: (GesturePose.Axis?) -> Void

    init(
        actions: [Action],
        excursions: [Excursion],
        actionLabel: @escaping (Action) -> String,
        excursionLabel: @escaping (Excursion) -> String,
        current: @escaping (Action) -> Excursion,
        assign: @escaping (Excursion, Action) -> Void,
        demoAxis: @escaping (Excursion) -> GesturePose.Axis?,
        demo: @escaping (GesturePose.Axis?) -> Void
    ) {
        self.actions = actions
        self.excursions = excursions
        self.actionLabel = actionLabel
        self.excursionLabel = excursionLabel
        self.current = current
        self.assign = assign
        self.demoAxis = demoAxis
        self.demo = demo
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(actions) { action in
                row(for: action)
            }
        }
    }

    private func row(for action: Action) -> some View {
        // A `Binding` whose setter routes the pick through the page's `assign` (i.e. the pure model
        // `assigning`), so picking a taken excursion swaps rather than duplicates.
        let selection = Binding<Excursion>(
            get: { current(action) },
            set: { assign($0, action) }
        )
        return HStack(spacing: 12) {
            Text(actionLabel(action))
            Spacer(minLength: 12)
            Picker("", selection: selection) {
                ForEach(excursions) { excursion in
                    Text(excursionLabel(excursion)).tag(excursion)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 220)
        }
        // Hovering the row demos the action's CURRENTLY-bound excursion in the preview — the move the row
        // controls. Exit clears the demo so the preview falls back to its attract loop.
        .contentShape(Rectangle())
        .onHover { inside in
            demo(inside ? demoAxis(current(action)) : nil)
        }
    }
}

// MARK: - Human-readable excursion labels

/// The single source of presentation strings for the gesture-binding vocabularies, so every surface's
/// picker reads identically. Pages pass the matching closure into `HubBindingPicker.excursionLabel`.
enum HubBindingLabels {
    static func canvas(_ excursion: GestureBindings.CanvasExcursion) -> String {
        switch excursion {
        case .swipeUp:    return "Swipe up"
        case .swipeDown:  return "Swipe down"
        case .swipeLeft:  return "Swipe left"
        case .swipeRight: return "Swipe right"
        }
    }

    static func canvasAction(_ action: GestureBindings.CanvasAction) -> String {
        switch action {
        case .commit:  return "Commit"
        case .dismiss: return "Dismiss"
        case .ignore:  return "Ignore"
        }
    }

    static func files(_ excursion: GestureBindings.FilesExcursion) -> String {
        switch excursion {
        case .lift:                 return "Lift"
        case .plusOneFingerLift:    return "+1 finger then lift"
        case .fourFingerHorizontal: return "Four fingers sideways"
        }
    }

    static func filesAction(_ action: GestureBindings.FilesAction) -> String {
        switch action {
        // The Files-band-actions change repurposes these excursions: `open` is the primary resolve (it runs
        // the configured lift action — deliver or open), and `openWith` opens the action menu (Open-With
        // folds in as the menu's "Open in ▸"). The enum case names are kept; only the labels reflect this.
        case .open:     return "Lift action"
        case .openWith: return "Action menu"
        case .discard:  return "Discard"
        }
    }

    static func axisDirection(_ direction: GestureBindings.AxisDirection) -> String {
        switch direction {
        case .normal:   return "Normal"
        case .reversed: return "Reversed"
        }
    }
}

#if DEBUG
private struct HubBindingPickerPreviewHost: View {
    @State private var binding = GestureBindings.CanvasBinding.default
    @State private var demo: GesturePose.Axis?

    var body: some View {
        HubBindingPicker(
            actions: GestureBindings.CanvasAction.allCases,
            excursions: GestureBindings.CanvasExcursion.allCases,
            actionLabel: HubBindingLabels.canvasAction,
            excursionLabel: HubBindingLabels.canvas,
            current: { binding.excursion(for: $0) },
            assign: { excursion, action in binding = binding.assigning(excursion, to: action) },
            demoAxis: { _ in .horizontal },
            demo: { demo = $0 }
        )
        .frame(width: 360)
        .padding()
    }
}

#Preview("HubBindingPicker — canvas") { HubBindingPickerPreviewHost() }
#endif
