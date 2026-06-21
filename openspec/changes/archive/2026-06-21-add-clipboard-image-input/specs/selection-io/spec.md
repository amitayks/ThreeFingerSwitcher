## ADDED Requirements

### Requirement: Read the current clipboard image as vision input
The system SHALL read the current clipboard **image** — from the **live system pasteboard** (preferring `public.png`, falling back to `public.tiff`), normalized to **PNG** bytes — and supply it to the runtime as a vision command's image input. This SHALL be symmetric with the existing live clipboard-**text** read: it reads the live pasteboard, **not** the stored clipboard history, and SHALL reuse already-held access (reading the pasteboard requires no new permission). When the pasteboard holds no image, or its image data cannot be decoded/normalized to PNG, the read SHALL yield **no image** so the caller surfaces a "no input" state rather than invoking the model on empty input.

#### Scenario: Clipboard image is read as PNG for the vision model
- **WHEN** an image is on the clipboard and a `clipboardImage` command is fired
- **THEN** the image is read as PNG bytes and passed to the runtime as the command's image input

#### Scenario: TIFF-only clipboard image is normalized to PNG
- **WHEN** the pasteboard holds only a `public.tiff` image and a `clipboardImage` command is fired
- **THEN** the image is normalized to PNG bytes before being supplied to the runtime

#### Scenario: No clipboard image yields no input
- **WHEN** a `clipboardImage` command is fired and the clipboard holds no image (or undecodable image data)
- **THEN** no image is produced and the caller surfaces a "no input" state (the model is not invoked)

#### Scenario: No new permission for the clipboard-image read
- **WHEN** a `clipboardImage` command runs
- **THEN** no new permission is requested (reading the pasteboard uses already-held access)
