import SwiftUI
import AppKit

/// The pages of the configuration Hub, as sidebar destinations. One window, grouped navigation:
/// Overview · Content(Bands) · Features(Switcher/Spaces/Launcher/Clipboard/AI) · System(Setup/General).
enum HubDestination: Hashable, CaseIterable {
    case overview
    case bands
    case switcher, spaces, launcher, clipboard, ai, keyboardLanguage
    case setup, general

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .bands: return "Bands"
        case .switcher: return "Window Switcher"
        case .spaces: return "Spaces"
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
        case .spaces: return "rectangle.split.3x1"
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

    init(context: HubContext, nav: HubNavigation) {
        self.context = context
        self.nav = nav
    }

    var body: some View {
        NavigationSplitView {
            sidebar
                .navigationSplitViewColumnWidth(min: 200, ideal: 220, max: 280)
        } detail: {
            detail
                .frame(minWidth: 540, minHeight: 480)
        }
        .frame(minWidth: 940, minHeight: 580)
    }

    private var sidebar: some View {
        List(selection: $nav.selection) {
            row(.overview)
            Section("Content") {
                row(.bands)
            }
            Section("Features") {
                row(.switcher); row(.spaces); row(.launcher); row(.clipboard); row(.ai); row(.keyboardLanguage)
            }
            Section("System") {
                row(.setup); row(.general)
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("ThreeFingerSwitcher")
    }

    private func row(_ destination: HubDestination) -> some View {
        Label(destination.sidebarTitle, systemImage: destination.systemImage)
            .tag(destination)
    }

    @ViewBuilder
    private var detail: some View {
        switch nav.selection ?? .overview {
        case .overview: OverviewPage(context: context, nav: nav)
        case .bands: BandsPage(context: context)
        case .switcher: SwitcherPage(settings: context.settings)
        case .spaces: SpacesPage(settings: context.settings)
        case .launcher: LauncherPage(settings: context.settings)
        case .clipboard: ClipboardPage(context: context)
        case .ai: AIPage(context: context)
        case .keyboardLanguage: KeyboardLanguagePage(context: context)
        case .setup: SetupPage(context: context)
        case .general: GeneralPage(context: context)
        }
    }
}
