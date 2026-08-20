import AppKit

/// §11.3 — builds the **real** overlay demo models the Hub gesture previews render: a `SwitcherModel`
/// seeded with the user's actual windows (+ live thumbnails) and a `LauncherModel` seeded with the
/// user's actual bands. It is the Hub's analogue of `FirstTouchWizardModel.seedSampleDemo` /
/// `seedLauncherDemo`, reusing the SAME `realWindowRows` / `seedThumbnails` / `launcherBands`
/// providers the wizard does (handed in from `HubContext`).
///
/// Pure-ish by design: it has NO timers and drives nothing — it only constructs and seeds the models.
/// The pose loop that *drives* `setColumn` / `stepHorizontal` / `stepVertical` (and launches /
/// dismisses the launcher) lives in the preview component (§11.4), which owns the timing. The holder
/// degrades gracefully: empty `realWindowRows` falls back to stylized sample art so the page is alive
/// with no windows / no Accessibility, and `seedThumbnails` leaves icons in place when Screen
/// Recording is not granted.
@MainActor
struct HubPreviewModels {
    private let realWindowRows: () -> [[WindowInfo]]
    private let seedThumbnails: (SwitcherModel) -> Void
    private let launcherBands: (_ clipboardOn: Bool) -> [ContextBand]

    init(realWindowRows: @escaping () -> [[WindowInfo]],
         seedThumbnails: @escaping (SwitcherModel) -> Void,
         launcherBands: @escaping (_ clipboardOn: Bool) -> [ContextBand]) {
        self.realWindowRows = realWindowRows
        self.seedThumbnails = seedThumbnails
        self.launcherBands = launcherBands
    }

    /// Build the mini switcher's `SwitcherModel` for the Hub preview: the user's REAL windows grouped into
    /// Space-rows (`realWindowRows` is already grouped by the coordinator), at their true proportions and at
    /// the user's window-scale `maxScale`. Two fallbacks keep the preview alive and teachable:
    ///   - **Single / no window:** if the user has at most one real window (only the Hub is open), mimic two
    ///     icon-only windows so the row still reads as a real switcher.
    ///   - **Fewer than two Spaces:** fabricate a sample second Space, so the teaching demo's "up to the
    ///     second row, back down" move always has a row to reach.
    /// Thumbnails are NOT seeded here — the page seeds them against the RENDERED model so the post-reveal
    /// live-capture retries land there; the fabricated / icon-only windows simply stay icon-only.
    func makeSwitcherModel(canvas: CGSize, maxScale: CGFloat) -> SwitcherModel {
        let model = SwitcherModel()
        model.setCanvas(canvas)
        model.setMaxScale(maxScale)

        var rows = realWindowRows().filter { !$0.isEmpty }.map { Array($0.prefix(6)) }
        let totalWindows = rows.reduce(0) { $0 + $1.count }
        if totalWindows <= 1 {
            // At most one real window (just the Hub): mimic two icon-only windows.
            rows = [Self.iconOnlyWindows(count: 2, baseID: 930_000)]
        }
        // Ensure at least two Space-rows so the up/down teaching move always lands on a real row (the
        // requested "add a fake second Space" behavior).
        while rows.count < 2 {
            rows.append(Self.iconOnlyWindows(count: 3, baseID: CGWindowID(940_000 + rows.count * 100)))
        }
        let labels = rows.indices.map { String($0 + 1) }
        model.setRows(rows, labels: labels, startRow: 0, column: 0)
        return model
    }

    /// Build a `LauncherModel` seeded from the user's bands for the given toggles. `dwell` comes from
    /// the caller's settings (`dwellToArmDuration`). Lands on the band list at the home band (nothing
    /// armed), exactly as the real launcher / the wizard tour do.
    func makeLauncherModel(clipboardOn: Bool, dwell: Double) -> LauncherModel {
        let model = LauncherModel()
        model.dwell = dwell
        let bands = launcherBands(clipboardOn)
        guard !bands.isEmpty else { return model }
        model.setBands(bands.map(\.items),
                       names: bands.map(\.name),
                       colors: bands.map(\.color),
                       icons: bands.map(\.resolvedIcon),
                       startBand: 0,
                       column: 0,
                       clipboardBandIndex: bands.firstIndex(where: ClipboardBandBuilder.isClipboardBand))
        return model
    }

    /// A short row of **icon-only** mock windows — used for the single-window and fabricated-second-Space
    /// fallbacks. Each carries a real app icon (so it reads as a window) and a varied frame so the grid
    /// solves to true, different proportions; no thumbnail, so the card renders the icon.
    private static func iconOnlyWindows(count: Int, baseID: CGWindowID) -> [WindowInfo] {
        let apps = resolvedSampleApps(count)
        let aspects: [CGSize] = [CGSize(width: 1280, height: 800), CGSize(width: 1024, height: 768),
                                 CGSize(width: 900, height: 1300), CGSize(width: 1440, height: 900)]
        return (0..<count).map { i in
            WindowInfo(id: baseID + CGWindowID(i), pid: 0,
                       appName: apps[i].name, title: apps[i].name, appIcon: apps[i].icon,
                       frame: CGRect(origin: .zero, size: aspects[i % aspects.count]),
                       axElement: nil, isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
        }
    }

    /// Resolve up to `n` real app icons + names for the mock windows (degrading to the generic app icon for
    /// any that aren't installed), so the fallback looks like the user's own Mac rather than abstract art.
    private static func resolvedSampleApps(_ n: Int) -> [(icon: NSImage, name: String)] {
        let candidates: [(path: String, name: String)] = [
            ("/System/Library/CoreServices/Finder.app", "Finder"),
            ("/Applications/Safari.app", "Safari"),
            ("/System/Applications/Notes.app", "Notes"),
            ("/System/Applications/Music.app", "Music"),
            ("/System/Applications/Mail.app", "Mail"),
            ("/System/Applications/Calendar.app", "Calendar"),
            ("/System/Applications/Maps.app", "Maps")
        ]
        let workspace = NSWorkspace.shared
        var resolved: [(icon: NSImage, name: String)] = []
        for app in candidates where FileManager.default.fileExists(atPath: app.path) {
            resolved.append((workspace.icon(forFile: app.path), app.name))
            if resolved.count >= n { break }
        }
        let generic = NSImage(named: NSImage.applicationIconName) ?? NSImage()
        while resolved.count < n { resolved.append((generic, "Window \(resolved.count + 1)")) }
        return resolved
    }
}
