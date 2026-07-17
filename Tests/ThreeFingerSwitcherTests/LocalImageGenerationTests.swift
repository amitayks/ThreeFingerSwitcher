import XCTest
@testable import ThreeFingerSwitcherCore

/// `ai-local-image-generation` — the Core (MLX-free) substrate of the local image backend: the image
/// `ModelDescriptor` variant table + `imageModelID` selection (§1), the pure `ImageResidencyClass`
/// classifier (§2), `MediaRequest` validation + the seed-capability gate (§3.1), the `StubImageRuntime`
/// (§3.2–3.3), and the cost-disclosure + busy-painting state values (§5.1–5.3 pure parts). The
/// `MFluxImageRuntime` MLX conformer (§4) is native-linked — `xcodebuild` compile-verify only.
final class LocalImageGenerationTests: XCTestCase {

    // MARK: - 1.1 Descriptor variant table (bytes / role / lane / provider / capabilities)

    func testQ4AndFP16DescriptorsHonestShape() {
        let q4 = ImageModelCatalog.q4Descriptor
        XCTAssertEqual(q4.role, .image)
        XCTAssertEqual(q4.lane, .gpu)
        XCTAssertEqual(q4.provider, .onDevice)
        XCTAssertEqual(q4.residencyBytes, 7 * 1024 * 1024 * 1024)
        // Klein 4B is t2i + conditioning-mode i2i, but NOT inpaint (no mask field on the seam) — see
        // ImageModelCatalog's type doc.
        XCTAssertEqual(ImageModelCatalog.tags(for: q4.id), [.image, .img2img])

        let fp16 = ImageModelCatalog.fp16Descriptor
        XCTAssertEqual(fp16.role, .image)
        XCTAssertEqual(fp16.lane, .gpu)
        XCTAssertEqual(fp16.provider, .onDevice)
        XCTAssertEqual(fp16.residencyBytes, 24 * 1024 * 1024 * 1024)
        XCTAssertEqual(ImageModelCatalog.tags(for: fp16.id), [.image, .img2img])
    }

    func testQ4ResidesBelowFP16() {
        XCTAssertLessThan(ImageModelCatalog.q4ResidencyBytes, ImageModelCatalog.fp16ResidencyBytes)
    }

    // MARK: - 1.2 imageModelID selection (default Q4; FP16 by id; unknown rejected)

    func testDefaultSelectionIsQ4() {
        XCTAssertEqual(ImageModelCatalog.selected(imageModelID: nil)?.id, ImageModelCatalog.q4ID)
        XCTAssertEqual(ImageModelCatalog.selected(imageModelID: "")?.id, ImageModelCatalog.q4ID)
        XCTAssertEqual(ImageModelCatalog.defaultID, ImageModelCatalog.q4ID)
    }

    func testFP16SelectedByID() {
        XCTAssertEqual(ImageModelCatalog.selected(imageModelID: ImageModelCatalog.fp16ID)?.id,
                       ImageModelCatalog.fp16ID)
    }

    func testUnknownIDRejectedNotDefaulted() {
        // An unknown id resolves to nil (rejected) — NOT silently coerced to the Q4 default.
        XCTAssertNil(ImageModelCatalog.selected(imageModelID: "no-such-image-model"))
        XCTAssertFalse(ImageModelCatalog.isKnown("no-such-image-model"))
        XCTAssertTrue(ImageModelCatalog.isKnown(ImageModelCatalog.q4ID))
        XCTAssertTrue(ImageModelCatalog.isKnown(ImageModelCatalog.fp16ID))
    }

    // MARK: - 1.3 Descriptors registered with the fleet ModelRegistry

    func testDescriptorsRegisteredInFleet() async throws {
        let registry = StubModelRegistry(members: ImageModelCatalog.descriptors)
        let ids = registry.descriptors().map(\.id)
        XCTAssertTrue(ids.contains(ImageModelCatalog.q4ID))
        XCTAssertTrue(ids.contains(ImageModelCatalog.fp16ID))
        // And the SAME ids appear in the production roster (this slice does not fork the roster ids).
        let rosterIDs = FleetRoster.standard.descriptors().map(\.id)
        XCTAssertTrue(rosterIDs.contains(ImageModelCatalog.q4ID))
        XCTAssertTrue(rosterIDs.contains(ImageModelCatalog.fp16ID))
    }

    // MARK: - 2.1/2.2 Residency classification (pure, injected resident set + ceiling)

    private func chat() -> ModelDescriptor { FleetRoster.standard.descriptor(id: "gemma-4-31b")! }
    private func ternary() -> ModelDescriptor { FleetRoster.standard.descriptor(id: "ternary-cpu-chat")! }

    func testQ4CoResidesWithChatAndTernary() {
        let classifier = ImageResidencyClassifier()
        let result = classifier.classify(image: ImageModelCatalog.q4Descriptor,
                                         resident: [chat(), ternary()],
                                         ceilingBytes: FleetRoster.unifiedBudget48GB)
        XCTAssertEqual(result, .coResident)   // ~17 + ~0.5 + ~7 + ~4 KV ≈ 28.5 GB < 48 GB
    }

    func testFP16EvictsChat() {
        let classifier = ImageResidencyClassifier()
        let result = classifier.classify(image: ImageModelCatalog.fp16Descriptor,
                                         resident: [chat(), ternary()],
                                         ceilingBytes: FleetRoster.unifiedBudget48GB)
        // FP16 (24 GB > 16 GB threshold) is a HEAVY GPU gen → GPU-lane exclusivity evicts chat even though
        // ~17 + ~0.5 + ~24 + ~4 KV ≈ 45.5 GB technically fits under 48 (it can't stream chat + paint at once).
        XCTAssertEqual(result, .evictsChat)
    }

    func testCeilingBoundaryIsDeterministic() {
        // Construct a tight ceiling so the boundary is exact: chat-only resident, image fits iff
        // chat + image + KV <= ceiling. Use a 0 KV reserve to make the boundary clean.
        let classifier = ImageResidencyClassifier(kvReserveBytes: 0)
        let c = chat()                         // 17 GB
        let img = ImageModelCatalog.q4Descriptor  // 7 GB
        let exact = c.residencyBytes + img.residencyBytes   // 24 GB
        // Exactly at the ceiling → fits → co-resident.
        XCTAssertEqual(classifier.classify(image: img, resident: [c], ceilingBytes: exact), .coResident)
        // One byte under → does not fit → evicts chat (chat is the resident GPU victim).
        XCTAssertEqual(classifier.classify(image: img, resident: [c], ceilingBytes: exact - 1), .evictsChat)
    }

    func testNoChatResidentNeverEvictsChat() {
        // With no chat resident, even a too-big image can't be classified as evicting chat.
        let classifier = ImageResidencyClassifier(kvReserveBytes: 0)
        let result = classifier.classify(image: ImageModelCatalog.fp16Descriptor,
                                         resident: [ternary()],
                                         ceilingBytes: 1)   // ceiling far below the image
        XCTAssertEqual(result, .coResident)   // nothing chat-like to evict
    }

    // MARK: - 2.3 The same class value drives disclosure AND the busy-painting state

    func testSameClassDrivesDisclosureAndBusyState() {
        let evicts = ImageResidencyClass.evictsChat
        let disclosure = ImageCostDisclosure.make(descriptor: ImageModelCatalog.fp16Descriptor,
                                                  classification: evicts)
        let busy = ImageBusyPaintingState(evicts)
        XCTAssertTrue(disclosure.evictsChat)
        XCTAssertEqual(busy, .busyPainting)
        XCTAssertEqual(busy.residencyNote, .busyPainting)

        let coResident = ImageResidencyClass.coResident
        let d2 = ImageCostDisclosure.make(descriptor: ImageModelCatalog.q4Descriptor, classification: coResident)
        XCTAssertFalse(d2.evictsChat)
        XCTAssertEqual(ImageBusyPaintingState(coResident), .coResident)
        XCTAssertEqual(ImageBusyPaintingState(coResident).residencyNote, .coResident)
    }

    // MARK: - 3.1 Request validation + seed capability gate

    private func pngSeed() -> Data { Data(MediaSeedValidation.pngMagic + [0x00, 0x01]) }

    func testValidTextToImagePasses() {
        let req = MediaRequest(prompt: "a cat", kind: .image,
                               parameters: MediaParameters(size: .square1024, steps: 28))
        XCTAssertNil(ImageRequestValidator.validate(req, descriptor: ImageModelCatalog.q4Descriptor))
    }

    func testValidImg2ImgWithSeedCapableDescriptorPasses() {
        let req = MediaRequest(prompt: "repaint", seed: pngSeed(), kind: .image,
                               parameters: MediaParameters(size: MediaSize(width: 512, height: 512), steps: 20))
        XCTAssertNil(ImageRequestValidator.validate(req, descriptor: ImageModelCatalog.q4Descriptor))
    }

    func testSeedAgainstNonSeedCapableDescriptorIsError() {
        // A t2i-only descriptor (no img2img tag) — seed must be rejected, not silently dropped.
        let t2iOnly = ModelDescriptor(
            id: "image-t2i-only", displayName: "t2i only", sizeBytes: 1,
            integritySHA: "x", downloadURL: URL(string: "https://example.com")!,
            capabilities: [.text], quantization: .qat4bit,
            role: .image, lane: .gpu, provider: .onDevice, residencyBytes: 1)
        // It is NOT in the catalog's tags → not seed-capable.
        XCTAssertFalse(ImageModelCatalog.isSeedCapable(t2iOnly.id))
        let req = MediaRequest(prompt: "x", seed: pngSeed(), kind: .image)
        let err = ImageRequestValidator.validate(req, descriptor: t2iOnly)
        XCTAssertNotNil(err)
        if case .generationFailed = err {} else { XCTFail("expected a generationFailed mismatch error, got \(String(describing: err))") }
    }

    func testOutOfRangeParamsRejected() {
        let big = MediaRequest(prompt: "x", kind: .image,
                               parameters: MediaParameters(size: MediaSize(width: 9000, height: 512), steps: 28))
        XCTAssertNotNil(ImageRequestValidator.validate(big, descriptor: ImageModelCatalog.q4Descriptor))

        let tooManySteps = MediaRequest(prompt: "x", kind: .image,
                                        parameters: MediaParameters(size: .square1024, steps: 9999))
        XCTAssertNotNil(ImageRequestValidator.validate(tooManySteps, descriptor: ImageModelCatalog.q4Descriptor))

        var badGuidance = MediaParameters(size: .square1024, steps: 28)
        badGuidance.guidance = 999
        XCTAssertNotNil(ImageRequestValidator.validate(MediaRequest(prompt: "x", kind: .image, parameters: badGuidance),
                                                       descriptor: ImageModelCatalog.q4Descriptor))
    }

    func testNonImageKindRejected() {
        let vid = MediaRequest(prompt: "x", kind: .video)
        XCTAssertNotNil(ImageRequestValidator.validate(vid, descriptor: ImageModelCatalog.q4Descriptor))
    }

    func testUnknownImageModelIDValidationRejected() {
        let req = MediaRequest(prompt: "x", kind: .image)
        XCTAssertNotNil(ImageRequestValidator.validate(req, imageModelID: "no-such"))
        XCTAssertNil(ImageRequestValidator.validate(req, imageModelID: ImageModelCatalog.fp16ID))
        XCTAssertNil(ImageRequestValidator.validate(req, imageModelID: nil))   // default Q4
    }

    // MARK: - 3.2 The image stub: ordered steps → finished asset with a readable PNG; cancellation

    func testStubEmitsOrderedStepsThenFinishedReadablePNG() async throws {
        let runtime = StubImageRuntime()
        let req = MediaRequest(prompt: "a cat", kind: .image,
                               parameters: MediaParameters(size: MediaSize(width: 640, height: 480), steps: 4))
        var indices: [Int] = []
        var finished: MediaAsset?
        for try await progress in runtime.generate(req) {
            switch progress {
            case let .step(index, total, preview):
                indices.append(index)
                XCTAssertEqual(total, 4)
                XCTAssertNotNil(preview)
            case let .finished(asset):
                finished = asset
            }
        }
        XCTAssertEqual(indices, [0, 1, 2, 3])           // ordered, ascending
        let asset = try XCTUnwrap(finished)
        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.width, 640)                // dimensions match the request
        XCTAssertEqual(asset.height, 480)
        // The URL points at a real, readable PNG.
        let data = try Data(contentsOf: asset.url)
        XCTAssertTrue(MediaSeedValidation.isDecodablePNG(data))
        try? FileManager.default.removeItem(at: asset.url)
    }

    func testStubCancellationEmitsNoFinished() async throws {
        // A per-step delay makes the cancellation window deterministic (we cancel before the steps drain).
        let runtime = StubImageRuntime(maxSteps: 100, perStepDelayNanos: 2_000_000)   // ~2 ms/step
        let req = MediaRequest(prompt: "x", kind: .image,
                               parameters: MediaParameters(size: .square1024, steps: 100))
        let task = Task { () -> Bool in
            var sawFinished = false
            for try await progress in runtime.generate(req) {
                if case .finished = progress { sawFinished = true }
            }
            return sawFinished
        }
        // Give it a moment to start, then cancel.
        try await Task.sleep(nanoseconds: 5_000_000)
        task.cancel()
        let sawFinished = try await task.value
        XCTAssertFalse(sawFinished)   // cancellation → stream ends WITHOUT a .finished
    }

    func testStubSeedAgainstNonSeedDescriptorThrows() async {
        let t2iOnly = ModelDescriptor(
            id: "image-t2i-only", displayName: "t2i only", sizeBytes: 1,
            integritySHA: "x", downloadURL: URL(string: "https://example.com")!,
            capabilities: [.text], quantization: .qat4bit,
            role: .image, lane: .gpu, provider: .onDevice, residencyBytes: 1)
        let runtime = StubImageRuntime(descriptor: t2iOnly)
        let req = MediaRequest(prompt: "x", seed: pngSeed(), kind: .image)
        do {
            for try await _ in runtime.generate(req) {}
            XCTFail("expected the stub to throw a MediaError for a seed vs non-seed descriptor")
        } catch let e as MediaError {
            if case .generationFailed = e {} else { XCTFail("unexpected MediaError \(e)") }
        } catch {
            XCTFail("unexpected error \(error)")
        }
    }

    // MARK: - 3.3 End-to-end: route → progress → asset over the stub (incl. the seed/img2img branch)

    func testEndToEndImg2ImgBranchProducesImageAsset() async throws {
        let runtime = StubImageRuntime()    // Q4, seed-capable
        let req = MediaRequest(prompt: "repaint", seed: pngSeed(), kind: .image,
                               parameters: MediaParameters(size: MediaSize(width: 256, height: 256), steps: 3))
        var finished: MediaAsset?
        for try await progress in runtime.generate(req) {
            if case let .finished(asset) = progress { finished = asset }
        }
        let asset = try XCTUnwrap(finished)
        XCTAssertEqual(asset.kind, .image)
        XCTAssertEqual(asset.width, 256)
        XCTAssertEqual(asset.height, 256)
        XCTAssertEqual(runtime.receivedRequests.count, 1)
        XCTAssertNotNil(runtime.receivedRequests.first?.seed)   // the seed threaded through
        try? FileManager.default.removeItem(at: asset.url)
    }

    // MARK: - 5.1 Cost disclosure tracks the chosen quant

    func testDisclosureTracksChosenQuant() {
        let q4 = ImageCostDisclosure.make(descriptor: ImageModelCatalog.q4Descriptor, classification: .coResident)
        XCTAssertFalse(q4.evictsChat)
        XCTAssertTrue(q4.ram.contains("7"))
        XCTAssertTrue(q4.ram.lowercased().contains("co-resides"))
        XCTAssertFalse(q4.heat.isEmpty)
        XCTAssertFalse(q4.latency.isEmpty)

        let fp16 = ImageCostDisclosure.make(descriptor: ImageModelCatalog.fp16Descriptor, classification: .evictsChat)
        XCTAssertTrue(fp16.evictsChat)
        XCTAssertTrue(fp16.ram.contains("24"))
        XCTAssertTrue(fp16.ram.lowercased().contains("paus"))   // "PAUSES the chat model"
    }

    // MARK: - 5.3 Gating — the contributor offers the image tool only under the flags

    func testImageToolGatedBehindMasterAndMediaFlags() {
        // OFF: master off → no media tools, so no image capability offered.
        let off = MediaToolAvailability(isFullPotentialEnabled: { false }, isMediaGenEnabled: { true })
        XCTAssertFalse(off.mediaActive)

        // media flag off under master on → still off.
        let mediaOff = MediaToolAvailability(isFullPotentialEnabled: { true }, isMediaGenEnabled: { false })
        XCTAssertFalse(mediaOff.mediaActive)

        // both on → media active (the contributor will then offer generate_image if an image runtime
        // advertises .image — exercised in MediaRuntimeTests; here we assert the gate floor).
        let on = MediaToolAvailability(isFullPotentialEnabled: { true }, isMediaGenEnabled: { true })
        XCTAssertTrue(on.mediaActive)
    }

    func testDiffusionRoleRoutesToGPULane() {
        // The gen role→lane policy: mediaDiffusion → .gpu (consumed from ai-compute-tiers).
        XCTAssertEqual(DefaultLaneRouting().lane(for: .mediaDiffusion), .gpu)
    }
}
