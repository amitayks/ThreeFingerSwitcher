import Foundation

/// One row in the Files Open-With picker (`files-band`). The picker lists the external applications that can
/// open the highlighted file. A pure value type — the controller acts on the case (an external open), the
/// view renders `label`.
enum OpenWithEntry: Identifiable, Equatable {
    /// Open in an external application (the system candidate).
    case external(OpenWithCandidate)

    /// Stable list identity (so re-querying associations doesn't strobe the highlight).
    var id: String {
        switch self {
        case let .external(candidate): return "external:\(candidate.id)"
        }
    }

    /// The human-facing row label: the application's display name.
    var label: String {
        switch self {
        case let .external(candidate):
            return candidate.app.name
        }
    }

    /// True when this is the file's default external application (so the view can mark it).
    var isDefault: Bool {
        if case let .external(candidate) = self { return candidate.isDefault }
        return false
    }
}

/// Builds the Open-With picker rows for a highlighted file: the external applications, in system order.
/// Pure and testable.
enum OpenWithEntries {
    /// - `externalApps`: the system Open-With candidates, in system order.
    static func build(externalApps: [OpenWithCandidate]) -> [OpenWithEntry] {
        externalApps.map(OpenWithEntry.external)
    }
}
