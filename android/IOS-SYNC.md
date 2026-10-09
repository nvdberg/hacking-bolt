# iOS → Android sync — what to port next

**Read this at the start of every Android session.** It's the running record of what the
**iOS app (`../hacking-bolt-ios`) currently does**, so the Android port can catch up and stay at
parity. iOS is the source of truth. File names below refer to iOS files — see the README's
iOS↔Android mapping table for the Kotlin counterpart.

- **iOS parity target: build 97** (bump this line whenever iOS ships). Android is at 97 (versionCode 7, 2026-10-08; b5 added the in-app self-update, Android-only).
- iOS deep reference: memory `project-hackingbolt-app` (build-by-build), `reference-lb-swaportunity-api`
  (the real LB data model), `reference-shift-taxonomy`, `project-workingbolt-android` (Android rules).
- **Golden rule from the Android project: NO owner/admin surface, ever.** ⚠️ *Corrected 2026-08-14 by
  the Android side — the original wording of this line was wrong.* The rule is **no owner/admin
  surface**: no `AdminView`, no `StartScreenSettings`, no `hb_show_admin`, and none of the three
  owner-gated Stats cards ("You vs group", "Unit mix", "Shift pickups"). It does **NOT** mean
  "read-only". **Android has full Swap + Give-away**, built at Nicolaas's explicit request on
  2026-08-08 — `offerToPerson` / `offerToGroup` / `splitShift` / `cancelOffer` are all live behind
  confirm dialogs. Do not remove them, and do not tag swap/give-away work as [iOS-ONLY]. Each item
  below is tagged **[PORT]** (mirror it) or **[iOS-ONLY]** (skip on Android).

---

## Core architecture Android must mirror [PORT]

- **LB auth capture:** iOS injects a documentStart script into the LB web view that wraps `fetch`/`XHR`
  to grab the `Authorization: Bearer …` the SPA sends to `lbapi.lightning-bolt.com`, into
  `window.__lbAuth`. Android WebView equivalent = a documentStart `evaluateJavascript` hook or a
  `WebViewClient` that does the same. **lbapi rejects the cookie (401) — you MUST use the captured Bearer.**
- **Pool (open shifts):** `GET lbapi…/schedule/range/?start_date=YYYYMMDD&end_date=YYYYMMDD&listed=true&emp_id=<EMP>&only_pending=true`, looped ~14 months forward, dedup by `slot_id`, keep `is_pending===true`. This is emp-scoped but returns the currently-open pool; picked-up/canceled shifts correctly drop out (verified live 2026-08-14).
- **Who's On / group history:** `…/schedule/range/?start_date=Y0101&end_date=Y1231&listed=true` (no emp, no only_pending), per year **2022 → current+1**, chunked one year at a time (a single all-years call is ~30 MB and overflows the bridge). A slot with `original_emp_id != emp_id` = it changed hands (giver=original, taker=current, `modified_date`=approval time).
- **~1h token expiry is the #1 gotcha.** The Bearer dies after ~1 hour → live fetches 401 → stale data. iOS handles it two ways, BOTH of which Android needs:
  - **Reactive self-heal:** on an empty/failed fetch, reload the web view to re-capture the token, then retry once (directory, group history, pool, swap all do this).
  - **Proactive prevention (build 62):** on foreground after >20 min away, re-capture the token AND refresh group data *before* any screen reads it; keep the token warm with a ~30-min refresh while the app is open, 2-min light pool refresh.
- **Pasqua rule:** `Pasqua-Rapid (PRR, day) + Pasqua-MSU (MSU, night)` worked by the same doc on the same day = ONE 24h "Pasqua" shift (08:00→08:00). Applies in stats, calendar, and swaps.
- **Demo mode:** "Explore with sample data" (`DemoData`) — a no-login path for reviewers; keep it.

---

## Android status — verified against the Kotlin source, 2026-08-14

**Android is already at parity with iOS builds 53–57.** Everything those builds describe is
implemented: same-day swaps, Pasqua 24h/Rapid/MSU split, swap **Filter** by unit + colleague, the
unified swap+give-away screen, tightened eligibility, text-to-ask, multi-select recipients with
per-person / selected / everyone texting, "Ask to pickup" beside "Ask to swap", per-day "Text all",
and tapping a shift in My Shifts → "Find a swap / Give it away". Build 57 is an owner Admin card —
correctly absent. The 53/54 notes below asking whether Android gets a swap view are **already
answered: yes, it has one, with writes.**

**Builds 58–62 ported 2026-08-14 — Android is now at parity with iOS build 62.**

| iOS | What Android does now | Where |
| --- | --- | --- |
| 62 | `onForeground`: if >20 min away, `refresh()` (re-captures the token) **then** `loadGroupHistory(force=true)` before any tab reads — so you never land on a stale Who's On. Otherwise a light pool refresh, escalating to a full one if it fails. | `AppViewModel.onForeground` |
| 61 | Swap detects **stale** as well as empty: if nobody at all is recorded on the selected shift's own date, the data can't be current → force re-capture + reload. | `SwapScreen.ensureLoaded` |
| 60 | `loadGroupHistory` releases its scan lock, `refresh()`es to re-capture the token and retries once on an empty fetch. Who's On snaps to today once (`landedOnToday`) when fresh data first covers it. | `AppViewModel.loadGroupHistory`, `ui/WhoScreen.kt` |
| 59 | Splash hold is adjustable (`wb_splash_secs`). **Since b6 (iOS 96): More → App → "Start screen", a 2–8 s menu in half-second steps** — same place as iOS now (it left the owner screen there). | `ui/LaunchScreen.kt`, `ui/Prefs.kt`, `ui/SettingsScreen.kt` |
| 58 | `buildMonths` now builds month **headers** only; each month's day cells are built by `buildCells` the first time that month scrolls into view. | `ui/RosterCalendar.kt` |

**Builds 63–90 ported 2026-10-03 — Android is now at parity with iOS build 90** (Android 1.0, versionCode 3,
`../dist-android/WorkingBolt-1.0-b3.apk`). Checked on the emulator in sample-data mode only; the live
Lightning Bolt paths (auto sign-in, fingerprint prompt, time-off writes, two-way swaps, calendar sync,
cancelling a post) compile and mirror iOS but have **not** been run against LB from Android yet.

| Area | What Android does now | Where |
| --- | --- | --- |
| Pool | Lists `poolShifts` (offers aimed at one person show only for the target); "Updated" time; "Recently taken" (2 days, no names, hideable); busy-day flag + ask-before-taking; "no longer available" note; pull to refresh; a taken shift shows in My Shifts right away. | `ui/PoolScreen.kt`, `AppViewModel` |
| My posts | Tab in the Pool (auto / always / only when pending): waiting + picked up, swap / one-person labels, cancel. | `ui/MyPostsScreen.kt` |
| Swaps | Two-way swap = two plain offers paired by the `swap:` / `swapback:` tag in `offer_notes.reason` (first slot only, as iOS). Sending is behind a confirm; the return half is taken only for a swap the user sent. "Swap didn't go through" note. | `ui/SwapScreen.kt`, `AppViewModel.requestSwap/sendSwapBack/finishIncomingSwap` |
| Give-away | Partial outcomes reported, Pasqua part selector, started shifts excluded. | `ui/GiveAwayWizard.kt` |
| My Shifts | Busy days (long-press, on-device only), double-tap → who's-on panel, open square → Pool, violet "Posted" square, week start, .ics export. | `ui/CalendarScreen.kt`, `ui/RosterCalendar.kt`, `data/CalendarExport.kt` |
| Time off | List / new request / cancel. | `ui/TimeOffScreen.kt` |
| Calendar sync | Live subscribable feed on/off + copy link (`cal_subs`). Token cached per person (`wb_cal_token_emp`). | `ui/CalendarSyncScreen.kt` |
| Sign-in | Optional "Keep me signed in" / fingerprint-or-face auto sign-in; login AES-GCM encrypted with an Android Keystore key, on-device only. | `data/LBCreds.kt`, `MainActivity.kt` |
| Stats | Pasqua Rapid+MSU counted as one 24h. | `ui/StatsScreen.kt` |
| Android-only | System Back inside a More page returns to More. | `ui/SettingsScreen.kt` |

**Builds 91–93 ported 2026-10-06 — Android is now at parity with iOS build 93** (versionCode 4,
`../dist-android/WorkingBolt-1.0-b4.apk` + tester zip). Sample-data mode checked on the emulator; the live
on-call roster / cafeteria reads (Supabase) compile and mirror iOS but haven't been run on a real phone yet.

| Area | What Android does now | Where |
| --- | --- | --- |
| Who's On | 🩺 toggle (remembered): ICU intensivist + on-call number per row, in-CCU cardiologist, unit desk + CCA call-room bar, two-line nightly ICU / cardiology strip, landscape Tonight row. The on-call read is owned by the store (rows join it), so a cancelled row can't strand the others (iOS 93 fix). | `ui/DoctorsOnCall.kt`, `ui/WhoScreen.kt`, `ui/WhoShared.kt` |
| Cafeteria | RGH / Pasqua (remembered), day arrows, lunch + sides first, ☀/🌙 headers, rotation by week, 30-min refresh, cached on disk, keep-on-failure, bigger text (iOS 93). | `ui/CafeteriaScreen.kt` |
| Guide | Searchable "How to use Working-Bolt", Android-accurate copy of `Guide.swift` (no push, no PDF, no TestFlight feedback). `Guide.updatedForBuild` = versionCode. | `ui/GuideScreen.kt` |
| More | Grouped My shifts · Calendar · 🍴 Cafeteria (today's lunch subtitle) · App; rows pad to fill the screen (iOS 93); Auto sign-in under Advanced; Advanced's sub-pages go back to Advanced. No Feedback (TestFlight-only), no Admin. | `ui/SettingsScreen.kt` |
| Update banner | Reads gist `wb-android.json` `{latestBuild,url}`; nothing shows if it's missing. b5: Update downloads + installs the APK in-app (see README "In-app update"). | `data/UpdateChecker.kt`, `MainActivity.kt` |

Not ported, by decision: every owner/admin surface (swap log, swap trace, accept capture, admin card, owner
Stats cards incl. the Pasqua column in Unit mix), push notifications, TestFlight Feedback.

**Build 96 ported 2026-10-07 — Android is now at parity with iOS build 96** (versionCode 6,
`../dist-android/WorkingBolt-1.0-b6.apk`). The new LB read JS was checked old-vs-new in a Node harness (20/20,
incl. 401s, wrapped replies, Regina month/year edges, New-Year windows); sample-data mode checked on the
emulator. The live LB reads haven't been run from Android yet.

| Area | What Android does now | Where |
| --- | --- | --- |
| Faster reads | My shifts + open offers fetched in parallel; offers read 4 months at a time from the **Regina** month (no more UTC month slip on an evening open); my shifts 3 years at a time up to Regina year + 1. An unreadable reply now counts as a failure (keeps the cache). | `data/LBWebSource.kt` (`harvest`, `fetchOpenOffers`, `fetchMyShifts`) |
| Catch-up | Foreground after >20 min: if the group log is <12 h old, read only today −7 → +90 days (Regina, split at New Year) and splice it in; full re-read only if that fails or comes back empty. | `AppViewModel.refreshGroupWindow`, `LBWebSource.fetchGroupRange` |
| Who's On | Rebuilds are generation-checked (`whoGen`) — an older rebuild can't overwrite a newer one. | `AppViewModel.rebuildWho` |
| Calendars | Swap calendars follow "Week starts on"; My Shifts groups shifts by month in one pass. | `ui/SwapCalendar.kt`, `ui/RosterCalendar.kt` |
| Digits | Keys / ISO dates / CSV hours formatted with `Locale.ROOT` (an Arabic/Persian phone setting broke them). | Stats, Calendar, Pool, GiveAwayWizard, ShiftExport, LBWebSource |
| Start screen | More → App → Start screen (2–8 s menu); the stepper left Advanced. Guide updated. | `ui/SettingsScreen.kt`, `ui/Prefs.kt`, `ui/LaunchScreen.kt`, `ui/GuideScreen.kt` |

## iOS build changelog = the port worklist

Newest first. **[PORT]** = mirror on Android; **[iOS-ONLY]** = owner/give-away/admin, skip.

- **97** *(iOS, 2026-10-08, sent to crew)* — ✅ ported (Android b7, versionCode 7, `../dist-android/WorkingBolt-1.0-b7.apk`; published 2026-10-09 as `android-b7` + `wb-android.json` → 7). [PORT] My Shifts day card (double-tap) gets its own 🩺 (remembered, `wb_panel_doctors` / iOS `hb_panel_doctors`, separate from Who's On). On: card goes full width (≤560 dp), hours shorten to "08–08", each unit's FIRST row gets a doctor column (thin divider, 116 dp: ♥ in-CCU name for CCU, else 🌙 if also tonight's night intensivist + day intensivist + on-call number), and one Tonight line under the rows (🌙 night ICU · ♥ "On call" cardiology · "STEMI"). Height cap portrait = 48% (iOS) / 50% (Android, taller rows) of the area minus header + Tonight line, landscape 60%; past it the rows scroll inside the card. Card still drags up/down (clamped). Android rows go to 4 dp vertical padding and a 10 sp / 74 dp unit label with doctors on, so all 7 rows + Tonight fit and "Pasqua-Rapid" isn't cut (emulator-checked, sample data). Guide double-tap text updated both sides. **Android-only fix in b7:** My Shifts day number had Material's 24 sp line height, pushing the shift blocks ~10 dp lower than iOS and under the amber open-shift square; now `lineHeight = daySize × 1.25` (`ui/RosterCalendar.kt` `DayCell`), so blocks sit under the number like iOS and the square's corner stays clear. Files: iOS `WhoView.swift` (`WhoDayPanel`), `CalendarView.swift` (DEBUG `DEMO_PANEL*` screenshot hooks), `Guide.swift`; Android `ui/CalendarScreen.kt` (`WhoDayPanel`, `DayPanelRow`, `TonightLine`), `ui/Prefs.kt`, `ui/GuideScreen.kt`.

- **96** *(iOS, 2026-10-07, Nicolaas only)* — ✅ ported (Android b6, see the table above). All [PORT]: parallel pool + mine reads, Regina-anchored month/year, 3-month group catch-up on foreground, generation-checked Who's On rebuild, swap calendars honour week start, one-pass month grouping, locale-safe digits, Start screen moved to More → App (2–8 s, half-second menu).
- **95** *(iOS, 2026-10-06, Nicolaas only)* — ✅ nothing to port. 94's fix (`scrollPosition`) still jumped on a phone with the full 2022→ history and added lag; replaced: the day on top is read before the toggle and put back with `scrollTo(day, .top)` (the Today-button path), once more if a doctors' month lands within 3 s. Doctors' current month is read on open, so turning it on is instant. Android's `LazyColumn` already keeps its day (see 94).
- **94** *(iOS, 2026-10-06)* — ✅ nothing to port. Who's On holds the top day when the stethoscope is toggled (iOS list slid weeks back because every day changed height). Android's `LazyColumn` anchors on the first visible day already — checked on the emulator (b5): toggling at today, mid-list and after scrolling with doctors on keeps the same day on top.
- **93** *(shipped to TestFlight 2026-10-06)* — ✅ ported (Android b4). Stethoscope off/on race fixed (the on-call read is the store's own task; rows join it, so one cancelled row can't strand the rest). Cafeteria text a size bigger (items body, prices footnote, headers subheadline). More rows pad with screen height so the list fills a tall phone.
- **92** *(shipped to TestFlight 2026-10-06)* — ✅ ported (Android b4). On-call strip, cardiology part (♥ + red/CCU-colour text as before) becomes TWO lines: line A = in-CCU name (no "in CCU" text — the ♥ says it) · red "Consults 8–5" + name; line B (under it, no icon) = red "On call" + pair · red "STEMI" + pair (falls back to On call / STEMI stacked if too wide). ♥ now reads as "who's in CCU this week". Landscape unchanged. Also: **More** — the 🍴 Cafeteria section moves up, between Calendar and App. **More** fits one screen: inline (small) title, compact section spacing, min row height ~38 dp, the 🍴 section has no header. **Cafeteria screen**: no top gap (site tabs right under the title), weekday + date on ONE line, a card per special with tight rows (~4 dp vertical, min ~28 dp), headers pulled up, ~4 dp between sections; order = Lunch feature + the side section(s) printed right after it, then the rest in printed order; Lunch/Supper headers get ☀/🌙 icons in accent bold, others plain muted. Guide text updated.
- **91** *(shipped to TestFlight 2026-10-06)* — ✅ ported (Android b4, versionCode 4). All [PORT]. iOS files: `DoctorsOnCall.swift`, `WhoView.swift`, `CafeteriaView.swift`, `Guide.swift`, `Quips.swift` (More). Suggested Kotlin: `data/OnCallRoster.kt` + `ui/OnCallStrip.kt`, `ui/CafeteriaScreen.kt`, `ui/GuideScreen.kt`, changes in `ui/WhoScreen.kt` / `ui/WhoShared.kt` / `ui/SettingsScreen.kt`.
  - **Doctors on call — the toggle.** Who's On top bar gets a **stethoscope** button (its own button, separate from Today; filled + accent when on), persisted (`hb_who_doctors` → `wb_who_doctors`). Off = Who's On exactly as before; everything below appears only while it's on. No double-tap anywhere.
  - **Data.** Read-only from Supabase `oncall_roster` (date, unit SICU/MICU/PHICU/CCU, role day/oncall/stemi_day/stemi_oncall/consults, name) — same REST base + publishable key as `pickups`/`cal_subs`. Load the month around a day (1st −7 d → 1st +38 d), at most once per month per 10 min, only while the toggle is on; disk-cache it; **a failed read keeps the cache**. Data is entered by hand on the Unit Board (PetalMD + the RGH cardiology PDF), so it can lag. **Never hard-code or log names (public repo); demo = invented tree names** (see iOS `demoRows`).
  - **Rules.** *Night intensivist* = ONE person covers all ICUs overnight: the name on the most `oncall` rows of SICU/MICU/PHICU (tie → SICU, MICU, PHICU order); any other `oncall` name = "2nd" (mass event only). *In CCU* = an explicit CCU `ccu` row if one ever exists, else the CCU `day` cardiologist on the **Friday that starts the Fri → Thu week**.
  - **Numbers bar (portrait only), once under the top bar:** a rounded bar, one column per unit in the user's unit order — unit label (unit colour) + desk number (SICU 3990 · MICU 4291 · CCU 4266 · PICU 8555), and under it, smaller/greyed with a bed icon, the CCA call room (SICU 3971 · MICU 4823 · CCU 4241 · PICU 8556); then a last **"Wards"** column (Pasqua-Rapid green) with only the room, 2417 (Pasqua wards). Not on the rows.
  - **Doctor column (portrait).** The FIRST CCA row of each ICU unit per day gets a right-hand column (thin divider, ~78 dp, right-aligned): that day's intensivist (`day` role, 🌙 moon in front if they're also tonight's night person) and under it a small phone icon + the on-call intensivist number (SICU 4268 · MICU 4265 · PICU 4249). The CCU row shows the in-CCU cardiologist + "in CCU". Unit-label width shrinks a little to make room; the CCA name may scale down to ~75%.
  - **On-call strip** closing each day (rounded card, indigo tint — stronger on today). Labels are **icons only**. Line 1: 🌙 + tonight's intensivist **circled** (indigo capsule outline) + "2nd X" small/greyed. Line 2: ♥ (CCU colour) + cardiology on ONE line: on call · **STEMI** pair · **8–5** consults. A "pair" = daytime name, then the evening (17:00 →) name circled; one circled name if it's the same person. If it doesn't fit, fall back to two lines: [on call · STEMI] / "Consults 8–5" name, then [on call] / [STEMI · 8–5]. Names caption-size, small gaps (real data: most days fit on one line).
  - **Landscape week grid** (Android has one in `WhoShared.kt`): a small doctor line under each ICU/CCU cell (stethoscope icon + day intensivist, or moon if they're tonight's; heart + in-CCU for CCU) + an extra last row "On call tonight": 🌙 night intensivist · ♥ CCU on-call.
  - **Title** "Who's Working" → **"Who's On"** (matches the tab).
- **91 (cont.)** — [PORT] **More regrouped**, in order: *My shifts* (Swap or Give Away, Time Off Requests, My Stats) · *Calendar* (Sync to Calendar, Export) · *App* (How to use Working-Bolt, Advanced, Feedback, About, Sign out; footer "Signed in as …") · last a 🍴 section (fork-and-knife header) with **Cafeteria menu** + today's lunch feature as its subtitle. **Auto sign-in** moved into More → Advanced → Personalize. (iOS's Admin row in *App* is owner-only — skip.) · [PORT] **Cafeteria menu**: RGH/Pasqua switch (remember the site), day arrows, sections + prices from Supabase `cafeteria_menu` (one row per weekly page of a rotating cycle; a page printing the exact date wins, else rotate from the lowest page's `first_date` by week, matching weekday). · [PORT] **How to use Working-Bolt** guide: searchable topics, copied from iOS `Guide.swift` — crew-facing only, drop anything owner-gated or iOS-only (Face ID → fingerprint wording, no push). · [iOS-ONLY] DEBUG-only bottom-accessory mock-up — not shipped, skip.
- **90** — [PORT] Offers/swaps aimed at ONE person are no longer listed in everyone's Pool — only the target sees them; mine sit under My posts (`OpenShift.directedTo`, `poolShifts`). · [PORT] "Recently taken" under *For me* shows only shifts I could have picked up (`recentlyTakenForMe`).
- **89** — [PORT] **Busy days**: long-press a day in My Shifts → mark busy (+ short note); the Pool flags shifts that day and asks before taking. **On-device only** (`hb_busy_days` / `wb_busy_days`). · [PORT] Pool "Updated" time + **Recently taken** (last 2 days, no names, hideable — `hb_show_recent_taken`; read from Supabase `pickups`). · [PORT] Swaps / direct offers are no longer marked "open" on calendars (`openForAllDates`). · [PORT] My posts labels swaps / one-person offers. · [PORT] My Stats count fixes + Pasqua column.
- **88** — [PORT] A shift taken from the Pool shows in My Shifts right away: when the accept page closes and the shift has left the pool, the roster is re-read (`afterAcceptAttempt`).
- **87** — [iOS-ONLY] Owner swap trace (LB's full record for swap slots, beside the accept capture). · [PORT] "Swap didn't go through" note when a swap I sent is declined or cancelled (`declinedSwaps`, dismissable).
- **86** — [PORT] Swap returns are recognised without the colleague's tag (they may send back on LB itself) → "Take it" card (`swapReturnsForMe`). · [iOS-ONLY] private push; owner-only watch-only recorder on the accept page (Admin → Accept capture).
- **85** — [PORT] **Swaps = two plain offers paired by a tag** (offer-note `reason`: `swap:<toEmp>:<slots I get back>` / `swapback:<toEmp>:<slots they took>`). LB's own Exchange leaves the sender unable to accept their half (live test 2026-10-01). Swaps card in the Pool: accept swap (your shift goes back automatically — the one approved automatic write, see project CLAUDE.md), send-back catch-up, take the return half. Instant roster refresh when a shift you're in changes hands; **started shifts can't be offered**. Needs `Assignment.slotID`/`slotID2`. Poller pushes swap halves privately (backend, shared).
- **84** — [PORT] Swap calendars no longer hide the first days of a month (blank-cell ids clashed with day ids).
- **83** — [SUPERSEDED by 85] Swap requests as LB's one-step Exchange — do not port.
- **82** — [PORT] Time Off Requests lives under More (below Swap or Give Away), not in the My Shifts toolbar.
- **81** — [PORT] **Time-off / night-off requests** (list, send, cancel own pending — `GET /request/range/`, assign 20248/20251). · [PORT] Double-tap a day in My Shifts → floating, draggable Who's On panel.
- **80** — [PORT] Review fixes: group fetch re-runs when the roster is empty, wizard eligibility tracks `whoByDay`, retry recomputes years, Pasqua partial result, sign-out persists across relaunch, calendar token never re-minted on a failed read. · [iOS-ONLY] owner swap-log rebuild.
- **79** — [PORT] Sign-out never auto re-logs-in, demo write guards, idle-wait refresh after split/cancel (`refreshWhenIdle`), Pasqua half-offer reporting (`WriteOutcome.partial`), Regina dates, incremental group fetch (only live years re-read), off-main decode. · [iOS-ONLY] push refresh-then-jump, group compare (owner card).
- **78** — [iOS-ONLY] Owner earnings card + hourly rate, splash timer in Admin. · [PORT] Data-safety fixes: a failed pool / roster / group read keeps the cached data (`offersOK`, `MyShiftsResult.all`, `GroupFetch.failedYears`); calendar redraw + tap fixes.
- **77** — [PORT] Friendly "shift no longer available" banner + pool auto-refresh.
- **76** — [iOS-ONLY] Pickup trails (owner Shift-pickups card).
- **74–75** — [PORT] Auto sign-in ("Keep me signed in", silent; plus the Face ID mode from 63–65), Who's On long-press, give-away / swap split of the swap screen.
- **73** — [PORT?] App Store share link added to Admin (iOS-specific URL; Android would use its own Play/store link). Marketed 1.0.2.
- **72** — [PORT] **Live Calendar sync** — More→Sync to Calendar: toggle mints a stable token in `cal_subs`, poller uploads a per-user .ics to the public Supabase `calendars` bucket, user subscribes in Google/Apple Calendar. Backend (poller + bucket) is shared, so Android just needs the enroll toggle + subscribe-URL screen + Google how-to.
- **71** — [PORT] Pool mini-calendars honor the Sunday/Monday week-start setting (build 69 did My Shifts only).
- **69** — [PORT] **Week start** setting (More→Advanced, `hb_week_start` Sun/Mon) reorders the calendar header + leading pad + post-call fuse edge (last-column check). · [PORT] **Export to Calendar** (.ics) — share button in My Shifts → emoji-colour-tagged titles ("🟥 CCU", no time), 24h calls folded to one 08:00→08:00 event, Pasqua Rapid+MSU merged; UTC times (Regina UTC-6), stable UIDs. Google ignores per-event .ics colour → emoji is the cue. `CalendarExport.swift`.
- **68** — [PORT] **My Posts: swaps + cancel.** Pending posts labeled `.swap` (vs give-away) by reading my `offer_notes` from Supabase (`myOfferNotes(byEmp:)`; note containing "swap" ⇒ swap) — the app's "Ask to swap" is a directed give-away + swap-worded note. **Cancel** on each pending entry → `cancelGiveAway` (proven "delete swap"); target remembered locally at offer-time (`hb_offer_targets`) since the pool doesn't carry it, fallback to owner-emp + graceful "cancel in LB" hint. Easter egg "Hein's idea 🤝". LB-native swaps (created in LB, no note) still show as give-aways — parked.
- **67** — [PORT] **"My Posts" tracker.** A new segment in the Pool (**auto-shows only when you have posts**; Advanced setting `hb_myposts_mode` = auto/always/pending) listing shifts you've put up: **Waiting for pickup** (pending give-aways + swaps, from the open pool filtered to `offererEmp == me` — needed a new `offererEmp:Int?` on `OpenShift`, threaded from `RawSlot.emp`), and **Picked up** (grouped by month, eye-toggle, whole year). A **violet "Posted" square** marks posted-and-pending days on My Shifts (`postedPendingDates`), plus a "Posted" legend entry. · **Backend (all clients):** the poller now scans the whole year's group schedule for pool pickups (`original_emp_id`≠`emp_id`, "request to swap…approved by"), writes them to a new Supabase **`pickups`** table, and sends the **giver** a targeted "your shift was picked up by X" APNs push (via `devices.emp_id`; `notified` flag + 6h cutoff so first run doesn't flood). The app reads `pickups?giver_emp=eq.<me>` for the "Picked up" list — **works for everyone, not just owner.** Android equivalent: same `pickups` read + Biometric... n/a; just the Supabase read + a "My Posts" screen. Files: `MyPosts.swift`, `MyPost` model, `AppModel.myPosts/loadPickups/postedPendingDates`, `SupabaseClient.pickups`, `stage2/run.mjs` (detectPickups/syncAndNotifyPickups), `stage2/supabase.mjs`. Poller `detectPickups` records BOTH pool pickups (kind `giveaway`) and completed direct swaps (kind `swap`); app renders "Picked up by X" vs "Swapped with X". Poller `LOOP_MINUTES=330` (bridges GitHub's delayed cron), pickup scan current-year (`PICKUP_YEARS_BACK`). **PARKED [PORT-later]:** pending *trade-request* tracking (LB-native pending swaps you initiated) — needs a live LB pending-swap sample to build; deferred until a test swap is captured. The `.swap` kind + UI already exist; only the real pending-swap data source is missing (iOS + Android both).
- **66** — [PORT] My Shifts: the amber open-shift square is its own tap target → jumps to that shift in the Pool even on a day you work.
- **65** — [PORT] **Face ID auto-login now available to ALL users** (moved out of owner-Admin → More → "Sign in with Face ID"). Opt-in, off by default: stores the user's own LB username+password in the Face ID–protected Keychain and auto-fills+submits LB's login form when the session fully expires (the longer-lived *login* session, beyond the ~1h token). Android equivalent = `BiometricPrompt` + Keystore-encrypted creds + WebView form-fill. Privacy-policy update is drafted (`store/privacy.html`) but **held from deploy until App Store build 57 is approved**. See iOS `BiometricLogin.swift` (`LBCreds`), `LBWebSource.autoSignIn`, `AppModel.autoLoginAndLoad`, `FaceIDLoginView`.
- **63–64** — [PORT] Face ID auto-login introduced (63) + toggle-state fix using an `@AppStorage` flag instead of the finicky biometric-Keychain existence check (64). · [PORT] Pool "updated" timestamp shows the DATE when the snapshot isn't from today (so stale data reads as stale).
- **62** — [PORT] **Staleness prevention**: `onForeground` (>20min away) proactively re-captures the LB session + refreshes group data before any tab opens. This is the big one for Android too (same ~1h token). · [iOS-ONLY] Shift-pickups card reformatted (leads with pickup date).
- **61** — [PORT] Swap screen self-heals on *stale* (not just empty) group data — detects when the loaded data doesn't cover the selected shift's date. (Android swap view, if any, wants the same guard.)
- **60** — [PORT] `loadGroupHistory` self-heals the token (refresh + retry) on an empty fetch; Who's On snaps to *today* when fresh data arrives (`landedOnToday`). Directly relevant to Android's Who's On.
- **59** — [PORT] Opening-screen (splash) hold time is user-adjustable (`hb_splash_secs`, 2.5–8s) in settings.
- **58** — [PORT] **My Shifts perf**: the month calendar uses a lazy list so it builds only on-screen months (was eagerly building ~50 months 2022→next-yr on every open → ~2s lag). Who's On/Crew were already lazy.
- **57** — [iOS-ONLY] Admin "Invite link" (TestFlight public link) card. Also = the iOS App Store submission build.
- **56** — [iOS-ONLY] Give-away: multi-select recipients + 3 text options (per-person / selected / everyone). · [iOS-ONLY] Swap "Ask to pickup" beside "Ask to swap" (diff-day only) + per-day "Text all" feeler.
- **55** — [iOS-ONLY] Removed give-away toolbar arrow; tapping a shift → "Find a swap / Give it away" both open one shared screen. · [PORT] SwapView session self-heal (empty).
- **54** — [iOS-ONLY] Pasqua 24h/Rapid/MSU give-away split; swap results **Filter** (by unit/colleague); unified swap+give-away; give-away eligibility tightened; text-to-ask. *(A read-only Android could still port the swap **Filter** and the same-day swap view — see 53.)*
- **53** — [PORT-ish] **Same-day swaps** in the Swap Finder (trade units with someone working another unit that day) + Pasqua-as-24h in the swap counter. Swap itself is borderline for a read-only Android; confirm with Nicolaas whether Android gets a (read-only) swap/pool browsing view or stays calendar+who's-on+pool only.

Anything not tagged is safe to mirror. When unsure whether a feature crosses the "no owner surface"
line, ask Nicolaas — the Android app is for colleagues to *view*, not to mutate the schedule.

---

## How to keep this current

- **iOS side (this repo's chat):** after each iOS build ships, add a one-line entry at the top of the
  changelog with the [PORT]/[iOS-ONLY] tag, and bump the "parity target" line.
- **Android side:** work down the [PORT] items above; when a build reaches parity with iOS build N,
  note it in the Android README. Ping the iOS chat if an item's behavior is unclear — the iOS code +
  the `reference-lb-swaportunity-api` memory are the authority.
