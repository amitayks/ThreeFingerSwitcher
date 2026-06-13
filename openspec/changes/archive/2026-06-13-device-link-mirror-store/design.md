## Context

The iOS app shows a scrollable list of moved items and lets the user re-share a received one (so it must keep the bytes). This is pure Foundation, so it lives in a shared `DeviceLinkMirror` package consumed by the iOS Xcode app and tested on macOS. It mirrors `ClipboardStore` (index + blobs) but simpler.

## Goals / Non-Goals

**Goals:** a tested `MovedItem` + `MovedItemStore` (index + blobs, newest-first, count cap), shared and macOS-testable.

**Non-Goals:** any UI; de-dup/pins (not needed for a chronological move log); the iOS Network/transport (separate change); blob inline-threshold tuning (all representation bytes go to blobs for simplicity).

## Decisions

**D1 — All representation bytes go to blob files; the index holds only metadata + blob filenames.** Unlike `ClipboardStore`'s inline-vs-blob threshold, the mirror externalizes every representation to a blob (named by id + uti hash). Simpler, keeps the index tiny, and most moved items are images/files anyway. In-memory the store holds `StoredItem` metadata (not bytes), materializing to `MovedItem` only on `list()` — so it never holds all payloads in memory. *Alternative:* the threshold split — unnecessary complexity here.

**D2 — Newest-first by timestamp, replace-by-id, count cap.** A move log is chronological; an item re-inserted with the same id (e.g. a resend) replaces the prior record. The count cap evicts the oldest and deletes their blobs. No de-dup by content (two separate moves of the same text are two log entries). *Alternative:* content de-dup like the clipboard — wrong model for a "what moved when" log.

**D3 — Depends only on `DeviceLinkProtocol`.** Reuses `LinkItemKind`/`LinkItem`/`LinkUTI` for the mapping; no UIKit, no Network, so it tests on macOS.

## Risks / Trade-offs

- **A blob orphaned if a write is interrupted mid-insert.** → Best-effort: blobs are written before the index; a future sweep could prune orphans. For v1, eviction/remove/clear delete known blobs; acceptable.

## Migration Plan

Additive: a new package target + tests. Rollback = delete the target.
