## ADDED Requirements

### Requirement: Clipboard-image vision presets
The catalog SHALL include at least one **clipboard-image** vision preset whose input source is `clipboardImage` and whose output target is `previewOnly`, so a user can analyze an image already on the clipboard without capturing the screen. These presets SHALL belong to the **Vision** category alongside the screen-region presets, and each SHALL be a complete, fireable command (name, icon, the `clipboardImage` input, a prompt template, and `previewOnly` output) requiring no further editing.

#### Scenario: Catalog offers a clipboard-image vision preset
- **WHEN** the catalog is enumerated
- **THEN** it contains at least one Vision-category preset whose input source is `clipboardImage`

#### Scenario: Clipboard-image preset is complete and fireable
- **WHEN** a clipboard-image vision preset is inspected
- **THEN** it carries a name, icon, the `clipboardImage` input source, a prompt template, and `previewOnly` output sufficient to fire without further editing
