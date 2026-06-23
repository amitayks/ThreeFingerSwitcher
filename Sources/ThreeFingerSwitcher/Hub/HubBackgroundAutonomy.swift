import SwiftUI
import AppKit

// The Hub AI page's **Background autonomy** section (`ai-background-autonomy`, §7): the user-editable
// whitelist editor (trusted folder prefixes + command patterns, persisted to `AppSettings`) and the
// append-only audit-log viewer ("what your agents did while you were away"). App-target view code
// (`xcodebuild` compile-verify; the user run-verifies the live feel). Both surfaces reuse the shared
// `HubSection` Liquid Glass presentation. A store-persist failure is surfaced as a bounded, non-blocking
// banner — NEVER an `NSAlert` (house rule), the headline routed through the single `AIError.message(for:)`.

// MARK: - The whitelist editor (trusted paths + command patterns)

/// The whitelist editor: add/remove trusted **folder path prefixes** (picked as local folders only) and
/// trusted **command patterns** (anchored globs). Binds directly to the persisted `AppSettings` arrays —
/// the single source of truth the agent's `BackgroundPolicyResolver` reads. Default-empty (a fresh install
/// trusts nothing arbitrary).
struct HubWhitelistEditor: View {
    @Binding var trustedPaths: [String]
    @Binding var trustedCommands: [String]
    /// Disabled when the AI feature is off (the whitelist only matters while the agent runs).
    let isEnabled: Bool

    /// The in-progress command pattern the user is typing before committing it with the add button.
    @State private var newCommand = ""

    var body: some View {
        HubSection("Background autonomy — trusted writes",
                   footnote: "Whitelisting a folder or command lets a parked agent run a matching write automatically (still audited). Dangerous operations — delete, overwrite an existing file, arbitrary shell — are NEVER made automatic by the whitelist. Empty by default: a fresh install trusts nothing on your wider filesystem.") {
            trustedFolders
            Divider()
            trustedCommandPatterns
        }
        .disabled(!isEnabled)
    }

    // MARK: Trusted folders (path prefixes)

    @ViewBuilder private var trustedFolders: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trusted folders").font(.callout).bold()
            if trustedPaths.isEmpty {
                Text("No trusted folders. A write under a trusted folder runs in the background; off-list writes still ask.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(trustedPaths, id: \.self) { path in
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(displayPath(path)).font(.callout).lineLimit(1).truncationMode(.middle)
                        .help(path)
                    Spacer(minLength: 8)
                    Button { trustedPaths.removeAll { $0 == path } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop trusting \(path)")
                }
            }
            Button { addFolder() } label: {
                Label("Add trusted folder…", systemImage: "plus")
            }
            .buttonStyle(.borderless)
        }
    }

    // MARK: Trusted command patterns (globs)

    @ViewBuilder private var trustedCommandPatterns: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trusted command patterns").font(.callout).bold()
            if trustedCommands.isEmpty {
                Text("No trusted commands. A command (tool / Shortcut / shell name) matching a pattern below runs in the background. Use * and ? as wildcards (e.g. git*).")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            ForEach(trustedCommands, id: \.self) { pattern in
                HStack(spacing: 8) {
                    Image(systemName: "terminal").foregroundStyle(.secondary)
                    Text(pattern).font(.system(.callout, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                    Spacer(minLength: 8)
                    Button { trustedCommands.removeAll { $0 == pattern } } label: {
                        Image(systemName: "minus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Stop trusting \(pattern)")
                }
            }
            HStack(spacing: 8) {
                TextField("Command pattern (e.g. git*)", text: $newCommand)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.callout, design: .monospaced))
                    .onSubmit { addCommand() }
                Button { addCommand() } label: { Image(systemName: "plus.circle.fill") }
                    .buttonStyle(.borderless)
                    .disabled(trimmedNewCommand.isEmpty)
            }
        }
    }

    // MARK: Actions (pure, local-folder-only validation)

    private var trimmedNewCommand: String {
        newCommand.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Commit the typed command pattern (de-duplicated, trimmed).
    private func addCommand() {
        let pattern = trimmedNewCommand
        guard !pattern.isEmpty, !trustedCommands.contains(pattern) else { newCommand = ""; return }
        trustedCommands.append(pattern)
        newCommand = ""
    }

    /// Folder pick via `NSOpenPanel`, **local folders only** (network / iCloud-placeholder rejected per the
    /// spec's "only local folders" scenario). Stores the standardized absolute path; de-duplicates.
    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.canCreateDirectories = false
        panel.prompt = "Trust"
        panel.message = "Choose a local folder a parked agent may write into automatically."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where HubWhitelistEditor.isLocalFolder(url) {
            let std = url.standardizedFileURL.resolvingSymlinksInPath().path
            if !trustedPaths.contains(std) { trustedPaths.append(std) }
        }
    }

    /// Accept only a genuinely local, non-placeholder folder (reject network volumes and iCloud
    /// not-yet-downloaded placeholders). The spec's "only local folders can be added" scenario.
    static func isLocalFolder(_ url: URL) -> Bool {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .volumeIsLocalKey, .isUbiquitousItemKey]
        guard let values = try? url.resourceValues(forKeys: keys) else { return false }
        guard values.isDirectory == true else { return false }
        if values.isUbiquitousItem == true { return false }      // iCloud placeholder
        if values.volumeIsLocal == false { return false }        // network volume
        return true
    }

    /// Abbreviate `/Users/me/Notes` to `~/Notes` for display (the full path stays in the row's `help`).
    private func displayPath(_ path: String) -> String {
        (path as NSString).abbreviatingWithTildeInPath
    }
}

// MARK: - The audit-log viewer ("what your agents did while you were away")

/// The audit-log viewer (§7.2): a bounded, reverse-chronological ledger of recent tool steps — each row
/// shows the tool, the redacted args summary, the effective tier, the outcome (a `.failed` as a clean
/// headline + opt-in details disclosure), a timestamp, and whether it ran in the background. Reads the
/// Core `AuditLog` synchronously via the `HubContext` seam. A store-persist failure shows as a bounded,
/// non-blocking banner (NEVER an `NSAlert`).
struct HubAuditLogViewer: View {
    /// Pulls the most-recent records on each render (synchronous read seam).
    let records: (_ limit: Int) -> [AuditRecord]
    /// A clean headline if the durable store last failed to persist (else `nil`) — already routed through
    /// `AIError.message(for:)`, so the headline is safe and the details copyable.
    let persistError: () -> AIPresentedError?

    /// How many recent records the viewer shows.
    private let limit = 100

    var body: some View {
        HubSection("Audit log",
                   footnote: "Every tool step your agents ran — automatic, confirmed, skipped, or failed — newest first. “While you were away” marks steps that ran in the background while a session was parked.") {
            if let error = persistError() {
                AuditPersistBanner(error: error)
                Divider()
            }
            let recent = records(limit)
            if recent.isEmpty {
                Text("No agent activity yet. When an agent runs a tool step, it appears here.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(recent) { record in
                    AuditRow(record: record)
                    if record.id != recent.last?.id { Divider() }
                }
            }
        }
    }
}

/// One audit row — tool + redacted summary on top, the effective tier · outcome · timestamp below, with a
/// "while you were away" tag for background steps and an opt-in details disclosure for a failure headline's
/// copyable detail.
private struct AuditRow: View {
    let record: AuditRecord
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: outcomeIcon).foregroundStyle(outcomeTint)
                Text(record.tool).font(.callout).bold().lineLimit(1).truncationMode(.middle)
                if record.wasBackground {
                    Text("while you were away")
                        .font(.caption2).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
                Spacer(minLength: 8)
                Text(record.timestamp, format: .relative(presentation: .named))
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !record.argumentsSummary.isEmpty {
                Text(record.argumentsSummary)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle)
            }
            HStack(spacing: 6) {
                tierBadge
                Text(outcomeLabel).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let detail = failureDetail {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(detail)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4).truncationMode(.middle)
                } label: {
                    Text("Show details").font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var tierBadge: some View {
        Text(tierLabel)
            .font(.caption2.bold())
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Capsule().fill(tierTint.opacity(0.18)))
            .foregroundStyle(tierTint)
    }

    private var tierLabel: String {
        switch record.policy {
        case .auto:      return "AUTO"
        case .confirm:   return "CONFIRM"
        case .dangerous: return "DANGEROUS"
        }
    }

    private var tierTint: Color {
        switch record.policy {
        case .auto:      return .green
        case .confirm:   return .blue
        case .dangerous: return .orange
        }
    }

    private var outcomeLabel: String {
        switch record.outcome {
        case .done:                       return "Done"
        case .awaitingApproval:           return "Awaiting your approval"
        case let .declined(reason):       return reason.isEmpty ? "Skipped" : "Skipped — \(reason)"
        case let .failed(headline):       return headline
        }
    }

    private var outcomeIcon: String {
        switch record.outcome {
        case .done:             return "checkmark.circle.fill"
        case .awaitingApproval: return "hourglass.circle.fill"
        case .declined:         return "slash.circle.fill"
        case .failed:           return "exclamationmark.triangle.fill"
        }
    }

    private var outcomeTint: Color {
        switch record.outcome {
        case .done:             return .green
        case .awaitingApproval: return .blue
        case .declined:         return .secondary
        case .failed:           return .orange
        }
    }

    /// A failed outcome's headline is already clean; the disclosure simply re-shows it as the copyable
    /// detail (the audit record stores only the headline, never raw OS text — by design).
    private var failureDetail: String? {
        if case let .failed(headline) = record.outcome { return headline }
        return nil
    }
}

/// The bounded, non-blocking store-persist failure banner (house rule: never `NSAlert`; headline clean,
/// details opt-in). Mirrors the AI canvas's failure card.
private struct AuditPersistBanner: View {
    let error: AIPresentedError
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                Text(error.headline)
                    .font(.callout)
                    .lineLimit(2).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            if let details = error.details {
                DisclosureGroup(isExpanded: $showDetails) {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(4).truncationMode(.middle)
                } label: {
                    Text("Show details").font(.caption2)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
    }
}
