# Proposal — Keep Awake: silent Touch ID behind the curtain

## Why

Owner test of `keep-awake-agent-curtain` (2026-10-10): in Curtain mode any touch on the trackpad or keyboard opened the Touch ID prompt. The prompt tells a stranger how to get in, and the owner wanted touches simply ignored.

Owner requirements:
1. Every trackpad and keyboard input is ignored, silently. Only the owner's finger on Touch ID ends the curtain, at once. No message that hints to an outsider. (The fingerprint icon may show — it confirms the sensor is listening.)
2. If Touch ID does not recognize the finger, the prompt opens, and it must offer the password, not only Touch ID.

## What Changes

- **Silent listener (`SilentOwnerListener`).** An `LAAuthenticationView` in an almost-transparent key window evaluates Touch ID with no system prompt. Hardware-verified: it reads a resting finger in 1–2 s, but only while this app is active and the window is key.
- **Focus policy.** The listener takes focus at arm, on every person input (and shows the fingerprint icon), and when the trusted agent has been idle 15 s. A trusted key event that arrives while this app is active is held, the agent's app is re-activated, and the key is re-posted after 0.15 s (marked, so the curtain passes it).
- **Curtain mode.** Person input → no prompt. Owner finger → session ends, no lock. Unrecognized finger (detected from coreauthd's `no-match` log line — the embedded evaluation retries silently) or Touch ID lockout → **blind password entry**: a focused secure field in the listener's key window; the owner types the login password + Return even on a black screen (OpenDirectory check). The curtain passes hardware keys only while this app is active. 30 s idle or 5 wrong passwords → back to silent listening. (Owner feedback: the system prompt needed a click on "Use Password…", impossible on a screen dimmed to black.)
- **Lock mode.** Person input → silent; no owner finger within 20 s → lock. Unrecognized finger → lock at once (the lock screen handles passwords).
- **No Touch ID** (clamshell, no sensor): the previous visible-prompt behaviour stays.

## Impact

- Affected spec: `automations` (MODIFIED curtain requirement).
- Affected code: new `SilentOwnerListener`; `CurtainEventTap` (trusted-event hook, prompt-only pass-through), `KeepAwakeController` (listener lifecycle, Lock-mode deadline), `GuardAuthenticator` (password option).
- Trade-off: while the curtain is up this app takes focus when the agent is idle; an agent's open menu can close when that happens.
