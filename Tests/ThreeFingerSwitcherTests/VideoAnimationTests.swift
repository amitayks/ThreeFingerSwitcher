import XCTest
@testable import ThreeFingerSwitcherCore

/// `ai-video-animation-generation` — the VIDEO backend behind the `MediaRuntime` seam: the `VideoProvider`
/// selector + master-gated validity, the `VideoUploadDisclosure` redaction, the rolling-24h `VideoBudget`
/// (relaunch-surviving ledger + refund + degrade-not-drop), the effective-tier + over-budget degrade
/// resolution, the audit-per-attempt with redacted summary, the two scripted video stubs (progress →
/// finished video asset + img2video seed), parking, the error taxonomy, and the swap-in contract. All
/// MLX-/network-free Core, driven against the scripted stubs (no weights, no hosted API).
final class VideoAnimationTests: XCTestCase {

    // MARK: - Helpers

    private func png() -> Data { Data(MediaSeedValidation.pngMagic + [0x01, 0x02, 0x03]) }

    private func videoAsset() -> MediaAsset {
        MediaAsset.video(url: FileManager.default.temporaryDirectory.appendingPathComponent("clip.mp4"),
                         width: 1024, height: 576, durationMs: 4000)
    }

    // MARK: - 1.1 VideoProvider

    func testVideoProviderDefaultIsCloud() {
        XCTAssertEqual(VideoProvider.defaultProvider, .cloud)
        XCTAssertTrue(VideoProvider.cloud.isCloud)
        XCTAssertFalse(VideoProvider.localLTXV.isCloud)
    }

    func testVideoProviderCodableRoundTrip() throws {
        for p in VideoProvider.allCases {
            let data = try JSONEncoder().encode(p)
            let back = try JSONDecoder().decode(VideoProvider.self, from: data)
            XCTAssertEqual(back, p)
        }
    }

    func testLocalProviderRequiresMasterToggle() {
        // Cloud is always selectable; local needs BOTH master flags ON.
        XCTAssertTrue(VideoProvider.cloud.isSelectable(fullPotentialEnabled: false, mediaGenEnabled: false))
        XCTAssertFalse(VideoProvider.localLTXV.isSelectable(fullPotentialEnabled: false, mediaGenEnabled: true))
        XCTAssertFalse(VideoProvider.localLTXV.isSelectable(fullPotentialEnabled: true, mediaGenEnabled: false))
        XCTAssertTrue(VideoProvider.localLTXV.isSelectable(fullPotentialEnabled: true, mediaGenEnabled: true))
    }

    func testResolvedFallsBackToCloudWhenLocalForbidden() {
        // A persisted `.localLTXV` with the master off degrades to the calm `.cloud` default.
        let r = VideoProvider.resolved(rawValue: "localLTXV", fullPotentialEnabled: false, mediaGenEnabled: false)
        XCTAssertEqual(r, .cloud)
        // With the master on, the stored choice is honored.
        let r2 = VideoProvider.resolved(rawValue: "localLTXV", fullPotentialEnabled: true, mediaGenEnabled: true)
        XCTAssertEqual(r2, .localLTXV)
        // An absent/garbage value resolves to the default.
        XCTAssertEqual(VideoProvider.resolved(rawValue: nil, fullPotentialEnabled: true, mediaGenEnabled: true), .cloud)
        XCTAssertEqual(VideoProvider.resolved(rawValue: "bogus", fullPotentialEnabled: true, mediaGenEnabled: true), .cloud)
    }

    // MARK: - 1.2 / 7.x VideoUploadDisclosure

    func testCloudDisclosureFlagsUploadAndRedactsPrompt() {
        let secretPrompt = "make a clip token=SUPERSECRETVALUE123 of a sunset"
        let d = VideoUploadDisclosure.make(provider: .cloud, prompt: secretPrompt, seedPresent: true)
        XCTAssertTrue(d.bytesLeaveDevice)
        XCTAssertTrue(d.seedPresent)
        // The full prompt + the raw secret never appear in the audit summary.
        XCTAssertFalse(d.auditSummary.contains("SUPERSECRETVALUE123"), "raw secret leaked into summary")
        XCTAssertFalse(d.auditSummary.contains(secretPrompt), "full prompt leaked into summary")
        XCTAssertTrue(d.auditSummary.contains("cloud"))
        XCTAssertTrue(d.auditSummary.contains("seed:yes"))
    }

    func testLocalDisclosureDoesNotClaimUpload() {
        let d = VideoUploadDisclosure.make(provider: .localLTXV, prompt: "a dog running", seedPresent: false)
        XCTAssertFalse(d.bytesLeaveDevice)
        XCTAssertFalse(d.seedPresent)
        XCTAssertTrue(d.auditSummary.contains("localLTXV"))
        XCTAssertTrue(d.auditSummary.contains("seed:no"))
    }

    func testCloudConfirmLineStatesUploadAndCost() {
        let d = VideoUploadDisclosure.make(provider: .cloud, prompt: "x", seedPresent: true)
        let line = d.cloudConfirmLine(perClipCostOrder: "~$0.20")
        XCTAssertTrue(line.contains("remote video service"))
        XCTAssertTrue(line.contains("~$0.20"))
        XCTAssertTrue(line.contains("source image"), "seed-present run mentions the uploaded image")
    }

    func testLocalCostLineDisclosesResidencyLatencyEvictionThermal() {
        let line = VideoUploadDisclosure.localCostLine
        XCTAssertTrue(line.contains("gigabytes"))      // residency
        XCTAssertTrue(line.contains("minutes"))        // latency
        XCTAssertTrue(line.contains("evicted"))        // chat eviction
        XCTAssertTrue(line.lowercased().contains("hot")) // thermal
        XCTAssertTrue(line.contains("Nothing is uploaded"))
    }

    // MARK: - 2.1 VideoBudget under cap

    func testBudgetUnderCapAllows() {
        var b = VideoBudget(maxCallsPerWindow: 3)
        let now = Date()
        XCTAssertTrue(b.allows(now: now))
        b.record(at: now); b.reap()
        XCTAssertTrue(b.allows(now: now))               // 1 of 3 used
    }

    func testZeroCapNeverAllows() {
        let b = VideoBudget(maxCallsPerWindow: 0)
        XCTAssertFalse(b.allows(now: Date()))
    }

    func testConcurrencyCapBlocksInFlight() {
        var b = VideoBudget(maxCallsPerWindow: 5, maxConcurrent: 1)
        let now = Date()
        b.record(at: now)                               // in-flight = 1, not reaped
        XCTAssertFalse(b.allows(now: now), "concurrency cap blocks a second concurrent gen")
        b.reap()
        XCTAssertTrue(b.allows(now: now))
    }

    // MARK: - 2.2 Rolling window, NOT calendar reset

    func testRollingWindowNotGamedAcrossMidnight() {
        // Two spends straddling midnight but within 24h count TOGETHER (no calendar reset).
        let cal = Calendar(identifier: .gregorian)
        let base = cal.date(from: DateComponents(year: 2026, month: 6, day: 22, hour: 23, minute: 59))!
        let afterMidnight = cal.date(from: DateComponents(year: 2026, month: 6, day: 23, hour: 0, minute: 1))!
        var b = VideoBudget(maxCallsPerWindow: 2)
        b.record(at: base); b.reap()
        b.record(at: afterMidnight); b.reap()
        // Both inside the rolling 24h window ending just after midnight → cap (2) reached.
        XCTAssertEqual(b.callsInLast24h(afterMidnight), 2)
        XCTAssertFalse(b.allows(now: afterMidnight), "midnight does NOT reset the rolling window")
        // A spend OUTSIDE the window (25h later) no longer counts.
        let later = afterMidnight.addingTimeInterval(25 * 60 * 60)
        XCTAssertEqual(b.callsInLast24h(later), 0)
        XCTAssertTrue(b.allows(now: later))
    }

    // MARK: - 2.3 Ledger survives relaunch (replay)

    func testLedgerSurvivesRelaunchWithinWindow() {
        let now = Date()
        let store = InMemoryVideoLedgerStore()
        let first = RollingVideoBudget(cap: { 2 }, store: store)
        XCTAssertTrue(first.hasRemaining(now: now))
        first.consume(now: now); first.reap()
        first.consume(now: now); first.reap()
        XCTAssertFalse(first.hasRemaining(now: now), "cap reached")
        // A NEW box reading the SAME store replays the ledger → prior spends still count.
        let relaunched = RollingVideoBudget(cap: { 2 }, store: store)
        XCTAssertFalse(relaunched.hasRemaining(now: now), "relaunch does not reset the rolling cap")
        XCTAssertEqual(relaunched.snapshot().callsInLast24h(now), 2)
    }

    // MARK: - 2.4 Refund + degrade-not-drop

    func testFailedLaunchRefundLeavesCapUnchanged() {
        let now = Date()
        let b = RollingVideoBudget(cap: { 1 })
        XCTAssertTrue(b.hasRemaining(now: now))
        let at = now
        b.consume(now: at)                              // spend recorded
        XCTAssertFalse(b.hasRemaining(now: now), "cap consumed")
        b.refund(at: at)                                // launch failed → refund
        XCTAssertTrue(b.hasRemaining(now: now), "refund restores the cap")
        XCTAssertEqual(b.snapshot().callsInLast24h(now), 0)
        XCTAssertEqual(b.snapshot().inFlight, 0)
    }

    func testOverBudgetReturnsDegradeSignalNotDrop() {
        // The resolver returns a DEGRADE gate (never a silent drop) when cloud is over budget.
        let resolver = VideoTierResolver(provider: .cloud)
        let gate = resolver.gate(budgetHasRoom: false)
        XCTAssertEqual(gate, .cloudOverBudget)
        XCTAssertTrue(gate.spendsCloudBudget)
    }

    func testLiveCapBumpTakesEffect() {
        // A settings bump to the cap takes effect immediately (the box reads the cap live).
        let now = Date()
        var capValue = 1
        let b = RollingVideoBudget(cap: { capValue })
        b.consume(now: now); b.reap()
        XCTAssertFalse(b.hasRemaining(now: now))
        capValue = 5
        XCTAssertTrue(b.hasRemaining(now: now), "raising the cap admits more without losing recorded spend")
        XCTAssertEqual(b.snapshot().callsInLast24h(now), 1, "the existing spend is preserved")
    }

    // MARK: - 3.1 Effective tier

    func testCloudVideoResolvesDangerous() {
        let desc = ToolDescriptor(name: MediaTool.generateVideo, summary: "",
                                  argsSchema: StructuredSchema(name: MediaTool.generateVideo, json: "{}"),
                                  writePolicy: .dangerous)
        let resolver = VideoTierResolver(provider: .cloud,
                                         resolver: BackgroundPolicyResolver(whitelist: .empty))
        XCTAssertEqual(resolver.effectiveTier(for: desc), .dangerous, "cloud video is never lowered")
    }

    func testLocalVideoTierIsConfirmAndMasterGated() {
        let desc = ToolDescriptor(name: MediaTool.generateVideo, summary: "",
                                  argsSchema: StructuredSchema(name: MediaTool.generateVideo, json: "{}"),
                                  writePolicy: .dangerous)
        // Local: confirm tier, off the spend axis.
        let onResolver = VideoTierResolver(provider: .localLTXV,
                                           isFullPotentialEnabled: { true }, isMediaGenEnabled: { true })
        XCTAssertEqual(onResolver.effectiveTier(for: desc), .confirm)
        XCTAssertEqual(onResolver.gate(budgetHasRoom: true), .localConfirm)
        // Master off → provider disabled (a settings desync degrades to disabled, never runs).
        let offResolver = VideoTierResolver(provider: .localLTXV,
                                            isFullPotentialEnabled: { false }, isMediaGenEnabled: { true })
        XCTAssertEqual(offResolver.gate(budgetHasRoom: true), .providerDisabled)
    }

    // MARK: - 3.2 Over-budget degrade messages

    func testOverBudgetActiveConfirmAndParkedNeedsYouMessages() {
        let active = VideoTierResolver.overBudgetReason(parked: false)
        let parked = VideoTierResolver.overBudgetReason(parked: true)
        XCTAssertTrue(active.contains("budget is used up"))
        XCTAssertTrue(active.contains("Approve"), "active degrades to a foreground confirm")
        XCTAssertTrue(parked.contains("budget is used up"))
        XCTAssertNotEqual(active, parked, "parked message differs (needs-you)")
    }

    // MARK: - 4.1 Audit per attempt, redacted

    func testAuditRecordCarriesRedactedSummaryNeverFullPrompt() {
        let log = InMemoryAuditLog()
        let sessionID = AgentSessionID()
        let prompt = "animate token=LEAK_ME_NOW_PLEASE the logo spinning"
        let disclosure = VideoUploadDisclosure.make(provider: .cloud, prompt: prompt, seedPresent: false)
        // Emit one record per attempt with the redacted summary (the sink's pattern, exercised directly).
        log.record(AuditRecord(sessionID: sessionID, tool: MediaTool.generateVideo, policy: .dangerous,
                               argumentsSummary: disclosure.auditSummary, outcome: .done,
                               wasBackground: true))
        let recent = log.recent(limit: 10)
        XCTAssertEqual(recent.count, 1, "exactly one record per attempt")
        let rec = recent[0]
        XCTAssertTrue(rec.wasBackground, "wasBackground set when parked")
        XCTAssertFalse(rec.argumentsSummary.contains("LEAK_ME_NOW_PLEASE"), "raw secret never in the summary")
        XCTAssertFalse(rec.argumentsSummary.contains(prompt), "full prompt never in the summary")
        XCTAssertTrue(rec.argumentsSummary.contains("cloud"))
        XCTAssertTrue(rec.argumentsSummary.contains("seed:no"))
    }

    // MARK: - 5.1 Stub progress → finished video asset

    func testCloudStubStreamsThenFinishesVideoAsset() async throws {
        let asset = videoAsset()
        let runtime = StubCloudVideoRuntime.make(
            script: .successWithPreviews(count: 3, total: 3, preview: png(), asset: asset))
        XCTAssertEqual(runtime.capabilities, [.video])
        var steps = 0
        var finished: MediaAsset?
        for try await p in runtime.generate(MediaRequest(prompt: "a sunrise", kind: .video)) {
            switch p {
            case .step: steps += 1
            case let .finished(a): finished = a
            }
        }
        XCTAssertEqual(steps, 3)
        XCTAssertEqual(finished?.kind, .video)
        XCTAssertNotNil(finished?.durationMs, "a finished video asset carries durationMs")
        XCTAssertEqual(finished?.durationMs, 4000)
    }

    // MARK: - 5.2 img2video seed threads through + sets disclosure

    func testSeedThreadsThroughToRequestAndDisclosure() async throws {
        let asset = videoAsset()
        let runtime = StubCloudVideoRuntime.make(script: .success(asset))
        let req = MediaRequest(prompt: "animate this", seed: png(), kind: .video,
                               parameters: MediaParameters(durationMs: 2000))
        for try await _ in runtime.generate(req) {}
        XCTAssertEqual(runtime.receivedRequests.count, 1)
        XCTAssertNotNil(runtime.receivedRequests.first?.seed, "the seed reached the backend as the first frame")
        // A seed-present run sets the disclosure flag (cloud → bytes leave too).
        let d = runtime.disclosure(for: req)
        XCTAssertTrue(d.seedPresent)
        XCTAssertTrue(d.bytesLeaveDevice)
    }

    func testLocalStubSeedSetsDisclosureButNoUpload() async throws {
        let runtime = StubLocalVideoRuntime.make(script: .success(videoAsset()))
        let req = MediaRequest(prompt: "animate this", seed: png(), kind: .video)
        for try await _ in runtime.generate(req) {}
        let d = runtime.disclosure(for: req)
        XCTAssertTrue(d.seedPresent)
        XCTAssertFalse(d.bytesLeaveDevice, "local never uploads even with a seed")
    }

    // MARK: - 6.1 Parking — slow job parks, completion glows; over-budget escalates

    func testVideoParkingFeedsSchedulerAndGlowsOnFinish() {
        let id = AgentSessionID()
        let scheduler = SerialParkScheduler(sessions: [ParkedSession(id: id, title: "v", state: .parked)])
        let feed = MediaParkFeed(scheduler: scheduler)
        feed.reportPainting(id, tool: MediaTool.generateVideo)
        feed.reportFinished(id, tool: MediaTool.generateVideo, asset: videoAsset())
        let after = scheduler.snapshot().first { $0.id == id }
        XCTAssertEqual(after?.state, .idle,
                       "completion idles with the unseen result — never a terminal state that removes it")
        XCTAssertGreaterThanOrEqual(after?.badgeCount ?? 0, 1)
    }

    func testParkedOverBudgetEscalatesNeedsYou() {
        let id = AgentSessionID()
        let scheduler = SerialParkScheduler(sessions: [ParkedSession(id: id, title: "v", state: .parked)])
        let feed = MediaParkFeed(scheduler: scheduler)
        feed.reportNeedsYou(id, reason: VideoTierResolver.overBudgetReason(parked: true))
        XCTAssertEqual(scheduler.snapshot().first { $0.id == id }?.state, .needsYou)
    }

    // MARK: - 6.2 Finished clip → Files-band asset + canvas player (CONSUMED seam)

    func testFinishedVideoLandsAsFilesBandEntryAndCanvasPlayer() throws {
        // The finished clip is durable in the gallery (output #1) as an .mp4 .fileEntry, and the canvas
        // state model (output #2) advances to `.finished` with a playable video asset — both CONSUMED from
        // the `ai-media-runtime` seam, unchanged by this slice.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("VideoGalleryTests-\(UUID().uuidString)", isDirectory: true)
        let gallery = MediaGallery(root: root)
        let asset = try gallery.write(Data([0, 1, 2]), kind: .video, width: 1024, height: 576, durationMs: 4000)
        XCTAssertEqual(asset.kind, .video)
        XCTAssertEqual(asset.url.pathExtension, "mp4")
        let entry = asset.fileEntry()
        XCTAssertEqual(entry.kind, .video, "the clip lists as a video Files-band entry")
        XCTAssertFalse(entry.isDirectory)

        // The canvas advances to a finished player on the .finished progress.
        var state = MediaJobState.idle
        state.advance(.step(index: 0, total: 1, preview: nil))
        state.advance(.finished(asset))
        XCTAssertTrue(state.isTerminal)
        XCTAssertEqual(state.asset?.kind, .video)
        XCTAssertEqual(state.asset?.durationMs, 4000)
    }

    // MARK: - 8.1 / 8.2 Error taxonomy + translator

    func testVideoErrorsMapToMediaTaxonomyAndTranslateClean() {
        let cases: [MediaError] = [.cloudBudgetExhausted, .videoProviderDisabled, .cloudUnavailable,
                                   .generationFailed(headline: "The upload failed.")]
        for c in cases {
            let presented = AIError.message(for: c)
            XCTAssertFalse(presented.headline.isEmpty)
            XCTAssertEqual(presented.headline, c.errorDescription)
        }
    }

    func testGenerationFailedHeadlineNeverCarriesRawText() {
        // A boundary maps an NSURLError into a clean headline; raw text never reaches the headline.
        let raw = "NSURLErrorDomain Code=-1009 \"The Internet connection appears to be offline.\""
        let mapped = MediaError.generationFailed(headline: "The video service isn't reachable right now.")
        let presented = AIError.message(for: mapped)
        XCTAssertFalse(presented.headline.contains("NSURLErrorDomain"))
        XCTAssertFalse(presented.headline.contains(raw))
        XCTAssertEqual(presented.headline, "The video service isn't reachable right now.")
    }

    func testFailedMidFlightStreamThrowsNotFinished() async {
        let runtime = StubCloudVideoRuntime.make(script: .failMidFlight(steps: 2, headline: "The render failed."))
        var thrown: Error?
        var finished = false
        do {
            for try await p in runtime.generate(MediaRequest(prompt: "x", kind: .video)) {
                if case .finished = p { finished = true }
            }
        } catch { thrown = error }
        XCTAssertFalse(finished, "a failed render never yields a finished asset (failed, not a false Done)")
        XCTAssertNotNil(thrown)
        if case MediaError.generationFailed = (thrown as? MediaError) ?? .cloudUnavailable {} else {
            XCTFail("a failure maps into the MediaError taxonomy")
        }
    }

    // MARK: - 9.1 Swap-in contract

    func testSecondBackendJoinsSameSeamUnchanged() async throws {
        // Both backends are interchangeable `MediaRuntime` conformers selected by `videoProvider`. Feature
        // code drives them identically — the ONLY observable difference is the disclosure flag.
        func drive(_ runtime: MediaRuntime) async throws -> MediaAsset? {
            var out: MediaAsset?
            for try await p in runtime.generate(MediaRequest(prompt: "same", kind: .video)) {
                if case let .finished(a) = p { out = a }
            }
            return out
        }
        let cloud: MediaRuntime = StubCloudVideoRuntime.make(script: .success(videoAsset()))
        let local: MediaRuntime = StubLocalVideoRuntime.make(script: .success(videoAsset()))
        // Same seam, same capability, same finished shape — the sink/canvas/Files path is identical.
        XCTAssertEqual(cloud.capabilities, local.capabilities)
        let a = try await drive(cloud)
        let b = try await drive(local)
        XCTAssertEqual(a?.kind, .video)
        XCTAssertEqual(b?.kind, .video)
    }

    // MARK: - AppSettings persistence (1.3)

    @MainActor
    func testAppSettingsVideoKeysDefaultAndPersist() {
        let suite = "VideoAnimationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = AppSettings(defaults: defaults)
        XCTAssertEqual(settings.videoProvider, .cloud, "default provider is cloud")
        XCTAssertEqual(settings.mediaVideoBudgetPerDay, 3, "conservative default cap")
        settings.videoProvider = .localLTXV
        settings.mediaVideoBudgetPerDay = 7
        // A fresh instance over the same store reads back the persisted values.
        let reloaded = AppSettings(defaults: defaults)
        XCTAssertEqual(reloaded.videoProvider, .localLTXV)
        XCTAssertEqual(reloaded.mediaVideoBudgetPerDay, 7)
    }
}
