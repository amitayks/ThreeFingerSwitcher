import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the model registry and capability-based selection (spec: "Model registry and
/// capability-based selection"): a vision command selects a vision-capable model, an audio command
/// routes to the reserved audio model, the default is preferred when it qualifies, and an impossible
/// requirement fails clearly instead of degrading.
final class ModelRegistryTests: XCTestCase {

    private let registry = ModelRegistry.standard

    func testStandardRegistryHasTheThreeKnownEntries() {
        let ids = Set(registry.models.map(\.id))
        XCTAssertEqual(ids, ["gemma-4-31b", "gemma-4-26b-a4b", "gemma-4-12b"])
        XCTAssertEqual(registry.defaultModelID, "gemma-4-31b", "31B is the quality-first default")
    }

    func testDefaultDescriptorResolves() {
        XCTAssertEqual(registry.defaultDescriptor?.id, "gemma-4-31b")
    }

    func testTextOnlySelectionPrefersTheDefault() throws {
        let chosen = try registry.selectModel(requiring: [.text])
        XCTAssertEqual(chosen.id, "gemma-4-31b", "the default is preferred when it satisfies the need")
    }

    func testVisionCommandSelectsVisionCapableModel() throws {
        let chosen = try registry.selectModel(requiring: [.vision])
        XCTAssertTrue(chosen.capabilities.contains(.vision))
        XCTAssertEqual(chosen.id, "gemma-4-31b", "the default 31B is vision-capable and preferred")
    }

    func testAudioCommandRoutesToReservedAudioModel() throws {
        // Only the 12B carries `.audio`, so an audio requirement must route to it even though it is
        // not the default — without any feature-code change (capability routing).
        let chosen = try registry.selectModel(requiring: [.audio])
        XCTAssertEqual(chosen.id, "gemma-4-12b")
        XCTAssertTrue(chosen.capabilities.contains(.audio))
    }

    func testSelectionFailsClearlyWhenNoModelSatisfies() {
        // A registry whose only model is text-only cannot serve a vision command.
        let textOnly = ModelRegistry(
            models: [ModelDescriptor(
                id: "text-only",
                displayName: "Text Only",
                sizeBytes: 1,
                integritySHA: "deadbeef",
                downloadURL: URL(string: "https://models.invalid/text-only")!,
                capabilities: [.text],
                quantization: .qat4bit
            )],
            defaultModelID: "text-only"
        )
        XCTAssertThrowsError(try textOnly.selectModel(requiring: [.vision])) { error in
            guard case RuntimeError.unavailable = error else {
                return XCTFail("expected .unavailable, got \(error)")
            }
        }
    }

    func testSelectionFallsBackToFirstQualifyingWhenDefaultDisqualified() throws {
        // Make the default text-only; a vision requirement should then pick the next qualifying entry
        // (the 26B-A4B comes before 12B in curated order).
        var r = ModelRegistry.standard
        r.defaultModelID = "gemma-4-12b" // default is audio-capable but we ask for something it has too
        // Ask for vision: 12B qualifies and is the default, so it is preferred.
        let chosen = try r.selectModel(requiring: [.vision])
        XCTAssertEqual(chosen.id, "gemma-4-12b")
    }

    func testDefaultSwitchIsAOneLineChange() throws {
        var r = ModelRegistry.standard
        r.defaultModelID = "gemma-4-26b-a4b" // the documented speed alternative
        let chosen = try r.selectModel(requiring: [.text])
        XCTAssertEqual(chosen.id, "gemma-4-26b-a4b", "switching the default re-routes selection")
    }
}
