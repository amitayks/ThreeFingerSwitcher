# Tasks — keep-awake-agent-curtain

## 1. Trust
- [x] 1.1 `InputOrigin` + `InputTrustPolicy` (hardware / self / trusted / untrusted, fail closed)
- [x] 1.2 `ResponsibleAppResolver` (responsibility API via dlsym, parent-chain + enclosing-bundle fallback, 30 s cache)
- [x] 1.3 `AppSettings.keepAwakeTrustedApps` (default Vex) + `keepAwakeHookCommand`; not reset by Reset to defaults (security choice)
- [x] 1.4 `InputActivityMonitor` filters by the trust policy instead of self-PID

## 2. Curtain
- [x] 2.1 `CurtainEventTap` (active session tap, all events, swallow untrusted, self re-enable, pass-through flag)
- [x] 2.2 `GuardAuthenticator` (Touch ID only, no fallback button, 20 s timeout; password only when allowed and no biometrics)
- [x] 2.3 `CurtainWatchdog` (marker + `--curtain-watchdog` second instance; `Bootstrap` entry)
- [x] 2.4 `GuardHook` + `GuardLog`

## 3. Controller
- [x] 3.1 `Config.curtain`, `guarded`; effects seam grows with inert defaults (legacy tests unchanged)
- [x] 3.2 ARM installs curtain + watchdog, else passive monitor (fail closed)
- [x] 3.3 Intrusion → one check; trackpad contact behind the curtain asks instead of stopping
- [x] 3.4 Outcomes: success restores without lock; lock-mode failure locks before curtain removal and restore; curtain-mode failure stays + cooldown
- [x] 3.5 Stop cancels an in-flight check; late answers ignored

## 4. Item + UI
- [x] 4.1 `.automation(…, curtain: Bool? = nil)` decode-safe; `AutomationSettings.curtain`; `KeepAwakeGuardMode`
- [x] 4.2 Inspector: Guard picker Off / Lock / Curtain with captions
- [x] 4.3 General page: "Keep Awake guard" section — trusted-apps editor (running apps + Choose app…) and the hook command

## 5. Verification
- [x] 5.1 `swift build`; `swift test` (857 tests, 0 unexpected; 22 new in `KeepAwakeCurtainTests`)
- [x] 5.2 Live check: the responsible-app resolver maps a Vex-spawned process to `ai.shift.vex.desktop`
- [ ] 5.3 Owner: `INSTALL=1 ./scripts/build-app.sh`, then a Curtain session — agent clicks pass, a hardware touch opens Touch ID, the finger ends it with no lock; Lock mode — failure locks
- [ ] 5.4 Owner: kill the app with the curtain up → the watchdog locks the Mac
