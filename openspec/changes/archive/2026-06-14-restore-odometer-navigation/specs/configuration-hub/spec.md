## REMOVED Requirements

### Requirement: Positional navigation tuning with a live trackpad preview
**Reason**: The positional navigation model is removed, so the Hub Launcher page no longer exposes positional tunables (padding box, edge margin, footprint factor, ease curve) or the live trackpad preview that visualized the deadzone, outer rings, and footprint-scaled fingertips.
**Migration**: The Hub Launcher page surfaces the restored odometer tunables instead — the item-step / context-step travel distances and the edge-triggered auto-repeat parameters — covered by the generic *Feature pages preserve all tunables and persistence* requirement. The `Hub/PositionalTrackpadPreview.swift` view and its page wiring are deleted.

### Requirement: Axis-lock controls and committed-axis wedge in the trackpad preview
**Reason**: The directional axis-lock is removed, so the Hub Launcher page no longer exposes axis-lock controls (commit wedge, crossing wedge, re-commit hysteresis) and the trackpad preview no longer draws the aim-wedge cones or the ambiguous-diagonal gaps.
**Migration**: None. With the odometer there is no committed axis to visualize; the aim-wedge drawing and its controls are removed from the Hub Launcher page.
