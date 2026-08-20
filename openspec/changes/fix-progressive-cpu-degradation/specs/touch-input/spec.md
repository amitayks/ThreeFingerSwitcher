## ADDED Requirements

### Requirement: Single multitouch device across sleep/wake

The app SHALL own the multitouch listener's sleep/wake policy exclusively: at most ONE registered, running multitouch device SHALL exist at any time, across any number of sleep/wake cycles. The vendored package's own sleep/wake reactions SHALL be neutralized at startup (they double-start devices, orphaning one running, callback-registered device per wake — each orphan re-processes every subsequent touch frame). Neutralization SHALL degrade to a no-op (never a crash) if the package's internals change.

#### Scenario: Sleep/wake cycles do not multiply touch processing
- **WHEN** the machine sleeps and wakes N times with the switcher enabled
- **THEN** each subsequent touch frame is processed exactly once (not N+1 times), and the app's idle CPU does not grow with wake count

#### Scenario: Wake restart is the coordinator's alone
- **WHEN** the system posts its wake notifications
- **THEN** only the app's own restart path re-attaches the listener; the package's internal wake handler does not start an additional device

### Requirement: Consuming event taps self-heal

Each consuming `CGEventTap` the app installs (scroll consume, ⌘-Tab) SHALL be re-enabled within a bounded interval after the system disables it (`tapDisabledByTimeout` / `tapDisabledByUserInput`), independently of event delivery — the in-band re-enable alone drops the first post-stall event, which presents as a gesture that "needs to wake up". Tap teardown SHALL destroy the underlying mach port deterministically.

#### Scenario: A system-disabled tap recovers without user input
- **WHEN** the system disables a tap because the main thread stalled past the tap timeout
- **THEN** the tap is re-enabled within the watchdog interval (≤ ~2 s) even if no further event of its kind arrives in between
