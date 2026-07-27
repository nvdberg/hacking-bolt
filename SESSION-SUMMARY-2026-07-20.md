# Working-Bolt — Session Summary (2026-07-20)

UX + performance tweaks to My Shifts, Who's On, and My Stats. Technical notes only.
All changes below are **in code, not yet shipped** — the live TestFlight build is still **1.0 (3)** (see §7).

---

## 1. My Shifts — render performance (MonthGrid.swift)

- `RosterCalendar.build()` (which turns the whole 2022→ log into month grids) was running **on every SwiftUI render** — every `@Published` change on AppModel re-ran it, and it re-ran on each tab switch. That was the "touch delay" entering My Shifts.
- Now **memoized**: `build()` output is cached in `@State (months, subtitle, builtSig)` and `rebuildIfNeeded()` recomputes only when a cheap signature (`shifts.count | first date | last date | userName`) changes. Switching to the tab no longer rebuilds — it's cached.
- Decoupled "rebuild" (on `sig` change) from "scroll" (on `scrollTick` change), so re-centering never triggers a rebuild.
- (Who's On was already optimal — `LazyVStack`/`LazyHStack` + model-precomputed `whoByDay`/`whoDays`.)

## 2. My Shifts — centering + tab re-center

- `jump()` anchor changed **`.top` → `.center`** — "This Month" now centers the current month in view.
- **Tapping the My Shifts tab re-centers** on the current month (same as the This Month button), via new tab-tick plumbing in MainTabs (§5).
- MonthGrid uses a **non-lazy** month layout, so its single deferred scroll is reliable (no two-pass needed).

## 3. My Shifts — year-month jump picker (CalendarView.swift)

- New toolbar-leading **Menu** (`calendar.badge.clock` icon): Year → Month submenus built from the log's date range (`yearMonths`, both descending). Selecting sets `targetYM`.
- MonthGrid gained a `jumpToYM` input; `.onChange(of: jumpToYM)` scrolls to that month (anchor `.top`).
- Uses `String(year)` (not `\(year)`) to avoid the "2,026" digit-grouping comma.

## 4. Who's On — tab re-center + reliable centering (WhoView.swift)

- Added `tabTick` input; `.onChange(of: tabTick)` snaps `selectedISO` to today and bumps `scrollTick` → re-centers on today when the tab is tapped (on top of the existing `.onAppear` snap).
- **Fixed intermittent "~1-in-3 doesn't center"**: the lazy list's target row wasn't laid out when the single deferred `scrollTo` fired. `recenter()` is now **two-pass** — a quick unanimated `scrollTo` (0.05s) to materialize the rows, then an animated centering `scrollTo` (0.30s). Applied to both the portrait timeline and landscape grid.

## 5. Tab plumbing (ContentView.swift → MainTabs)

- `TabView` now uses a **selection binding**; setting selection to My Shifts (tag 1) bumps `myShiftsTick`, to Who's On (tag 2) bumps `whoTick`. These pass into `CalendarView(tabTick:)` / `WhoView(tabTick:)`.
- Note: fires on *switching to* the tab (selection change). Re-tapping the already-active tab is a SwiftUI limitation and not covered — switching-to covers the reported use.

## 6. My Stats (Stats.swift)

- **Coming Up card** now has a **BY MONTH** breakdown under the two horizon blocks: per upcoming month, total shift count + per-unit chips (colour dot · short name · ×count), unit order from `WhoView.unitOrder`. New `upcomingMonthRow()` (plain func, not `@ViewBuilder`, because it does a `for` loop to tally counts).
- **"2025" card → per-year card with chips.** New `yearCard` + `fullYears` (full calendar years in the log that are `< current year`, newest first) + `@State yearSel`. Horizontal year chips (2025/2024/2023/2022…); selecting shows that year's full-year `StatsCard` (embedded). The `StatSection.year2025` raw value is unchanged, so saved section order still resolves.

---

## 7. TestFlight status (unchanged today)

- Build **1.0 (3)** still **`WAITING_FOR_REVIEW`** (submitted 2026-07-19 14:46; ~28h+ in queue by evening 07-20 — within normal, just slow). Internal ("My Devices") is live on Nicolaas's phone. Public link `https://testflight.apple.com/join/9ThGvNv3` goes live on approval.
- Review-status monitor: `tools/review_status.py` + hourly cron `fd17d070` (session-only) still running; pings on approval/rejection. Apple's email is the reliable backstop.
- **These 07-20 tweaks are NOT in build 3** — they need a new build (bump `CURRENT_PROJECT_VERSION` → 4, rebuild, upload) whenever we decide to ship them. Uploading build 4 while 3 is in review would just replace 3 in the queue.

## Open / next
- Ship the 07-20 tweaks in build 4 (on request).
- Await Beta App Review → share public link.
- Later: Unlisted App Store (permanent, no 90-day churn) — full review + privacy policy + screenshots + EU DSA trader status + unlisted request.
