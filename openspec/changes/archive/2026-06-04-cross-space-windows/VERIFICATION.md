# Implementation Verification (vs AltTab live source)

A 4-agent workflow diffed the error-prone constants against AltTab's current GPL-3 source.

## Critical bugs found + fixed
- **CGSCopyWindowsWithOptionsAndTags options `2` → `7`** (Spaces.swift). `2` is only
  `screenSaverLevel1000`; `7 = screenSaverLevel1000 | invisible1 | invisible2` (AltTab
  `includeInvisible=true`). With `2`, minimized/hidden/off-Space windows were silently dropped.
- **"Main" display-identifier sentinel** (Spaces.swift). When the display id is the literal
  `"Main"`, `CGSManagedDisplayGetCurrentSpace` returns 0 and the dict fallback was unreachable,
  leaving `currentSpaceIDs` empty. Fixed: always read `Current Space`→`id64` from the dict;
  refine via the API only for real (non-"Main") UUIDs.
- Minor ABI fidelity: `owner` and tag pointers changed to `Int` to mirror AltTab's signature.

## Verified clean
- **raise-bytes**: `makeKeyWindow` byte protocol (0xf8 buffer, offsets 0x04/0x08/0x3a/0x3c/0x20,
  two `SLPSPostEventRecordTo`) and `_SLPSSetFrontProcessWithOptions(0x200)` match AltTab exactly.
- **remote-token**: 20-byte layout (pid / 0x636f636f / id), `0..<1000`, subrole filter correct
  (byte 4..8 relies on Data zero-fill — behaviorally identical).
