import XCTest
@testable import ThreeFingerSwitcherCore

/// Tests for the launcher's AI preview-canvas state machine (spec launcher-overlay MODIFIED:
/// "Armed AI command lift opens the preview canvas" + "Swipe-to-resolve (commit / discard)"). These
/// cover the genuinely-headless logic: the model's canvas state, and the controller's lift / commit /
/// discard transitions wired to the executor callbacks — WITHOUT real gestures (the gesture feel is in
/// the manual-test checklist). Every NON-AI lift-fire-and-dismiss path is asserted unchanged.
@MainActor
final class LauncherCanvasModeTests: XCTestCase {

    private func appItem(_ name: String) -> LaunchItem {
        LaunchItem(title: name, icon: .appDefault,
                   kind: .app(bundleURL: URL(fileURLWithPath: "/Applications/\(name).app"), strategy: nil))
    }

    private func aiItem(_ name: String) -> LaunchItem {
        let command = AICommand(name: name, icon: .sfSymbol("sparkles"), input: .selection,
                                promptTemplate: "{input}", output: .previewOnly)
        return LaunchItem(id: command.id, title: name, icon: command.icon, kind: .aiCommand(command))
    }

    // MARK: - Model canvas state

    func testModelEnterAndExitCanvas() {
        let model = LauncherModel()
        let cmd = AICommand(name: "Fix", icon: .emoji("✅"), input: .selection,
                            promptTemplate: "{input}", output: .previewOnly)
        XCTAssertFalse(model.canvasActive)
        model.enterCanvas(cmd)
        XCTAssertTrue(model.canvasActive)
        XCTAssertEqual(model.canvasCommand, cmd)
        model.exitCanvas()
        XCTAssertFalse(model.canvasActive)
        XCTAssertNil(model.canvasCommand)
    }

    func testCurrentBandIsAICommandAndSelectedAICommand() {
        let model = LauncherModel()
        let apps = [appItem("A0"), appItem("A1")]
        let aiBand = AICommandBandBuilder.build(from: [
            AICommand(name: "Fix", icon: .emoji("✅"), input: .selection, promptTemplate: "{input}", output: .previewOnly)
        ])
        model.setBands([apps, aiBand.items],
                       names: ["Dev", "AI"],
                       colors: [ItemColor(red: 0, green: 0, blue: 1), AICommandBandBuilder.color],
                       startBand: 0, column: 0, aiCommandBandIndex: 1)
        XCTAssertFalse(model.currentBandIsAICommand, "starts on the app band")
        // Rise to headers, switch to the AI band, drop into it.
        model.stepVertical(1)          // → headers
        model.stepHorizontal(1)        // → AI band
        model.stepVertical(-1)         // → into the AI grid
        XCTAssertTrue(model.currentBandIsAICommand, "now on the AI band")
        XCTAssertEqual(model.selectedAICommand?.name, "Fix", "the selected item exposes its AICommand")
    }

    // MARK: - Controller: armed AI lift opens the canvas (does NOT dismiss)

    func testArmedAILiftOpensCanvasAndDoesNotDismiss() {
        let controller = LauncherOverlayController()
        var fired: [LaunchItem] = []
        var committed = 0
        var discarded = 0
        controller.onFire = { item, _ in fired.append(item) }
        controller.onCommitCanvas = { committed += 1 }
        controller.onDiscardCanvas = { discarded += 1 }

        let ai = aiItem("Summarize")
        let band = ContextBand(id: AICommandBandBuilder.bandID, name: "AI",
                               color: AICommandBandBuilder.color, items: [ai])
        controller.show(bands: [band], startBand: 0, startColumn: 0, dwell: 0.01,
                        aiCommandBandIndex: 0)
        controller.model.setArmed()    // simulate the dwell having armed the AI item

        let result = controller.end()  // first lift
        XCTAssertTrue(result, "an armed AI lift reports a fire")
        XCTAssertEqual(fired.map(\.title), ["Summarize"], "the AI command is handed off via onFire")
        XCTAssertTrue(controller.canvasActive, "the canvas is open — the overlay did NOT dismiss")
        XCTAssertTrue(controller.isVisible, "the panel stays visible behind the canvas")
        XCTAssertEqual(committed, 0)
        XCTAssertEqual(discarded, 0)
        controller.cancel()            // teardown (also discards the open canvas)
    }

    // MARK: - Controller: a second lift is a NO-OP (commit is a fresh DOWN swipe, not a lift)

    func testSecondLiftIsNoOpWhileCanvasOpen() {
        // After the firing lift opens the canvas the fingers are already up, so a re-touch-and-lift
        // must NOT resolve the canvas — the canvas is now resolved by a fresh four-finger swipe
        // (`resolveCanvasCommit` / `discardCanvas`). A stray lift therefore leaves the canvas intact.
        let controller = LauncherOverlayController()
        var committed = 0
        var discarded = 0
        controller.onFire = { _, _ in }
        controller.onCommitCanvas = { committed += 1 }
        controller.onDiscardCanvas = { discarded += 1 }

        let ai = aiItem("Explain")
        let band = ContextBand(id: AICommandBandBuilder.bandID, name: "AI",
                               color: AICommandBandBuilder.color, items: [ai])
        controller.show(bands: [band], startBand: 0, startColumn: 0, dwell: 0.01, aiCommandBandIndex: 0)
        controller.model.setArmed()
        controller.end()                       // open the canvas
        XCTAssertTrue(controller.canvasActive)

        let liftResult = controller.end()      // a second lift is a no-op
        XCTAssertTrue(liftResult, "the lift still reports handled (the canvas owns the gesture)")
        XCTAssertEqual(committed, 0, "a lift never commits")
        XCTAssertEqual(discarded, 0, "a lift never discards — the canvas waits for a resolving swipe")
        XCTAssertTrue(controller.canvasActive, "the canvas stays open for a resolving swipe")
        XCTAssertTrue(controller.isVisible)
        controller.cancel()                    // teardown (this legitimately discards the open canvas)
    }

    // MARK: - Controller: a DOWN-swipe resolution commits and dismisses

    func testResolveCanvasCommitCommitsAndDismisses() {
        let controller = LauncherOverlayController()
        var committed = 0
        controller.onFire = { _, _ in }
        controller.onCommitCanvas = { committed += 1 }
        controller.onDiscardCanvas = { XCTFail("commit must not discard") }

        let ai = aiItem("Explain")
        let band = ContextBand(id: AICommandBandBuilder.bandID, name: "AI",
                               color: AICommandBandBuilder.color, items: [ai])
        controller.show(bands: [band], startBand: 0, startColumn: 0, dwell: 0.01, aiCommandBandIndex: 0)
        controller.model.setArmed()
        controller.end()                       // open the canvas
        XCTAssertTrue(controller.canvasActive)

        controller.resolveCanvasCommit()       // the DOWN-swipe resolution
        XCTAssertEqual(committed, 1, "a down-swipe commits exactly once")
        XCTAssertFalse(controller.canvasActive, "committing closes the canvas")
        XCTAssertFalse(controller.isVisible, "and dismisses the overlay")
    }

    // MARK: - Controller: resolveCanvasCommit is a no-op when there is no open canvas

    func testResolveCanvasCommitNoOpWhenCanvasClosed() {
        let controller = LauncherOverlayController()
        controller.onCommitCanvas = { XCTFail("nothing to commit when the canvas is closed") }
        controller.resolveCanvasCommit()       // canvas never opened → must be inert
        XCTAssertFalse(controller.canvasActive)
    }

    // MARK: - Controller: a deliberate horizontal excursion discards and dismisses (fallback path)

    func testHorizontalExcursionDiscardsAndDismisses() {
        // Exercises the controller-level fallback discard (`stepHorizontal` → `accumulateCanvasDiscard`).
        // In production the recognizer's canvas-resolution swipe drives discard via `discardCanvas`; this
        // path remains as a defensive secondary and is asserted directly here.
        let controller = LauncherOverlayController()
        var discarded = 0
        controller.clipboardPinSteps = 3   // the deliberate-excursion threshold reused for the discard
        controller.onFire = { _, _ in }
        controller.onCommitCanvas = { XCTFail("a discard excursion must not commit") }
        controller.onDiscardCanvas = { discarded += 1 }

        let ai = aiItem("Translate")
        let band = ContextBand(id: AICommandBandBuilder.bandID, name: "AI",
                               color: AICommandBandBuilder.color, items: [ai])
        controller.show(bands: [band], startBand: 0, startColumn: 0, dwell: 0.01, aiCommandBandIndex: 0)
        controller.model.setArmed()
        controller.end()                       // open the canvas

        // A small jitter under the threshold does NOT discard.
        controller.stepHorizontal(1)
        controller.stepHorizontal(-1)
        XCTAssertEqual(discarded, 0, "sub-threshold horizontal jitter never discards")
        XCTAssertTrue(controller.canvasActive)

        // A deliberate excursion past the threshold discards once.
        controller.stepHorizontal(1)
        controller.stepHorizontal(1)
        controller.stepHorizontal(1)
        XCTAssertEqual(discarded, 1, "one deliberate excursion discards exactly once")
        XCTAssertFalse(controller.canvasActive, "discarding closes the canvas")
        XCTAssertFalse(controller.isVisible, "and dismisses the overlay")
    }

    // MARK: - Controller: hard cancel while canvas open discards generation

    func testCancelWhileCanvasOpenDiscards() {
        let controller = LauncherOverlayController()
        var discarded = 0
        controller.onFire = { _, _ in }
        controller.onDiscardCanvas = { discarded += 1 }

        let ai = aiItem("Fix")
        let band = ContextBand(id: AICommandBandBuilder.bandID, name: "AI",
                               color: AICommandBandBuilder.color, items: [ai])
        controller.show(bands: [band], startBand: 0, startColumn: 0, dwell: 0.01, aiCommandBandIndex: 0)
        controller.model.setArmed()
        controller.end()                       // open the canvas

        controller.cancel()                    // gesture abandoned mid-canvas
        XCTAssertEqual(discarded, 1, "a hard cancel while the canvas is open discards generation")
        XCTAssertFalse(controller.canvasActive)
        XCTAssertFalse(controller.isVisible)
    }

    // MARK: - PRESERVED: a non-AI armed lift still fires AND dismisses (order-out-before-fire)

    func testNonAIArmedLiftFiresAndDismissesAsBefore() {
        let controller = LauncherOverlayController()
        var fired: [LaunchItem] = []
        controller.onFire = { item, _ in
            // The panel MUST already be ordered out before a non-AI fire (the regression guard).
            XCTAssertFalse(controller.isVisible, "non-AI items order the panel out BEFORE firing")
            fired.append(item)
        }
        controller.onCommitCanvas = { XCTFail("a non-AI item never enters the canvas") }

        let app = appItem("Safari")
        let band = ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1), items: [app])
        controller.show(bands: [band], startBand: 0, startColumn: 0, dwell: 0.01)
        controller.model.setArmed()

        let result = controller.end()
        XCTAssertTrue(result)
        XCTAssertEqual(fired.map(\.title), ["Safari"], "the app fires exactly as before")
        XCTAssertFalse(controller.canvasActive, "a non-AI item never opens the canvas")
        XCTAssertFalse(controller.isVisible, "and the overlay dismisses on the lift, unchanged")
    }

    // MARK: - PRESERVED: an unarmed lift still just dismisses

    func testUnarmedLiftDismissesWithoutFiring() {
        let controller = LauncherOverlayController()
        var fired = 0
        controller.onFire = { _, _ in fired += 1 }
        let app = appItem("Mail")
        let band = ContextBand(name: "Dev", color: ItemColor(red: 0, green: 0, blue: 1), items: [app])
        controller.show(bands: [band], startBand: 0, startColumn: 0, dwell: 0.5)
        // No setArmed() — the dwell hasn't armed.
        let result = controller.end()
        XCTAssertFalse(result, "an unarmed lift fires nothing")
        XCTAssertEqual(fired, 0)
        XCTAssertFalse(controller.isVisible, "and the overlay dismisses")
        XCTAssertFalse(controller.canvasActive)
    }
}
