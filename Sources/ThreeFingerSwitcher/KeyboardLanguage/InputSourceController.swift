import Foundation

/// The seam isolating all Carbon TIS side effects from the pure Core logic (design D4). The input
/// source is controllable only via Carbon (`TISSelectInputSource` / `TISCopyCurrentKeyboardInputSource`);
/// this protocol is the entire surface `KeyboardLanguageService` touches, so the engine is testable
/// against a fake while the real `CarbonInputSourceController` links Carbon. (Carbon is importable in
/// Core; the seam exists for **testability and side-effect isolation**, not a target constraint.)
///
/// Note there is deliberately no input-source-change notification here: the service learns each app's
/// source by *reading it on deactivation* (the next app's activation), not by observing/classifying an
/// asynchronous global change notification — see `KeyboardLanguageService` (design D3/D5).
@MainActor
protocol InputSourceController: AnyObject {
    /// The currently selected keyboard input source's id, or nil if it can't be read.
    func currentSourceID() -> InputSourceID?

    /// Programmatically select the input source `id`. Returns whether the selection succeeded; a
    /// since-disabled source fails here and is treated as a best-effort no-op by the caller (design D5).
    @discardableResult
    func select(_ id: InputSourceID) -> Bool

    /// The user's selectable keyboard / input-method sources, paired with their localized names — the
    /// list the Hub's global-default picker is populated from.
    func enabledSources() -> [(id: InputSourceID, name: String)]
}
