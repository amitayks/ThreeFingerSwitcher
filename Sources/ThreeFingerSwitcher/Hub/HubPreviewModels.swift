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
    private let launcherBands: (_ clipboardOn: Bool, _ aiOn: Bool) -> [ContextBand]

    init(realWindowRows: @escaping () -> [[WindowInfo]],
         seedThumbnails: @escaping (SwitcherModel) -> Void,
         launcherBands: @escaping (_ clipboardOn: Bool, _ aiOn: Bool) -> [ContextBand]) {
        self.realWindowRows = realWindowRows
        self.seedThumbnails = seedThumbnails
        self.launcherBands = launcherBands
    }

    /// Build a `SwitcherModel` for the mini switcher: the user's real windows (current Space) sized to
    /// `canvas`, the selection on a middle column, with live thumbnails seeded. Falls back to stylized
    /// sample windows (mirroring the wizard's `seedSampleDemo`) when there are no real rows — so the
    /// preview is alive even with no windows or no Accessibility.
    func makeSwitcherModel(canvas: CGSize) -> SwitcherModel {
        let model = SwitcherModel()
        let realRow = realWindowRows().first ?? []
        if realRow.isEmpty {
            // Sample art — no real windows / no Accessibility. Mirrors the wizard's sample strip.
            let cards: [(String, NSColor, NSColor)] = [
                ("Canvas", NSColor(calibratedRed: 0.42, green: 0.36, blue: 0.91, alpha: 1),
                           NSColor(calibratedRed: 0.20, green: 0.55, blue: 0.95, alpha: 1)),
                ("Notes",  NSColor(calibratedRed: 0.95, green: 0.62, blue: 0.25, alpha: 1),
                           NSColor(calibratedRed: 0.93, green: 0.35, blue: 0.42, alpha: 1)),
                ("Music",  NSColor(calibratedRed: 0.22, green: 0.72, blue: 0.55, alpha: 1),
                           NSColor(calibratedRed: 0.13, green: 0.45, blue: 0.60, alpha: 1)),
                ("Mail",   NSColor(calibratedRed: 0.60, green: 0.40, blue: 0.86, alpha: 1),
                           NSColor(calibratedRed: 0.90, green: 0.45, blue: 0.75, alpha: 1))
            ]
            let baseID: CGWindowID = 920_000
            let windows = cards.enumerated().map { index, card in
                WindowInfo(id: baseID + CGWindowID(index), pid: 0, appName: card.0, title: card.0,
                           appIcon: nil, frame: .zero, axElement: nil,
                           isOnCurrentSpace: true, spaceID: nil, spaceIndex: 0)
            }
            model.setCanvas(canvas)
            model.setRows([windows], labels: ["1"], startRow: 0, column: middleColumn(of: windows.count))
            for (index, card) in cards.enumerated() {
                model.setThumbnail(Self.gradientArt(from: card.1, to: card.2), for: baseID + CGWindowID(index))
            }
            return model
        }
        // Real windows — cap to a clean single row for the mini, seed live thumbnails.
        let row = Array(realRow.prefix(6))
        model.setCanvas(canvas)
        model.setRows([row], labels: ["1"], startRow: 0, column: middleColumn(of: row.count))
        seedThumbnails(model)
        return model
    }

    /// Build a `LauncherModel` seeded from the user's bands for the given toggles. `dwell` comes from
    /// the caller's settings (`dwellToArmDuration`). Lands on the band list at the home band (nothing
    /// armed), exactly as the real launcher / the wizard tour do.
    func makeLauncherModel(clipboardOn: Bool, aiOn: Bool, dwell: Double) -> LauncherModel {
        let model = LauncherModel()
        model.dwell = dwell
        let bands = launcherBands(clipboardOn, aiOn)
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

    /// A middle column so the demo opens with a centered selection (and has room to scrub either way).
    private func middleColumn(of count: Int) -> Int {
        guard count > 1 else { return 0 }
        return count / 2
    }

    /// A soft diagonal gradient "window" — deliberately abstract (art, not a fake screenshot), mirroring
    /// the wizard's sample art so the no-window fallback reads as one app with onboarding.
    private static func gradientArt(from: NSColor, to: NSColor) -> NSImage {
        let size = NSSize(width: 400, height: 300)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGradient(starting: from, ending: to)?
            .draw(in: NSRect(origin: .zero, size: size), angle: -35)
        NSColor.white.withAlphaComponent(0.18).setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 230, width: 200, height: 26), xRadius: 13, yRadius: 13).fill()
        NSColor.white.withAlphaComponent(0.10).setFill()
        NSBezierPath(roundedRect: NSRect(x: 22, y: 40, width: 356, height: 170), xRadius: 10, yRadius: 10).fill()
        image.unlockFocus()
        return image
    }
}
