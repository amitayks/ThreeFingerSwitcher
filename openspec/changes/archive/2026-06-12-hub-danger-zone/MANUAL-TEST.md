# Manual test — hub-danger-zone

Run on a real machine with a user-installed build (`INSTALL=1 ./scripts/build-app.sh`). The
filesystem/TCC effects are inherently machine-level; verify each with the listed probe.

## Selective clear

- [ ] Hub ▸ General ▸ Danger zone: all four switches start OFF and **Clear selected…** is disabled.
- [ ] Select **Caches** only → Clear → confirm: `~/Library/Caches/com.threefingerswitcher.app` and
      `~/Library/HTTPStorages/com.threefingerswitcher.app` are gone; the app keeps running and shows
      a summary; preferences/bands/models untouched.
- [ ] Select **AI models** only (with a downloaded model) → Clear: the AI opt-in flips off, the
      model evicts, `~/Library/Application Support/ThreeFingerSwitcher/models` is gone; `clipboard/`
      and `projects/` siblings survive; Hub ▸ AI shows "not downloaded" with a working re-download.
- [ ] Select **App data & settings** only (with gestures relocated) → Clear: the confirmation states
      the restore-first rule; trackpad/Dock keys read their pre-app values afterwards
      (`defaults read com.apple.AppleMultitouchTrackpad`); `models/` SURVIVES; the app relaunches
      into the First Touch wizard (fresh state); bands/settings are factory.
- [ ] Select **Permissions** only → Clear: `tccutil` rows vanish from System Settings ▸ Privacy &
      Security (Accessibility / Screen Recording); the app relaunches; the completed-install safety
      net opens the Hub on Setup (or the wizard's permission acts on a fresh-state machine).
- [ ] All four selected → one confirmation lists everything; whole `ThreeFingerSwitcher` App
      Support root gone; relaunch into the wizard with fresh prompts end-to-end (true fresh-install
      experience).
- [ ] Cancel on the confirmation → nothing deleted, toggles unchanged.

## Restore native gestures

- [ ] With Space-rows + launcher enabled and applied: **Restore native gestures…** restores all
      trackpad keys (absent keys deleted, not written), `mru-spaces` restored, the three opt-ins
      flip off in the Hub, pending markers clear (Setup shows no amber), summary notes the re-login.
- [ ] With nothing relocated: the button reports "Nothing to restore" and changes nothing.
