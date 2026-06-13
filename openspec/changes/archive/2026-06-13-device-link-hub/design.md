## Context

The device-link pieces are built but inert. This change wires them into the Mac app exactly like the clipboard-history feature is wired: a default-off opt-in, a Combine toggle observer in `AppCoordinator`, and a Hub page. The pure/testable surface here is the `AppSettings` opt-in; the `AppCoordinator` lifecycle, the Hub page, and Info.plist are compile-verified integration (runtime on-device behavior is user-verified, like the rest of the app's OS-dependent code).

## Goals / Non-Goals

**Goals:** make the Mac device-link usable behind an opt-in; route received items into the existing clipboard store; a Devices Hub page; the Info.plist keys; an outbound trigger.

**Non-Goals:** the pinned-TLS wire integration (pairing follow-up); the on-device pairing UI flow beyond listing/forgetting; per-device send targeting (v1 broadcasts).

## Decisions

**D1 — `enableDeviceLink` mirrors `keepClipboardHistory` exactly.** Same four-touch pattern (declaration + load + `Defaults` + `Keys`), no `is…Effective` gate, immediate effect. The `AppCoordinator` observer mirrors `observeClipboardToggle` (use the *emitted* value, not a re-read, because `@Published` fires in `willSet`).

**D2 — Received items go into the existing `ClipboardStore`.** The service's `onItem` (delivered on main) runs `LinkInboundAdapter.entry(from:)` (inbox = the clipboard store's inbox dir) → `clipboardStore.insert`. This reuses retention, the band, and lift-to-paste, and makes received items appear tagged "from \<device\>". The Clipboard band only injects when `keepClipboardHistory` is on, so the page notes device-link pairs best with clipboard history on. *Alternative:* a separate received-items store — rejected (duplicates everything; the clipboard band is exactly the right surface).

**D3 — Local identity from the host name.** `DeviceIdentity(id: <stable id>, name: Host.current().localizedName ?? "Mac")`. A stable id is persisted (reuse a `UserDefaults` value) so the peer's pin stays valid across launches.

**D4 — Outbound v1 = "send latest clipboard item".** A Devices-page button maps the most recent `ClipboardStore` entry via `LinkOutboundAdapter` and `DeviceLinkService.send`. A richer "send this entry" affordance from the band is a later UX change.

**D5 — Honest security copy.** Because pinned TLS isn't wired yet, the page states the link is local-network only and not yet encrypted, and the opt-in stays default off. This avoids shipping a false sense of security.

## Risks / Trade-offs

- **Wiring is compile-verified, not runtime-verified.** → It mirrors the proven clipboard wiring closely; on-device behavior (Bonjour, the Local Network prompt, real transfer) is a user-verify task.
- **Unencrypted v1.** → Default off + explicit page copy + the pairing-TLS follow-up; documented.

## Migration Plan

Additive: a new opt-in (legacy settings load off), a new Hub page + destination, AppCoordinator wiring, two Info.plist keys. Rollback = remove the destination + opt-in + wiring.
