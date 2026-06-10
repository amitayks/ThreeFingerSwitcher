## ADDED Requirements

### Requirement: AI availability is resolved in the preview canvas, not by hiding items
AI-command items SHALL always appear and be fireable in the launcher regardless of whether AI is enabled or the model is downloaded. When an AI-command item is fired while AI is **disabled** or the selected model is **not yet available** (not downloaded or not ready), the overlay SHALL open the AI preview canvas in an **unavailable** state — a non-error presentation showing a clear message (a clean, bounded string — either an error headline routed through the single AI error→message translator, or a clear non-error guidance string; never raw error text), an **Enable** affordance that turns the AI opt-in on, a **Download** action that begins fetching the model, and a **model picker** to choose the desired model. This canvas SHALL be **dismissable with the normal swipe-to-resolve gesture** (a horizontal discard), and any download it starts SHALL continue **in the background** after dismissal. The unavailable state SHALL NOT be surfaced via an app-modal alert and SHALL NOT block; it is bounded and non-blocking per the AI error-handling convention. When AI is enabled and the model becomes ready, firing an AI-command item SHALL proceed to normal streaming.

#### Scenario: Firing an AI item with AI off opens the enable/download canvas
- **WHEN** an AI-command item is fired while the AI opt-in is off
- **THEN** the preview canvas opens in the unavailable state offering Enable, Download, and a model picker, and nothing is generated yet

#### Scenario: Firing with the model not downloaded offers download
- **WHEN** an AI-command item is fired while AI is enabled but the model is not downloaded
- **THEN** the canvas shows the unavailable state with a Download action and a model picker

#### Scenario: Canvas is dismissable and the download continues in the background
- **WHEN** the user starts the model download from the unavailable canvas and then dismisses the canvas with a horizontal discard swipe
- **THEN** the canvas closes and the download continues in the background

#### Scenario: Once available, firing streams normally
- **WHEN** AI is enabled and the selected model is ready and an AI-command item is fired
- **THEN** the command begins and its result streams into the preview canvas as usual (no unavailable state)
