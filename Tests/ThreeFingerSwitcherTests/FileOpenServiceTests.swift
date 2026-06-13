import XCTest
import Foundation
@testable import ThreeFingerSwitcherCore

/// Tests for the Files-band open / Open-With / defusable-open service (change: files-band, tasks 3.2 / 3.3 /
/// 3.4) against a stub `FileWorkspace` that records every call and can simulate a failure:
/// - default open routes a **file** to its default app and a **folder** to a Finder-window open;
/// - Open-With lists ONLY the capable apps, with the default indicated;
/// - choosing an app opens with it;
/// - a defuse cancels a pending open so the stub records NO open, and **never terminates** anything;
/// - a failed open surfaces a clean, bounded headline carrying NO raw error text.
///
/// `@MainActor` because `FileOpenService` / `PendingOpen` are `@MainActor` (they hold observable UI state),
/// matching `AICommandExecutorTests`.
@MainActor
final class FileOpenServiceTests: XCTestCase {

    // MARK: - Stub workspace

    /// A scriptable `FileWorkspace` that records what it was asked to open (so a defuse's "opens nothing" is
    /// testable) and serves canned app associations. It has **no terminate capability at all** — there is
    /// nothing for a defuse to call — which is exactly the point: defuse can only prevent a not-yet-fired open,
    /// it can't kill a running app. `openError`, when set, makes every open throw (the mapped-at-the-boundary
    /// `FileActionError`), exercising the `.failed` surfacing. Foundation-only (no `import AppKit`).
    private final class StubFileWorkspace: FileWorkspace {
        private(set) var openedDefault: [URL] = []
        private(set) var openedWith: [(file: URL, app: URL)] = []
        private let apps: [URL]
        private let defaultApp: URL?
        private let openError: FileActionError?

        init(apps: [URL] = [], defaultApp: URL? = nil, openError: FileActionError? = nil) {
            self.apps = apps
            self.defaultApp = defaultApp
            self.openError = openError
        }

        /// Total opens of any kind — `0` proves a defuse opened nothing.
        var totalOpens: Int { openedDefault.count + openedWith.count }

        func open(_ url: URL) async throws {
            if let openError { throw openError }
            openedDefault.append(url)
        }

        func open(_ url: URL, withApplicationAt applicationURL: URL) async throws {
            if let openError { throw openError }
            openedWith.append((file: url, app: applicationURL))
        }

        func urlsForApplications(toOpen url: URL) -> [URL] { apps }
        func urlForApplication(toOpen url: URL) -> URL? { defaultApp }
    }

    // MARK: - Fixtures

    private func fileEntry(_ path: String) -> FileEntry {
        let url = URL(fileURLWithPath: path)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: false,
                         modificationDate: nil, kind: .text)
    }

    private func folderEntry(_ path: String) -> FileEntry {
        let url = URL(fileURLWithPath: path)
        return FileEntry(url: url, name: url.lastPathComponent, isDirectory: true,
                         modificationDate: nil, kind: .folder)
    }

    /// Spin the run loop until `condition` holds (the open fires on a `Task`), bounded so a never-firing open
    /// fails loudly via the caller's assertion instead of hanging. Mirrors `AICommandExecutorTests.waitUntil`.
    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 2) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        }
    }

    /// Let any scheduled `Task` run, then return — for the "nothing opened" assertions, where we must give a
    /// (possibly defused) open the chance to fire before asserting it did NOT. A short, fixed settle: a defuse
    /// has no async work to do, so a few run-loop turns is plenty.
    private func settle() async {
        for _ in 0..<10 {
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000) // 2 ms
        }
    }

    // MARK: - Default open routing (task 3.2 / 3.4)

    func testDefaultOpenRoutesAFileToItsDefaultApp() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)
        let file = fileEntry("/tmp/report.txt")

        service.prepareOpen(file).commit()
        await waitUntil { service.state == .opened }

        XCTAssertEqual(workspace.openedDefault, [file.url], "a file opens in its default app via the workspace")
        XCTAssertTrue(workspace.openedWith.isEmpty, "a default open is not an Open-With")
        XCTAssertEqual(service.state, .opened)
    }

    func testDefaultOpenRoutesAFolderToAFinderWindowOpen() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)
        let folder = folderEntry("/tmp/Projects")

        service.prepareOpen(folder).commit()
        await waitUntil { service.state == .opened }

        // A folder opens through the SAME default-open seam (which, in production, opens a Finder window on
        // the current Space) — the service routes both kinds to `workspace.open(_:)`, never via SpaceWindowMover.
        XCTAssertEqual(workspace.openedDefault, [folder.url], "a folder opens as a Finder window via the default open")
        XCTAssertTrue(workspace.openedWith.isEmpty)
    }

    func testOpenTargetsTheCapturedFrontAppContextBeforeFiring() async {
        let workspace = StubFileWorkspace()
        var activated = 0
        let service = FileOpenService(workspace: workspace, activateFrontAppContext: { activated += 1 })

        service.prepareOpen(fileEntry("/tmp/a.txt")).commit()
        await waitUntil { service.state == .opened }

        XCTAssertEqual(activated, 1, "the open re-asserts the captured front-app context (not the frontmost at fire time)")
    }

    // MARK: - Built-in player routing (spec: media-player)

    /// Records hand-offs to the built-in player.
    private final class PlaySpy {
        private(set) var played: [(entry: FileEntry, kind: MediaKind)] = []
        func record(_ entry: FileEntry, _ kind: MediaKind) { played.append((entry, kind)) }
    }

    func testMediaFileWithOptInRoutesToThePlayerNotTheWorkspace() async {
        let workspace = StubFileWorkspace()
        let spy = PlaySpy()
        // The controller builds `mediaPlaybackRoute` from settings; here it routes any classified media.
        let service = FileOpenService(workspace: workspace,
                                      mediaPlaybackRoute: { MediaKind.classify($0) },
                                      playMedia: { entry, kind in spy.record(entry, kind) })
        let clip = fileEntry("/movies/clip.mp4")

        service.prepareOpen(clip).commit()
        await waitUntil { service.state == .opened }

        XCTAssertEqual(spy.played.count, 1, "a playable media file is handed to the built-in player")
        XCTAssertEqual(spy.played.first?.kind, .video)
        XCTAssertTrue(workspace.openedDefault.isEmpty, "it must NOT also open in the system default app")
    }

    func testNonMediaFileFallsThroughToTheWorkspace() async {
        let workspace = StubFileWorkspace()
        let spy = PlaySpy()
        let service = FileOpenService(workspace: workspace,
                                      mediaPlaybackRoute: { MediaKind.classify($0) },
                                      playMedia: { entry, kind in spy.record(entry, kind) })
        let doc = fileEntry("/docs/report.pdf")

        service.prepareOpen(doc).commit()
        await waitUntil { service.state == .opened }

        XCTAssertTrue(spy.played.isEmpty, "a non-media file is not handed to the player")
        XCTAssertEqual(workspace.openedDefault, [doc.url], "it opens in the system default app as before")
    }

    func testOptInOffFallsThroughEvenForMedia() async {
        let workspace = StubFileWorkspace()
        let spy = PlaySpy()
        // Opt-in off ⇒ the route returns nil for everything.
        let service = FileOpenService(workspace: workspace,
                                      mediaPlaybackRoute: { _ in nil },
                                      playMedia: { entry, kind in spy.record(entry, kind) })
        let clip = fileEntry("/movies/clip.mp4")

        service.prepareOpen(clip).commit()
        await waitUntil { service.state == .opened }

        XCTAssertTrue(spy.played.isEmpty, "with the opt-in off, even media opens in the system app")
        XCTAssertEqual(workspace.openedDefault, [clip.url])
    }

    func testOpenWithAlwaysOpensExternallyNeverThePlayer() async {
        let app = URL(fileURLWithPath: "/Applications/VLC.app")
        let workspace = StubFileWorkspace(apps: [app], defaultApp: app)
        let spy = PlaySpy()
        let service = FileOpenService(workspace: workspace,
                                      mediaPlaybackRoute: { MediaKind.classify($0) },
                                      playMedia: { entry, kind in spy.record(entry, kind) })
        let clip = fileEntry("/movies/clip.mp4")

        service.prepareOpenWith(clip, appURL: app).commit()
        await waitUntil { service.state == .opened }

        XCTAssertTrue(spy.played.isEmpty, "Open-With is never diverted to the built-in player")
        XCTAssertEqual(workspace.openedWith.first?.app, app, "it opens with the chosen external app")
    }

    // MARK: - Open-With enumeration (task 3.2 / 3.4)

    func testOpenWithListsOnlyCapableAppsWithTheDefaultIndicated() {
        let textEdit = URL(fileURLWithPath: "/Applications/TextEdit.app")
        let xcode = URL(fileURLWithPath: "/Applications/Xcode.app")
        // Only these two are "capable"; the full installed-apps list is irrelevant — the service lists exactly
        // what the workspace's association returns, in order, with the default flagged.
        let workspace = StubFileWorkspace(apps: [textEdit, xcode], defaultApp: xcode)
        let service = FileOpenService(workspace: workspace)

        let candidates = service.openWithCandidates(for: fileEntry("/tmp/a.swift"))

        XCTAssertEqual(candidates.map { $0.app.url }, [textEdit, xcode], "only the capable apps, in system order")
        XCTAssertEqual(candidates.first { $0.isDefault }?.app.url, xcode, "the default app is indicated")
        XCTAssertEqual(candidates.filter { $0.isDefault }.count, 1, "exactly one app is marked default")
        XCTAssertEqual(candidates.first { $0.app.url == textEdit }?.isDefault, false)
        // The reused `AppCandidate` derives a display name from the bundle URL.
        XCTAssertEqual(candidates.first?.app.name, "TextEdit")
    }

    func testOpenWithIsEmptyForAFolder() {
        let finder = URL(fileURLWithPath: "/System/Library/CoreServices/Finder.app")
        let workspace = StubFileWorkspace(apps: [finder], defaultApp: finder)
        let service = FileOpenService(workspace: workspace)
        // Open-With is a file action: a folder's default open is a Finder window, so no Open-With list.
        XCTAssertTrue(service.openWithCandidates(for: folderEntry("/tmp/Projects")).isEmpty)
    }

    func testOpenWithIsEmptyWhenNoApplicationHandlesTheFile() {
        let service = FileOpenService(workspace: StubFileWorkspace(apps: [], defaultApp: nil))
        XCTAssertTrue(service.openWithCandidates(for: fileEntry("/tmp/thing.weird")).isEmpty)
    }

    func testChoosingAnAppOpensTheFileWithIt() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)
        let file = fileEntry("/tmp/a.swift")
        let app = URL(fileURLWithPath: "/Applications/Xcode.app")

        service.prepareOpenWith(file, appURL: app).commit()
        await waitUntil { service.state == .opened }

        XCTAssertEqual(workspace.openedWith.count, 1)
        XCTAssertEqual(workspace.openedWith.first?.file, file.url)
        XCTAssertEqual(workspace.openedWith.first?.app, app, "the file opens with the chosen app")
        XCTAssertTrue(workspace.openedDefault.isEmpty, "Open-With does not also fire the default open")
    }

    // MARK: - Defusable open (task 3.3 / 3.4)

    func testDefuseBeforeCommitOpensNothing() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)

        let pending = service.prepareOpen(fileEntry("/tmp/a.txt"))
        XCTAssertTrue(pending.isCommittable, "a freshly prepared open is held, awaiting commit")
        pending.cancel()   // discard before the open ever fired

        // Give any (nonexistent) scheduled open a chance to run, then assert nothing opened.
        await settle()
        XCTAssertEqual(workspace.totalOpens, 0, "a defused open opens nothing")
        XCTAssertEqual(service.state, .idle, "a defused open rests at idle, never .opened")
        XCTAssertFalse(pending.isCommittable, "a cancelled open is resolved (a stray re-lift is a no-op)")
    }

    func testDefuseViaTheServiceOpensNothing() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)

        service.prepareOpen(fileEntry("/tmp/a.txt"))
        service.cancelPending()   // discard via the service's held pending

        await settle()
        XCTAssertEqual(workspace.totalOpens, 0)
        XCTAssertNil(service.pendingOpen, "the pending open is cleared after a defuse")
    }

    func testDefuseDuringTheFuseWindowOpensNothing() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)

        let pending = service.prepareOpen(fileEntry("/tmp/a.txt"))
        pending.commit(afterFuse: .milliseconds(200))   // armed, but not yet fired
        XCTAssertTrue(pending.isDefusable, "a fusing open is still defusable")
        pending.cancel()                                // discard within the fuse window

        await settle()
        XCTAssertEqual(workspace.totalOpens, 0, "defusing within the fuse window opens nothing")
        XCTAssertEqual(service.state, .idle)
    }

    func testFuseThatIsNotDefusedFires() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)
        let file = fileEntry("/tmp/a.txt")

        service.prepareOpen(file).commit(afterFuse: .milliseconds(20))
        await waitUntil { service.state == .opened }
        XCTAssertEqual(workspace.openedDefault, [file.url], "an un-defused fuse fires the open")
    }

    func testDefuseNeverTerminatesAnything() async {
        // The stub workspace exposes NO terminate API — so the only way this test compiles is if defuse never
        // tries to terminate. Defuse only prevents a not-yet-fired open; an already-running app is untouched.
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)

        let pending = service.prepareOpen(fileEntry("/tmp/already-running.txt"))
        pending.cancel()

        await settle()
        // No open, and (by construction) no terminate — the recorded calls are open-only.
        XCTAssertEqual(workspace.openedDefault, [], "defuse opens nothing")
        XCTAssertEqual(workspace.openedWith.count, 0, "defuse fires no Open-With")
    }

    func testStrayReLiftAfterCommitDoesNotDoubleOpen() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)
        let file = fileEntry("/tmp/a.txt")

        let pending = service.prepareOpen(file)
        pending.commit()
        await waitUntil { service.state == .opened }
        // A stray re-lift after the firing lift: a second commit AND a late cancel are both no-ops.
        pending.commit()
        pending.cancel()
        await settle()

        XCTAssertEqual(workspace.openedDefault, [file.url], "the open fired exactly once")
        XCTAssertEqual(service.state, .opened, "a late discard does not undo or kill the opened window")
    }

    func testPreparingASecondOpenSupersedesAStillPendingOne() async {
        let workspace = StubFileWorkspace()
        let service = FileOpenService(workspace: workspace)
        let first = fileEntry("/tmp/first.txt")
        let second = fileEntry("/tmp/second.txt")

        let firstPending = service.prepareOpen(first)
        let secondPending = service.prepareOpen(second)   // supersedes the first (cancels it)
        XCTAssertFalse(firstPending.isCommittable, "the superseded open is cancelled")
        XCTAssertTrue(secondPending.isCommittable)

        secondPending.commit()
        await waitUntil { service.state == .opened }
        XCTAssertEqual(workspace.openedDefault, [second.url], "only the live (second) open fires")
    }

    // MARK: - Failure surfacing: clean, bounded, no raw error text (task 3.4)

    func testAFailedOpenSurfacesACleanBoundedHeadline() async {
        let rawOSText = "Error Domain=NSCocoaErrorDomain Code=257 \"You don't have permission.\" UserInfo={…}"
        // The workspace boundary already mapped the OS error into the taxonomy, stashing the raw text in the
        // opt-in `details` — never the headline.
        let mapped = FileActionError.openFailed(name: "report.txt", details: rawOSText)
        let workspace = StubFileWorkspace(openError: mapped)
        let service = FileOpenService(workspace: workspace)

        service.prepareOpen(fileEntry("/tmp/report.txt")).commit()
        await waitUntil { if case .failed = service.state { return true }; return false }

        guard case let .failed(headline, details) = service.state else {
            return XCTFail("a failed open must surface .failed, got \(service.state)")
        }
        XCTAssertFalse(headline.isEmpty, "the failure carries a clean headline")
        XCTAssertTrue(headline.contains("report.txt"), "the headline names the file")
        assertHeadlineIsClean(headline)
        // The raw OS text rides ONLY in the opt-in details (for a Show-details/Copy disclosure), never the
        // headline: the details carry it verbatim, the headline (asserted clean above) does not.
        XCTAssertEqual(details, rawOSText, "the raw OS text is preserved as opt-in copyable details")
        XCTAssertTrue(workspace.openedDefault.isEmpty, "a failed open never falsely records a success")
    }

    func testAFailedOpenWithSurfacesACleanBoundedHeadline() async {
        let mapped = FileActionError.openFailed(name: "a.swift",
                                                details: "Error Domain=NSOSStatusErrorDomain Code=-10814")
        let workspace = StubFileWorkspace(openError: mapped)
        let service = FileOpenService(workspace: workspace)

        service.prepareOpenWith(fileEntry("/tmp/a.swift"),
                                appURL: URL(fileURLWithPath: "/Applications/Xcode.app")).commit()
        await waitUntil { if case .failed = service.state { return true }; return false }

        guard case let .failed(headline, details) = service.state else {
            return XCTFail("a failed Open-With must surface .failed, got \(service.state)")
        }
        assertHeadlineIsClean(headline)
        // The raw status text is opt-in details only — present (so a disclosure can show it), never inline:
        // the details carry the raw text verbatim, while the headline (asserted clean above) does not.
        XCTAssertEqual(details, "Error Domain=NSOSStatusErrorDomain Code=-10814",
                       "the raw status text is preserved as opt-in copyable details")
        XCTAssertTrue(workspace.openedWith.isEmpty, "a failed Open-With never falsely records a success")
    }

    /// A surfaced headline must read as a human sentence — never a reflected enum dump or raw OS text. Mirrors
    /// the needle set `FilesSeamsTests` pins on `FileActionError` headlines.
    private func assertHeadlineIsClean(_ headline: String,
                                       file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(headline.isEmpty, "headline is non-empty", file: file, line: line)
        for needle in ["Domain=", "Code=", "Error Domain", "UserInfo", "FileActionError",
                       "NSCocoaErrorDomain", "NSOSStatusErrorDomain"] {
            XCTAssertFalse(headline.contains(needle),
                           "headline must not contain raw error text (\(needle)): \(headline)",
                           file: file, line: line)
        }
    }
}
