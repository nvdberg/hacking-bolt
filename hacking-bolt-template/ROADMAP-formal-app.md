# 🛣️ From this prototype to a real app

This web version proves the idea. Here's the map to a proper app — plus everything we reverse-engineered
about Lightning Bolt so you don't start from zero. (You've got an Apple Developer account, so the native
route is very much on the table.)

---

## Where this is now (and its limits)
- **Architecture:** GitHub Actions cron → Playwright **scrapes** the Lightning Bolt web app with stored
  credentials → writes `shifts.json` → static GitHub Pages renders it → ntfy push.
- **Limits:** one deploy per person; credentials live as GitHub secrets; it *scrapes the DOM* (brittle if
  LB changes its markup); hosting is public on the free tier; no in-app login.

## The three ways forward

| Path | Effort | In-app login | Best for |
|---|---|---|---|
| **1. Wrap the web app (PWA/Capacitor)** | low | no (still per-user deploy) | shipping *something* to the App Store fast |
| **2. Hybrid (Capacitor + small backend)** | medium | yes | a shared multi-user app without a full rewrite |
| **3. Native (SwiftUI, on-device API)** | higher | yes | the clean, private, "real app" — **recommended** |

### Path 1 — PWA / Capacitor wrap
The pages already have `apple-mobile-web-app-capable` etc. Point **PWABuilder** or **Capacitor** at your
hosted site and it produces an Xcode project you can sign and submit. Fastest, but it's still the
scrape-based per-user model behind glass.

### Path 3 — Native (recommended) — and this is how "login in the app" actually works
Skip scraping entirely and talk to Lightning Bolt's **JSON API directly, on-device**:
- User types their Lightning Bolt username/password **in the app**; you do the OAuth token exchange;
  the token + refresh token live in the **iOS Keychain**. Credentials never leave the phone, no server.
- Fetch the schedule/feed endpoints (below), compute the same conflict logic (port it straight from
  `run.mjs` — it's plain JS/Swift-portable), render natively.
- **APNs** for real push (a light server or a service like OneSignal handles the push fan-out; the
  schedule polling can be **BGAppRefresh** on-device or a tiny per-user serverless poller).

This is private (no shared credential store), robust (real API, not DOM scraping), and it's the version
worth putting your name on.

---

## Lightning Bolt API — what we reverse-engineered
Host base is `*.lightning-bolt.com`. Auth is **OAuth bearer**.

**Login / token**
- Web login `https://lblite.lightning-bolt.com/login` redirects to the `s2.lightning-bolt.com` sign-in
  form (username/password; the React form ignores programmatic `value` sets — real keystrokes needed when
  scraping, irrelevant for a native OAuth call).
- `POST https://lbapi.lightning-bolt.com/token` → `{ access_token, token_type, expires_in, refresh_token }`.
  Use the `access_token` as `Authorization: Bearer …` on the calls below. Refresh with the refresh token.

**Data endpoints (Bearer)**
- `GET lblite.lightning-bolt.com/api/v1/dashboard` → `{ destinations, departments, applications,
  personnel, permissions, user, user_personnel, … }` (the logged-in user, group, etc.).
- `GET lbapi.lightning-bolt.com/subscription` → the saved schedule view: `{ id, customer_id, emp_id,
  sched_view_id, start_offset, end_offset, tz, … }` — defines the date window the viewer requests.
- `GET fd.lightning-bolt.com/employee_feed/{customerId}/{empId}` → the activity feed:
  `{ data: [ { type, timestamp, message, message_args:{a,d,h,t}, created_emp_id, emp_id, data } ] }`.
  Event `type`s include **`preswap_create`** (a shift offered = a swaportunity), `preswap_delete`
  (withdrawn), `preswap_finalized` (taken), plus `grant`, `grant_swap`, `replace_personnel`.
  In `message_args`: `a`=unit/assignment, `d`=date `YYYYMMDD`, `h`/`t`=hours/title; `created_emp_id`=offerer.
- `GET lbapi.lightning-bolt.com/schedule/range/…` → slots:
  `{ slot_id, emp_id, assign_id, slot_date, start_time, stop_time, status, work_units, template, template_id,
     display_name, **emp_request_id**, **emp_request_status**, … }`. Offered shifts carry an
  `emp_request_id`. This is the schedule the group Viewer renders (with the "wifi" pickup icon).

**Accepting a shift (the deep link) — SOLVED**
- Deep link (confirmed against a real Lightning Bolt decline email):
  `https://lblite.lightning-bolt.com/login/?origin=https://lblite.lightning-bolt.com/login&origin_hash=swop/<ID>/accept`
  (action = `accept` or `decline`) — a logged-in user is routed to `origin_hash = swop/<ID>/<action>`.
- **`<ID>` is the offered shift's `slot_id`** (verified: the id in the email == the slot's `slot_id`). It is
  NOT `emp_request_id` — that field exists but is a different thing.
- **Getting slot_id token-free:** the web app keeps the loaded schedule in `window.LbsAppData.Slots` (a
  Backbone collection). Open swaportunities are the slots with `attributes.is_pending === true`; read
  `attributes.slot_id`, `slot_date`, `start_time`/`stop_time`, `work_units`, `display_name`. The scraper
  (`run.mjs → harvestPendingSlots`) loads `/viewer/?dt=…` per affected week and reads this object.
- **For the native app:** you have the Bearer token in-app, so call `lbapi.lightning-bolt.com/viewerapi`
  (the endpoint the web viewer POSTs to) for the group's date window — the slots come back with `slot_id` and
  the pending flag directly, no DOM/scrape needed. Then build the same `swop/<slot_id>/accept` link (or hit the
  accept API). **The last 20% is done.**

---

## Conflict logic (reuse as-is)
It's in `stage2/run.mjs` (`interval`, `openInterval`, `flagFor`): build each shift as an absolute-minute
interval; an open shift is blocked if it overlaps/touches any of yours (closed intervals — finishing a
24 h at 08:00 conflicts with an 08:00 start). Post-call = the whole next day is a rest day. Straight to port.

## App Store / ethics checklist
- **Terms of service:** it reads a third-party system with the user's own login. Read PerfectServe/Lightning
  Bolt's terms; ideally ask them — a companion tool is often welcome, and official API access would make
  this bulletproof.
- **No credential storage on a server** if you can help it — native + Keychain is cleanest.
- **App Review:** companion apps for third-party services are fine; make clear the user brings their own
  account, and that "accept" happens in Lightning Bolt.
- **Data:** it surfaces colleagues' names/shifts (already visible to the group inside Lightning Bolt) — keep
  any hosted version access-controlled; on a native per-user app this is a non-issue.

---
Questions? The whole thing was built conversationally in Claude Code — open this folder in Claude Code and
just ask it to explain or extend any part.
