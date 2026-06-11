import Foundation
import Carbon

/// The real `InputSourceController` (design D4): the only place the per-app keyboard-language feature
/// touches Carbon's Text Input Sources (TIS) API. Everything above this seam — the store, the pure
/// `KeyboardLanguagePolicy`, and `KeyboardLanguageService` — is Carbon-free and unit-tested against a
/// fake; here we do the impure I/O of reading the current source, selecting one, and enumerating the
/// user's enabled sources. (The service learns by reading the current source on each app switch, so
/// there is no change-notification observer to manage here.)
///
/// TIS is a C API surfaced to Swift as `TISInputSource` (a `CFType`) plus `kTIS*` `CFString`/`CFBoolean`
/// property keys. `TISGetInputSourceProperty` hands back an `UnsafeMutableRawPointer?` we must
/// reinterpret as the documented value type — hence the `tisString`/`tisBool` bridging helpers below,
/// the single chokepoint for that unsafe cast.
@MainActor
final class CarbonInputSourceController: InputSourceController {

    // MARK: - Reads

    /// The currently selected keyboard input source's id (`kTISPropertyInputSourceID`), or nil if it
    /// can't be read (no current source, or the property is missing).
    func currentSourceID() -> InputSourceID? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        return tisString(source, kTISPropertyInputSourceID)
    }

    /// The user's selectable keyboard / input-method sources, paired with their localized names — the
    /// list the Hub's global-default picker is populated from. Filtered to the keyboard-input-source
    /// category and to sources that are select-capable (so the picker only offers sources `select`
    /// can actually switch to, design D7), sorted by localized name, de-duped by id.
    func enabledSources() -> [(id: InputSourceID, name: String)] {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        var seen = Set<InputSourceID>()
        var result: [(id: InputSourceID, name: String)] = []
        for source in list {
            // Keep only enabled keyboard layouts / input methods the user can actually switch to.
            guard tisString(source, kTISPropertyInputSourceCategory) == (kTISCategoryKeyboardInputSource as String),
                  tisBool(source, kTISPropertyInputSourceIsSelectCapable),
                  let id = tisString(source, kTISPropertyInputSourceID),
                  let name = tisString(source, kTISPropertyLocalizedName),
                  seen.insert(id).inserted
            else { continue }
            result.append((id: id, name: name))
        }
        return result.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Write

    /// Programmatically select the input source with id `id`. We look it up among the existing source
    /// list and `TISSelectInputSource` it; we never *enable* a disabled source (design D7 / non-goal).
    /// Returns whether the selection succeeded — a since-disabled or missing source returns false, which
    /// the caller treats as a silent best-effort no-op (design D5).
    @discardableResult
    func select(_ id: InputSourceID) -> Bool {
        guard let list = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return false
        }
        guard let source = list.first(where: { tisString($0, kTISPropertyInputSourceID) == id }) else {
            return false
        }
        return TISSelectInputSource(source) == noErr
    }

    // MARK: - TIS property bridging

    /// Read a `CFString`-valued TIS property (e.g. `kTISPropertyInputSourceID`,
    /// `kTISPropertyLocalizedName`) off `source`, bridged to a Swift `String`. Returns nil when the
    /// property is absent. `TISGetInputSourceProperty` returns a non-retained raw pointer to the
    /// property value, so we `fromOpaque` + `takeUnretainedValue` it as the documented `CFString`.
    private func tisString(_ source: TISInputSource, _ key: CFString) -> String? {
        guard let raw = TISGetInputSourceProperty(source, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
    }

    /// Read a `CFBoolean`-valued TIS property (e.g. `kTISPropertyInputSourceIsSelectCapable`) off
    /// `source` as a Swift `Bool`. A missing property (nil pointer) reads as false.
    private func tisBool(_ source: TISInputSource, _ key: CFString) -> Bool {
        guard let raw = TISGetInputSourceProperty(source, key) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(raw).takeUnretainedValue())
    }
}
