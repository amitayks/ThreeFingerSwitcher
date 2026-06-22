import Foundation

/// Known terminals and editors the Files action menu can "open a folder in" (`files-action-menu`). Pure
/// data — bundle-id seeds + display names, in a sensible default order. The boundary (`AppCoordinator`)
/// probes which are actually installed (via `NSWorkspace.urlForApplication(withBundleIdentifier:)`) and
/// applies the user's curation (`AppSettings.filesToolsDisabled`); this file holds no AppKit dependency so
/// the seed list stays unit-inspectable.
enum FilesToolCatalog {
    /// `(bundleID, display name)` for terminals, Apple Terminal first.
    static let terminals: [(bundleID: String, name: String)] = [
        ("com.apple.Terminal", "Terminal"),
        ("com.googlecode.iterm2", "iTerm"),
        ("dev.warp.Warp-Stable", "Warp"),
        ("com.github.wez.wezterm", "WezTerm"),
        ("net.kovidgoyal.kitty", "kitty"),
        ("org.alacritty", "Alacritty"),
        ("com.mitchellh.ghostty", "Ghostty"),
        ("co.zeit.hyper", "Hyper")
    ]
    /// `(bundleID, display name)` for code editors.
    static let editors: [(bundleID: String, name: String)] = [
        ("com.microsoft.VSCode", "VS Code"),
        ("com.todesktop.230313mzl4w4u92", "Cursor"),
        ("com.sublimetext.4", "Sublime Text"),
        ("dev.zed.Zed", "Zed"),
        ("com.apple.dt.Xcode", "Xcode")
    ]
}
