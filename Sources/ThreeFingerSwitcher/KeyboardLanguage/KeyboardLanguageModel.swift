import Foundation

/// A concrete keyboard input-source identifier (Carbon's `kTISPropertyInputSourceID`), e.g.
/// `com.apple.keylayout.Hebrew` or `com.apple.inputmethod.SCIM.ITABC`. We persist the exact id
/// rather than a language code (design D2): it round-trips through `TISSelectInputSource` and
/// natively covers CJK **input methods**, not just keyboard layouts.
typealias InputSourceID = String

/// The single persisted value for the per-app keyboard-language feature: a bundle-id → input-source
/// map, learned implicitly from the user's own input-source changes (design D3). Stored as one
/// versioned JSON blob in `UserDefaults` (design D8), mirroring `Favorites` / the clipboard record;
/// `schemaVersion` drives forward migration in `KeyboardLanguageStore`.
struct KeyboardLanguageRecord: Codable, Equatable {
    /// Bumped when the on-disk shape changes; drives forward-only migration in the store.
    var schemaVersion: Int
    /// bundleID → remembered input-source id. Empty on first run (design D9 / "learn as you go").
    var map: [String: InputSourceID]

    init(schemaVersion: Int = KeyboardLanguageRecord.currentSchemaVersion,
         map: [String: InputSourceID] = [:]) {
        self.schemaVersion = schemaVersion
        self.map = map
    }

    /// v1 is the initial shape (`{ schemaVersion, map }`). No legacy record predates the feature, so
    /// there is no fold-in/import step — an absent key simply seeds an empty map on first run.
    static let currentSchemaVersion = 1
}
