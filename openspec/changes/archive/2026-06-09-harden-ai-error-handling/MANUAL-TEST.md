# Manual test checklist — harden-ai-error-handling

These verify the parts that can't run headless (real network, real EventKit/permissions, real AppKit
modality, the live Settings window). Run in the **stable-signed** build, not an agent build:

```bash
INSTALL=1 ./scripts/build-app.sh        # stable-signed, installed to /Applications
```

The invariant under test, end to end: **no raw error dump in any user-facing string, no frozen Settings
window, no stuck state, and no false "Done."**

## 1. Offline provision → clean status row + interactive Settings + Retry

1. Turn **Wi‑Fi off** (or enable Airplane mode).
2. Open **Settings ▸ AI commands**, enable **AI commands**, click **Download**.
3. Expect within a few seconds:
   - [ ] The model status row reads a **short connectivity message** ("No internet connection…") —
         **never** an `Error Domain=NSURLErrorDomain Code=-1009 UserInfo={…}` dump.
   - [ ] **No app‑modal alert appears.** The Settings window stays **scrollable and clickable**
         throughout (try scrolling the Form and clicking other controls while the row shows Failed).
   - [ ] A **Retry download** button is present on the failed row.
   - [ ] A collapsed **Show details** disclosure exists; expanding it reveals the raw text in a
         bounded, scrollable area with a **Copy details** button that puts the raw text on the clipboard.
4. Turn Wi‑Fi back **on**, click **Retry download** → the download proceeds (state leaves Failed).

## 2. Airplane‑mode mid‑download → state resolves (never stuck "Downloading…")

1. Start a fresh download (delete the cached model first if needed).
2. Partway through, toggle **Airplane mode on** to drop the connection.
3. Expect:
   - [ ] After the downloader exhausts its retries, the row leaves **Downloading…** and becomes
         **Failed** with a clean message — it does **not** hang at a frozen progress bar forever.
   - [ ] Re‑enabling the network + **Retry** resumes (byte‑resume picks up where it left off).

## 3. Cancellation is not a failure

1. Start a download, then turn the **AI commands opt‑in off** (or otherwise cancel) mid‑download.
2. Expect:
   - [ ] The row returns to **Not downloaded** (its resting state) — **not** Failed, and **no** error
         message or alert.

## 4. Calendar permission denied → message names the permission

1. Ensure Calendar access is **denied** for the app (System Settings ▸ Privacy & Security ▸ Calendars).
2. Fire an **Add to Calendar** AI command on some meeting‑like text; confirm the action (swipe down).
3. Expect:
   - [ ] The canvas shows a clean **"Calendar access is required… System Settings ▸ Privacy &
         Security ▸ Calendars"** message — never the raw enum name `calendarPermissionDenied` or a raw
         EventKit error.

## 5. A task whose tool open fails → surfaced, not a false "Done"

1. Configure an **Open tool** command pointing at a **non‑existent app path** (e.g. `/Applications/Nope.app`),
   or a **Send to ▸ URL scheme** with a scheme no app handles.
2. Fire it and commit.
3. Expect:
   - [ ] The canvas surfaces **Failed** with a clean message ("Could not open …" / "Nothing could open
         the destination URL.") — **not** a green **Done**.

## 6. Screen‑Recording gap → names the permission (when a vision command exists)

1. With Screen Recording **denied**, fire a **screen‑region** command.
2. Expect:
   - [ ] The canvas surfaces **Failed** naming **Screen Recording** and pointing at System Settings —
         **not** the generic **No input** state. (Vision is deferred in v1; verify if a vision command
         is wired.)

## 7. Long‑message layout safety

1. (If reproducible) force an unusually long failure message/details.
2. Expect:
   - [ ] The status row headline is **capped/truncated** (middle‑truncation), the details disclosure
         **scrolls** within its bounded area, and the Settings window **never overflows or freezes**
         (it is resizable; content degrades to scrolling).

## 8. Same message on every surface

- [ ] For a given underlying error (e.g. offline), the Settings status row and the overlay canvas show
      the **same** concise headline.
