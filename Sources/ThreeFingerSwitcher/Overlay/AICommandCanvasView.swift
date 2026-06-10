import SwiftUI
import AppKit

/// The AI command **streaming preview canvas** (spec launcher-overlay: "AI command streaming preview
/// canvas" + "Swipe-to-resolve (commit / discard)" + "Armed-confirmation state"). It replaces the launcher grid while an
/// AI command is in flight, binding to the injected `AICommandExecutor`'s observable `state` so the
/// model's result fills in **incrementally** as it streams — the same live-render pattern the
/// `ClipboardBandView` value preview uses, here driven by `@Published state` rather than `.task(id:)`.
///
/// The overlay panel stays non-activating throughout (the captured front app remains key); this view
/// is pure presentation. The gesture wiring (a fresh four-finger DOWN swipe commits, a horizontal
/// swipe discards; a stray re-lift is a no-op) lives in `LauncherOverlayController`; this view only
/// reflects the executor's state and shows the matching commit/discard affordance hint per state.
struct AICommandCanvasView: View {
    @ObservedObject var executor: AICommandExecutor
    /// The command being run (its name titles the canvas).
    let command: AICommand
    /// The command's tint (falls back to the band color) for the header + accents.
    let tint: Color
    /// Enable/download wiring for the `.unavailable` state (configuration-hub). Optional so the canvas
    /// still renders without it (a defensive fallback message); wired by the launcher overlay.
    var availability: AICanvasAvailability? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().opacity(0.35).padding(.vertical, 8)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().opacity(0.3).padding(.top, 8)
            footerHint
        }
        .padding(.top, 6)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
            Text(command.name)
                .font(.system(size: 18, weight: .semibold))
            Spacer()
            statusBadge
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch executor.state {
        case .loadingModel:
            badge("Loading…", systemImage: "hourglass", color: .secondary)
        case .streaming:
            badge("Generating…", systemImage: "dot.radiowaves.left.and.right", color: tint)
        case .ready:
            badge("Ready", systemImage: "checkmark.circle.fill", color: .green)
        case .reviewingAction:
            badge("Review", systemImage: "exclamationmark.shield.fill", color: .orange)
        case .noInput:
            badge("No input", systemImage: "text.cursor", color: .secondary)
        case .declined:
            badge("Declined", systemImage: "hand.raised.fill", color: .secondary)
        case .failed:
            badge("Failed", systemImage: "exclamationmark.triangle.fill", color: .red)
        case .unavailable:
            badge("Unavailable", systemImage: "exclamationmark.circle.fill", color: .orange)
        case .committed:
            badge("Done", systemImage: "checkmark.seal.fill", color: .green)
        case .idle:
            EmptyView()
        }
    }

    // MARK: Content (the live preview surface)

    @ViewBuilder
    private var content: some View {
        switch executor.state {
        case .idle, .loadingModel:
            centered {
                ProgressView().controlSize(.large)
                Text("Loading the model…").font(.system(size: 14)).foregroundStyle(.secondary)
            }
        case .noInput:
            centered {
                Image(systemName: "text.cursor").font(.system(size: 40)).foregroundStyle(.secondary)
                Text("No input").font(.system(size: 16, weight: .medium))
                Text("Select some text (or copy something) and try again.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        case let .streaming(partial):
            resultScroll(text: partial.isEmpty ? "…" : partial)
        case let .ready(result):
            resultScroll(text: result)
        case let .reviewingAction(review):
            reviewFields(review)   // `review` is the TaskReview carried by the state
        case let .declined(reason):
            centered {
                Image(systemName: "hand.raised.fill").font(.system(size: 36)).foregroundStyle(.secondary)
                Text("The model declined this command").font(.system(size: 15, weight: .medium))
                Text(reason).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6).truncationMode(.middle)   // bounded so a long reason can't overflow the panel
            }
        case let .failed(message):
            centered {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.red)
                Text("Something went wrong").font(.system(size: 15, weight: .medium))
                Text(message).font(.system(size: 12)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(6).truncationMode(.middle)   // bounded for symmetry with the Settings row cap
            }
        case .unavailable:
            if let availability {
                AIUnavailableCanvas(settings: availability.settings,
                                    models: availability.models,
                                    tint: tint,
                                    onDownload: availability.onDownload)
            } else {
                centered {
                    Image(systemName: "sparkles").font(.system(size: 40)).foregroundStyle(.secondary)
                    Text("AI is unavailable").font(.system(size: 16, weight: .medium))
                    Text("Enable AI commands and download the model in the Hub.")
                        .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        case .committed:
            centered {
                Image(systemName: "checkmark.seal.fill").font(.system(size: 40)).foregroundStyle(.green)
                Text("Done").font(.system(size: 16, weight: .medium))
            }
        }
    }

    /// The streamed/ready text, scrollable, in the canvas's large value pane.
    private func resultScroll(text: String) -> some View {
        ScrollView {
            Text(text)
                .font(.system(size: 14))
                .textSelection(.disabled)
                .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    /// The armed-confirmation review: the parsed action's concrete fields, before the commit fires the
    /// side effect (spec: "displays the parsed action's concrete fields before it can be committed").
    @ViewBuilder
    private func reviewFields(_ taskReview: TaskReview) -> some View {
        if case let .action(title, fields, _) = taskReview {
            VStack(alignment: .leading, spacing: 12) {
                Text(title).font(.system(size: 15, weight: .semibold))
                ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(field.label).font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.secondary).textCase(.uppercase)
                        Text(field.value).font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Swipe down to confirm the action, or swipe aside to cancel.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(.top, 4)
            }
        } else {
            Color.clear
        }
    }

    // MARK: Footer hint

    /// A short hint that mirrors the available gestures for the current state, so a signed-build user
    /// knows that a fresh four-finger DOWN swipe commits/applies and a HORIZONTAL swipe discards. The
    /// gestures themselves are in the controller; a stray re-lift is a no-op, so it is never advertised.
    @ViewBuilder
    private var footerHint: some View {
        switch executor.state {
        case .ready:
            hint("Swipe down to apply", "Swipe aside to discard")
        case .reviewingAction:
            hint("Swipe down to confirm", "Swipe aside to cancel")
        case .streaming:
            hint(nil, "Swipe aside to discard")
        case .noInput, .declined, .failed, .unavailable, .committed:
            hint(nil, "Swipe aside to dismiss")
        case .idle, .loadingModel:
            hint(nil, "Swipe aside to cancel")
        }
    }

    @ViewBuilder
    private func hint(_ commit: String?, _ discard: String?) -> some View {
        HStack(spacing: 16) {
            if let commit {
                Label(commit, systemImage: "arrow.down.circle.fill")   // down swipe = bring it into the document
                    .font(.system(size: 12)).foregroundStyle(tint)
            }
            Spacer()
            if let discard {
                Label(discard, systemImage: "arrow.left.and.right.circle.fill")   // sideways swipe = discard
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Helpers

    private func badge(_ text: String, systemImage: String, color: Color) -> some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
    }

    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 10) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Enable/download wiring the canvas needs for its `.unavailable` state (configuration-hub). Holds the
/// observable `AppSettings` + `ModelManager` (the unavailable subview observes them) and the download
/// action. A value type so the overlay can set it on every `show` without retaining cycles.
struct AICanvasAvailability {
    let settings: AppSettings
    let models: ModelManager
    /// Begin (or retry) the on-device model download (honors the selected model). Continues in the
    /// background after the canvas is dismissed.
    let onDownload: () -> Void
}

/// The canvas body for `.unavailable`: a clean message plus Enable / Download actions and a model
/// picker, reflecting live opt-in + model state. Dismissable like any canvas (a horizontal swipe);
/// any download it starts keeps running in the background.
private struct AIUnavailableCanvas: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var models: ModelManager
    let tint: Color
    let onDownload: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header
                if !settings.aiCommandsEnabled {
                    Button { settings.aiCommandsEnabled = true } label: {
                        Label("Turn on AI commands", systemImage: "power")
                    }
                    .buttonStyle(.borderedProminent)
                }
                modelPicker
                statusRow
                Text("Swipe aside to dismiss — any download keeps running in the background.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(settings.aiCommandsEnabled ? "Model not downloaded yet" : "AI commands are turned off")
                .font(.system(size: 16, weight: .semibold))
            Text(settings.aiCommandsEnabled
                 ? "Download the on-device model to run this command. It runs entirely on your Mac."
                 : "Turn AI on and download the on-device model to run this command.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var modelPicker: some View {
        let registry = ModelRegistry.standard
        Picker("Model", selection: Binding(
            get: { settings.aiSelectedModelID },
            set: { settings.aiSelectedModelID = $0 })) {
            Text("Default (\(registry.defaultDescriptor?.displayName ?? "registry"))").tag(String?.none)
            ForEach(registry.models, id: \.id) { model in
                Text(model.displayName).tag(String?.some(model.id))
            }
        }
        .pickerStyle(.menu)
        .disabled(!settings.aiCommandsEnabled)
    }

    @ViewBuilder
    private var statusRow: some View {
        switch models.state {
        case .notDownloaded:
            Button { onDownload() } label: { Label("Download model", systemImage: "arrow.down.circle") }
                .buttonStyle(.bordered)
                .disabled(!settings.aiCommandsEnabled)
        case let .downloading(progress):
            HStack(spacing: 8) {
                ProgressView(value: progress).frame(width: 140)
                Text("Downloading… \(Int(progress * 100))%").font(.system(size: 12)).foregroundStyle(.secondary)
            }
        case .verifying:
            Label("Verifying…", systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(.secondary)
        case .ready, .loading, .loaded:
            Label("Model ready — fire the command again.", systemImage: "checkmark.circle.fill")
                .font(.system(size: 12)).foregroundStyle(.green)
        case let .failed(reason, _):
            VStack(alignment: .leading, spacing: 6) {
                Text(reason).font(.system(size: 12)).foregroundStyle(.red)
                    .lineLimit(3).truncationMode(.middle)
                Button { onDownload() } label: { Label("Retry download", systemImage: "arrow.clockwise") }
                    .buttonStyle(.bordered)
                    .disabled(!settings.aiCommandsEnabled)
            }
        }
    }
}
