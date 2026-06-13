## Why

When the Mac receives a moved item from the iPhone over the link, it needs to become a first-class entry in the existing Clipboard band — reusing the store's de-dup, retention caps, band rendering, and lift-to-paste that are already built. The cleanest integration is a thin adapter that turns a wire `LinkItem` into a `ClipboardEntry` and calls the **single existing write seam** (`ClipboardStore.insert`), so a peer item flows through exactly the same path as a local copy. Two concerns are peer-specific and handled here: received **files** must be persisted somewhere real (the wire carries bytes, but a `.file` clipboard entry needs a URL on disk), and the user should see **where an item came from** ("from iPhone"). This change is the receive-side adapter only — it has no networking; the transport change calls into it.

## What Changes

- **`ClipboardEntry` gains an optional `origin` provenance field** (`ClipboardOrigin` = `.local` or `.peer(deviceName:)`). It is **additive and backward-compatible**: absent in old persisted indexes (decodes to `nil` = treated as local), defaulted to `nil` in the existing initializer, so no call site and no stored history breaks. Local captures continue to leave it unset; only peer items stamp `.peer`.
- **A new `LinkInboundAdapter`** (in `ThreeFingerSwitcherCore`, depending on `DeviceLinkProtocol`) that maps a `LinkItem` → `ClipboardEntry`, mirroring `ClipboardMonitor.makeEntry`'s per-kind representation building (text / richText / image / color / url / file), deriving the same `key` (via `ClipboardKey`) and a stable `fingerprint`, and stamping `origin = .peer(deviceName:)`.
- **Received files land in a dedicated `inbox/` directory** (sibling to the store's `blobs/`, under `…/clipboard/inbox`). For a `.file` `LinkItem` the adapter writes the transferred bytes to `inbox/received-<messageID>-<suggestedName>` and produces a `.file` `ClipboardEntry` whose `fileURL` representation points at that path — so lift-to-paste pastes a real file reference into Finder/Mail/etc. The inbox lives outside the `blobs/` deterministic-naming scheme, so `externalizedForStorage` never clobbers it; retention eviction applies to peer files the same as local ones.
- **The Clipboard band surfaces provenance.** `ClipboardBandView` shows a small "from \<device\>" chip on entries whose `origin` is `.peer`, so the user can tell a mirrored item apart from a local copy at a glance.
- **Insertion reuses everything.** The adapter's output goes through `ClipboardStore.insert`, so de-dup (identical content bumps recency), the count/byte/age caps the user configured, and the band build are all reused unchanged. An identical text copied locally and then received from the phone de-dups to one entry.

## Capabilities

### New Capabilities
- `device-link-inbound`: the receive-side adapter that converts a `LinkItem` into a `ClipboardEntry` (per-kind representations, key, fingerprint, peer `origin`), persists received file bytes to a dedicated inbox directory, and inserts through the existing store write seam so retention/de-dup/band/paste are reused. The item's device provenance is recorded and surfaced in the band. **No networking** — the transport change feeds this adapter.

### Modified Capabilities
- `clipboard-history`: `ClipboardEntry` gains an additive, backward-compatible `origin` provenance field (`.local` / `.peer(deviceName:)`); the Clipboard band renders a provenance chip for peer entries. Existing persisted indexes load unchanged (absent origin = local); local capture behavior is unchanged.

## Impact

- **New:** `Sources/ThreeFingerSwitcher/Clipboard/LinkInboundAdapter.swift` (+ a `ClipboardOrigin` type, placed alongside `ClipboardEntry`). `Tests/ThreeFingerSwitcherTests/LinkInboundAdapterTests.swift`.
- **Modified:** `ClipboardEntry.swift` (optional `origin` field + default in init), `ClipboardBandBuilder.swift`/`Overlay/ClipboardBandView.swift` (provenance chip), `Package.swift` (`ThreeFingerSwitcherCore` depends on `DeviceLinkProtocol`).
- **Permissions / distribution:** none. Pure logic + local file writes (the app is unsandboxed; no new entitlement). No native-gesture relocation.
- **Build:** stays in the MLX-free fast loop — `swift build` / `swift test` cover the adapter and the view compiles under `swift build`.
- **Privacy/speed/UX:** privacy — received files are written only under the app's Application Support inbox, subject to the same retention the user set; speed — none (reuses the store); UX — peer items appear in the band the user already knows, tagged with where they came from.
