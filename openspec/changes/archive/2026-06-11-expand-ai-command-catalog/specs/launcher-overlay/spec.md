## MODIFIED Requirements

### Requirement: AI command streaming preview canvas
When an AI command is fired, the overlay SHALL present a preview canvas (reusing the master-detail preview surface) into which the model's result is **streamed incrementally** as it is generated. The captured front app SHALL remain frontmost throughout (the overlay stays non-activating), and the canvas SHALL show a loading state while the model is loading or before the first tokens arrive. The canvas SHALL be the surface for **vision (screen-region) command results** as well — a vision command's text result streams into the same canvas exactly as a text command's does.

#### Scenario: Result streams into the canvas
- **WHEN** an AI command is generating
- **THEN** the preview canvas fills with the result incrementally rather than only at completion

#### Scenario: Loading is shown before tokens
- **WHEN** the model is loading or has not yet produced output
- **THEN** the canvas shows a loading state rather than appearing blank or frozen

#### Scenario: Front app stays focused
- **WHEN** the preview canvas is visible
- **THEN** the previously focused app remains key and the overlay never becomes the key window

#### Scenario: A vision command result streams into the same canvas
- **WHEN** a screen-region (vision) command is fired and the model produces a grounded answer
- **THEN** that answer streams into the same preview canvas as any text command's result

## ADDED Requirements

### Requirement: In-canvas runtime-parameter (language) selection re-runs the command
For an AI command that declares a runtime parameter (v1: a target language), the preview canvas SHALL present an **in-canvas control** (a language dropdown) reflecting the command's active value. Choosing a different value SHALL **re-run the command in place** — cancelling the in-flight generation (cancellation is not a failure) and starting a new generation with the re-resolved prompt (`{lang}` ⇒ the new value) streaming into the same canvas — **without reopening the launcher** or losing the captured front app. The newly chosen value SHALL be persisted (per command) so the next run defaults to it, and the control's initial selection SHALL reflect that persisted value. The dropdown SHALL offer a fixed list of languages (no free-form text entry, keyboardless).

#### Scenario: Picking a language re-translates in place
- **WHEN** a translate result is shown and the user picks a different language from the in-canvas dropdown
- **THEN** the current generation is cancelled and the command re-runs to the new language, streaming into the same canvas

#### Scenario: The dropdown opens on the remembered language
- **WHEN** the user previously translated to "Hebrew" with this command and fires it again
- **THEN** the canvas opens with the dropdown set to "Hebrew" and translates to Hebrew by default

#### Scenario: Re-run keeps the captured app and output target
- **WHEN** the command re-runs after a language change
- **THEN** the captured front app remains frontmost and a subsequent commit still routes to the command's output target

#### Scenario: A command with no runtime parameter shows no dropdown
- **WHEN** a command that declares no runtime parameter is fired
- **THEN** the canvas shows no language dropdown

### Requirement: Collapsible live Thinking section and scrollable, input-capturing canvas
When a **reasoning** command streams, the preview canvas SHALL present the model's **thinking** in a **collapsible** section that is **collapsed by default** — showing a live activity indicator (a pulse + elapsed time) so the user can see the model is actively working (not stuck or silently slow) without it sprawling across the screen — **expandable on tap** to watch the thinking stream live, and **scrollable** when long. The committed/inserted result SHALL remain the **response** only (thinking is never committed). The canvas's thinking and response panes SHALL be **scrollable**, and while the canvas is open it SHALL **capture 1–2-finger scroll** (routing it to the canvas content, not the front app) until the canvas is dismissed; the four-finger commit/discard swipe SHALL continue to resolve the canvas.

#### Scenario: Thinking shows collapsed by default, expandable
- **WHEN** a reasoning command is generating
- **THEN** the canvas shows a collapsed Thinking section with a live pulse + elapsed timer; tapping it expands a scrollable live view of the thinking, and tapping again collapses it

#### Scenario: Only the response is committed
- **WHEN** the user commits a reasoning command's result
- **THEN** only the response is inserted into the front app (or used by the task); the thinking is never committed

#### Scenario: Scroll routes to the open canvas
- **WHEN** the canvas is open and the user does a 1–2-finger scroll
- **THEN** the canvas content scrolls (through the thinking or the response) rather than the front app, until the canvas is dismissed; a four-finger swipe still commits/discards

### Requirement: Bidirectional (RTL/LTR) text rendering in the preview canvas
The preview canvas SHALL render text **bidirectionally**: each paragraph's **base direction SHALL be natural (first-strong)** — derived from its first strong directional character — so a right-to-left paragraph (e.g. Hebrew or Arabic) starts from the correct side and aligns correctly, while a left-to-right paragraph remains left-aligned. **Mixed** left-to-right and right-to-left runs within a paragraph SHALL resolve via the Unicode Bidi algorithm so combined text reads cleanly (e.g. a Latin word or URL inside a Hebrew sentence). This SHALL apply to the **streamed output**, the **input echo**, and the **task-review fields**. Because streaming may deliver the first strong character late, the base direction SHALL be **recomputed as content streams** rather than fixed at the first token.

#### Scenario: A right-to-left result starts from the correct side
- **WHEN** the streamed result is Hebrew text
- **THEN** it renders right-aligned with a right-to-left base direction and correct punctuation placement

#### Scenario: Mixed-direction text resolves cleanly
- **WHEN** a paragraph contains both Hebrew and an embedded Latin word or URL
- **THEN** the paragraph's base direction follows its first strong character and the embedded run is placed correctly by the Bidi algorithm

#### Scenario: Base direction updates as tokens stream
- **WHEN** the first strong directional character arrives after some neutral characters have already streamed
- **THEN** the canvas updates the paragraph's base direction to match rather than locking to the environment direction

#### Scenario: Left-to-right text is unaffected
- **WHEN** the streamed result is English text
- **THEN** it renders left-aligned with a left-to-right base direction as before
