# Working-Bolt web vs the iOS app: what the web is still missing

**Nothing crew-facing is missing any more (2026-11-18).** One deliberate difference: the return half of a swap is one click ("Take it") on the web, as it is in the app. Taking it automatically would need Lightning Bolt's accept call, which has never been captured, and we don't guess at writes to LB.

Checked 2026-11-17 against a full read of `hacking-bolt-ios/HackingBolt/*.swift` (build 118).
This covers crew features only. Owner/admin features (cover finder, colleague notes, earnings, You vs group, unit mix, pickups leaderboard, Admin screen) never go on the web.

## Texting: same as the app
- **Swap:** 💬 per person, "Text all" for the chosen day, "Text {first}" when composing a swap or pick-up (pick-up has its own wording), and a heads-up text after sending.
- **Give away:** 💬 per person, "Text the N picked", "Text everyone free (N)", and "Text {first}" after offering.
- The app has no "text everyone across all days" either. That could be a web extra ("and more").

## Built 2026-11-17 (items 1–9, plus 12 and the custom unit order from 13)
1. **Settings tab** (sidebar, key 6). Covers which tab it opens on, the Pool's default (All / For me), My posts mode, week start, appearance, Who's On unit order (↑/↓), the Time off page, Calendar sync, Export, Keep me signed in, About, and Sign out.
2. **Pool → My posts.** "Waiting for pickup" with Withdraw (asks first), and "Picked up" grouped by month from Supabase `pickups`.
3. **Swaps box** (Pool). Covers Accept swap and Decline (both open LB's own page in a sheet, so the user's click there is the approval), "Take it" for the return half, and OK to dismiss a swap that was declined.
4. **Not offered to you.** Shown in the All list from `open_shifts`, read-only, with an "Unable to accept" explanation.
5. **Time Off page.** Upcoming and past, consecutive days grouped, decision text, "Cancel all N days", and a New request form (multi-date picker, days on the roster blocked) with review before sending.
6. **Keep me signed in.** Touch ID / Face ID (passkey PRF) or plain. Credentials are typed by the user and encrypted on the device.
7. **My stats** (Crew → My stats). Month by month, monthly average, coming up, year to date, year chips, custom range, and reorderable sections.
8. **Export.** This year, all time or custom: shifts as CSV or PDF, stats as CSV or PDF, or a calendar file (.ics).
9. **Calendar sync.** A subscribe link from `cal_subs`, with Google / Apple steps.

Also built:
- **Hennie holiday** on Today.
- A **Swap or give away** button on Crew that picks one of your shifts.

## Built 2026-11-18 (items 10, 11, 13, 14)
10. **Cafeteria page** (Settings → More → Cafeteria menu, or "Full menu ›" on Today's widget). RGH / Pasqua, ‹ Today ›, and ← → T on the keyboard. Lunch and its sides come first, lunch and supper features are highlighted, and "Menu week N of M" is shown.
11. **How to use Working-Bolt** (Settings → More). A web version of the app's guide, crew features only, with search that filters as you type. Like Guide.swift, keep it current: every crew-visible web change adds a line to `GUIDE` in `wb.js`.
13. **Who's On: hold or right-click your own shift.** Only shifts that haven't started, aren't pending and aren't buddy shifts. The menu offers Find a swap… and Give it away…. Pasqua MSU goes as the 24 h with Rapid, as in the day panel.
14. **Notifications (Web Push).**
    - Settings → Notifications opens `https://nvdberg.github.io/hacking-bolt/#push=<emp>`. That page asks the browser for permission, registers `sw.js`, subscribes with the VAPID public key and stores the subscription with `rpc/web_push_subscribe`. `#push=off` turns it off.
    - The poller (`stage2/run.mjs` → `stage2/webpush.mjs`) sends the same alerts as APNs: Open: … to everyone, Swap offer / Offered to you / Swap back to the person they're aimed at, and Picked up: … to the giver. Subscriptions that are gone (404/410) are pruned.
    - It needs the CI secret `VAPID_PRIVATE_KEY`. The key lives in `~/.working-bolt/vapid.json`, never in the repo.
    - iPhone Safari only allows push for home-screen apps, so phones keep using the app.

## App-only (no need on the web)
- Splash screen and its length setting.
- Witty lines editor.
- App icon picker.
- TestFlight update banner.
