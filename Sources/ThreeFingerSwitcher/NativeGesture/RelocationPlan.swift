import Foundation

/// The gesture features whose native-gesture relocations the app manages. A feature names the
/// *user-facing choice* (free the horizontal swipe for the switcher, free three-finger vertical
/// for Space-rows, free the four-finger swipes for the launcher); `RelocationPlan` compiles a set
/// of them into the trackpad keys to write.
struct GestureFeatures: OptionSet, Hashable, Sendable {
    let rawValue: Int

    /// Core switcher: free the three-finger horizontal swipe (full-screen-app switch).
    static let horizontal = GestureFeatures(rawValue: 1 << 0)
    /// Space-row switching: free the three-finger vertical swipe (Mission Control / App Exposé).
    static let spaceRows = GestureFeatures(rawValue: 1 << 1)
    /// Four-finger launcher: free both four-finger swipes.
    static let launcher = GestureFeatures(rawValue: 1 << 2)

    static let all: GestureFeatures = [.horizontal, .spaceRows, .launcher]

    /// The single features contained in this set, in stable order.
    var individualFeatures: [GestureFeatures] {
        [GestureFeatures.horizontal, .spaceRows, .launcher].filter { contains($0) }
    }
}

/// The trackpad defaults keys and domains the relocations touch. Both domains are always written
/// in lockstep (built-in and Bluetooth trackpads).
enum TrackpadKey {
    static let domains = [
        "com.apple.AppleMultitouchTrackpad",
        "com.apple.driver.AppleBluetoothMultitouch.trackpad"
    ]
    static let threeFingerHoriz = "TrackpadThreeFingerHorizSwipeGesture"
    static let threeFingerVert = "TrackpadThreeFingerVertSwipeGesture"
    static let fourFingerHoriz = "TrackpadFourFingerHorizSwipeGesture"
    static let fourFingerVert = "TrackpadFourFingerVertSwipeGesture"
}

/// Pure computation of a combined relocation: which final value every touched key gets, given the
/// FULL set of features that should be active. Computing from the full set is what resolves the
/// shared four-finger keys (the historic collision: the horizontal relocation alone parks the
/// full-screen swipe on four fingers with `1`, but a chosen launcher needs that key freed with `2`;
/// the Space-row relocation alone parks Mission Control on four fingers with `2`, but a chosen
/// launcher needs it freed with `0`).
///
/// Key encodings (empirically confirmed, see the config classes):
/// - HORIZONTAL keys: `1` == assigned to that finger count, `2` == unassigned.
/// - VERTICAL keys:   `2` == enabled for that finger count, `0` == disabled.
enum RelocationPlan {
    /// key → final value for the union of active features. Keys not in the map are untouched.
    static func assignments(for features: GestureFeatures) -> [String: Int] {
        var plan: [String: Int] = [:]
        if features.contains(.horizontal) {
            plan[TrackpadKey.threeFingerHoriz] = 2                                        // 3F horiz freed
            plan[TrackpadKey.fourFingerHoriz] = features.contains(.launcher) ? 2 : 1      // park vs free
        }
        if features.contains(.spaceRows) {
            plan[TrackpadKey.threeFingerVert] = 0                                         // 3F vert freed
            plan[TrackpadKey.fourFingerVert] = features.contains(.launcher) ? 0 : 2       // free vs park MC
        }
        if features.contains(.launcher) {
            plan[TrackpadKey.fourFingerHoriz] = 2                                         // 4F horiz freed
            plan[TrackpadKey.fourFingerVert] = 0                                          // 4F vert freed
        }
        return plan
    }

    /// The keys a single feature's backup slot must record (its restore scope).
    static func touchedKeys(for feature: GestureFeatures) -> [String] {
        switch feature {
        case .horizontal: return [TrackpadKey.threeFingerHoriz, TrackpadKey.fourFingerHoriz]
        case .spaceRows:  return [TrackpadKey.threeFingerVert, TrackpadKey.fourFingerVert]
        case .launcher:   return [TrackpadKey.fourFingerHoriz, TrackpadKey.fourFingerVert]
        default:          return []
        }
    }

    /// The per-feature backup slot in the app's own defaults. These names predate the plan (they
    /// are the slots the config classes' `restore()` reads), so individual restores keep working.
    static func backupSlot(for feature: GestureFeatures) -> String? {
        switch feature {
        case .horizontal: return "trackpadGestureBackup"
        case .spaceRows:  return "verticalGestureBackup"
        case .launcher:   return "fourFingerGestureBackup"
        default:          return nil
        }
    }
}

/// Shared absent-aware backup-token helpers (the per-config copies remain for their restores;
/// these are the canonical versions the applier writes with).
enum RelocationBackup {
    /// Token persisted as the backup for a key: "absent" when unset, otherwise the normalized
    /// integer string. Restoring "absent" deletes the key (faithful to a factory default).
    static func token(forRawValue raw: String?) -> String {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty,
              let v = Int(raw) else { return "absent" }
        return String(v)
    }
}
