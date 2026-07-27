# Hacking-Bolt — orientation for Claude Code

You're helping the user (a physician in the **Critical Care Associates** ICU group) deploy or extend
**Hacking-Bolt**: a companion tool that scrapes their **Lightning Bolt** swaportunity (shift-swap) board,
publishes a live open-shift web app on GitHub Pages, and pushes their phone (ntfy) when a shift they can
actually pick up appears. **Read `README.md` and `ROADMAP-formal-app.md` first** — they have the full
architecture and the Lightning Bolt API map we reverse-engineered.

## Most likely task: deploy the user's own web copy (~15 min)
This exact sequence worked cleanly for the original author — follow it:
1. **GitHub CLI:** `brew install gh` (non-interactive — you can run it). Then have the **user** run
   `gh auth login` themselves (interactive browser flow — you can't do it for them). Wait for "done".
2. **Create + push:** from the repo root, `gh repo create hacking-bolt --public --source=. --remote=origin --push`.
   Public repo = free GitHub Pages + unlimited Actions minutes. (Private needs GitHub Pro for Pages.)
3. **Secrets:** you may set `LB_USER` (their Lightning Bolt username) and a random `NTFY_TOPIC`
   (`gh secret set … --body …`). **The user sets `LB_PASS` themselves** — they run `gh secret set LB_PASS`
   and paste their password. **Never type or handle their Lightning Bolt password yourself.**
4. **Enable Pages:** `gh api --method POST /repos/<user>/hacking-bolt/pages -f build_type=workflow`.
5. **Push app:** have them install the **ntfy** iOS app and subscribe to the `NTFY_TOPIC` value.
6. **Run:** `gh workflow run refresh.yml`. To read logs, download the zip:
   `gh api /repos/<user>/hacking-bolt/actions/runs/<runId>/logs > /tmp/l.zip && unzip -p /tmp/l.zip`.
7. App is at `https://<user>.github.io/hacking-bolt/` → they open it on iPhone → Share → Add to Home Screen.

Verify a run printed `open=… pickable=… roster: … (NN shifts)` and that `shifts.json` is served.

## Gotchas learned the hard way
- **Login:** `/login` redirects to the `s2.lightning-bolt.com` sign-in form; its React fields ignore
  programmatic `value` sets — type **real keystrokes** and submit (click the button *and* press Enter as a
  fallback). Wait for the username field to appear before typing.
- **Response capture:** filter Lightning Bolt responses by real host (`new URL(u).hostname.endsWith('lightning-bolt.com')`)
  — the New Relic analytics URLs contain `ref=https://s2.lightning-bolt.com/` and pollute a naive substring match.
- **GitHub Pages** on the free tier works only on a **public** repo; keep the Pages steps `continue-on-error`.
- **CSS:** media queries don't add specificity — put responsive/portrait overrides **after** the base rules.
- **Free Actions minutes:** public = unlimited; private ≈ 2000 min/mo (so ~30-min cron max on private).
- The roster is cached (`roster.json`) and only re-scraped every ~12 h to keep runs fast.

## Direct-to-shift accept link — SOLVED (this is how it works)
Tapping an open shift jumps straight to Lightning Bolt's own accept screen (which still asks the user to
confirm — nothing auto-accepts). Confirmed against a real Lightning Bolt decline email:
- **Format:** `https://lblite.lightning-bolt.com/login/?origin=https://lblite.lightning-bolt.com/login&origin_hash=swop/<ID>/accept` (action = `accept` or `decline`).
- **`<ID>` is the offered shift's `slot_id`.**
- **Where slot_id comes from (token-free):** load the group viewer (`/viewer/?dt=YYYYMMDD`) and read
  `window.LbsAppData.Slots` — a Backbone collection of that week's slots. Every open swaportunity is a slot
  whose `attributes.is_pending === true`; its `attributes.slot_id` is the id (plus real `start_time`/`stop_time`,
  `work_units`, `display_name` = offerer). `LbsAppData.Slots` only holds the *loaded* week, so `run.mjs` loads
  one week per offered shift and reads it (`harvestPendingSlots`). No auth token or network-response capture needed.

## Safety (non-negotiable)
Read-only tool. **Never accept or decline shifts** on the user's behalf. **Never handle the user's password**
(they set `LB_PASS` themselves). It uses only the user's own login and data they can already see in Lightning
Bolt.
