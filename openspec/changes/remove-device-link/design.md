# Design — remove-device-link

Removal, not redesign. The two decisions worth recording:

## D1 — Delete the provenance model instead of stranding it

`ClipboardOrigin` existed only so the band could badge entries that arrived over the link. With the link gone nothing can mint a `.peer` entry, so keeping the field would be dead schema that every future reader has to reason about. It is deleted from `ClipboardEntry` (property, `CodingKeys`, initializer, `isPeer`/`peerDeviceName`) rather than deprecated.

**Compatibility:** `Codable` ignores unknown JSON keys, so a persisted index whose entries carry `"origin"` (including `.peer` records received before the removal) decodes cleanly; those entries just render as ordinary local copies. This is codified in `clipboard-history`'s new "Legacy index compatibility" requirement — the replacement for the two deleted provenance requirements.

## D2 — `suppressSelfWrite` goes with its only caller

The monitor's one-shot change-count suppression existed solely so the receive path's auto-paste wouldn't be re-captured as a duplicate entry. No other writer uses it (the launcher's paste path *wants* its writes treated normally, and fires through the same pasteboard the user sees). Keeping an untriggerable seam plus its three tests would be exactly the kind of surface the cleanup is for — deleted, with `poll()` reverted to the plain change-count comparison.

## Explicitly untouched

- The clipboard store's `materializedEntry`/`recentWindow` full-byte materialization (the band's truncated-preview design needs it regardless of who consumes the bytes).
- The archive (`openspec/changes/archive/`) — all device-link change folders remain as design history.
- `v1` branch / `v1.0.0` tag — the preserved full-featured app.
