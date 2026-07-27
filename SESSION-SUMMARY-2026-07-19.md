# Working-Bolt — Session Summary (2026-07-19)

Rename, new features, demo mode, and first TestFlight ship. Purely technical notes.

---

## 1. Rename: Hacking-Bolt → Working-Bolt

- Display name (`INFOPLIST_KEY_CFBundleDisplayName`) → **Working-Bolt**.
- Updated user-facing strings: About title, calendar footer (`⚡ Working-Bolt`), `.ics` PRODID.
- **Bundle ID unchanged** (`com.nvdberg.hackingbolt`) — internal, never surfaced; changing it would fork the app identity.
- Launch-screen "proofreader" gag kept on purpose (see §2).

## 2. Launch-screen animation (LaunchScreen.swift)

- ECG-bolt draws in → wordmark rises → **red pen strikes through "Hacking"** (`strike`, ~1.7s) → **handwritten "Working" scrawls in above** (`workingReveal`, ~2.2s).
- Fixes after first render was invisible:
  - Font `"Bradley Hand"` didn't resolve on iOS (silent fallback) → switched to **`MarkerFelt-Wide`** (ships on iOS).
  - Amber text was lost over the amber bolt glow → moved into the dark gap (`offset y:-48`), added **amber glow + dark edge shadow**.
  - Fragile `.mask` left-to-right reveal rendered muddy → replaced with **spring-driven opacity + scale pop** (reliable).

## 3. Copy cleanup

- Removed "Send feedback" section from **AboutView**.
- Stripped **all user-facing "Lightning Bolt" mentions** → "your roster" / "your schedule" / "the scheduler":
  - About, sign-in button, Pool/Who's On/Calendar loaders, sign-out dialog, Stats footer, 3 witty lines.
  - (Only the login web page itself still shows the vendor — unavoidable, it's their site.)
  - Note: the 3 scrubbed witty lines are seeded into an editable pool; existing installs keep their saved copy until "Reset to defaults."

## 4. Export hub — custom date range (Export.swift)

- Period toggle now **This year / All time / Custom**.
- Custom reveals **From / To `DatePicker`s** (ISO in America/Regina); count, filtering, CSV/ICS/PDF exports and PDF headers all follow the chosen range via a shared `periodLabel`.

## 5. New admin card: "Unit mix by doctor" (Stats.swift)

Owner-only (emp 20147), hideable **together with "You vs group"** via `@AppStorage("hb_show_admin")` (eye.slash on either card, or Settings → Start Screen toggle). Minimizable.

- Matrix: **every doctor × 7 units** (SICU·MICU·CCU·PICU·RR·PRR·MSU), counts per unit + Σ total + "Group" totals row.
- **Frozen doctor-name column**; unit columns scroll horizontally (`mixNameW`/`mixColW`/`mixRowH`/`mixHeadH` constants).
- **Tap a unit heading** → sort rows most→least in that unit (`mixSort`). **Tap a doctor** → reorder columns by that doctor's most-worked units (`mixDocCols`). **Reset** clears both.
- Per-year chips (2026 YTD / 2025 / …) sharing the same year windowing as "You vs group" (current year through last completed month; else full year). Excludes LB "EMPTY" placeholder.
- Section wired into `StatSection` enum (`.unitMix`), reorderable/persisted order, owner+`showAdmin` gating.

## 6. Demo mode — "Explore with sample data" (DemoData.swift + AppModel + ContentView)

Lets a reviewer or curious person walk the whole app **with no login**; fully in-memory, no network.

- **DemoData.build(today:)** generates ~2.5 yrs (2024 → +60d) of deterministic data: every unit covered daily by rotating fake doctors; "Demo User" holds ~1 shift/5 days; ~6 upcoming open offers for the Pool.
- **AppModel.enterDemo()** fills `shiftLog/myShifts/groupLog/assignments/openShifts`, sets `demo=true`, `showLogin=false`, `loggedIn=false`, `rebuildWho()`.
- Guards so demo data is never clobbered: `refresh()` bails on `demo`; `detectLoginLoop()` returns on `demo`; `loadHistory`/`loadGroupHistory` already guard on `loggedIn` (false in demo). `signOut()` resets `demo=false`.
- Button lives on the sign-in overlay (ContentView).

## 7. iPhone-only fix (project.yml)

- Apple upload rejected build 1 with **error 90474** (universal app missing `UIInterfaceOrientationPortraitUpsideDown` for iPad multitasking).
- Fix: `TARGETED_DEVICE_FAMILY: "1"` (iPhone-only) — sidesteps the iPad rule entirely; iPhone apps still run on iPad.

## 8. Versioning

- `MARKETING_VERSION: 1.0`, `CURRENT_PROJECT_VERSION` bumped 1 → 2 → **3**. Live build = **1.0 (3)** (build 3 = iPhone-only + demo mode).

---

## 9. TestFlight ship (App Store Connect)

**App record:** ID **6792563972**, "Working-Bolt", team RF4R5X25Y2, Apple Distribution cert present, Free Apps Agreement active.

**Build pipeline (scripted, repeatable):**
```
# bump CURRENT_PROJECT_VERSION in project.yml, then:
xcodegen generate
xcodebuild -project HackingBolt.xcodeproj -scheme HackingBolt -configuration Release \
  -archivePath <arch> -destination 'generic/platform=iOS' -allowProvisioningUpdates archive
xcodebuild -exportArchive -archivePath <arch> -exportPath <out> \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates      # method: app-store-connect, automatic signing
xcrun altool --upload-app -f <ipa> -t ios --apiKey VHUC7XW3Y6 --apiIssuer b24cf15b-dcb0-41de-9d02-774b4886a091
```

**App Store Connect API key** (for headless upload + status checks): name "Working-Bolt Upload", role App Manager, Key ID **VHUC7XW3Y6**, Issuer **b24cf15b-dcb0-41de-9d02-774b4886a091**. `.p8` stored **local-only** at `~/.appstoreconnect/private_keys/AuthKey_VHUC7XW3Y6.p8` (moved out of Dropbox; perms 600).

**Groups:**
- **Internal — "My Devices":** Nicolaas added → build 1.0(3) installs on his phone, **no review**.
- **External — "Colleagues":** build 1.0(3) **submitted for Beta App Review**; **public link `https://testflight.apple.com/join/9ThGvNv3`** (tester cap 100). Link goes live only after approval.

**Test Information / review strategy:**
- Beta App Description, feedback email (`nicolaasvanderberg2@gmail.com`), reviewer contact (Nicolaas van der Berg / phone 13063514801) filled.
- **"Sign-in required" left UNCHECKED** (both Test Info and the submission) — reviewer can't get hospital credentials, so **demo mode covers them**. Review notes + "What to Test" both **lead with "tap Explore with sample data."**

**Testers (Working-Bolt):** Adele, Pieter, Hennie, Matt, Aivars.

## 10. Review-status monitor (tools/review_status.py)

- Python + **PyJWT / cryptography / certifi** (installed `--user`). Signs an ES256 JWT from the `.p8` and queries the ASC API (`/v1/builds?filter[app]=…&include=betaAppReviewSubmission`), prints latest build's `betaReviewState`, exit 0=APPROVED / 2=REJECTED / 1=pending.
- Hourly **cron `fd17d070`** runs it; on APPROVED/REJECTED it fires a **PushNotification** and self-deletes. Session-only (dies if the Claude session closes). Apple's own email is the reliable backstop.
- Current state (end of session): **WAITING_FOR_REVIEW**.

---

## Env / access facts
- Apple/dev login username: **nicolaasvanderberg@gmail.com** (NO "2"). Contact/feedback email: nicolaasvanderberg2@gmail.com.
- App is **not in git** — lives in Dropbox at `hacking-bolt-ios/`. XcodeGen (`project.yml` → `xcodegen generate`).
- Signed `.ipa`s archived at `LigthningBolt/dist/`.

## Open / next
- Await Beta App Review (~24h) → share public link with colleagues.
- Future: **Unlisted App Store** distribution (permanent, not searchable) — needs full review + privacy policy URL + app-privacy details + screenshots + EU DSA trader status + the unlisted request. Same app record.
- Herman (non-physician brother) → future/other apps only, via internal (Limited app access) or an external link; **never Working-Bolt**.
