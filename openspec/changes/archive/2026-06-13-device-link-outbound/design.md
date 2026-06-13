## Context

The inbound adapter (`LinkInboundAdapter`) turns a `LinkItem` into a `ClipboardEntry` and writes received files to an inbox. This change adds the inverse for the Mac→iPhone direction, plus a way to hand the item to the transport. The strongest test is the round-trip against the existing inbound adapter.

## Goals / Non-Goals

**Goals:** a pure, tested `ClipboardEntry → LinkItem` adapter (incl. reading file bytes for `.file`); a service `send` that broadcasts to connections; round-trip fidelity.

**Non-Goals:** the user trigger / target-device picker / menu / Hub action (Hub change); per-device routing (v1 broadcasts to whatever is connected — typically the single paired phone).

## Decisions

**D1 — `.file` reads bytes and sends them; other kinds send their inline representation bytes verbatim.** The clipboard stores a `.file` entry as a `file://` reference, but sending must transfer the *content*. So `.file` resolves the URL, reads the bytes, and carries them under a generic `public.data` UTI with `suggestedName` = filename — exactly what the inbound adapter expects (it writes those bytes to the inbox and re-references them). Non-file kinds already hold their content inline, so their bytes map straight across. *Alternative:* send the file URL string — rejected: the path is meaningless on the other device.

**D2 — Origin is the local identity, assigned by the caller.** The adapter takes the local `DeviceIdentity` so the receiver stamps the entry "from \<this Mac\>". The adapter does not invent identity (the service owns it).

**D3 — Materialized entries only.** The adapter reads `payload.inlineData`; callers pass entries from `ClipboardStore.recentWindow` (already materialized). Blob-only payloads are skipped; an entry left with no bytes errors rather than sending nothing.

**D4 — `DeviceLinkService.send` broadcasts on the queue.** v1 has effectively one paired peer, so broadcasting to all live connections is correct and simple; per-device targeting is deferred. The send is dispatched on the service's serial queue (where connections live).

## Risks / Trade-offs

- **Reading a huge file fully into memory to send.** → Same v1 limitation as inbound; the streamed-from-disk path is a shared later refinement. Documented.
- **Broadcast vs targeted send.** → Fine for one peer; the Hub change adds target selection when multiple devices exist.

## Migration Plan

Additive: one new adapter file + tests, plus a `send` method on the existing service. Rollback = delete the adapter + method.
