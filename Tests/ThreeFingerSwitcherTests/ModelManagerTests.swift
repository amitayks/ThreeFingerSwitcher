import XCTest
import Combine
@testable import ThreeFingerSwitcherCore

/// Tests for the model lifecycle (spec: "Model lifecycle management") against a fake downloader —
/// NO real network: no download while the opt-in is off, integrity (SHA) verified before load with a
/// corrupt download rejected (never loaded), residency across two calls (no re-load), and eviction
/// (on demand / opt-in off) unloads the resident runtime.
@MainActor
final class ModelManagerTests: XCTestCase {

    // MARK: - Fakes

    /// A fake downloader that fabricates the bytes it "downloads" — never touches the network.
    /// Counts calls so residency tests can prove a second run did NOT re-download.
    private final class FakeDownloader: ModelDownloading, @unchecked Sendable {
        /// The bytes to hand back on download (default: a fixed payload).
        let payload: Data
        private(set) var downloadCount = 0
        private let lock = NSLock()

        init(payload: Data = Data("gemma-weights".utf8)) {
            self.payload = payload
        }

        func download(_ descriptor: ModelDescriptor, to destination: URL,
                      progress: @Sendable (Double) -> Void) async throws -> Data {
            bumpCount()
            progress(0.5)
            progress(1.0)
            return payload
        }

        private func bumpCount() { lock.lock(); downloadCount += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return downloadCount }
    }

    // MARK: - Helpers

    private func tempRoot() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tfs-model-tests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A registry with a single descriptor whose `integritySHA` matches `payload`, so the happy path
    /// verifies. Capabilities default to text+vision.
    private func registry(matching payload: Data,
                          capabilities: Set<Modality> = [.text, .vision],
                          id: String = "test-model") -> ModelRegistry {
        ModelRegistry(
            models: [ModelDescriptor(
                id: id,
                displayName: "Test Model",
                sizeBytes: Int64(payload.count),
                integritySHA: ModelManager.sha256Hex(payload),
                downloadURL: URL(string: "https://models.invalid/\(id)")!,
                capabilities: capabilities,
                quantization: .qat4bit
            )],
            defaultModelID: id
        )
    }

    // MARK: - No download when opt-in off

    func testNoDownloadWhenOptInOff() async {
        let payload = Data("w".utf8)
        let downloader = FakeDownloader(payload: payload)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: downloader,
                                   optedIn: false,
                                   storageRoot: tempRoot())
        let descriptor = manager.registry.models[0]
        do {
            try await manager.downloadAndVerify(descriptor)
            XCTFail("download must be refused while the opt-in is off")
        } catch let e as RuntimeError {
            guard case .unavailable = e else { return XCTFail("expected .unavailable, got \(e)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(downloader.count, 0, "no bytes are fetched while opted out")
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    // MARK: - Corrupt-hash rejection

    func testCorruptDownloadIsRejectedAndNeverLoaded() async {
        let realPayload = Data("good-weights".utf8)
        // The descriptor declares the hash of the REAL payload, but the downloader returns garbage.
        let manager = ModelManager(registry: registry(matching: realPayload),
                                   downloader: FakeDownloader(payload: Data("corrupted".utf8)),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        let descriptor = manager.registry.models[0]
        do {
            try await manager.downloadAndVerify(descriptor)
            XCTFail("a corrupt download must not verify")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .integrityFailed)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        guard case .failed = manager.state else {
            return XCTFail("corrupt download leaves the manager in .failed, got \(manager.state)")
        }
        // And it must not be loadable.
        do {
            _ = try await manager.loadIfNeeded()
            XCTFail("a corrupt model must never load")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .modelMissing, "no verified weights → modelMissing")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Happy path: verify then load

    func testVerifyThenLoadReachesLoadedState() async throws {
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: FakeDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        let descriptor = manager.registry.models[0]
        try await manager.downloadAndVerify(descriptor)
        XCTAssertEqual(manager.state, .ready, "verified weights leave the manager .ready")

        let runtime = try await manager.loadIfNeeded()
        XCTAssertEqual(manager.state, .loaded)
        XCTAssertTrue(runtime.capabilities.contains(.vision), "the resolved runtime mirrors capabilities")
        XCTAssertTrue(manager.isResident)
    }

    // MARK: - Residency across two calls (no re-load / no re-download)

    func testResidencyAcrossTwoCallsDoesNotReload() async throws {
        let payload = Data("good".utf8)
        let downloader = FakeDownloader(payload: payload)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: downloader,
                                   optedIn: true,
                                   storageRoot: tempRoot())
        let descriptor = manager.registry.models[0]
        try await manager.downloadAndVerify(descriptor)

        let first = try await manager.loadIfNeeded()
        let second = try await manager.loadIfNeeded()
        XCTAssertTrue((first as AnyObject) === (second as AnyObject),
                      "the same resident runtime is reused (no cold re-load)")
        XCTAssertEqual(downloader.count, 1, "residency means no second download")
        XCTAssertEqual(manager.state, .loaded)
    }

    func testRuntimeForCapabilityResolvesResident() async throws {
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: FakeDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        try await manager.downloadAndVerify(manager.registry.models[0])
        let runtime = try await manager.runtime(requiring: [.vision])
        XCTAssertTrue(runtime.capabilities.contains(.vision))
        XCTAssertTrue(manager.isResident)
    }

    func testRuntimeForCapabilityReportsMissingWhenNotDownloaded() async {
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: FakeDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        do {
            _ = try await manager.runtime(requiring: [.text])
            XCTFail("a non-downloaded model must report missing, not silently fetch")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .modelMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Eviction

    func testEvictUnloadsButKeepsVerifiedWeights() async throws {
        let payload = Data("good".utf8)
        let downloader = FakeDownloader(payload: payload)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: downloader,
                                   optedIn: true,
                                   storageRoot: tempRoot())
        try await manager.downloadAndVerify(manager.registry.models[0])
        _ = try await manager.loadIfNeeded()
        XCTAssertTrue(manager.isResident)

        manager.evict()
        XCTAssertFalse(manager.isResident, "eviction unloads the resident runtime")
        XCTAssertEqual(manager.state, .ready, "verified weights remain (a warm re-load, not re-download)")

        // Re-load is warm: no second download.
        _ = try await manager.loadIfNeeded()
        XCTAssertTrue(manager.isResident)
        XCTAssertEqual(downloader.count, 1, "eviction does not force a re-download")
    }

    func testOptingOutEvictsAndResets() async throws {
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: FakeDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        try await manager.downloadAndVerify(manager.registry.models[0])
        _ = try await manager.loadIfNeeded()
        XCTAssertTrue(manager.isResident)

        manager.setOptedIn(false)
        XCTAssertFalse(manager.isResident, "turning the opt-in off evicts immediately")
        XCTAssertEqual(manager.state, .notDownloaded, "opt-out resets lifecycle state")
    }

    // MARK: - Loading-state observability

    /// The lifecycle must be a VISIBLE sequence of states the UI can bind to (design D4), never a
    /// silent block. We subscribe to `$state` across a full download → verify → load cycle and assert
    /// the intermediate states surface: `.downloading(progress:)` (including the fake's 0.5 and 1.0
    /// progress values), `.verifying`, `.loading`, and the terminal `.loaded`.
    func testStatePublishesIntermediateLoadingSequence() async throws {
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: FakeDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot())

        // Collect every published state. `$state` emits the current value on subscription and then on
        // each change; the manager is @MainActor so synchronous transitions arrive in order.
        var observed: [ModelLifecycleState] = []
        let cancellable = manager.$state.sink { observed.append($0) }
        defer { cancellable.cancel() }

        try await manager.downloadAndVerify(manager.registry.models[0])
        try await manager.loadIfNeeded()

        // The progress callbacks (0.5, 1.0) are surfaced via `Task { @MainActor … }`, so drain the main
        // queue with a bounded poll until both progress values appear (no real sleep, no wall clock).
        for _ in 0..<200 {
            let hasHalf = observed.contains(.downloading(progress: 0.5))
            let hasFull = observed.contains(.downloading(progress: 1.0))
            if hasHalf && hasFull { break }
            await Task.yield()
        }

        XCTAssertTrue(observed.contains(.downloading(progress: 0)),
                      "the download phase surfaces an initial .downloading(progress: 0)")
        XCTAssertTrue(observed.contains(.downloading(progress: 0.5)),
                      "the fake downloader's 0.5 progress is surfaced as observable state")
        XCTAssertTrue(observed.contains(.downloading(progress: 1.0)),
                      "the fake downloader's 1.0 progress is surfaced as observable state")
        XCTAssertTrue(observed.contains(.verifying), "the integrity check is a visible .verifying state")
        XCTAssertTrue(observed.contains(.loading), "the lazy-load is a visible .loading state")
        XCTAssertTrue(observed.contains(.loaded), "the cycle surfaces the terminal .loaded state")
        XCTAssertEqual(manager.state, .loaded, "the manager settles resident in .loaded")
    }

    // MARK: - Strong-hardware-only guard

    func testUnsupportedHardwareReportsUnavailable() async {
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: FakeDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot(),
                                   hardwareSupports: { _ in false })
        do {
            try await manager.downloadAndVerify(manager.registry.models[0])
            XCTFail("unsupported hardware must report unavailable, not degrade")
        } catch let e as RuntimeError {
            guard case .unavailable = e else { return XCTFail("expected .unavailable, got \(e)") }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        guard case .failed = manager.state else {
            return XCTFail("unsupported hardware leaves the manager .failed, got \(manager.state)")
        }
    }

    // MARK: - A non-cancel download error resolves the state (never stuck .downloading)

    /// A downloader that throws a scripted error instead of returning bytes.
    private final class ThrowingDownloader: ModelDownloading, @unchecked Sendable {
        let error: Error
        init(_ error: Error) { self.error = error }
        func download(_ descriptor: ModelDescriptor, to destination: URL,
                      progress: @Sendable (Double) -> Void) async throws -> Data {
            progress(0.25)
            throw error
        }
    }

    func testNonCancelDownloadErrorEndsFailedWithCleanHeadline() async {
        let payload = Data("good".utf8)
        // A bare offline NSError — the byte path's generic catch must convert it to a clean .failed.
        let offline = NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: ThrowingDownloader(offline),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        do {
            try await manager.downloadAndVerify(manager.registry.models[0])
            XCTFail("a failing download must throw")
        } catch {
            // any error type is fine; the STATE is the assertion below
        }
        guard case let .failed(reason, _) = manager.state else {
            return XCTFail("a non-cancel download error must end .failed (not stuck .downloading), got \(manager.state)")
        }
        XCTAssertEqual(reason, RuntimeError.offline.errorDescription,
                       "the headline is the clean connectivity message")
        XCTAssertFalse(reason.contains("Domain="), "the headline never carries the raw NSError dump")
    }

    func testCancelledDownloadReturnsToNotDownloadedNotFailed() async {
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: ThrowingDownloader(CancellationError()),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        do {
            try await manager.downloadAndVerify(manager.registry.models[0])
            XCTFail("a cancelled download throws")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .cancelled, "cancellation is surfaced as RuntimeError.cancelled")
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(manager.state, .notDownloaded,
                       "cancellation returns to the resting state, never .failed")
    }

    // MARK: - Provisioner path: rediscover an already-downloaded model (no re-download)

    /// Thread-safe call counter for the fake provisioner (it may be touched off the main actor).
    private final class ProvisionCounter: @unchecked Sendable {
        private let lock = NSLock(); private var n = 0
        func bump() { lock.lock(); n += 1; lock.unlock() }
        var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    }

    /// A provisioner-backed manager (the real-runtime shape) whose disk-probe reports `onDisk` and whose
    /// provisioner returns a stub (counting invocations) — so rediscovery + lazy-load are testable with
    /// no network and no real MLX.
    private func provisionerManager(onDisk: Bool,
                                    counter: ProvisionCounter,
                                    optedIn: Bool = true) -> ModelManager {
        let payload = Data("w".utf8)
        return ModelManager(
            registry: registry(matching: payload),
            downloader: FakeDownloader(payload: payload),
            optedIn: optedIn,
            storageRoot: tempRoot(),
            provisioner: { descriptor, progress in
                counter.bump()
                progress(1.0)
                return StubLLMRuntime(capabilities: descriptor.capabilities)
            },
            provisionedOnDisk: { _ in onDisk }
        )
    }

    func testReconcileDiscoversOnDiskModelAsReady() {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: true, counter: counter)
        XCTAssertEqual(manager.state, .notDownloaded, "fresh manager starts not-downloaded")
        manager.reconcileWithDisk()
        XCTAssertEqual(manager.state, .ready,
                       "an already-downloaded model is rediscovered as .ready (no Download click needed)")
        XCTAssertFalse(manager.isResident, "rediscovery does NOT eagerly load (load stays lazy)")
        XCTAssertEqual(counter.count, 0, "rediscovery is a pure disk probe — the provisioner never runs")
    }

    func testReconcileIsNoOpWhenNothingOnDisk() {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: false, counter: counter)
        manager.reconcileWithDisk()
        XCTAssertEqual(manager.state, .notDownloaded, "nothing on disk → stays not-downloaded")
    }

    func testReconcileIsNoOpWhenNotOptedIn() {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: true, counter: counter, optedIn: false)
        manager.reconcileWithDisk()
        XCTAssertEqual(manager.state, .notDownloaded, "no rediscovery while opted out")
    }

    /// The real AppCoordinator flow when a user enables AI commands: opt-in flips on, THEN reconcile
    /// runs — an already-downloaded model must surface as .ready without a Download click.
    func testReconcileAfterOptingInRediscoversOnDiskModel() {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: true, counter: counter, optedIn: false)
        manager.reconcileWithDisk()
        XCTAssertEqual(manager.state, .notDownloaded, "no rediscovery while still opted out")

        manager.setOptedIn(true)
        manager.reconcileWithDisk()   // mirrors observeAICommandsToggle's on-enable reconcile
        XCTAssertEqual(manager.state, .ready, "enabling AI commands rediscovers the on-disk model as .ready")
        XCTAssertEqual(counter.count, 0, "rediscovery still never downloads/loads")
    }

    func testReconcileNeverRegressesAResolvedState() async throws {
        // Guard: reconcile must not clobber an already-resolved lifecycle. Once loaded, a stray
        // reconcile (e.g. a second opt-in toggle) must leave .loaded untouched — not drop to .ready.
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: true, counter: counter)
        _ = try await manager.runtime(requiring: [.text])
        XCTAssertEqual(manager.state, .loaded)

        manager.reconcileWithDisk()
        XCTAssertEqual(manager.state, .loaded, "reconcile is a no-op on .loaded (never regresses it)")
        XCTAssertEqual(counter.count, 1, "the stray reconcile triggered no extra provision")
    }

    func testRediscoveredModelLazyLoadsAsLoadingNotDownloading() async throws {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: true, counter: counter)
        manager.reconcileWithDisk()
        XCTAssertEqual(manager.state, .ready)

        var observed: [ModelLifecycleState] = []
        let c = manager.$state.sink { observed.append($0) }
        defer { c.cancel() }

        let runtime = try await manager.runtime(requiring: [.text])
        XCTAssertTrue(runtime.capabilities.contains(.text))
        XCTAssertTrue(manager.isResident, "first use lazy-loads the rediscovered model resident")
        XCTAssertEqual(manager.state, .loaded)
        XCTAssertEqual(counter.count, 1, "the provisioner ran exactly once — to LOAD, not re-download")
        XCTAssertTrue(observed.contains(.loading), "a rediscovered load surfaces as .loading")
        XCTAssertFalse(observed.contains(where: { if case .downloading = $0 { return true }; return false }),
                       "loading an already-present model never shows a (misleading) download bar")
    }

    func testRuntimeRequestLoadsOnDiskModelWithoutPriorReconcileOrDownload() async throws {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: true, counter: counter)
        // Straight to a command's runtime request — no reconcile, no downloadAndVerify.
        let runtime = try await manager.runtime(requiring: [.text])
        XCTAssertTrue(manager.isResident)
        XCTAssertEqual(manager.state, .loaded)
        XCTAssertEqual(counter.count, 1, "the on-disk model is loaded on demand, not re-downloaded")
    }

    func testRuntimeRequestReportsMissingWhenNothingOnDisk() async {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: false, counter: counter)
        do {
            _ = try await manager.runtime(requiring: [.text])
            XCTFail("nothing on disk must report missing, not silently load")
        } catch let e as RuntimeError {
            XCTAssertEqual(e, .modelMissing)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertEqual(counter.count, 0, "no provisioner call when nothing is on disk")
    }

    func testProvisionerEvictFallsBackToReadyAndReloadsWarm() async throws {
        let counter = ProvisionCounter()
        let manager = provisionerManager(onDisk: true, counter: counter)
        _ = try await manager.runtime(requiring: [.text])   // load resident
        XCTAssertEqual(manager.state, .loaded)
        XCTAssertEqual(counter.count, 1)

        manager.evict()
        XCTAssertFalse(manager.isResident, "evict unloads the resident runtime")
        XCTAssertEqual(manager.state, .ready,
                       "provisioner-path evict falls back to .ready (weights remain on disk), not stuck .loaded")

        // A subsequent request reloads from disk (no re-download): the provisioner runs again to LOAD.
        _ = try await manager.runtime(requiring: [.text])
        XCTAssertTrue(manager.isResident)
        XCTAssertEqual(manager.state, .loaded)
        XCTAssertEqual(counter.count, 2, "the warm reload re-runs the provisioner (load), still no byte fetch path")
    }

    // MARK: - Per-model status + delete

    /// A mutable on-disk model set the provisioner-path probe & delete read/write, so a test can assert a
    /// delete actually removes the weights (and a re-probe then reads "not downloaded").
    private final class DiskState: @unchecked Sendable {
        private let lock = NSLock()
        private var present: Set<String>
        private(set) var deleted: [String] = []
        init(_ present: Set<String>) { self.present = present }
        func contains(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return present.contains(id) }
        func remove(_ id: String) { lock.lock(); present.remove(id); deleted.append(id); lock.unlock() }
    }

    /// A two-model registry (default = "model-a") so per-model selection/status is exercisable.
    private func twoModelRegistry() -> ModelRegistry {
        func descriptor(_ id: String) -> ModelDescriptor {
            ModelDescriptor(id: id, displayName: id, sizeBytes: 1, integritySHA: "sha-\(id)",
                            downloadURL: URL(string: "https://models.invalid/\(id)")!,
                            capabilities: [.text, .vision], quantization: .qat4bit)
        }
        return ModelRegistry(models: [descriptor("model-a"), descriptor("model-b")], defaultModelID: "model-a")
    }

    /// A provisioner-backed manager whose disk state is the mutable `disk` (probe + delete go through it).
    private func managerBackedBy(_ disk: DiskState) -> ModelManager {
        ModelManager(
            registry: twoModelRegistry(),
            downloader: FakeDownloader(),
            optedIn: true,
            storageRoot: tempRoot(),
            provisioner: { descriptor, progress in
                progress(1.0)
                return StubLLMRuntime(capabilities: descriptor.capabilities)
            },
            provisionedOnDisk: { disk.contains($0.id) },
            provisionedDelete: { disk.remove($0.id) }
        )
    }

    func testShowStatusTracksSelectedModelPerDisk() {
        let disk = DiskState(["model-b"])      // B downloaded, A not
        let manager = managerBackedBy(disk)
        let a = manager.registry.descriptor(id: "model-a")!
        let b = manager.registry.descriptor(id: "model-b")!

        manager.showStatus(for: a)
        XCTAssertEqual(manager.state, .notDownloaded, "the selected model A is not on disk")
        manager.showStatus(for: b)
        XCTAssertEqual(manager.state, .ready, "selecting B reflects B's own on-disk status")
        manager.showStatus(for: a)
        XCTAssertEqual(manager.state, .notDownloaded,
                       "switching back to A shows A's status, not a stale carry-over from B")
    }

    func testShowStatusIsNoOpWhileOptedOut() {
        let disk = DiskState(["model-b"])
        let manager = managerBackedBy(disk)
        manager.setOptedIn(false)
        manager.showStatus(for: manager.registry.descriptor(id: "model-b")!)
        XCTAssertEqual(manager.state, .notDownloaded, "no status surfaces while AI is opted out")
    }

    func testDeleteFromDiskRemovesWeightsAndResetsSelected() {
        let disk = DiskState(["model-b"])
        let manager = managerBackedBy(disk)
        let b = manager.registry.descriptor(id: "model-b")!
        manager.showStatus(for: b)
        XCTAssertEqual(manager.state, .ready)

        manager.deleteFromDisk(b)
        XCTAssertFalse(disk.contains("model-b"), "delete removes the provisioned weights from disk")
        XCTAssertTrue(disk.deleted.contains("model-b"), "the injected provisioner-delete ran for B")
        XCTAssertEqual(manager.state, .notDownloaded, "the on-screen model resets to not-downloaded")
    }

    func testDeletedModelDoesNotRediscoverAsDownloaded() {
        // The reported bug: after deleting, re-opening the AI section / re-enabling must NOT say
        // "Downloaded". With the weights actually gone, every re-probe reads not-downloaded.
        let disk = DiskState(["model-b"])
        let manager = managerBackedBy(disk)
        let b = manager.registry.descriptor(id: "model-b")!
        manager.showStatus(for: b)
        manager.deleteFromDisk(b)

        manager.showStatus(for: b)             // re-open the AI section
        XCTAssertEqual(manager.state, .notDownloaded, "a deleted model never re-discovers as Downloaded")
        manager.reconcileWithDisk()            // launch / opt-in rediscovery path
        XCTAssertEqual(manager.state, .notDownloaded)
    }

    func testDeleteResidentModelEvictsIt() async throws {
        let disk = DiskState(["model-a"])
        let manager = managerBackedBy(disk)
        let a = manager.registry.descriptor(id: "model-a")!
        _ = try await manager.runtime(requiring: [.text])   // A resident + .loaded
        XCTAssertEqual(manager.state, .loaded)

        manager.deleteFromDisk(a)
        XCTAssertFalse(manager.isResident, "deleting the resident model unloads it")
        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertFalse(disk.contains("model-a"))
    }

    func testDeleteAllFromDiskClearsEveryModelAndResidency() async throws {
        let disk = DiskState(["model-a", "model-b"])
        let manager = managerBackedBy(disk)
        _ = try await manager.runtime(requiring: [.text])   // load the default (A) resident
        XCTAssertTrue(manager.isResident)

        manager.deleteAllFromDisk()
        XCTAssertFalse(manager.isResident, "deleting all drops residency")
        XCTAssertEqual(manager.state, .notDownloaded)
        XCTAssertFalse(disk.contains("model-a"))
        XCTAssertFalse(disk.contains("model-b"))
    }

    func testDeleteFromDiskBytePathClearsVerifiedWeights() async throws {
        // Dev/byte path: no provisioner — deleting clears the held verified weights and resets state.
        let payload = Data("good".utf8)
        let manager = ModelManager(registry: registry(matching: payload),
                                   downloader: FakeDownloader(payload: payload),
                                   optedIn: true,
                                   storageRoot: tempRoot())
        try await manager.downloadAndVerify(manager.registry.models[0])
        XCTAssertEqual(manager.state, .ready)

        manager.deleteFromDisk(manager.registry.models[0])
        XCTAssertEqual(manager.state, .notDownloaded, "deleting clears the verified weights → not-downloaded")
    }
}
