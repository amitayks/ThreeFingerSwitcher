import Foundation

/// The two pure decision rules for the per-app keyboard-language feature (design D4). These are the
/// "brains": no AppKit, no Carbon, no I/O — just dictionary math — so they compile and unit-test
/// under `swift build` / `swift test` in the MLX-free Core. All side effects (reading/selecting the
/// input source) live behind `InputSourceController`; all persistence lives in `KeyboardLanguageStore`.
enum KeyboardLanguagePolicy {
    /// What to select when `bundleID` becomes frontmost: its remembered source if we have one, else
    /// the user's global default, else `nil` (an unseen app with no default — leave the source as-is
    /// and learn from the next user change). The caller is responsible for short-circuiting a
    /// redundant select when the result already equals the current source.
    static func activate(bundleID: String,
                         map: [String: InputSourceID],
                         globalDefault: InputSourceID?) -> InputSourceID? {
        map[bundleID] ?? globalDefault
    }

    /// The updated map after the user changes the input source to `source` while `bundleID` is
    /// frontmost (the only write path — implicit auto-learn, design D3). Returns a copy with
    /// `map[bundleID] = source`; last write wins, and each bundle id is independent.
    static func learn(bundleID: String,
                      source: InputSourceID,
                      into map: [String: InputSourceID]) -> [String: InputSourceID] {
        var map = map
        map[bundleID] = source
        return map
    }
}
