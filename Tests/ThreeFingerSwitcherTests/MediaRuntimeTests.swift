import XCTest
@testable import ThreeFingerSwitcherCore

/// `ai-media-runtime` — the seam + value types, the two tools + contributor, the `MediaGenSink`, the seed
/// path, the gallery + `.fileEntry`, the canvas state/resolve model, the parked feed, residency, and
/// `MediaError`. All MLX-free Core, driven against `StubMediaRuntime` (no weights).
final class MediaRuntimeTests: XCTestCase {

    // MARK: - Helpers

    private func pngBytes() -> Data {
        Data(MediaSeedValidation.pngMagic + [0x00, 0x01, 0x02])
    }

    private func tmpGalleryRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaGalleryTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func imageAsset(in root: URL) -> MediaAsset {
        MediaAsset(url: root.appendingPathComponent("x.png"), kind: .image, width: 512, height: 512)
    }

    private func route(_ tool: String, argsJSON: String = "{}", userText: String = "draw a cat") -> RoutedCall {
        let desc = (tool == MediaTool.generateImage) ? MediaToolContributor.imageDescriptor
            : ToolDescriptor(name: tool, summary: "", argsSchema: StructuredSchema(name: tool, json: "{}"),
                             writePolicy: .dangerous)
        return RoutedCall(descriptor: desc,
                          route: ToolRoute(tool: tool, argumentsJSON: argsJSON),
                          userText: userText,
                          source: TaskSource())
    }

    /// A scripted gate (mirrors the routing tests' pattern).
    struct ScriptedGate: ApprovalGate {
        let decision: ApprovalDecision
        func awaitDecision(for review: TaskReview) async -> ApprovalDecision { decision }
    }

    /// A recording observer.
    final class SpyObserver: MediaJobObserving, @unchecked Sendable {
        var steps = 0
        var finished: MediaAsset?
        var failedHeadline: String?
        var cancelled = false
        var residency: MediaResidencyNote?
        func didDecideResidency(_ note: MediaResidencyNote) { residency = note }
        func didStep(index: Int, total: Int, preview: Data?) { steps += 1 }
        func didFinish(_ asset: MediaAsset) { finished = asset }
        func didFail(headline: String) { failedHeadline = headline }
        func didCancel() { cancelled = true }
    }

    // MARK: - 1.1 Value types: Codable round-trip; seed shapes; durationMs video-only

    func testMediaAssetCodableRoundTrip() throws {
        let asset = MediaAsset(url: URL(fileURLWithPath: "/tmp/a.mp4"), kind: .video,
                               width: 1280, height: 720, durationMs: 4000)
        let data = try JSONEncoder().encode(asset)
        let back = try JSONDecoder().decode(MediaAsset.self, from: data)
        XCTAssertEqual(asset, back)
        XCTAssertEqual(back.durationMs, 4000)
    }

    func testMediaParametersDurationVideoOnlyByConvention() {
        let img = MediaArgs(prompt: "p", durationMs: 5000).request(kind: .image, seed: nil)
        XCTAssertNil(img.parameters.durationMs, "image requests carry no duration")
        let vid = MediaArgs(prompt: "p", durationMs: 5000).request(kind: .video, seed: nil)
        XCTAssertEqual(vid.parameters.durationMs, 5000)
    }

    func testRequestSeedPresentAndAbsentShapes() {
        let none = MediaRequest(prompt: "p", kind: .image)
        XCTAssertNil(none.seed)
        let seeded = MediaRequest(prompt: "p", seed: pngBytes(), kind: .image)
        XCTAssertNotNil(seeded.seed)
    }

    // MARK: - 1.3 StubMediaRuntime scripts drive a deterministic stream

    func testStubSuccessWithPreviews() async throws {
        let asset = imageAsset(in: tmpGalleryRoot())
        let stub = StubMediaRuntime(capabilities: [.image],
                                    script: .successWithPreviews(count: 3, total: 3, preview: pngBytes(), asset: asset))
        var steps = 0
        var finished: MediaAsset?
        for try await p in stub.generate(MediaRequest(prompt: "p", kind: .image)) {
            switch p {
            case .step: steps += 1
            case let .finished(a): finished = a
            }
        }
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(finished, asset)
    }

    func testStubFailMidFlightThrows() async {
        let stub = StubMediaRuntime(script: .failMidFlight(steps: 2, headline: "boom"))
        do {
            for try await _ in stub.generate(MediaRequest(prompt: "p", kind: .image)) {}
            XCTFail("expected throw")
        } catch {
            guard case let MediaError.generationFailed(h) = error else { return XCTFail("wrong error \(error)") }
            XCTAssertEqual(h, "boom")
        }
    }

    // MARK: - 2.1 Descriptors: names + tiers + argsSchema validates

    func testImageDescriptorIsConfirmTier() {
        XCTAssertEqual(MediaToolContributor.imageDescriptor.name, "generate_image")
        XCTAssertEqual(MediaToolContributor.imageDescriptor.writePolicy, .confirm)
    }

    func testImageArgsSchemaIsValidJSON() throws {
        let data = MediaToolContributor.imageArgsSchemaJSON.data(using: .utf8)!
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(obj?["properties"])
    }

    func testCloudVideoDescriptorIsDangerous() {
        let contributor = makeContributor(videoCloud: true, cloudOn: true, budget: 5, hasVideoProvider: true)
        let video = contributor.videoDescriptor
        XCTAssertEqual(video.name, "generate_video")
        XCTAssertEqual(video.writePolicy, .dangerous)
    }

    // MARK: - 2.2 Availability gating (D11)

    func testNothingContributedWhenMediaDisabled() {
        let contributor = makeContributor(mediaOn: false, fullPotentialOn: true)
        XCTAssertTrue(contributor.descriptors().isEmpty)
    }

    func testNothingContributedWhenFullPotentialOff() {
        let contributor = makeContributor(mediaOn: true, fullPotentialOn: false)
        XCTAssertTrue(contributor.descriptors().isEmpty)
    }

    func testImageOfferedOnlyWhenImageRuntimeAdvertisesImage() {
        let withImage = makeContributor(imageCaps: [.image])
        XCTAssertTrue(withImage.descriptors().contains { $0.name == "generate_image" })
        let withoutImage = makeContributor(imageCaps: [])
        XCTAssertFalse(withoutImage.descriptors().contains { $0.name == "generate_image" })
    }

    func testVideoOmittedWhenNoProviderOrCloudOffOrBudgetOut() {
        // No provider → omitted.
        XCTAssertFalse(makeContributor(videoCaps: [.video], hasVideoProvider: false)
            .descriptors().contains { $0.name == "generate_video" })
        // Cloud provider, cloud escalation OFF → omitted.
        XCTAssertFalse(makeContributor(videoCaps: [.video], videoCloud: true, cloudOn: false, hasVideoProvider: true)
            .descriptors().contains { $0.name == "generate_video" })
        // Cloud provider on, budget 0 → omitted.
        XCTAssertFalse(makeContributor(videoCaps: [.video], videoCloud: true, cloudOn: true, budget: 0, hasVideoProvider: true)
            .descriptors().contains { $0.name == "generate_video" })
        // Cloud provider on, budget left → present.
        XCTAssertTrue(makeContributor(videoCaps: [.video], videoCloud: true, cloudOn: true, budget: 3, hasVideoProvider: true)
            .descriptors().contains { $0.name == "generate_video" })
    }

    // MARK: - 3.1 Approval precedes compute; skip / approve

    func testApproveDrivesGenerationAndReturnsDoneWithGalleryPath() async throws {
        let root = tmpGalleryRoot()
        let gallery = MediaGallery(root: root)
        let stub = StubMediaRuntime(capabilities: [.image],
                                    script: .successWithPreviews(count: 2, total: 2, preview: pngBytes(),
                                                                 asset: imageAsset(in: root)))
        let observer = SpyObserver()
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, gallery: gallery,
                                budget: PerDayVideoBudget(cap: { 0 }), observer: observer)
        let result = await sink.run(route(MediaTool.generateImage), gate: ScriptedGate(decision: .approve))
        XCTAssertEqual(result.status, .done)
        XCTAssertNotNil(observer.finished)
        XCTAssertEqual(observer.steps, 2)
    }

    func testSkipAppliesNothing() async {
        let root = tmpGalleryRoot()
        let stub = StubMediaRuntime(capabilities: [.image], script: .success(imageAsset(in: root)))
        let observer = SpyObserver()
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, gallery: MediaGallery(root: root),
                                budget: PerDayVideoBudget(cap: { 0 }), observer: observer)
        let result = await sink.run(route(MediaTool.generateImage), gate: ScriptedGate(decision: .skip))
        guard case .declined = result.status else { return XCTFail("expected declined") }
        XCTAssertNil(observer.finished, "no compute on skip")
        XCTAssertEqual(stub.receivedRequests.count, 0, "the runtime is never called on skip")
    }

    func testCancelIsNotAFailure() async {
        let root = tmpGalleryRoot()
        let stub = StubMediaRuntime(capabilities: [.image], script: .success(imageAsset(in: root)))
        let observer = SpyObserver()
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, gallery: MediaGallery(root: root),
                                budget: PerDayVideoBudget(cap: { 0 }), observer: observer)
        let result = await sink.run(route(MediaTool.generateImage), gate: ScriptedGate(decision: .cancel))
        guard case let .declined(reason) = result.status else { return XCTFail("expected declined") }
        XCTAssertEqual(reason, MediaGenSink.cancelledReason)
        XCTAssertTrue(observer.cancelled)
        XCTAssertNil(observer.failedHeadline, "cancel is never a failure")
    }

    // MARK: - 3.3 Budget cap enforced before spend

    func testExhaustedBudgetResolvesBeforeAnyRuntimeCall() async {
        let stub = StubMediaRuntime(capabilities: [.video], script: .success(imageAsset(in: tmpGalleryRoot())))
        let videoDesc = ToolDescriptor(name: MediaTool.generateVideo, summary: "",
                                       argsSchema: StructuredSchema(name: "v", json: "{}"), writePolicy: .dangerous)
        let call = RoutedCall(descriptor: videoDesc, route: ToolRoute(tool: MediaTool.generateVideo),
                              userText: "make a clip", source: TaskSource())
        let sink = MediaGenSink(imageRuntime: nil, videoRuntime: stub, gallery: MediaGallery(root: tmpGalleryRoot()),
                                budget: PerDayVideoBudget(cap: { 0 }))   // 0 → exhausted
        let result = await sink.run(call, gate: ScriptedGate(decision: .approve))
        guard case let .failed(headline) = result.status else { return XCTFail("expected failed") }
        XCTAssertEqual(headline, MediaError.cloudBudgetExhausted.errorDescription)
        XCTAssertEqual(stub.receivedRequests.count, 0, "budget-out → no runtime call, no spend")
    }

    // MARK: - 3.4 Residency: eviction → busy painting

    func testResidencyEvictionSurfacesBusyPainting() async throws {
        let root = tmpGalleryRoot()
        let stub = StubMediaRuntime(capabilities: [.image], script: .success(imageAsset(in: root)))
        let registry = EvictingStubRegistry()   // chat resident before, evicted after ensureResident
        let residency = MediaResidencyCoordinator(registry: registry)
        let observer = SpyObserver()
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, gallery: MediaGallery(root: root),
                                budget: PerDayVideoBudget(cap: { 0 }), residency: residency,
                                observer: observer, imageModelID: "image-model")
        _ = await sink.run(route(MediaTool.generateImage), gate: ScriptedGate(decision: .approve))
        XCTAssertEqual(observer.residency, .busyPainting)
    }

    // MARK: - 4 Seed path

    func testSeedWiredIntoRequest() async throws {
        let root = tmpGalleryRoot()
        let stub = StubMediaRuntime(capabilities: [.image], script: .success(imageAsset(in: root)))
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, seed: CapturedSeed(png: pngBytes()),
                                gallery: MediaGallery(root: root), budget: PerDayVideoBudget(cap: { 0 }))
        _ = await sink.run(route(MediaTool.generateImage, argsJSON: "{\"seedImage\":\"clipboardImage\"}"),
                           gate: ScriptedGate(decision: .approve))
        XCTAssertEqual(stub.receivedRequests.first?.seed, pngBytes())
    }

    func testMissingRequiredSeedFailsCleanlyWithNoCompute() async {
        let stub = StubMediaRuntime(capabilities: [.image], script: .success(imageAsset(in: tmpGalleryRoot())))
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, seed: NoSeed(),
                                gallery: MediaGallery(root: tmpGalleryRoot()), budget: PerDayVideoBudget(cap: { 0 }))
        let result = await sink.run(route(MediaTool.generateImage, argsJSON: "{\"seedImage\":\"screenRegion\"}"),
                                    gate: ScriptedGate(decision: .approve))
        guard case let .failed(h) = result.status else { return XCTFail("expected failed") }
        XCTAssertEqual(h, MediaError.seedRequired.errorDescription)
        XCTAssertEqual(stub.receivedRequests.count, 0)
    }

    func testInvalidSeedFails() async {
        let stub = StubMediaRuntime(capabilities: [.image], script: .success(imageAsset(in: tmpGalleryRoot())))
        let badSeed = CapturedSeed(png: Data([0x00, 0x01, 0x02, 0x03]))   // not a PNG signature
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, seed: badSeed,
                                gallery: MediaGallery(root: tmpGalleryRoot()), budget: PerDayVideoBudget(cap: { 0 }))
        let result = await sink.run(route(MediaTool.generateImage, argsJSON: "{\"seedImage\":\"clipboardImage\"}"),
                                    gate: ScriptedGate(decision: .approve))
        guard case let .failed(h) = result.status else { return XCTFail("expected failed") }
        XCTAssertEqual(h, MediaError.seedInvalid.errorDescription)
    }

    // MARK: - 5 Gallery output + .fileEntry

    func testGalleryWritePersistsAndSurvivesRelaunchRead() throws {
        let root = tmpGalleryRoot()
        let gallery = MediaGallery(root: root)
        let asset = try gallery.write(pngBytes(), kind: .image, width: 256, height: 256, durationMs: nil)
        XCTAssertTrue(FileManager.default.fileExists(atPath: asset.url.path))
        // A "relaunch" read: a fresh gallery instance over the same root still finds the file.
        let reread = try Data(contentsOf: asset.url)
        XCTAssertEqual(reread, pngBytes())
    }

    func testAssetMapsToFileEntryWithPathStableIdentity() {
        let url = tmpGalleryRoot().appendingPathComponent("a.png")
        let asset = MediaAsset(url: url, kind: .image, width: 1, height: 1)
        let e1 = asset.fileEntry()
        let e2 = asset.fileEntry()
        XCTAssertEqual(e1.id, e2.id, "path-stable identity — no strobe")
        XCTAssertEqual(e1.kind, .image)
        XCTAssertFalse(e1.isDirectory)
    }

    // MARK: - 6.1 Canvas state model

    func testJobStateAdvancesAndTerminates() {
        var s = MediaJobState.idle
        s.advance(.step(index: 0, total: 4, preview: pngBytes()))
        guard case .generating = s else { return XCTFail() }
        XCTAssertFalse(s.isTerminal)
        let asset = imageAsset(in: tmpGalleryRoot())
        s.advance(.finished(asset))
        XCTAssertEqual(s.asset, asset)
        XCTAssertTrue(s.isTerminal)
    }

    func testJobStateFailVsCancel() {
        var failed = MediaJobState.generating(index: 0, total: 1, preview: nil)
        failed.fail(with: MediaError.generationFailed(headline: "nope"))
        guard case let .failed(h) = failed else { return XCTFail() }
        XCTAssertEqual(h, "nope")

        var cancelled = MediaJobState.generating(index: 0, total: 1, preview: nil)
        cancelled.fail(with: CancellationError())
        XCTAssertEqual(cancelled, .cancelled)
    }

    // MARK: - 6.3 Canvas resolve compass

    func testResolveDownAtTopExtracts() {
        let s = MediaJobState.finished(imageAsset(in: tmpGalleryRoot()))
        XCTAssertEqual(MediaCanvasResolver.resolve(dx: 0, dy: 0.5, atTop: true, state: s), .extract)
    }

    func testResolveDownNotAtTopDoesNotExtract() {
        let s = MediaJobState.finished(imageAsset(in: tmpGalleryRoot()))
        XCTAssertEqual(MediaCanvasResolver.resolve(dx: 0, dy: 0.5, atTop: false, state: s), .none)
    }

    func testResolveRightDiscards() {
        let s = MediaJobState.finished(imageAsset(in: tmpGalleryRoot()))
        XCTAssertEqual(MediaCanvasResolver.resolve(dx: 0.5, dy: 0, atTop: true, state: s), .discard)
    }

    func testSubThresholdScrollDoesNotResolve() {
        let s = MediaJobState.finished(imageAsset(in: tmpGalleryRoot()))
        XCTAssertEqual(MediaCanvasResolver.resolve(dx: 0.05, dy: 0.05, atTop: true, state: s), .none)
    }

    func testNonTerminalNeverResolves() {
        let s = MediaJobState.generating(index: 0, total: 1, preview: nil)
        XCTAssertEqual(MediaCanvasResolver.resolve(dx: 0, dy: 0.9, atTop: true, state: s), .none)
    }

    // MARK: - 7 Parked feed

    func testPaintingThenFinishedFeedsScheduler() {
        let id = AgentSessionID()
        let row = ParkedSession(id: id, title: "gen", state: .parked)
        let scheduler = SerialParkScheduler(sessions: [row])
        let feed = MediaParkFeed(scheduler: scheduler)
        feed.reportPainting(id, tool: MediaTool.generateImage)
        feed.reportFinished(id, tool: MediaTool.generateImage, asset: imageAsset(in: tmpGalleryRoot()))
        let after = scheduler.snapshot().first { $0.id == id }
        XCTAssertEqual(after?.state, .idle,
                       "a finished gen idles with its unseen result — never a terminal state that removes it")
        XCTAssertGreaterThanOrEqual(after?.badgeCount ?? 0, 1, "unseen count bumped")
    }

    func testDangerousVideoParkedEscalates() {
        let id = AgentSessionID()
        let scheduler = SerialParkScheduler(sessions: [ParkedSession(id: id, title: "v", state: .parked)])
        let feed = MediaParkFeed(scheduler: scheduler)
        feed.reportNeedsYou(id, reason: "Cloud video spends from today's budget.")
        XCTAssertEqual(scheduler.snapshot().first { $0.id == id }?.state, .needsYou)
    }

    // MARK: - 8 MediaError taxonomy + translator

    func testEveryMediaErrorCaseHasCleanNonEmptyDescription() {
        let cases: [MediaError] = [
            .noCapableBackend(kind: .image), .noCapableBackend(kind: .video),
            .seedRequired, .seedInvalid, .generationFailed(headline: "x"),
            .outputWriteFailed(detail: "io"), .cloudBudgetExhausted, .cloudUnavailable
        ]
        for c in cases {
            XCTAssertFalse((c.errorDescription ?? "").isEmpty, "\(c) has empty description")
        }
    }

    func testMediaErrorRoutesThroughTranslatorRawTextOnlyInDetails() {
        let err = MediaError.outputWriteFailed(detail: "POSIX error 13: Permission denied")
        let presented = AIError.message(for: err)
        XCTAssertEqual(presented.headline, err.errorDescription)
        XCTAssertFalse(presented.headline.contains("POSIX"), "raw text never in headline")
        XCTAssertEqual(presented.details, "POSIX error 13: Permission denied")
    }

    func testCancellationDistinctFromFailureInTranslator() {
        let presented = AIError.message(for: CancellationError())
        XCTAssertEqual(presented.headline, RuntimeError.cancelled.errorDescription)
    }

    // MARK: - 8.3 Audit

    func testOneAuditRecordPerTerminalOutcome() async {
        let root = tmpGalleryRoot()
        let stub = StubMediaRuntime(capabilities: [.image], script: .success(imageAsset(in: root)))
        let audit = InMemoryAuditLog()
        let id = AgentSessionID()
        let sink = MediaGenSink(imageRuntime: stub, videoRuntime: nil, gallery: MediaGallery(root: root),
                                budget: PerDayVideoBudget(cap: { 0 }), audit: audit, sessionID: id)
        _ = await sink.run(route(MediaTool.generateImage), gate: ScriptedGate(decision: .approve))
        let records = audit.recent(limit: 10)
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.tool, MediaTool.generateImage)
        XCTAssertEqual(records.first?.policy, .confirm)
        XCTAssertEqual(records.first?.outcome, .done)
    }

    // MARK: - Cloud-video dangerous tier is never lowered

    func testDangerousNeverLoweredByDescriptorResolver() {
        let videoDesc = ToolDescriptor(name: MediaTool.generateVideo, summary: "",
                                       argsSchema: StructuredSchema(name: "v", json: "{}"), writePolicy: .dangerous)
        XCTAssertEqual(DescriptorWritePolicy().effectiveTier(for: videoDesc), .dangerous)
    }

    // MARK: - Builders

    private func makeContributor(mediaOn: Bool = true, fullPotentialOn: Bool = true,
                                 imageCaps: Set<MediaKind> = [.image], videoCaps: Set<MediaKind> = [.video],
                                 videoCloud: Bool = true, cloudOn: Bool = false, budget: Int = 0,
                                 hasVideoProvider: Bool = false) -> MediaToolContributor {
        let availability = MediaToolAvailability(
            isFullPotentialEnabled: { fullPotentialOn },
            isMediaGenEnabled: { mediaOn },
            isCloudEscalationEnabled: { cloudOn },
            hasVideoProvider: { hasVideoProvider },
            videoProviderIsCloud: { videoCloud })
        let img = StubMediaRuntime(capabilities: imageCaps, script: .success(imageAsset(in: tmpGalleryRoot())))
        let vid = StubMediaRuntime(capabilities: videoCaps, script: .success(imageAsset(in: tmpGalleryRoot())))
        let budgetObj = PerDayVideoBudget(cap: { budget })
        let sink = MediaGenSink(imageRuntime: img, videoRuntime: vid, gallery: MediaGallery(root: tmpGalleryRoot()),
                                budget: budgetObj)
        return MediaToolContributor(availability: availability, imageRuntime: img, videoRuntime: vid,
                                    budget: budgetObj, sink: sink)
    }
}

/// A stub registry where chat is resident BEFORE `ensureResident` and EVICTED after (models a heavy gen).
private final class EvictingStubRegistry: ModelRegistry, @unchecked Sendable {
    private var residentChat = true
    private let chat = ModelDescriptor(id: "chat", displayName: "Chat", sizeBytes: 1, integritySHA: "x",
                                       downloadURL: URL(string: "https://example.com")!, capabilities: [.text],
                                       quantization: .qat4bit, role: .chat)
    func descriptors() -> [ModelDescriptor] { [chat] }
    func resident() -> [ModelDescriptor] { residentChat ? [chat] : [] }
    func ensureResident(_ id: String) async throws { residentChat = false }   // the gen evicts chat
}
