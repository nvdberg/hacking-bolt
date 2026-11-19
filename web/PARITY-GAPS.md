# Working-Bolt web vs the iOS app: what the web is still missing

Still open: 10 (cafeteria page), 11 (guide), 13 (long-press), 14 (push), and taking the return half of a swap automatically. On the web that is one click, "Take it".

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

## Missing: smaller items
10. **Cafeteria page.** The full menu with day arrows, Today, lunch and supper, and "week N of M". The web only shows today's menu in a widget.
11. **How to use Working-Bolt.** The guide page.
13. **Who's On.** Long-press your own shift for Find a swap / Give it away. The Crew button covers this for now.
14. **Notifications.**
    - The app gets push for new open shifts and for "your shift was picked up".
    - The web would need Web Push (a service worker plus server work). It's a bigger job, so it's listed last.

## App-only (no need on the web)
- Splash screen and its length setting.
- Witty lines editor.
- App icon picker.
- TestFlight update banner.
