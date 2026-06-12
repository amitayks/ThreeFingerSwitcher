import Foundation

/// The playground tour's band composition — fixed and small, so the first contact with the
/// launcher reads in one glance:
///
/// - **flame** — every app currently scattered across the user's bands, gathered into one row.
/// - **display** — the twelve window-management actions (halves, quarters, maximize, center,
///   minimize, full screen): two exact rows of six.
/// - **sparkles** — only when AI is on: the user's AI commands (or the seeded set when they have
///   none yet).
/// - **clipboard** — only when history is on: the real clipboard band (sample entries while empty).
///
/// Nothing more. Pure value composition — unit-tested; the coordinator supplies the inputs.
enum WizardTourBands {
    /// The twelve window actions, in teaching order: position (halves), corner (quarters), then
    /// shape (maximize / center / minimize / full screen). Exactly two rows of the launcher's
    /// six-column grid.
    static let windowActions: [SystemAction] = [
        .tileLeftHalf, .tileRightHalf, .tileTopHalf, .tileBottomHalf,
        .tileTopLeft, .tileTopRight, .tileBottomLeft, .tileBottomRight,
        .maximizeWindow, .centerWindow, .minimizeWindow, .toggleFullScreen
    ]

    static func compose(userBands: [ContextBand],
                        aiOn: Bool,
                        seededAIBand: () -> ContextBand,
                        clipboardBand: ContextBand?) -> [ContextBand] {
        var result: [ContextBand] = [appsBand(from: userBands), windowsBand()]
        if aiOn {
            result.append(aiBand(from: userBands, seeded: seededAIBand))
        }
        if let clipboardBand {
            result.append(clipboardBand)
        }
        return result
    }

    /// flame: every `.app` item across the user's bands, deduped by bundle URL, original order.
    private static func appsBand(from userBands: [ContextBand]) -> ContextBand {
        var seen = Set<URL>()
        var apps: [LaunchItem] = []
        for band in userBands {
            for item in band.items {
                if case let .app(bundleURL, _) = item.kind, seen.insert(bundleURL).inserted {
                    apps.append(item)
                }
            }
        }
        return ContextBand(name: "Apps",
                           color: ItemColor(red: 0.95, green: 0.45, blue: 0.20),
                           icon: .sfSymbol("flame.fill"),
                           items: apps)
    }

    /// display: the twelve window actions as first-class `.action` items. Internal on purpose —
    /// `FavoritesStore.seeded()` ships this exact band as a DEFAULT band for new users, so the
    /// tour and the real launcher hold the same items by construction.
    static func windowsBand() -> ContextBand {
        ContextBand(name: "Windows",
                    color: ItemColor(red: 0.30, green: 0.62, blue: 0.78),
                    icon: .sfSymbol("display"),
                    items: windowActions.map { action in
                        LaunchItem(title: action.title, icon: .sfSymbol(action.symbol),
                                   kind: .action(action))
                    })
    }

    /// sparkles: the user's own AI commands gathered from their bands; the seeded band when they
    /// have none yet (fresh install, or AI just switched on in the wizard).
    private static func aiBand(from userBands: [ContextBand], seeded: () -> ContextBand) -> ContextBand {
        let owned = userBands.flatMap(\.items).filter {
            if case .aiCommand = $0.kind { return true } else { return false }
        }
        guard !owned.isEmpty else { return seeded() }
        return ContextBand(name: "AI",
                           color: ItemColor(red: 0.66, green: 0.36, blue: 0.86),
                           icon: .sfSymbol("sparkles"),
                           items: owned)
    }
}
