import Foundation

/// The favorites data model for the four-finger launcher.
///
/// Everything here is pure value types with no AppKit/SwiftUI dependency, so it is trivially
/// `Codable` (one versioned blob in `UserDefaults`, see `FavoritesStore`) and unit-testable
/// without a running app. Rendering concerns (resolving an `ItemColor` to a SwiftUI `Color`,
/// an `ItemIcon` to an `NSImage`) live in the view layer.

/// An RGBA color stored as components so the model stays AppKit-free and `Codable`.
struct ItemColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red; self.green = green; self.blue = blue; self.alpha = alpha
    }
}

/// How an item's icon is sourced. The app icon / file icon are resolved at render time.
enum ItemIcon: Codable, Equatable {
    case appDefault          // the app's own icon (`.app` kind)
    case fileIcon            // the file/folder icon (`.path` kind)
    case sfSymbol(String)    // an SF Symbol name
    case emoji(String)       // a literal emoji / short text glyph
}

/// The body of a `.script` item.
enum ScriptBody: Codable, Equatable {
    case shell(String)         // an inline shell snippet (run via /bin/zsh -c)
    case appleScript(String)   // an inline AppleScript (run via osascript -e)
    case file(URL)             // a path to an executable script / .scpt
}

/// Optional per-item value control for the volume/brightness actions. `nil` (the default) keeps the
/// native OS-step behavior; otherwise the action sets an absolute level or changes it by an amount.
struct ValueAdjustment: Codable, Equatable {
    enum Mode: String, Codable, CaseIterable, Identifiable {
        case absolute   // set the level directly to `percent`
        case relative   // change by `percent` points; sign comes from the action's up/down
        var id: String { rawValue }
    }
    var mode: Mode
    /// 0…100. For `.absolute` the target level; for `.relative` the magnitude of the change.
    var percent: Double
}

/// A built-in action performed natively (Accessibility / NSWorkspace / synthesized keys) without a
/// subprocess or any new permission. Extensible — add a case here + a branch in `LaunchService.perform`.
/// Every action targets the app that was frontmost when the launcher opened (captured at open time).
enum SystemAction: String, Codable, Equatable, CaseIterable, Identifiable {
    // Window
    case minimizeWindow, toggleFullScreen, zoomWindow, maximizeWindow, centerWindow
    case tileLeftHalf, tileRightHalf, tileTopHalf, tileBottomHalf
    case tileTopLeft, tileTopRight, tileBottomLeft, tileBottomRight
    case closeFrontWindow, closeAllWindows
    // App
    case newWindow, hideFrontApp, hideOtherApps, quitFrontApp, forceQuitFrontApp
    // System
    case missionControl, appExpose, showDesktop, nextSpace, previousSpace
    case lockScreen, screenSaver, sleepDisplay, emptyTrash
    case screenshotSelection, screenshotFullScreen, screenshotTools
    // Media & display
    case playPause, nextTrack, previousTrack, volumeUp, volumeDown, mute, brightnessUp, brightnessDown

    var id: String { rawValue }

    enum Category: String, CaseIterable, Identifiable {
        case window = "Window", app = "App", system = "System", media = "Media & Display"
        var id: String { rawValue }
    }

    var category: Category { meta.category }
    var title: String { meta.title }
    var symbol: String { meta.symbol }
    var detail: String { meta.detail }

    /// Actions that control a continuous 0–100% level and so accept a `ValueAdjustment`.
    var isValueAdjustable: Bool {
        switch self {
        case .volumeUp, .volumeDown, .brightnessUp, .brightnessDown: return true
        default: return false
        }
    }

    /// For value actions: whether this is the "increase" direction (drives a relative change's sign).
    var increasesValue: Bool {
        switch self {
        case .volumeUp, .brightnessUp: return true
        default: return false
        }
    }

    /// Whether a value action targets volume (vs. brightness).
    var controlsVolume: Bool { self == .volumeUp || self == .volumeDown }

    private var meta: (title: String, symbol: String, detail: String, category: Category) {
        switch self {
        case .minimizeWindow:      return ("Minimize Window", "minus.circle", "Minimize the front window to the Dock.", .window)
        case .toggleFullScreen:    return ("Toggle Full Screen", "arrow.up.left.and.arrow.down.right", "Enter or exit full screen for the front window.", .window)
        case .zoomWindow:          return ("Zoom Window", "arrow.up.left.and.down.right.magnifyingglass", "Press the front window's green zoom button.", .window)
        case .maximizeWindow:      return ("Maximize", "rectangle.fill", "Resize the front window to fill the screen (not full screen).", .window)
        case .centerWindow:        return ("Center", "rectangle.center.inset.filled", "Center the front window on screen.", .window)
        case .tileLeftHalf:        return ("Left Half", "rectangle.lefthalf.filled", "Tile the front window to the left half.", .window)
        case .tileRightHalf:       return ("Right Half", "rectangle.righthalf.filled", "Tile the front window to the right half.", .window)
        case .tileTopHalf:         return ("Top Half", "rectangle.tophalf.filled", "Tile the front window to the top half.", .window)
        case .tileBottomHalf:      return ("Bottom Half", "rectangle.bottomhalf.filled", "Tile the front window to the bottom half.", .window)
        case .tileTopLeft:         return ("Top-Left Quarter", "arrow.up.left", "Tile the front window to the top-left quarter.", .window)
        case .tileTopRight:        return ("Top-Right Quarter", "arrow.up.right", "Tile the front window to the top-right quarter.", .window)
        case .tileBottomLeft:      return ("Bottom-Left Quarter", "arrow.down.left", "Tile the front window to the bottom-left quarter.", .window)
        case .tileBottomRight:     return ("Bottom-Right Quarter", "arrow.down.right", "Tile the front window to the bottom-right quarter.", .window)
        case .closeFrontWindow:    return ("Close Front Window", "xmark.rectangle", "Close the window that was in front when you opened the launcher.", .window)
        case .closeAllWindows:     return ("Close All Windows", "xmark.square.fill", "Close every window of the front app.", .window)
        case .newWindow:           return ("New Window", "macwindow.badge.plus", "Open a new window of the front app on this Space.", .app)
        case .hideFrontApp:        return ("Hide Front App", "eye.slash", "Hide the front app.", .app)
        case .hideOtherApps:       return ("Hide Others", "eye.slash.fill", "Hide every app except the front one.", .app)
        case .quitFrontApp:        return ("Quit Front App", "power", "Quit the front app (it may prompt to save).", .app)
        case .forceQuitFrontApp:   return ("Force Quit Front App", "xmark.octagon.fill", "Force-quit the front app immediately (loses unsaved work).", .app)
        case .missionControl:      return ("Mission Control", "rectangle.3.group", "Show all windows and Spaces.", .system)
        case .appExpose:           return ("App Exposé", "rectangle.on.rectangle", "Show all windows of the front app.", .system)
        case .showDesktop:         return ("Show Desktop", "menubar.dock.rectangle", "Reveal the desktop.", .system)
        case .nextSpace:           return ("Next Space", "arrow.right.square", "Move to the Space on the right (uses the system shortcut).", .system)
        case .previousSpace:       return ("Previous Space", "arrow.left.square", "Move to the Space on the left (uses the system shortcut).", .system)
        case .lockScreen:          return ("Lock Screen", "lock.fill", "Lock the screen.", .system)
        case .screenSaver:         return ("Start Screen Saver", "moon.stars.fill", "Start the screen saver.", .system)
        case .sleepDisplay:        return ("Sleep Display", "zzz", "Put the display to sleep.", .system)
        case .emptyTrash:          return ("Empty Trash", "trash.fill", "Empty the Trash (may ask for folder access once).", .system)
        case .screenshotSelection: return ("Screenshot — Selection", "camera.viewfinder", "Capture a selected area (system shortcut).", .system)
        case .screenshotFullScreen:return ("Screenshot — Full Screen", "camera.fill", "Capture the whole screen (system shortcut).", .system)
        case .screenshotTools:     return ("Screenshot — Tools", "camera.on.rectangle", "Open the screenshot toolbar (system shortcut).", .system)
        case .playPause:           return ("Play / Pause", "playpause.fill", "Toggle media playback.", .media)
        case .nextTrack:           return ("Next Track", "forward.fill", "Skip to the next track.", .media)
        case .previousTrack:       return ("Previous Track", "backward.fill", "Go to the previous track.", .media)
        case .volumeUp:            return ("Volume Up", "speaker.wave.3.fill", "Raise the system volume.", .media)
        case .volumeDown:          return ("Volume Down", "speaker.wave.1.fill", "Lower the system volume.", .media)
        case .mute:                return ("Mute", "speaker.slash.fill", "Toggle mute.", .media)
        case .brightnessUp:        return ("Brightness Up", "sun.max.fill", "Raise the display brightness.", .media)
        case .brightnessDown:      return ("Brightness Down", "sun.min.fill", "Lower the display brightness.", .media)
        }
    }
}

/// How firing an `.app` item should produce a usable window. Resolution order is: an item's own
/// override (if set) → its band's `defaultAppStrategy`. `.newInstance` is never chosen by `.smart`.
enum AppStrategy: String, Codable, Equatable, CaseIterable {
    case smart              // capable app ⇒ new window here; single-window app ⇒ go to its window
    case alwaysNewWindow    // force a new window (menu-press, else ⌘N)
    case bringExistingHere  // single-window app: focus the existing window (switches to its Space)
    case quitAndReopenHere  // single-window app: quit + relaunch so a fresh window opens here (lossy, opt-in)
    case newInstance        // launch a second process (`open -n`) — opt-in only
}

/// Exactly one kind of launchable thing.
enum LaunchItemKind: Codable, Equatable {
    /// An application. `strategy == nil` means "inherit the band default".
    case app(bundleURL: URL, strategy: AppStrategy?)
    /// A file or folder, opened in its default handler.
    case path(URL)
    /// A URL (https or an app scheme).
    case url(URL)
    /// A Shortcuts.app shortcut, run by name.
    case shortcut(name: String)
    /// A script (shell / AppleScript / file).
    case script(ScriptBody)
    /// A built-in system action performed via Accessibility (e.g. close the front window). The
    /// optional `ValueAdjustment` applies only to the value actions (volume/brightness); `nil` keeps
    /// the native step behavior.
    case action(SystemAction, ValueAdjustment? = nil)
    /// An ordered composite that fires other items (referenced by id). "Work mode" / "Home mode".
    case preset(itemIDs: [UUID])
}

/// A single launcher entry: stable identity + presentation + what it does.
struct LaunchItem: Codable, Equatable, Identifiable {
    var id: UUID
    var title: String
    var icon: ItemIcon
    var tint: ItemColor?
    var kind: LaunchItemKind

    init(id: UUID = UUID(), title: String, icon: ItemIcon, tint: ItemColor? = nil, kind: LaunchItemKind) {
        self.id = id; self.title = title; self.icon = icon; self.tint = tint; self.kind = kind
    }

    /// True for kinds whose firing has side effects worth a success/failure notification.
    var isConsequential: Bool {
        switch kind {
        case .script, .preset: return true
        case .app, .path, .url, .shortcut, .action: return false
        }
    }
}

/// A named, colored row in the launcher grid — a *mode of work*. Items within a band are kept in
/// an explicit, user-defined order (never recency-sorted).
struct ContextBand: Codable, Equatable, Identifiable {
    var id: UUID
    var name: String
    var color: ItemColor
    /// Default app strategy inherited by `.app` items in this band that don't override it.
    var defaultAppStrategy: AppStrategy
    var items: [LaunchItem]

    init(id: UUID = UUID(), name: String, color: ItemColor,
         defaultAppStrategy: AppStrategy = .smart, items: [LaunchItem] = []) {
        self.id = id; self.name = name; self.color = color
        self.defaultAppStrategy = defaultAppStrategy; self.items = items
    }
}

/// The root favorites record — the single persisted value (see `FavoritesStore`).
struct Favorites: Codable, Equatable {
    /// Bumped when the on-disk shape changes; drives forward migration in `FavoritesStore`.
    var schemaVersion: Int
    var bands: [ContextBand]
    /// The deterministic launcher entry point: which band, and which column within it.
    var homeBandID: UUID?
    var homeColumn: Int

    init(schemaVersion: Int = Favorites.currentSchemaVersion,
         bands: [ContextBand] = [], homeBandID: UUID? = nil, homeColumn: Int = 0) {
        self.schemaVersion = schemaVersion
        self.bands = bands
        self.homeBandID = homeBandID
        self.homeColumn = homeColumn
    }

    static let currentSchemaVersion = 1

    // MARK: Resolved, deterministic accessors (never recency-ordered)

    /// The launcher's entry band. v1: the **first** band, so reordering bands in the editor directly
    /// controls where the launcher opens. (`homeBandID` is retained for forward-compat / a future
    /// "pin home" setting, but does not override the first-band entry yet.)
    var homeBand: ContextBand? { bands.first }

    /// The home band's index in `bands` (0 when unset/missing), for the overlay's initial selection.
    var homeBandIndex: Int {
        guard let band = homeBand, let idx = bands.firstIndex(where: { $0.id == band.id }) else { return 0 }
        return idx
    }

    /// The home column, clamped to the home band's item range.
    var resolvedHomeColumn: Int {
        guard let band = homeBand, !band.items.isEmpty else { return 0 }
        return min(max(homeColumn, 0), band.items.count - 1)
    }

    /// Find an item anywhere in the tree by id (used to resolve preset references).
    func item(withID id: UUID) -> LaunchItem? {
        for band in bands {
            if let found = band.items.first(where: { $0.id == id }) { return found }
        }
        return nil
    }
}
