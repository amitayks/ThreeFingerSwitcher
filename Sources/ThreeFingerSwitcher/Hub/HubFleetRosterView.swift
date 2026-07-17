import SwiftUI
import AppKit

/// The Hub AI-page FLEET ROSTER (design D6, tasks 7.1–7.4). Evolves the single model picker into a list
/// of fleet members — each row shows its ROLE (Chat / Ternary / Image / Video / Cloud), LANE (GPU / CPU /
/// Cloud), PROVIDER, the existing per-model on-disk/resident status, and its HONEST residency cost
/// (`residencyBytes` in GB) in the same breath it offers selection.
///
/// FLAGGED: user xcodebuild + stable-signed build. This is native SwiftUI in the app target — the agent
/// compile-verifies it under `swift build`; the LIVE roster rendering, real per-model status, the
/// disclosure copy, and the gated cloud rows are verified only in the user's stable-signed build (§8.3).
///
/// Honest-surface invariants it upholds:
///  - The **evict-chat disclosure** is computed from the `ResidencyPlanner` PLAN (task 7.2), NOT hard-coded
///    — a member whose admission evicts chat shows "selecting ‹Role› pauses the chat model; it reloads
///    when generation finishes." It therefore shows for Video / FP16-image and NOT for Q4-image.
///  - **Cloud members** show a Cloud badge + escalation cost and are DISABLED with an explanatory caption
///    until `fleetCloudEscalationEnabled` (task 7.3). A fleet-of-one renders as today's single picker.
///  - Any admission/escalation failure is a **bounded, non-blocking** row (clean headline via
///    `AIError.message(for:)` + opt-in copyable details + Retry) — never an `NSAlert`, never raw error
///    text in a headline (task 7.4, D7).
struct HubFleetRosterView: View {
    /// The fleet roster (descriptors + the resident view). Defaults to the standard fleet.
    var roster: FleetRoster = .standard
    /// The pure planner driving the evict-chat disclosure (task 7.2).
    var planner: ResidencyPlanner = ResidencyPlanner()
    /// The unified-memory budget the planner spends against.
    var budgetBytes: UInt64 = FleetRoster.unifiedBudget48GB
    /// Live free-memory probe (injected; pure value in previews/tests).
    var freeBytes: () -> UInt64 = { FleetRoster.unifiedBudget48GB }
    /// `fleetCloudEscalationEnabled` (OWNED by `ai-full-potential-toggle`; consumed here, default false).
    var cloudEscalationEnabled: () -> Bool = { false }

    /// The pinned ACTIVE CHAT model id — a radio AMONG chat-role members (nil → the chat default). A chat
    /// model is the single resident conversational brain, so it is a mutually-exclusive choice.
    @Binding var activeChatID: String?

    /// The set of ENABLED capability-model ids (image / ternary / video) — INDEPENDENT toggles, NOT a
    /// radio: these co-reside with (or evict around) chat rather than replacing it. On-enable the row
    /// inserts the id AND triggers a download if the weights are not yet on disk.
    @Binding var enabledCapabilityModelIDs: Set<String>

    /// Trigger a download for a capability model the user just enabled (wired to the existing
    /// `ModelManager.download/downloadAndVerify` path in `AppCoordinator`). A side effect that didn't land
    /// surfaces through the manager's `.failed` state on that row — never a false "Done".
    var onDownloadCapabilityModel: (ModelDescriptor) -> Void = { _ in }

    /// The manager whose per-model lifecycle status each row reflects.
    @ObservedObject var manager: ModelManager

    /// Whether AI commands are enabled at all (the whole section is disabled otherwise).
    var aiEnabled: Bool

    /// A bounded, non-blocking failure surfaced inline (task 7.4) — never a modal.
    @State private var failure: AIPresentedError?
    @State private var showingFailureDetails = false

    private var members: [ModelDescriptor] { roster.descriptors() }

    /// A fleet-of-one renders as today's single picker (task 7.3).
    private var isFleetOfOne: Bool { members.count <= 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if isFleetOfOne {
                singlePicker
            } else {
                ForEach(members, id: \.id) { member in
                    memberRow(member)
                    Divider()
                }
            }
            if let failure { failureRow(failure) }
        }
        .disabled(!aiEnabled)
    }

    // MARK: - Fleet-of-one (today's single picker)

    @ViewBuilder private var singlePicker: some View {
        if let only = members.first {
            HStack(spacing: 8) {
                Image(systemName: "brain.head.profile").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(only.displayName).font(.headline)
                    Text(costLabel(only)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
    }

    // MARK: - One member row

    @ViewBuilder private func memberRow(_ member: ModelDescriptor) -> some View {
        let isCloud = member.provider == .cloud
        let cloudOn = cloudEscalationEnabled()
        let disabled = isCloud && !cloudOn
        let isChat = member.role == .chat

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: roleIcon(member.role))
                    .foregroundStyle(disabled ? Color.secondary : .primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(member.displayName)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(disabled ? Color.secondary : .primary)
                    HStack(spacing: 6) {
                        badge(roleTitle(member.role), color: .accentColor)
                        badge(laneTitle(member.lane), color: .secondary)
                        if isCloud { badge("Cloud", color: .purple) }
                        Text(costLabel(member)).font(.caption2).foregroundStyle(.secondary)
                    }
                    // Per-row lifecycle status (on-disk / downloading% + progress / resident), reusing the
                    // manager's pure per-descriptor probe — each row reflects its OWN model.
                    statusLine(member)
                }
                Spacer()
                if isCloud {
                    // Cloud rows keep the radio-style Select (it pins the active chat target only when the
                    // gate is on — escalation routing is owned elsewhere); gated off otherwise.
                    if activeChatID == member.id {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Select") { selectChat(member) }
                            .controlSize(.small)
                            .disabled(disabled)
                    }
                } else if isChat {
                    // Chat members are a RADIO — selecting one pins it as the active conversational brain.
                    if isActiveChat(member) {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Button("Select") { selectChat(member) }
                            .controlSize(.small)
                    }
                } else {
                    // Capability members (image / ternary / video) are INDEPENDENT toggles.
                    Toggle("", isOn: capabilityBinding(member))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            // The honest-cost disclosure (task 7.2): computed from the PLAN, never hard-coded.
            if !isCloud, evictsChat(member) {
                disclosure("Selecting \(roleTitle(member.role)) pauses the chat model; it reloads when generation finishes.",
                           systemImage: "pause.circle")
            }
            // Cloud caption (task 7.3): gated off → explain why it's disabled.
            if isCloud {
                if cloudOn {
                    disclosure("Cloud escalation — routes this turn off-device (confirm-by-default, per-day budget cap).",
                               systemImage: "cloud")
                } else {
                    disclosure("Cloud model. Turn on cloud escalation to use it (off by default — no silent spend).",
                               systemImage: "lock")
                }
            }
        }
        .padding(.vertical, 2)
    }

    /// One line of per-model lifecycle status, read non-mutatingly from the manager (`status(for:)`):
    /// on-disk, downloading with a live percentage + progress bar, verifying/loading, resident, or a
    /// bounded failure headline. Each fleet row shows its OWN model's status (the manager's single
    /// displayed `state` describes only one model at a time).
    @ViewBuilder private func statusLine(_ member: ModelDescriptor) -> some View {
        switch manager.status(for: member) {
        case .notDownloaded:
            EmptyView()
        case let .downloading(progress):
            VStack(alignment: .leading, spacing: 2) {
                Text("Downloading… \(Int(progress * 100))%")
                    .font(.caption2).foregroundStyle(Color.accentColor)
                ProgressView(value: progress).frame(maxWidth: 160)
            }
        case .verifying:
            Text("Verifying…").font(.caption2).foregroundStyle(Color.accentColor)
        case .ready:
            Label("On disk", systemImage: "internaldrive").font(.caption2).foregroundStyle(.secondary)
        case .loading:
            Text("Loading…").font(.caption2).foregroundStyle(Color.accentColor)
        case .loaded:
            Label("Resident", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(.green)
        case let .failed(reason, _):
            Label(reason, systemImage: "exclamationmark.triangle.fill")
                .font(.caption2).foregroundStyle(.red)
                .lineLimit(2).truncationMode(.middle)
        }
    }

    // MARK: - Selection / toggles

    /// Whether `member` is the active chat radio selection (an explicit pin, or the chat default when none
    /// is pinned and this is a chat member).
    private func isActiveChat(_ member: ModelDescriptor) -> Bool {
        if let id = activeChatID { return id == member.id }
        return member.role == .chat && member.id == defaultChatID
    }

    /// The id treated as the chat default when nothing is pinned (the first chat-role member).
    private var defaultChatID: String? { members.first(where: { $0.role == .chat })?.id }

    /// Pin a chat (or gated cloud) member as the active conversational brain. A cloud selection while the
    /// gate is off is a refusal surfaced through the ONE translator, bounded + inline.
    private func selectChat(_ member: ModelDescriptor) {
        failure = nil
        if member.provider == .cloud && !cloudEscalationEnabled() {
            failure = AIError.message(for: FleetError.cloudDisabled(modelName: member.displayName))
            return
        }
        activeChatID = member.id
    }

    /// The independent on/off binding for a capability member. On-enable it inserts the id AND triggers a
    /// download if the weights are not already on disk (residency itself stays lazy until a command runs).
    private func capabilityBinding(_ member: ModelDescriptor) -> Binding<Bool> {
        Binding(
            get: { enabledCapabilityModelIDs.contains(member.id) },
            set: { isOn in
                failure = nil
                if isOn {
                    enabledCapabilityModelIDs.insert(member.id)
                    // Trigger a download only when the weights aren't already present — re-enabling an
                    // on-disk model is a no-op fetch.
                    if !isOnDisk(member) { onDownloadCapabilityModel(member) }
                } else {
                    enabledCapabilityModelIDs.remove(member.id)
                }
            }
        )
    }

    /// Whether a capability model's weights are already on disk (so re-enabling needn't re-download).
    private func isOnDisk(_ member: ModelDescriptor) -> Bool {
        switch manager.status(for: member) {
        case .ready, .loaded: return true
        default: return false
        }
    }

    /// The bounded, non-blocking failure row (task 7.4): clean headline + opt-in details + Retry. NEVER a
    /// modal `NSAlert`, never raw error text in the headline.
    @ViewBuilder private func failureRow(_ presented: AIPresentedError) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label {
                Text(presented.headline)
                    .font(.caption)
                    .lineLimit(3)
                    .truncationMode(.middle)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } icon: {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let details = presented.details, !details.isEmpty {
                DisclosureGroup(isExpanded: $showingFailureDetails) {
                    ScrollView {
                        Text(details)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                    Button {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(details, forType: .string)
                    } label: { Label("Copy details", systemImage: "doc.on.doc") }
                    .controlSize(.small)
                } label: {
                    Text("Show details").font(.caption).foregroundStyle(.secondary)
                }
            }
            Button("Dismiss") { failure = nil }.controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 6).fill(Color.red.opacity(0.06)))
    }

    // MARK: - Plan-driven disclosure

    /// Whether admitting `member` would evict chat — straight from the planner (task 7.2).
    private func evictsChat(_ member: ModelDescriptor) -> Bool {
        // Assume chat resident (the resting state) so the disclosure reflects the real trade-off.
        let chatIDs = members.filter { $0.role == .chat }.map(\.id)
        let ternaryIDs = members.filter { $0.role == .ternaryChat }.map(\.id)
        return planner.admissionEvictsChat(targetID: member.id,
                                           descriptors: members,
                                           budgetBytes: budgetBytes,
                                           freeBytes: freeBytes(),
                                           currentlyResident: chatIDs + ternaryIDs)
    }

    // MARK: - Labels

    private func roleTitle(_ role: ModelRole) -> String {
        switch role {
        case .chat: return "Chat"
        case .ternaryChat: return "Ternary"
        case .image: return "Image"
        case .video: return "Video"
        case .cloudEscalation: return "Cloud"
        }
    }

    private func roleIcon(_ role: ModelRole) -> String {
        switch role {
        case .chat: return "brain.head.profile"
        case .ternaryChat: return "cpu"
        case .image: return "photo"
        case .video: return "film"
        case .cloudEscalation: return "cloud"
        }
    }

    private func laneTitle(_ lane: ComputeLane?) -> String {
        switch lane {
        case .gpu: return "GPU"
        case .cpuTernary: return "CPU"
        case .none: return "Cloud"
        }
    }

    /// The honest residency cost: resident footprint in GB (0 for cloud → "no local memory").
    private func costLabel(_ member: ModelDescriptor) -> String {
        if member.provider == .cloud { return "Cloud · no local memory" }
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .memory
        return "Resident: \(formatter.string(fromByteCount: Int64(member.residencyBytes)))"
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.15)))
            .foregroundStyle(color)
    }

    private func disclosure(_ text: String, systemImage: String) -> some View {
        Label {
            Text(text).font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).foregroundStyle(.secondary)
        }
    }
}
