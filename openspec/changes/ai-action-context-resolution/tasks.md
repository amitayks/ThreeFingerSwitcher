# Tasks — context-driven AI action resolution

## 1. Value model (`AI/AICommand.swift`)
- [x] 1.1 Add `Hashable` to `OutputTarget`, `TaskKind`, `Destination` (`InputSource` is already Hashable via its raw value)
- [x] 1.2 Replace `input: InputSource` → `inputs: Set<InputSource>` and `output: OutputTarget` → `outputs: Set<OutputTarget>`
- [x] 1.3 Designated init takes the sets; add a **legacy convenience init** `(input:output:)` that maps → sets (behavior-preserving table, design D5)
- [x] 1.4 Custom `Codable`: `init(from:)` decodes `inputs`/`outputs` if present, else legacy `input`/`output` → sets; `encode(to:)` writes the sets; preserve all other fields + `decodeIfPresent` optionals
- [x] 1.5 `defaultConfirmBeforeRun(for: Set)` + `isSideEffecting`/`sideEffect` key off "outputs contains a `runTask`/`sendTo`"
- [x] 1.6 `requiredCapabilities` = union over enabled inputs (vision if any image input, text otherwise; text if empty) — informational hint
- [x] 1.7 Pure resolution helper `inPlaceCommitPlan(resolvedWasSelection:outputs:) -> CommitPlan` used by the executor + tested directly
- [x] 1.8 `sideEffect: OutputTarget?` accessor + `needsInput` derived from the sets

## 2. Executor (`AI/AICommandExecutor.swift`)
- [x] 2.1 `run()` → **resolve**: `resolveAmbientInput` probes `selection` ▸ `clipboard` text ▸ `clipboardImage`; returns the text/image AND records the channel
- [x] 2.2 Request the model from the **resolved** channel's modality (image→vision else text), not the static union
- [x] 2.3 Empty inputs = standalone (no input required); non-empty but nothing live = `.noInput`
- [x] 2.4 `screenRegion` in inputs → keep the pre-supplied-capture path (region-first)
- [x] 2.5 Remember `resolvedWasSelection` from fire → commit
- [x] 2.6 `commit()` in-place branch uses `AICommand.inPlaceCommitPlan` (replace / paste / preview)
- [x] 2.7 Side-effecting branch reads the `sideEffect` accessor (`taskKind(for: command)`; unchanged accept-step/execute)

## 3. Catalog & seeding (`AI/AICommandCatalog.swift`, `AI/AIBand.swift`)
- [x] 3.1 `preset(…)` helper's legacy `input:`/`output:` args route through the convenience init — entries unchanged, no edit needed
- [x] 3.2 Seeded/curated bands compile and read the same (catalog tests green)

## 4. Skills serialization (`AI/Skills/SkillFile.swift`, `AI/Skills/SkillToolProvider.swift`)
- [x] 4.1 Serialize `inputs:`/`outputs:` (comma-joined raw values / encoded sinks)
- [x] 4.2 Parse new `inputs:`/`outputs:`; fall back to legacy `input:`/`output:` single lines
- [x] 4.3 `SkillToolProvider` reads `command.sideEffect` for its task kind + schema; round-trip tests green

## 5. Region routing (`Overlay/LauncherOverlayController.swift`, `App/AppCoordinator.swift`)
- [x] 5.1 `command.input == .screenRegion` → `command.inputs.contains(.screenRegion)` (region-first, exclusive)

## 6. Editor UI (`Hub/BandsCanvas.swift`)
- [x] 6.1 Input dropdown → multi-toggle over the ambient channels + `screenRegion` as an exclusive choice
- [x] 6.2 Output dropdown → a "Result" kind picker (in-place / task / send-to) + in-place capability toggles; task/`sendTo` sub-editor unchanged
- [x] 6.3 Crossing the in-place ⇄ side-effect boundary re-derives `confirmBeforeRun`
- [x] 6.4 Helper text explaining "the action reads the first available source; selection→replace, clipboard→paste"

## 7. Tests
- [x] 7.1 `AICommandTests`: set defaults, legacy-scalar migration (pure + decode), `requiredCapabilities` union, `inPlaceCommitPlan` truth table, `sideEffect` accessor
- [x] 7.2 `AICommandExecutorTests`: default selection→replace vs clipboard→paste, empty-selection→clipboard, clipboard-image→vision, disabled-channel skip, no-live-channel→noInput (existing + new)
- [x] 7.3 `AICommandCatalogTests` / `SkillsTests`: presets set-shaped; skill file round-trips new + legacy
- [x] 7.4 Other construction sites updated (blank-command creation uses the all-on defaults)

## 8. Verify
- [x] 8.1 `swift build` — clean
- [x] 8.2 `swift test` — 1482 tests, 0 failures
- [x] 8.3 `swift build --product ThreeFingerSwitcher` (the MLX-linked executable) — clean
- [ ] 8.4 Apply `ai-command-band` / `selection-io` deltas to the main specs at archive (`/opsx:archive` or `/opsx:sync`) after review — NOT done here to avoid double-applying the deltas
