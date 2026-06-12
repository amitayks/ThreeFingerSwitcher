import SwiftUI
import AppKit

/// The pages of the configuration Hub, as sidebar destinations. One window, grouped navigation:
/// Overview · Content(Bands) · Features(Switcher/Launcher/Clipboard/AI) · System(Setup/General).
/// Space-row switching is a sub-feature of the Switcher and lives on the Switcher page (no own destination).
enum HubDestination: Hashable, CaseIterable {
    case overview
    case bands
    case switcher, launcher, clipboard, ai, keyboardLanguage
    case setup, general

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .bands: return "Bands"
        case .switcher: return "Window Switcher"
        case .launcher: return "Launcher"
        case .clipboard: return "Clipboard"
        case .ai: return "AI Commands"
        case .keyboardLanguage: return "Keyboard Language"
        case .setup: return "Setup & Permissions"
        case .general: return "General"
        }
    }

    /// A short sidebar label (the full title is used for page headers).
    var sidebarTitle: String {
        switch self {
        case .switcher: return "Switcher"
        case .ai: return "AI"
        case .keyboardLanguage: return "Language"
        case .setup: return "Setup"
        default: return title
        }
    }

    var systemImage: String {
        switch self {
        case .overview: return "square.grid.2x2"
        case .bands: return "rectangle.3.group"
        case .switcher: return "arrow.left.arrow.right"
        case .launcher: return "square.grid.3x3.fill"
        case .clipboard: return "doc.on.clipboard"
        case .ai: return "sparkles"
        case .keyboardLanguage: return "globe"
        case .setup: return "gearshape.2"
        case .general: return "slider.horizontal.3"
        }
    }
}

/// Drives the Hub's selected page from outside the view (so the coordinator can deep-link an already
/// open window, and the Overview rows can jump to a feature page).
@MainActor
final class HubNavigation: ObservableObject {
    @Published var selection: HubDestination? = .overview
    init() {}
}

/// References and callbacks the Hub pages need, wired once by `AppCoordinator`. Keeps the pages free
/// of the coordinator while centralizing the (large) wiring in one place. The observable members
/// (`settings`, stores, `models`, `permissions`) are observed by the individual pages that use them.
@MainActor
final class HubContext {
    let settings: AppSettings
    let favorites: FavoritesStore
    let clipboard: ClipboardStore
    let models: ModelManager
    let permissions: PermissionsService

    // Clipboard feature page.
    var onClearClipboard: (_ includingPinned: Bool) -> Void = { _ in }

    // AI feature page.
    var onDownloadModel: () -> Void = {}

    // Keyboard Language feature page — the picker's source list (read fresh on each render). Provided by
    // the coordinator so the page never imports Carbon directly (the list comes from the service's
    // `InputSourceController`).
    var enabledInputSources: () -> [(id: String, name: String)] = { [] }

    // Setup page — the First Touch wizard entry (Resume while incomplete, Replay after) and the
    // self-relaunch helper for the Screen Recording grant.
    var onShowWelcomeTour: () -> Void = {}
    var firstRunCompleted: () -> Bool = { true }
    var onRelaunchApp: () -> Void = {}

    // Overview — the one-re-login banner: any gesture relocation still awaiting its re-login,
    // and the standard log-out keystroke (⇧⌘Q; macOS shows its own confirmation).
    var relocationsPendingRelogin: () -> Bool = { false }
    var onLogOutNow: () -> Void = {}

    // Setup page — actions.
    var onSetupNativeGesture: () -> Void = {}
    var onRestoreNativeGesture: () -> Void = {}
    var onKeepSpacesFixed: () -> Void = {}
    var onEnableSpaceRowSwitching: () -> Void = {}
    var onRestoreMissionControl: () -> Void = {}
    var onEnableLauncher: () -> Void = {}
    var onRestoreLauncher: () -> Void = {}
    var onRefreshPermissions: () -> Void = {}

    // Setup page — live state providers (read fresh on each render).
    var trackpadClaimed: () -> Bool = { false }
    var trackpadHasBackup: () -> Bool = { false }
    var trackpadNeedsRelogin: () -> Bool = { false }
    var spacesAutoRearrangeOn: () -> Bool = { false }
    var spaceRowNeedsRelogin: () -> Bool = { false }
    var verticalGestureHasBackup: () -> Bool = { false }
    var launcherNeedsRelogin: () -> Bool = { false }
    var launcherHasBackup: () -> Bool = { false }

    // General page.
    var isOpenAtLogin: () -> Bool = { false }
    var onToggleOpenAtLogin: () -> Void = {}
    var onWriteDiagnostics: () -> Void = {}
    var onCopyFocusLog: () -> Void = {}

    // General page — Danger zone.
    var onDangerZoneClear: (DangerZoneSelection) -> Void = { _ in }
    var onRestoreAllGestures: () -> Void = {}

    init(settings: AppSettings,
         favorites: FavoritesStore,
         clipboard: ClipboardStore,
         models: ModelManager,
         permissions: PermissionsService) {
        self.settings = settings
        self.favorites = favorites
        self.clipboard = clipboard
        self.models = models
        self.permissions = permissions
    }
}

/// The single configuration window: a `NavigationSplitView` with a glass sidebar and a detail column
/// that swaps the selected page.
struct HubView: View {
    let context: HubContext
    @ObservedObject var nav: HubNavigation
    /// Icon-only rail vs. expanded (icon + label). Toggled by the rail's header button, animated.
    @State private var sidebarExpanded = false

    init(context: HubContext, nav: HubNavigation) {
        self.context = context
        self.nav = nav
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(sidebarExpanded ? 210 : 52)
        } detail: {
            detail
                .frame(minWidth: 540, minHeight: 480)
        }
        .frame(minWidth: 820, minHeight: 580)
    }

    /// A rail of destinations that collapses to icons-only (names as tooltips) to save horizontal space,
    /// or expands to icon + label via the header button. Grouped by thin dividers in the same
    /// Overview · Content · Features · System order, with the selected destination tinted.
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.22)) { sidebarExpanded.toggle() }
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 15, weight: .medium))
                        .frame(width: 26, height: 30)
                        .padding(.horizontal, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(sidebarExpanded ? "Collapse sidebar" : "Expand sidebar")
                if sidebarExpanded { Spacer() }
            }
            .padding(.horizontal, 6).padding(.top, 6)

            ScrollView {
                VStack(spacing: 4) {
                    railButton(.overview)
                    railDivider
                    railButton(.bands)
                    railDivider
                    railButton(.switcher); railButton(.launcher); railButton(.clipboard); railButton(.ai); railButton(.keyboardLanguage)
                    railDivider
                    railButton(.setup); railButton(.general)
                }
                .padding(.vertical, 8).padding(.horizontal, 6)
                .frame(maxWidth: .infinity)
            }
            .scrollIndicators(.hidden)
        }
        .navigationTitle("ThreeFingerSwitcher")
    }

    private var railDivider: some View {
        Divider().padding(.horizontal, 8).padding(.vertical, 2)
    }

    private func railButton(_ destination: HubDestination) -> some View {
        let selected = (nav.selection ?? .overview) == destination
        return Button { nav.selection = destination } label: {
            HStack(spacing: 10) {
                Image(systemName: destination.systemImage)
                    .font(.system(size: 16, weight: .medium))
                    .frame(width: 26, height: 26)
                if sidebarExpanded {
                    Text(destination.sidebarTitle).font(.body).lineLimit(1).fixedSize()
                    Spacer(minLength: 0)
                }
            }
            .foregroundStyle(selected ? Color.accentColor : Color.secondary)
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            // Collapsed: the background hugs the icon (a tidy square); expanded: it fills the row. The
            // outer leading frame keeps the icon at a CONSISTENT x in both states, so expanding slides
            // the label in without the icon jumping sideways.
            .frame(maxWidth: sidebarExpanded ? .infinity : nil, alignment: .leading)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())   // the WHOLE row is the hit target, not just the glyph
        }
        .buttonStyle(.plain)
        .help(destination.title)
    }

    @ViewBuilder
    private var detail: some View {
        switch nav.selection ?? .overview {
        case .overview: OverviewPage(context: context, nav: nav)
        case .bands: BandsPage(context: context)
        case .switcher: SwitcherPage(settings: context.settings)
        case .launcher: LauncherPage(settings: context.settings)
        case .clipboard: ClipboardPage(context: context)
        case .ai: AIPage(context: context)
        case .keyboardLanguage: KeyboardLanguagePage(context: context)
        case .setup: SetupPage(context: context)
        case .general: GeneralPage(context: context)
        }
    }
}
