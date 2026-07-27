# Session Summary — 2026-07-18

## The goal
Make the **accept/deny shift button actually work for every open shift** — "one of the main
features of the app." Before today it only produced working one-tap accept links for near-term
ICU shifts (~6 of 14 posted offers); Rapid Response and far-future offers fell back to a plain
dashboard link. We set out to crack why, and fix it end-to-end (scraper + native app).

## What we cracked (the big one)
Open shifts in Lightning Bolt are **not** reliably in the SWAPORTUNITY feed and **not** limited to
a 2-month window as we'd feared. The authoritative source is a single endpoint — the one the
dashboard's **human-icon "posted shifts" widget** calls:

```
GET https://lbapi.lightning-bolt.com/schedule/range/
      ?start_date=YYYYMMDD&end_date=YYYYMMDD&listed=true&emp_id=<EMP>&only_pending=true
      (Authorization: Bearer <session token>)
```

It returns **every live open swaportunity — cross-department (Rapid Response included), across the
whole roster** — each item already carrying its `slot_id` (the id the accept deep-link needs).
One call per month covers everything.

### How we got there (the investigation, in order)
1. **The feed is a dead end.** `fd.lightning-bolt.com/employee_feed/580/20147` items are
   notifications only — a swaportunity post is `type:"preswap_create"` with `data:null` and only
   display strings. **No slot_id anywhere.** (And the feed lags — it lists offers already taken.)
2. **`viewerapi` has the ids but is scoped.** `lbapi.lightning-bolt.com/viewerapi` returns the
   group grid's slots with `is_pending:true` + `slot_id`, and they exist far into the future
   (confirmed a Jan 2027 pending slot). BUT its POST body is only `{"dt":"YYYYMMDD","tz":"UTC"}`
   — no department param — so it's fixed server-side to the user's saved viewer (**ICU,
   department_id 20002**). Rapid Response / PASQUA RR live in a different department → never loaded.
   That's why ICU offers matched but RR/PRR didn't (all 8 misses were RR/PRR).
3. **The human-icon widget was the key.** Nicolaas spotted it mid-cycle: clicking it fires
   `schedule/range?only_pending=true` — cross-department, whole roster, every id. That solved it.

## What we built / changed

### Scraper — `stage2/run.mjs` (GitHub Actions, runs every 10 min)
- Captures the session Bearer + emp_id, then builds the open pool directly from
  `schedule/range?only_pending` (14 monthly calls). Result: **`directIds = 9/9`** — every offer,
  all units, one-tap links. Faster than before (no per-week viewer loads).
- All the diagnostic scaffolding + the old feed/viewer-match code was removed → lean production code.
- Committed & pushed to `github.com/nvdberg/hacking-bolt` (public repo). Verified green.

### iOS app — `hacking-bolt-ios/` (native SwiftUI)
- `LBWebSource.swift`: a `documentStart` WKUserScript captures the SPA's Bearer into `window.__lbAuth`
  (never leaves the device); `fetchOpenOffers()` calls the same `only_pending` endpoint **in the
  logged-in web view**, so each user gets the complete cross-department pool with **their own**
  conflict flags. Falls back to the old on-device scan if the token isn't captured (can't break).
- `HackingBoltApp.swift`: pool now built from that complete list via `OpenShiftBuilder.build(pending:)`
  — no more stale feed.
- Dead feed code (`readFeed`, `feedJS`, `buildFromFeed`, `extractJS`) removed.
- **Confirmed on device:** Pool shows all 9 offers incl. Rapid Response + far-future (Jan 30), correct
  conflict flags. Screenshots match the scraper exactly.

### Who's On landscape fix
- Bug: unifying the grid with Crew made dense multi-doctor cells overflow into neighboring rows.
- Fix (`WhoView.swift`): cell names now share the row height equally and scale to fit + clip, so
  splits never spill. Reclaimed the empty strip below the grid via a per-view `bottomInset` (Who's On
  68, Crew stays 84 — untouched). Confirmed clean on device.
- Note: two names in a cell = **real split coverage** (two different doctors, usually day/night
  handover). The app collapses one doctor's own day+night segments but keeps distinct people — correct.

### Workflow — `.github/workflows/refresh.yml`
- Removed the broken GitHub Pages steps (they logged `deploy-pages error_count: 10` every run and
  weren't serving). Scrape + ntfy notifications + state/roster caching intact. (No hosted web page now
  — the app is the front-end. Pages is a settings toggle to re-enable if ever wanted.)

## Verification
- Scraper: `open=9 pickable=4 new=… directIds=9/9`, run succeeded, no Pages noise.
- App: **BUILD SUCCEEDED** (all changes), running on Nicolaas's iPhone, screenshots correlate with
  the scraper. Landscape fix confirmed.

## Key reference values
- Host: `lbapi.lightning-bolt.com` (Bearer) · feed `fd.lightning-bolt.com` · SPA `lblite.lightning-bolt.com`
- customer_id **580** · Nicolaas emp_id **20147** · ICU department_id **20002** · template_id 6
- Accept deep-link (already-logged-in app): `https://lblite.lightning-bolt.com/dashboard/#/swop/<slot_id>/accept`
- Accept link (email/external, logged-out): `…/login/?origin=<login>&origin_hash=swop/<slot_id>/accept`

## Security / boundaries kept
- Never handled Nicolaas's Lightning Bolt or Apple passwords.
- The captured Bearer is a session token used only for the user's own authorized data; never logged
  (the scraper's diagnostics were structure-only, no names/tokens, and are now removed).
- Never test-submitted an accept — deep-link only; the user taps SUBMIT on Lightning Bolt's own screen.

## Part 2 — Stats, calendar & shift log (same day, after the break)

### Durable shift log (per logged-in user)
- New **on-file log** in Application Support (not the purgeable cache), backfilled to **Jan 1 2025** via
  `schedule/range?...&emp_id=<me>` (no `only_pending` = the user's own roster). It **accumulates**: past
  shifts stay on file forever; today + future refresh live each harvest (give-aways drop, pick-ups appear).
- Stamped with the logged-in emp id; if a different person logs in on the device, a fresh log starts.
- `LBWebSource.fetchMyShifts(since:)`, `AppModel.shiftLog` + `mergePast`/`mergeFuture` + `loadHistory()`.

### My Stats screen (More → My Stats — everyone, their own data)
- Settings restructured: **More** tab now shows for all users → **Start Screen** (duration for all;
  witty-line editor owner-only) + **My Stats**.
- Sections (drag-to-reorder via the "Reorder" button; order saved per device): **Month by month**
  (collapsible cards, one per month since Jan 2026, newest first), **Monthly average** (since Jan 2025),
  **Coming up** (two horizons: to end of year + to roster end, with the end date), **Year to date**,
  **You vs group** (admin-only, see below), **2025**, **Custom range** (date pickers).
- Every card: shifts, hours, shifts/mo, h/mo, **by unit** (count · /mo · hours), **by length**
  (24h/12h/9h…), overnights + weekend days.
- **Pasqua Rapid Response (day) + Pasqua-MSU (night) same day = one combined 24h shift**, shown as
  "Pasqua Rapid+MSU" (matches the calendar's month-total combine).
- **Export** (manual, share icon): **CSV** (full log, for Excel) + **one-page PDF** summary.

### You vs group (admin-only, hideable) + cumulative group history
- Owner-only card after Year-to-date (gated on emp 20147). Shows your **shifts & hours vs the group
  average** with your **rank (#R of N)** + ±% badge, and the **whole group ranked by hours** — first
  initial disambiguates same-surname docs (e.g. `B. Arnold` / `J. Arnold`), your row highlighted.
- **Period selector: 2026 YTD / 2025** (segmented). Each is a true calendar-period comparison.
- **Cumulative group log** (`AppModel.groupLog`, file `hb_grouplog.json` in Application Support,
  owner-only): a **one-time background deep scan** pages the group viewer back to Jan 2025
  (`LBWebSource.harvestGroupSince` / `groupPagingJS`), writes it to file, then it's cumulative — the scan
  re-runs only if the file doesn't already reach Jan 2025; every refresh just replaces the recent window
  (`mergeGroup(replaceFrom:)`). Uses a `groupScanning` flag (background, not the global spinner);
  serialised against the pool refresh so they don't fight over the one web view.
- **Hideable** for demos: eye-slash on the card, or **More → Start Screen → Admin → "Show group
  comparison"** (`@AppStorage hb_show_admin`). Colleagues never see the card at all (gated + never scans
  on their devices).
- NOT runtime-tested: the deep scan (paging ~80 weeks). Degrades gracefully (partial/failed → shows what
  it got, or falls back to the live Who's On window).

### Calendar (My Shifts)
- Now shows the **full log (Jan 2025 →)**; opening My Shifts/My Stats backfills history.
- **"This Month"** toolbar button + auto-scroll to the current month on open.
- **Completed (past) shifts render lighter** (blocks ~0.5, faded day numbers); today/upcoming full-color,
  grid stays crisp.

All of the above **builds green** (xcodegen + xcodebuild). iOS app still lives only in Dropbox (not git).

## Part 3 — Group history fixed + verification + multi-year (2026-07-19)

### Group history rebuilt on the reliable source
- The old owner-only 80-week viewer scan was flaky (empty group tabs, "#15 of 14 / 0 h"). Root cause found
  via scraper diagnostics: **`schedule/range` with NO emp_id filter returns the WHOLE group** — all ~28
  doctors, every unit, cross-department, any date. (With emp_id it returns only that person.)
- `LBWebSource.fetchGroupShifts` now uses that; `AppModel.loadGroupHistory` fetches + replaces `groupLog`.
  Fixed the rank-display bug (`#15 of 14` → clamps / shows "—").

### Self-verification (Nicolaas's idea)
- Group covers every unit daily → **5 units × 24h + RGH-Rapid 9h = 129 h/day**. The admin card shows a
  **Data check**: actual total clinical hours vs `129 × days`, ✓ if within 5%, ⚠️ otherwise.
- Caught a real subtlety: LB leaves an **"EMPTY" vacant-slot placeholder** (system `emp=4`) — exactly one
  in 2025 (SICU, Feb 17, 24h). Excluded it → doctors' real total = **47,085 = 129 × 365 exactly**. Now
  filtered out of ranking + data-check everywhere.

### Multi-year — everything back to 2022
- Probes: group data **begins in 2022** (nothing before), and **a whole year fetches in one API call**
  (~4,855 slots for 2025). So the full history = ~6 calls (2022→next-year), seconds, cached.
- `historyStart = "20220101"`. Both `fetchMyShifts` (personal, emp-filtered) and `fetchGroupShifts` (group)
  now loop **one call per year**, start-year → next year (to catch the future roster).
- **Group log is now general (not owner-only)** — a per-device cache of the shared schedule that powers
  **Who's On + Crew across the full history** for every colleague (ranking leaderboard stays owner-only).
  `WhoView`/`CompareView` read `model.whoDays`/`whoByDay`/`whoData`; grouped data precomputed once per
  change (`AppModel.rebuildWho`) so scrolling 4+ years stays smooth.
- Admin "You vs group" → **per-year chips (2026 YTD · 2025 · 2024 · 2023 · 2022)**, each a full
  comparison + ranking + data-check (current year through last completed month).
- Both logs stamped with the logged-in emp id, cumulative, in Application Support.

## Confirmed working on device (2026-07-19)
- Personal 2025 card + calendar history ✓ (107 shifts / 2,348 h, by-unit sums correctly).
- Group me-vs-group + whole-group ranking ✓ (28 doctors; Nicolaas #1 in 2026 hours). Data check 100%.

## Open items / next up
- **Watch device perf** with the full multi-year history (~20k+ assignments held on device): if Who's On
  scroll lags or first load is slow, apply windowed rendering / lazy older-year loading.
- **Menu feature: shelved** — the RQHR cafeteria menu (`rqhintranet.rqhealth.ca`) is internal-only; not
  reachable from College or hospital *guest* WiFi (DNS won't resolve), no public source, VMware doesn't
  bridge to the host. Only viable via a device on the *staff* network. Screenshot-and-paste for one-offs.
- **TestFlight** for Adele, Pieter, Hennie, Matt, + brother Herman (see `TESTFLIGHT-SETUP.md`; internal
  testers = reusable across all your apps).
- **Apple non-public distribution** — start the ball rolling (naming/trademark caveats: rename off
  "Hacking-Bolt"/"Lightning Bolt" before external/App-Store submission).
- Optional polish: parallelize the year `schedule/range` calls; "hours under each name" in Who's On splits.
- The iOS app is **not** in the git repo (lives in Dropbox only) — decide if/how to back it up.

_Everything builds green (xcodegen + xcodebuild) as of end of 2026-07-19._
