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
}
