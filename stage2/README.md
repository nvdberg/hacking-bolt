# ⚡ Hacking-Bolt — always-on setup

Scrapes the Lightning Bolt swaportunity board every ~30 min, publishes a private open-shift page,
and **pushes a phone notification** the moment a shift you can actually pick up appears.

Runtime: **GitHub Actions (private repo) + GitHub Pages + ntfy push.** Free.

---

## What you need (10 min)
- Your GitHub account (already have it).
- The **ntfy** app on your iPhone (App Store, free) for push notifications.

---

## Step 1 — pick a push topic
1. Install **ntfy** on your phone.
2. In the app, tap **+** and subscribe to a **unique, hard-to-guess topic name**, e.g.
   `hackingbolt-nvdb-7q3x8k` (anyone who knows the topic can see the pushes, so make it random).
3. Remember it — it becomes the `NTFY_TOPIC` secret below.

## Step 2 — create a PRIVATE repo with these files
The repo needs `stage2/` and `.github/workflows/refresh.yml` at its root (this project folder already
has that layout). Create a **private** repo on GitHub and push this folder to it (or upload the files).

## Step 3 — add your secrets
Repo → **Settings → Secrets and variables → Actions → New repository secret**. Add three:
| Name | Value |
|---|---|
| `LB_USER` | your Lightning Bolt username (`nicolaasvanderberg@gmail.com`) |
| `LB_PASS` | your Lightning Bolt password |
| `NTFY_TOPIC` | the ntfy topic from Step 1 |

These are encrypted and only visible to the workflow — never in code, logs, or the page.

## Step 4 — turn on Pages
Repo → **Settings → Pages → Build and deployment → Source: GitHub Actions.**

## Step 5 — first run
Repo → **Actions → “Hacking-Bolt refresh” → Run workflow.**
When it finishes, open the **Pages URL** it prints (Settings → Pages) — that's your private board.
It then refreshes itself every ~30 min and pushes to your phone on new pickable shifts.

---

## Test locally first (recommended)
```bash
cd stage2
npm install
npx playwright install chromium
LB_USER='nicolaasvanderberg@gmail.com' LB_PASS='••••••' NTFY_TOPIC='your-topic' node run.mjs
```
Then look at `site/shifts.json` and the console output.

## ⚠️ Two things to verify on the first real run
1. **Login** — the script fills the username/password fields and clicks Sign in. If Lightning Bolt
   changed its login page, update the selectors in `run.mjs` (marked `TODO(verify)`).
2. **Direct accept links** — the console prints
   `directIds=X/Y` and, if any are missing, `TODO(verify) swop-id — captured payload URLs: [...]`.
   **Send Claude that output** — it's the last piece to turn each card into a straight-to-the-shift
   accept link. Until then, cards open the Lightning Bolt dashboard (still works, just one extra step).

## Good to know
- **Frequency:** `*/30` in `refresh.yml`. Faster than ~30 min will exceed GitHub's free private minutes —
  for true 10-min private, move the same script to a tiny always-on VM (Oracle Always-Free is $0).
- GitHub **pauses scheduled workflows after 60 days of no repo activity** — just re-enable them.
- The roster re-scrapes every 12 h; the swaportunity feed is checked every run.
- Nothing here ever accepts/declines on your behalf — it only reads and notifies.
