# app-branding Specification

## Purpose
TBD - created by archiving change publish-and-release. Update Purpose after archive.
## Requirements
### Requirement: App icon shipped in the bundle
The assembled `ThreeFingerSwitcher.app` SHALL contain an `AppIcon.icns` resource and reference it via `CFBundleIconFile` in `Info.plist`, so the app presents its brand icon in Finder, Spotlight, the System Settings login-items list, and the Accessibility/Privacy panes. The icon source SHALL be committed to the repository so the build does not depend on any external file.

#### Scenario: Bundle carries and references the icon
- **WHEN** the built `.app` bundle is inspected
- **THEN** `Contents/Resources/AppIcon.icns` is present
- **AND** `Info.plist` sets `CFBundleIconFile` to that icon

#### Scenario: Finder shows the brand icon
- **WHEN** the built app is viewed in Finder or Get Info
- **THEN** the project's brand icon is shown instead of a generic application placeholder

### Requirement: Brand mark asset for the menu bar
The repository SHALL carry the brand logo source and a generated **template-image** menu-bar mark (alpha-only, suitable for `isTemplate = true`) at the standard menu-bar scale factors (`@1x`, `@2x`, `@3x`), bundled into the app for the status item to load. Because the source logo is landscape, the menu-bar mark SHALL be fit onto a square canvas so it renders correctly at menu-bar size.

#### Scenario: Template mark is bundled at all scales
- **WHEN** the built app's resources are inspected
- **THEN** the menu-bar brand mark is present as a template image at `@1x`, `@2x`, and `@3x`

#### Scenario: Mark adapts to light and dark menu bars
- **WHEN** the status item displays the brand mark in both light and dark menu-bar appearances
- **THEN** the mark is legible in both because it is rendered as a template (alpha-only) image

### Requirement: Reproducible brand-asset generation
The menu-bar template mark SHALL be regenerable from the committed logo source by a repeatable script, so the assets are reproducible rather than hand-edited binaries of unknown origin.

#### Scenario: Regenerating assets is deterministic
- **WHEN** the asset-generation script is run against the committed logo source
- **THEN** it produces the menu-bar template mark set at the defined scales

