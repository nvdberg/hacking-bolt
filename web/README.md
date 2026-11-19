# Working-Bolt for the web

The Working-Bolt app, in a computer's browser. It runs on top of Lightning Bolt's own site, uses your own sign-in there, and reads your roster live in your browser. No roster data, names or secrets are stored in this folder or on the website.

**Goal:** everything the iOS app does, and more. What the web still lacks compared with the app is tracked in [PARITY-GAPS.md](PARITY-GAPS.md); nothing crew-facing is missing right now.

## Where it lives

| Address | Notes |
|---|---|
| https://working-bolt.github.io/ | Main address. Free GitHub organization `working-bolt`, repo `working-bolt/working-bolt.github.io`. |
| https://nvdberg.github.io/hacking-bolt/ | The original address, still live. Browser notifications are tied to this one. |
| `…/?demo` (either address) | Sample mode: made-up shifts and names, nothing sent anywhere. Use this for all testing. |

How someone starts it: open the page, drag the **Working-Bolt** button to the bookmarks bar, sign in to Lightning Bolt as usual, then click the bookmark. It opens over Lightning Bolt in its own window (a Shadow DOM, so it never mixes with Lightning Bolt's page).

## Files

| File | What it is |
|---|---|
| `wb.js` | The whole app: one self-contained script. Tabs, views, styles, the `GUIDE` (in-app help), and the demo data. |
| `index.html` | The landing page: bookmark button, `?demo` mode, and the notifications opt-in page (`#push=…`). |
| `sw.js` | Service worker that only shows notifications (no caching). |
| `manifest.json`, `icon.png`, `apple-touch-icon.png` | Home-screen name and the black bolt icon. When an icon changes, bump the `?v=` in index.html. |
| `PARITY-GAPS.md` | Web vs app comparison. |

## Publishing

- **Old address:** `.github/workflows/pages.yml` in this repo publishes `web/` on every push that touches it.
- **New address:** `working-bolt/working-bolt.github.io` holds only a workflow. It copies `web/` from this (public) repo and publishes it. It runs when triggered and once a day (09:17 UTC) as a catch-up. After a push, trigger it with:
  `gh workflow run pages.yml -R working-bolt/working-bolt.github.io`
- If a deploy fails with "No artifacts named github-pages", it's a GitHub glitch: re-run it (`gh run rerun <id>`) or the next push fixes it.

## What's in it (sidebar, keys 1–8)

1. **Today** — next shift, this month's hours, doctors on call, weather, Who's On today, Hennie holiday, cafeteria menu. Customizable.
2. **Shift Pool** — All / For me, swaps box, My posts (withdraw, picked up), recently taken. "Take it" opens Lightning Bolt's own accept page.
3. **My Shifts** — scrollable months; pick one or many days for day/night off, busy, give away, ask to swap.
4. **Who's On** — units as rows, days scrolling sideways, unit phones, On call switch. Trackpad: sideways swipes follow your fingers; up/down only scrolls when the board doesn't fit.
5. **Crew** — side-by-side board with colleagues you pick; swap or give away.
6. **My Stats** — month by month, averages, year to date, export. Cards pack tightly and drag by their titles.
7. **Cafeteria** — RGH / Pasqua menus: lunch with sides, pizza, soup, supper with sides.
8. **Settings** — preferences, Who's On order, time off, calendar sync and live calendar links, export, notifications, keep me signed in, the guide, about. Cards drag like My Stats.

Also: Edit layout (E) to move and resize blocks, keyboard shortcuts (?), light/dark/system.

## Backend pieces it uses

- **Supabase** (same project as the apps): `pickups`, `open_shifts`, `cal_subs`, the `ics-proxy` function (relays iCal links; allow-listed hosts, 5 MB cap, stores nothing), and `web_push` with the `web_push_subscribe` / `web_push_unsubscribe` functions (`stage2/web_push.sql`).
- **Notifications** are sent by the poller through `stage2/webpush.mjs`. The VAPID private key lives outside the repo; CI uses the secret `VAPID_PRIVATE_KEY`.

## Rules that never change

- The user's own click is the approval. Every write to Lightning Bolt asks first in Working-Bolt, and accepting goes through Lightning Bolt's own page. Nobody (and no tool) accepts or declines on someone's behalf.
- Passwords are typed by the user and kept only on their device.
- No owner/admin features on the web, ever.
- Never send anything to Lightning Bolt while testing — test in `?demo`.
- Crew-visible changes update the `GUIDE` in `wb.js`.
- Leak-scan before every commit: no emails, names or keys in this public repo.

## Open items

- **Notifications sign-up check:** `web_push_subscribe` doesn't check who's asking, so someone who knows another person's Lightning Bolt ID could sign up for their alerts. A Supabase change; waiting on the owner's go (could join the planned Supabase lockdown).
- **Return half of a swap** stays one click ("Take it"), as in the app.
- Today view runs ~14 px wide on very narrow (≈340 px) windows.
