# Tasks — notch-conversation-gestures

Ordering: extract the shared classifier first (with the canvas path re-wired through it and the existing tests proving fidelity), then the notch mode + wiring, then the purge plumbing, then tests. All Core; `swift test` end-to-end, `xcodebuild` compile-verify, live feel is user run-verify. Surgical edits — the fleet/media wave still holds uncommitted changes in shared files.

## 1. The shared flick classifier (Core — design D1)

- [x] 1.1 `Gesture/FlickExcursionClassifier.swift`: a pure value type holding the per-excursion state (start centroid, per-axis peak |velocity|, last-fast time, last-contact time, last signed dx/dy, sawFastFrame, started/resolved flags) with `mutating func track(centroid:velocity:time:)`, `mutating func begin(at:time:)`, `mutating func reset()`, and `func classifyOnLift(travelFloor:velocityThreshold:liftWindow:axisLockRatio:) -> (dx: Int, dy: Int)?` (axis-locked, exactly one non-zero; nil = soft scrub / decelerated lift / under floor).
- [x] 1.2 Re-route `GestureRecognizer.trackCanvasResolution`/`resolveCanvasFlickOnLift` through the classifier (the `canvasRes*` state block collapses into one classifier instance; routing + one-shot + emission stay in the recognizer). Behavior must be bit-identical: `GestureRecognizerTests` + `CanvasResolveBindingTests` pass unchanged.
- [x] 1.3 Classifier unit tests: fast flick up/down/left/right classify with the right sign; sub-threshold peak → nil; fast frames but lift after the window (decelerated hold) → nil; travel under the floor → nil; axis lock picks the dominant axis by ratio.

## 2. The notch conversation mode (Core — design D2/D3)

- [x] 2.1 `GestureRecognizer.notchConversationActive` + a second classifier instance; routing per D2: canvas mode first, Files drill second, then — two-finger frames track (start on exactly 2), a started excursion's lift classifies + emits one-shot `notchConversationResolve(dx:dy:)`, a 2→3+ morph resets and FALLS THROUGH, 0/1/3/4-finger frames fall through untouched. Delegate protocol gains `notchConversationResolve(dx:dy:)`.
- [x] 2.2 `ParkController.onExpandedChanged: ((Bool) -> Void)?` fired on every `expandedID` nil↔value transition (newSession, expand, expand-another, collapse, discard-of-expanded, setEnabled(false)) — the single choke point.
- [x] 2.3 `AppCoordinator`: wire `onExpandedChanged` → `recognizer.notchConversationActive`; implement the delegate mapping — `dy > 0` → `parkController.collapse()`, `dx > 0` → `parkController.purge(expandedID)`, `dy < 0`/`dx < 0` → reserved no-ops.

## 3. The purge (Core — design D4)

- [x] 3.1 `AuditLog.purge(sessionID:)` on the protocol; `InMemoryAuditLog` filters the ring under its lock; `DiskAuditLog` filters the ring synchronously then rewrites the JSON-lines file on the existing writer queue through the existing atomic `persist` (failure → `lastPersistError`, ring stays purged); `FailableInMemoryAuditLog` mirrors the in-memory behavior.
- [x] 3.2 `ParkController.purge(_ id:)`: the authoritative `discard(_:)` plus `auditLog.purge(sessionID:)`; injected `auditLog` (new init parameter, defaulted to a no-op/shared instance so existing call sites and tests stay source-compatible). No os_log/log line referencing the session anywhere on this path.
- [x] 3.3 The plain delete paths (card context menu, expanded header trash) remain `discard(_:)` — ledger intact (spec scenario).

## 4. Tests (Core)

- [x] 4.1 Recognizer notch-mode tests: a scripted two-finger fast-up excursion emits `notchConversationResolve(dx:0, dy:+1)` exactly once; a soft scrub emits nothing; a three-finger frame stream with the flag on still latches the switcher (fall-through); with BOTH `launcherCanvasResolutionActive` and `notchConversationActive` on, the canvas path wins.
- [x] 4.2 Audit purge tests: ring purge removes only the target session's records; `DiskAuditLog` purge + a fresh instance over the same file shows none of the purged session and all of the others; a forced persist failure leaves the ring purged and surfaces `lastPersistError`.
- [x] 4.3 ParkController purge test: seed a session + audit records → `purge(id)` → store row + conversation gone, engine gone, audit records for the id gone, other sessions' records intact; plain `discard(id)` on a sibling keeps its audit records.
- [x] 4.4 `onExpandedChanged` transitions: newSession → true; collapse → false; expand-another stays true (no false blip — assert the callback sequence); discard-of-expanded → false; setEnabled(false) → false.

## 5. Verify

- [x] 5.1 `swift build` + full `swift test` green (classifier, recognizer canvas fidelity + notch mode, audit purge, controller purge/wiring); `xcodebuild` compile-verify the app target. *(swift test: 1481 tests, 0 failures; xcodebuild → BUILD SUCCEEDED.)*
- [x] 5.2 `openspec validate --strict` passes; deltas match implementation. *(valid.)*
- [ ] 5.3 **User run-verify** in a stable-signed build: with a conversation expanded — a soft two-finger scroll reads the thread (nothing else happens); a fast flick up tucks the panel into the dock (card + badge behavior intact, in-flight turn survives); a fast flick right dismisses it and the session is gone everywhere (no card, no conversation after relaunch, no audit rows for it in the Hub ledger, other sessions' rows intact); fast down/left do nothing; the three-finger switcher and four-finger launcher work normally while a chat is open; the launcher AI canvas flick grammar feels unchanged (`flickVelocityThreshold`/`flickLiftWindow` tuning applies to both surfaces).
