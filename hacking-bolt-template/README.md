# ⚡ Hacking-Bolt

A companion tool for physicians who pick up shifts through **Lightning Bolt** (PerfectServe).

Lightning Bolt's swap board ("swaportunities") is hard to scan — it's sorted by *when things were
posted* and mixes in shifts already taken. Hacking-Bolt turns it into a **clean, live board of only the
shifts you can actually pick up**, and **pushes your phone** the moment a new one appears.

> Built with Claude Code. This is a **scrubbed copy** for you (Matt) — no one else's login, name, or
> roster. The unit names/colours are already set for **Critical Care Associates** (our group), so you
> mostly just add your own Lightning Bolt login and go. It auto-personalises to whoever logs in.

---

## What it does (built & working)
- **Headless scraper** (Playwright/Node): logs into Lightning Bolt with *your* credentials, reads the
  SWAPORTUNITY feed **and** your roster, and works out which open shifts you can realistically take.
- **Real conflict logic** (compares actual shift *hours*): `Post-call` (whole day after a 24 h = rest,
  nothing pickable), `Pre-call` (a 24 h that ends when your next shift starts = blocked), `Overlap`
  (already working = blocked), everything else = **Available**.
- **Live web app** (GitHub Pages, free): Home + Shift Pool (bird's-eye mini-calendars + colour-coded
  list; tap a free shift to open it in Lightning Bolt) + My Shifts calendar (24 h calls fuse into a
  lighter post-call bar). Full-screen, add-to-home-screen, portrait + landscape.
- **Auto-refresh ~10 min** via GitHub Actions (session persisted between runs).
- **Phone push** via [ntfy](https://ntfy.sh) when a new *pickable* shift appears.
- **Read-only & safe:** never accepts/declines for you — accepting is a deep-link into Lightning Bolt.
  Only surfaces data you can already see in your own account.

```
GitHub Actions (cron ~10 min)
  → run.mjs (Playwright): log in → scrape feed + roster → compute conflicts → write site/shifts.json
  → publish site/ to GitHub Pages  → your live web app (Home / Pool / Calendar)
  → new pickable shift vs last run? → POST to ntfy → your phone buzzes
```

---

## Two ways to run it

### A) Your own GitHub (the web app — ~15 min) ← start here
You'll need **your own GitHub account** (the robot + hosting live there; it's free). Full steps are in
**[`stage2/README.md`](stage2/README.md)** — in short:
1. Put this folder in **your** GitHub repo.
2. Add secrets **`LB_USER`**, **`LB_PASS`**, **`NTFY_TOPIC`** (your Lightning Bolt login + a random ntfy topic).
3. Turn on **Pages → GitHub Actions**, subscribe the **ntfy** app to your topic, run the workflow.
4. Open your Pages URL on iPhone → **Share → Add to Home Screen**.

> Note on privacy: GitHub Pages hosting is free only on **public** repos (or private with GitHub Pro).
> A public repo means the page is reachable by URL (already group-visible data, but be aware). See the
> deploy README for the trade-offs. Push notifications work either way.

### B) The Apple / native route (a real App Store app) ← for a "login in the app" experience
If you want people to **log in inside the app** and see their own data (no GitHub, credentials never
leaving the phone), that's a **native iOS app** — a great fit for your Apple Developer account. The whole
architecture, the Lightning Bolt API we reverse-engineered, and the build options are in
**[`ROADMAP-formal-app.md`](ROADMAP-formal-app.md)**.

**Why not just a login box on this web app?** A static page can't log into Lightning Bolt and scrape by
itself (browser security + no server). In-app login needs either a per-user backend or an on-device
native app — hence the two paths above.

---

## Configure (mostly optional — it's pre-set for our group)
- **Units/hours/colours:** `stage2/run.mjs` → the `UNITS` map (and the same in `stage2/site/*.html`).
- **Refresh interval:** the `cron` in `.github/workflows/refresh.yml` (10 min = fine on a public repo).

## Not finished yet
- **On-demand "scrape now"** — refreshes every ~10 min; instant-refresh needs a small trigger (iOS
  Shortcut or serverless function).

## Recently solved
- **Direct-to-shift accept link** — tapping an open shift now jumps straight to Lightning Bolt's own accept
  screen (which still asks you to confirm — nothing auto-accepts). The link uses the shift's `slot_id`, read
  token-free from the group viewer's in-memory data. See `ROADMAP-formal-app.md` / `CLAUDE.md` for the how.

## Ethics / terms
Uses **your own credentials**, is **read-only**, shows only what you can already see, and accepting a
shift happens **in Lightning Bolt**. Before publishing anything (especially to the App Store), check
PerfectServe/Lightning Bolt's terms — and consider just asking them; a well-behaved companion tool is
often welcome.
