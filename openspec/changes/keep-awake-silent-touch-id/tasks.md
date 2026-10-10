# Tasks — keep-awake-silent-touch-id

- [x] 1 Probe on hardware: embedded Touch ID reads silently only when this app is active + window key
- [x] 2 `SilentOwnerListener`: hidden key window, embedded evaluation, focus take/hand-back, held-key re-post, icon
- [x] 3 `CurtainEventTap`: trusted-event hook, re-post marker pass, password-prompt-only pass-through
- [x] 4 Controller: listener lifecycle; person input attends silently; unrecognized finger → password prompt (Curtain) / lock (Lock); Lock-mode 20 s silent deadline
- [x] 5 `GuardAuthenticator`: `allowPassword` → `.deviceOwnerAuthentication` with "Use Password…"
- [x] 6 Tests: 9 new controller tests; full suite green (0 unexpected)
- [ ] 7 Owner: touches ignored with no prompt; finger ends the curtain; wrong finger → prompt with password; agent keeps working
