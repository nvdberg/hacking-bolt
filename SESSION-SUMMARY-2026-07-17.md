# Hacking-Bolt — session summary (2026-07-17, night)

_A "for us" handoff so we can continue tomorrow without re-deriving anything._

## What we did this session

**1. Cracked the direct-to-shift accept link (the last big open item).**
- Nicolaas supplied a real Lightning Bolt *decline* email link → decoded it to:
  `.../login/?origin=<login>&origin_hash=swop/1824880/decline`.
- Reverse-engineered live in his logged-in Chrome (read-only, never clicked Accept/Decline):
  - The deep-link `<ID>` is the offered shift's **`slot_id`** — proven because the email's `1824880`
    == the `slot_id` in the app's own data for Brian Geller's 7/19 PASQUA Rapid Resp.
  - Open swaportunities are the slots with **`is_pending === true`** in **`window.LbsAppData.Slots`**
    (a Backbone collection). Each carries `slot_id`, real `start_time`/`stop_time`, `work_units`,
    `display_name` (offerer). No auth token / no network-capture needed — just read the object.
  - Correct accept-link format (old `s2.lightning-bolt.com/?source=access…` was WRONG):
    `https://lblite.lightning-bolt.com/login/?origin=https://lblite.lightning-bolt.com/login&origin_hash=swop/<slot_id>/accept`
- Nicolaas's own tip ("click the wifi shift → Accept button bottom-left") is what led us to the popup
  whose React props exposed `slot_id`.

**2. Wired it into the scraper (`stage2/run.mjs`) and shipped it.**
- New `harvestPendingSlots()`: for each week that has an open feed shift, loads `/viewer/?dt=<mon>`,
  reads `LbsAppData.Slots` (is_pending), maps `slot_id` onto each open shift, builds the real accept link.
- Removed the old (never-worked) API-payload guessing + the wrong `s2` URL.
- Name-match uses the LAST whitespace token of the display name on both sides (handles Van der Berg etc.).
- Committed to `main`, pushed, ran the workflow. **First live run:**
  `slot-ids: 9 pending across 7 weeks; open=10 pickable=5 directIds=7/10`.
- Live site confirmed serving **7/10 direct links + 3 dashboard fallbacks**.
  App: https://nvdberg.github.io/hacking-bolt/ (home / pool.html / calendar.html / shifts.json).

**3. Refreshed Matt Butz's shareable package.**
- Copied the solved `run.mjs` in, scrubbed personal refs, updated `README` / `CLAUDE.md` / `ROADMAP`
  (direct link moved from "unsolved" → "here's how, + native-app shortcut via `lbapi/viewerapi`).
- Re-zipped `hacking-bolt-template.zip` (31 KB). Full scrub re-check = zero personal identifiers.
- Location: `/Nicolaas/Claude/Projects/LigthningBolt/hacking-bolt-template.zip`. Not sent yet — Nicolaas
  will email the ZIP or make a Dropbox "Copy link" himself (our MCP link tool only makes restricted links).

## Current state
- Everything is deployed and working. Scraper runs in GitHub Actions every 10 min (cloud — laptop can be off).
- ntfy topic `hackingbolt-nvdb-f1639408`, iPhone subscribed; pushes now carry direct accept links.
- Read-only throughout: links open LB's own accept screen, which still asks to confirm. Nothing auto-accepts.

## Open items / ideas for next time
1. **The 3 dashboard fallbacks** — feed entries that aren't currently `is_pending` (taken/withdrawn but still
   in the feed as NEW, or a name-match edge case). Optional refinement: make `is_pending` the source of truth
   so taken shifts drop off entirely instead of showing a fallback link.
2. **Send Matt the ZIP** (or a self-made Dropbox share link).
3. **On-demand "scrape now"** trigger (iOS Shortcut / serverless) for instant refresh vs the 10-min cron.
4. (Long-standing, optional) git-history scrub of the public repo — old data-carrying artifact HTML still
   lives in earlier history (a clean-history rewrite was classifier-blocked before; a fresh repo would do it).

_Durable facts are saved in memory (`project-lightningbolt.md`). This file is the narrative handoff._
