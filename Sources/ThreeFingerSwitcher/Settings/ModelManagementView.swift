import SwiftUI
import AppKit

/// The on-device model-management surface (spec: "AI model management settings"). Binds to an
/// injected `ModelManager` (`@ObservedObject`) and renders its observable `ModelLifecycleState`:
/// the selected model's identity + size, the download status/progress, and the available actions
/// (download / retry, evict). Pure presentation — every action calls back into the manager, which
/// owns the lifecycle; the view re-renders as `@Published state` advances.
///
/// The view takes the resolved `ModelDescriptor` it represents (the selected model) so the call site
/// — Settings, with `AppSettings.aiSelectedModelID` resolved against `ModelRegistry` — decides which
/// model is shown; the view just reflects the manager's state for it.
struct ModelManagementView: View {
    @ObservedObject var manager: ModelManager

    /// The model this surface represents (selected model). Defaults to the registry default.
    var descriptor: ModelDescriptor

    /// Begin (or retry) the download. The call site supplies it so the view stays free of the async
    /// orchestration / error handling; it just triggers the action and reflects the resulting state.
    var onDownload: () -> Void = {}

    /// Whether the raw "Show details" disclosure is expanded for a failure (collapsed by default —
    /// detail is opt-in, never shown inline; design D4).
    @State private var showingDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(descriptor.displayName).font(.headline)
                    Text(sizeLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }

            statusRow

            actionRow
        }
        .padding(.vertical, 2)
    }

    // MARK: Status

    @ViewBuilder
    private var statusRow: some View {
        switch manager.state {
        case .notDownloaded:
            label("Not downloaded", systemImage: "arrow.down.circle", color: .secondary)
        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 4) {
                label("Downloading… \(Int(progress * 100))%", systemImage: "arrow.down.circle.fill", color: .accentColor)
                ProgressView(value: progress)
            }
        case .verifying:
            label("Verifying…", systemImage: "checkmark.shield", color: .accentColor)
        case .ready:
            label("Downloaded (not loaded)", systemImage: "internaldrive", color: .secondary)
        case .loading:
            label("Loading into memory…", systemImage: "memorychip", color: .accentColor)
        case .loaded:
            label("Loaded and ready", systemImage: "checkmark.circle.fill", color: .green)
        case let .failed(reason, details):
            VStack(alignment: .leading, spacing: 6) {
                label("Failed", systemImage: "exclamationmark.triangle.fill", color: .red)
                // The concise headline is primary: capped + middle-truncating + selectable, so an
                // unexpectedly long message degrades gracefully instead of overflowing the fixed frame.
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                if let details, !details.isEmpty {
                    detailsDisclosure(details)
                }
            }
        }
    }

    /// A collapsed "Show details" disclosure for the raw technical text behind a failure: bounded
    /// (scrolls past ~120pt) so even a giant dump can't grow the row, with a "Copy details" action.
    @ViewBuilder
    private func detailsDisclosure(_ details: String) -> some View {
        DisclosureGroup(isExpanded: $showingDetails) {
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    Text(details)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(details, forType: .string)
                } label: {
                    Label("Copy details", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            .padding(.top, 4)
        } label: {
            Text("Show details").font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Actions

    @ViewBuilder
    private var actionRow: some View {
        HStack {
            switch manager.state {
            case .notDownloaded:
                Button("Download") { onDownload() }
            case .failed:
                Button("Retry download") { onDownload() }
            case .downloading, .verifying, .loading:
                ProgressView().controlSize(.small)
            case .ready:
                Text("Loads on demand when a command runs.")
                    .font(.caption).foregroundStyle(.secondary)
            case .loaded:
                Button("Evict from memory") { manager.evict() }
                    .help("Unloads the model from memory; the next command reloads it on demand.")
            }
            Spacer()
        }
    }

    // MARK: Helpers

    private var sizeLabel: String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: descriptor.sizeBytes)
    }

    private func label(_ text: String, systemImage: String, color: Color) -> some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(color)
        }
        .font(.subheadline)
    }
}
