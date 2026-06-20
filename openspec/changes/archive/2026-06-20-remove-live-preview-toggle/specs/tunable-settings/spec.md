## REMOVED Requirements

### Requirement: Live preview opt-in

**Reason:** Live preview is now **always on** — the `livePreviewEnabled` setting, its persistence, its reset-to-defaults handling, and the Hub toggle are removed. The capture-layer defenses (motion gate + K-tick settle + `.fit`) prevent the in-flight / "sideways" frame that the opt-in once guarded against, so the setting is no longer needed. Any previously-persisted `livePreviewEnabled` value is simply ignored (no migration), which also resolves machines left stuck-off by the earlier reverted "default-off" experiment.
