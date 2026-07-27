# Hacking-Bolt — native iOS app

Our own native version. On-device, private, no server. The user logs into Lightning Bolt's
own page inside the app (we never handle the password), we read `window.LbsAppData` like the
scraper does, and render it in SwiftUI.

## The Xcode project is generated (no wizard needed)
`HackingBolt.xcodeproj` is produced from `project.yml` by **XcodeGen** (`brew install xcodegen`, then
`xcodegen generate` in this folder). To open: `open HackingBolt.xcodeproj`. Regenerate any time you
add files with `xcodegen generate` (the project just points at the `HackingBolt/` source folder).

**Status:** `swiftc -typecheck` against the iOS 26.5 simulator SDK passes **clean** (0 errors/warnings).
To build & run we only need the **iOS Simulator runtime** installed (Xcode → Settings → Components).
Then: pick your Team under Signing (for a device), and ⌘R on the iPhone 16 simulator — or from the CLI:
`xcodebuild build -scheme HackingBolt -destination 'platform=iOS Simulator,name=iPhone 16'`.

## What's here so far (Phase 1 — a runnable MVP scaffold)
- `Models.swift` — units taxonomy (mirrors `run.mjs` UNITS), `MyShift`, `OpenShift`.
- `ConflictEngine.swift` — the exact conflict logic ported from `run.mjs` (interval / openInterval / flagFor):
  post-call = full rest day, overlap, pre-call; supports an **exact** offered window (split shifts).
- `DataLayer.swift` — `RawSlot`/`HarvestResult`, and `OpenShiftBuilder` (exact hours, split flag, accept link).
- `LBWebSource.swift` — one WKWebView: user logs in on LB's real page, then we read `window.LbsAppData` via JS.
- `HackingBoltApp.swift` — `@main` app + `AppModel` (login → harvest 20 weeks → build pool/roster).
- `ContentView.swift` — login gate → `TabView` (Pool / My Shifts).
- `PoolView.swift` — native pool list: unit chip, exact hours, conflict flag, tap-to-accept.
- `CalendarView.swift` — my roster grouped by month (full month-grid is a Phase-3 upgrade).

## First-build checklist (I can't compile until the simulator finishes — expect a fix pass)
- **Compile pass:** minor Swift fixes are likely on the very first build; run it and I'll clear errors.
- **Validate on a real login (device/simulator):**
  1. `LbsAppData.User.emp_id` path in `LBWebSource.extractJS` — confirm it returns YOUR emp_id (roster filter + name).
     If empty, print `Object.keys(window.LbsAppData.User)` and adjust.
  2. Keep the WKWebView **alive during harvest** — if data comes back empty after login, we may need to keep the
     web view mounted (hidden 1×1) instead of removing it when we switch to the tabs.
  3. 20 sequential week-loads is ~30–40s for the first refresh; we'll cache + trim once it works.
- **ATS/network:** all calls are HTTPS to `*.lightning-bolt.com` (fine); no Info.plist exceptions needed.

## Accept link (already solved)
`https://lblite.lightning-bolt.com/login/?origin=<login>&origin_hash=swop/<slot_id>/accept` — open in Safari
(or an in-app view). Read-only: it drops you on Lightning Bolt's own accept screen, which asks to confirm.

## Next
- Phase 2: finish `LBWebSource` (navigate weeks, parse full roster + all pending slots).
- Phase 3: native Pool + Calendar views.
- Phase 4: `UNUserNotificationCenter` local alerts on new pickable shifts (BGAppRefresh).
- Phase 5: app icon (reuse `stage2/site/icon-1024.png`), archive → **Unlisted App Store**.
