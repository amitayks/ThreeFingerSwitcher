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

    /// Whether the collapsible Thinking section is expanded. COLLAPSED by default: the user sees only a
    /// pulsing "Thinking…" label + a live elapsed timer until they tap to expand the full reasoning.
    @State private var thinkingExpanded = false
    /// When the model's reasoning FIRST became non-empty — anchors the live elapsed timer. Set once per
    /// fire (cleared when thinking goes empty on a re-run/discard), so the timer counts from first token.
    @State private var thinkingStart: Date?
    /// When reasoning FINISHED — the moment the response began (or generation otherwise completed). Once
    /// set, the elapsed readout FREEZES at this value instead of ticking forever (the timer must stop once
    /// the model is done thinking + answering). Cleared with `thinkingStart` on a re-run/discard.
    @State private var thinkingEnd: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The language picker rides at the top-middle of the canvas as a centered Liquid-Glass pill,
            // above the header, only for translate-style commands (`showsLanguagePicker`).
            if showsLanguagePicker {
                HStack { Spacer(); languagePill; Spacer() }
                    .padding(.bottom, 6)
            }
            header
            Divider().opacity(0.35).padding(.vertical, 8)
            // The model's reasoning ("show the model's thinking"): a collapsible, scrollable section
            // under the header and above the response content. Rendered only while there's thinking to
            // show; the RESPONSE below is always the committed text (never the thinking).
            if !executor.thinking.isEmpty {
                thinkingSection
                    .padding(.bottom, 8)
            }
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider().opacity(0.3).padding(.top, 8)
            footerHint
        }
        .padding(.top, 6)
        // Anchor the elapsed timer to the moment thinking first appears; clear it (and the frozen end)
        // when thinking resets (a fresh fire / discard empties `executor.thinking`), so the next run times
        // from scratch. Also collapse the Thinking section on reset so a previously-expanded run doesn't
        // leak its expanded state into the next fire (keeps the collapsed-by-default behavior).
        .onChange(of: executor.thinking.isEmpty) { _, isEmpty in
            thinkingStart = isEmpty ? nil : (thinkingStart ?? Date())
            if isEmpty { thinkingExpanded = false; thinkingEnd = nil }
        }
        // Freeze the elapsed timer the moment reasoning finishes (the response begins, or generation
        // otherwise completes) — set once, so it stops ticking instead of counting forever.
        .onChange(of: reasoningFinished) { _, finished in
            if finished, thinkingStart != nil, thinkingEnd == nil { thinkingEnd = Date() }
        }
        // Update the resolve gate: a fresh DOWN swipe applies only when every scrollable region is at its
        // top (so scrolling the response/thinking never inserts). The reduce ANDs all reporters.
        .onPreferenceChange(CanvasAtTopKey.self) { atTop in
            executor.canvasAtTop = atTop
        }
        .onAppear {
            if !executor.thinking.isEmpty, thinkingStart == nil { thinkingStart = Date() }
            if reasoningFinished, thinkingStart != nil, thinkingEnd == nil { thinkingEnd = Date() }
        }
    }

    /// Whether the model has finished REASONING: false while loading or while only thinking is streaming
    /// (the response is still empty); true once the response begins streaming or any terminal state is
    /// reached. Drives the one-shot freeze of the elapsed timer.
    private var reasoningFinished: Bool {
        switch executor.state {
        case .idle, .loadingModel: return false
        case let .streaming(partial): return !partial.isEmpty   // response started → thinking is done
        default: return true                                    // ready / review / declined / failed / …
        }
    }

    // MARK: Thinking (collapsible reasoning)

    /// The collapsible "show the model's thinking" section. COLLAPSED (default) = a pulsing "✦ Thinking…"
    /// label + a live elapsed timer (so the user sees it's alive, not stuck) and a `chevron.right`.
    /// EXPANDED = a bounded, scrollable `BidiText` of the full streamed reasoning (capped at 160pt so it
    /// never sprawls) + a `chevron.down`. Tapping the row toggles — the canvas is interactive for its
    /// whole life (see `setCanvasInteractive`), so the tap lands.
    private var thinkingSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                thinkingExpanded.toggle()
            } label: {
                thinkingHeaderRow
            }
            .buttonStyle(.plain)

            if thinkingExpanded {
                thinkingExpandedBody
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.white.opacity(0.08)))
    }

    /// The always-visible header row: a pulsing sparkle + "Thinking…", a live elapsed readout, and a
    /// chevron reflecting the expanded/collapsed state.
    private var thinkingHeaderRow: some View {
        HStack(spacing: 8) {
            // A gentle pulse signals the reasoning is alive (TimelineView so it animates without a
            // bound @State; harmless once thinking finishes — it just keeps a calm idle pulse).
            TimelineView(.periodic(from: .now, by: 0.6)) { ctx in
                let phase = ctx.date.timeIntervalSinceReferenceDate
                Image(systemName: "sparkles")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tint)
                    .opacity(0.55 + 0.45 * (0.5 + 0.5 * sin(phase * 2.6)))
            }
            Text(reasoningFinished ? "Thought" : "Thinking…")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
            elapsedLabel
            Spacer()
            Image(systemName: thinkingExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .contentShape(Rectangle())   // the whole row is tappable, not just the glyphs
    }

    /// A live elapsed readout. While reasoning is in flight it recomputes ~10×/s off a `TimelineView` so
    /// the user sees it ticking; once `thinkingEnd` is set it FREEZES at the final duration (stops
    /// counting). Shows "3.2s" under a minute, "mm:ss" beyond, anchored at `thinkingStart`.
    @ViewBuilder
    private var elapsedLabel: some View {
        if let start = thinkingStart {
            if let end = thinkingEnd {
                // Frozen: reasoning finished — show the final duration, no longer ticking.
                Text(Self.elapsedString(end.timeIntervalSince(start)))
                    .font(.system(size: 11, weight: .regular).monospacedDigit())
                    .foregroundStyle(.secondary)
            } else {
                TimelineView(.periodic(from: .now, by: 0.1)) { ctx in
                    Text(Self.elapsedString(ctx.date.timeIntervalSince(start)))
                        .font(.system(size: 11, weight: .regular).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// Format an elapsed interval: "3.2s" under a minute, "m:ss" at/over a minute. Pure (testable).
    static func elapsedString(_ seconds: TimeInterval) -> String {
        let s = max(0, seconds)
        if s < 60 { return String(format: "%.1fs", s) }
        let total = Int(s)
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// The expanded reasoning: a bounded, scrollable `BidiText` of the full streamed thinking, auto-
    /// scrolling to the tail as it grows (a ScrollViewReader, best-effort). Capped at 160pt so streaming
    /// reasoning never pushes the response off the canvas.
    private var thinkingExpandedBody: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Color.clear.frame(height: 1).id(Self.thinkingHeadID)   // top anchor
                    BidiText(text: executor.thinking, fontSize: 12, color: .secondaryLabelColor)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                    Color.clear.frame(height: 1).id(Self.thinkingTailID)   // bottom anchor
                }
                .background(atTopReporter(space: Self.thinkingScrollSpace))
            }
            .frame(maxHeight: 160)
            .coordinateSpace(name: Self.thinkingScrollSpace)
            .onChange(of: executor.thinking) {
                // Follow the tail only WHILE reasoning is still streaming, so the user watches it grow.
                guard !reasoningFinished else { return }
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo(Self.thinkingTailID, anchor: .bottom)
                }
            }
            .onChange(of: reasoningFinished) { _, finished in
                // When reasoning ends, rest at the TOP (read from the start, and so the box reports at-top
                // and never blocks the commit gate from a stale tail position).
                if finished {
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(Self.thinkingHeadID, anchor: .top) }
                }
            }
        }
    }

    /// Stable ids for the top / bottom scroll anchors of the expanded reasoning.
    private static let thinkingHeadID = "ai-thinking-head"
    private static let thinkingTailID = "ai-thinking-tail"

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

    // MARK: Runtime language picker

    /// Whether the in-canvas language dropdown is shown: only when the active command declares a
    /// language runtime parameter (`executor.activeLanguage != nil`) AND the state still has a result
    /// worth re-translating. It rides across the in-flight/result states (loadingModel, streaming,
    /// ready, reviewingAction, …) but is hidden where re-running makes no sense — `.idle` (nothing in
    /// flight), `.unavailable` (the enable/download canvas owns the surface), and `.committed` (done).
    private var showsLanguagePicker: Bool {
        guard executor.activeLanguage != nil else { return false }
        switch executor.state {
        case .idle, .unavailable, .committed: return false
        default: return true
        }
    }

    /// A centered Liquid-Glass pill at the top-middle of the canvas reading as the "Detect language →
    /// dropdown" flow: a leading globe glyph + a subtle "Auto-detect" label, an arrow "→", then the
    /// language `Menu`. Picking one calls `executor.setLanguage`, which cancels + re-runs the command in
    /// place and persists the choice (the view only wires the control). The options come from the ACTIVE
    /// command's declared parameter — human languages for Translate, programming languages for "Rewrite
    /// in Language" — falling back to `AILanguages.all`. The current `executor.activeLanguage` is always
    /// included (prepended if missing, mirroring `AILanguages.including`) so a persisted/declared default
    /// off the canonical list stays selectable. The glass treatment matches `HubGlass` / `LauncherView`
    /// (macOS 26+ `glassEffect`, `.ultraThinMaterial` fallback).
    private var languagePill: some View {
        let opts = command.runtimeParameter?.options ?? AILanguages.all
        let active = executor.activeLanguage ?? opts.first ?? "English"
        let options = opts.contains(active) ? opts : [active] + opts
        return HStack(spacing: 8) {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
            Text("Auto-detect")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            Menu {
                ForEach(options, id: \.self) { language in
                    Button(language) { executor.setLanguage(language) }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(executor.activeLanguage ?? "English")
                        .font(.system(size: 12, weight: .medium))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                }
                .foregroundStyle(tint)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 12).padding(.vertical, 6)
        .background {
            if #available(macOS 26.0, *) { Color.clear.glassEffect(.regular, in: Capsule()) }
            else { Capsule().fill(.ultraThinMaterial) }
        }
        .overlay(Capsule().strokeBorder(.white.opacity(0.12)))
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
                // A decline reason can be a full Hebrew/Arabic sentence (multi-paragraph), so route it
                // through BidiText for true PER-PARAGRAPH base direction, not the single-direction helper.
                ScrollView {
                    BidiText(text: reason, fontSize: 12, color: .secondaryLabelColor)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 120)   // bounded so a long reason can't overflow the panel
            }
        case let .failed(message):
            centered {
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 36)).foregroundStyle(.red)
                Text("Something went wrong").font(.system(size: 15, weight: .medium))
                // A failure message can be a full Hebrew/Arabic sentence too — route it through BidiText
                // for true per-paragraph base direction (mixed LTR+RTL resolves cleanly).
                ScrollView {
                    BidiText(text: message, fontSize: 12, color: .secondaryLabelColor)
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: 120)   // bounded for symmetry with the Settings row cap
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

    /// The streamed/ready text, scrollable, in the canvas's large value pane. Rendered through
    /// `BidiText` (a natural-base-direction NSTextView) so Hebrew/Arabic output starts on the right and
    /// mixed LTR+RTL resolves cleanly, recomputed per paragraph as tokens stream (design D6).
    private func resultScroll(text: String) -> some View {
        ScrollView {
            BidiText(text: text, fontSize: 14)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .background(atTopReporter(space: Self.resultScrollSpace))
        }
        .coordinateSpace(name: Self.resultScrollSpace)
    }

    /// A 0-impact background probe that reports whether `space`'s scroll content is at its TOP, via
    /// `CanvasAtTopKey`. Placed as the content's background so its `minY` in the scroll's coordinate space
    /// is the content top's offset: 0 at the top, negative once scrolled down (small epsilon for rounding).
    private func atTopReporter(space: String) -> some View {
        GeometryReader { geo in
            Color.clear.preference(key: CanvasAtTopKey.self,
                                   value: geo.frame(in: .named(space)).minY >= -2)
        }
    }

    private static let resultScrollSpace = "ai-canvas-result-scroll"
    private static let thinkingScrollSpace = "ai-canvas-thinking-scroll"

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
                        // Review-field values (Title/Start/Email/…) are SHORT and single-paragraph by
                        // construction, so the lightweight first-strong SwiftUI helper suffices here —
                        // no BidiText / NSTextView needed for these single-line values.
                        Text(field.value).font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .naturalTextDirection(for: field.value)   // RTL value starts on the right
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

/// Reports whether the canvas's scrollable content is at its TOP. Each scrollable region contributes a
/// boolean; `reduce` ANDs them, so the combined value is true only when EVERY region is at its top — the
/// condition under which a fresh down-swipe applies the result (otherwise the down-swipe is a scroll).
private struct CanvasAtTopKey: PreferenceKey {
    static let defaultValue = true
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value && nextValue()
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
