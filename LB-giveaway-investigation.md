# "Give away a shift" (post/offer) — Lightning Bolt investigation

Investigated 2026-07-21 (read-only; **no shift was ever posted/submitted** — only read your own data and
opened dialogs without confirming). Goal: figure out how to add a "Give away / offer" button (Matt's request).

## What's confirmed

- **Accept (already done in the app)** = deep-link `dashboard/#/swop/<slot_id>/accept` → opens Lightning
  Bolt's own accept dialog (the app's AcceptSheet). Works because the slot is an existing *pending*
  swaportunity.
- **Router:** `swop/:slot_id/:swop_action` → `openSwop` → `openSwopReview(slot_id, action)` → fetches the
  slot, opens a "preswap-pending" dialog with `{action, slots:[slot]}`. Action tokens seen in JS:
  `accept, decline, cancel, finalize, open, post, create`.
- **Creating an offer = POST `/schedule/preswap`** — a Backbone collection (`url: <prefix>/schedule/preswap`)
  whose `save()` does `sync("create")`. So there IS a clean create endpoint.
- **Auth:** `window.LbsAppData.AppContext.session.get('token')` = the Bearer JWT (591 chars); header is
  `Bearer <token>`. (`session.get('auth')` is just a boolean flag — not the token.)
- **My shifts + slot_ids** are readable via `lbapi.lightning-bolt.com/schedule/range/?...&emp_id=20147`
  (e.g. CCU 2026-07-30 = slot 1788915; Rapid Response 2026-07-29 = 1788934).

## The catch — why "give away" is harder than accept

- **`swop/<my_slot_id>/open` opens an "Open" dialog but it renders EMPTY** (title + SUBMIT only) in the
  `dashboard/` app. The dashboard is the lightweight "login" app (`LbsAppData.id === "login"`) — it lacks the
  personnel/schedule data the offer form needs. So **creating an offer is NOT a clean deep-link** the way
  accept is; it lives in the full **viewer/maker** app (MY SCHEDULE → click your shift → offer).
- The exact `/schedule/preswap` payload field names are NOT the obvious guesses (no `pending_type`,
  `personnel_ids`, `all_personnel`, etc. in the minified bundles) — they're inside the minified preswap model
  (webpack module 88815), which regex-extraction couldn't cleanly pull.
- Targeting (offer to **one specific person vs everyone**) exists in the UX (Matt confirmed) but the exact
  fields weren't pinned down.

## Two ways to build it (future)

1. **Integrated (what Matt wants):** app builds the `/schedule/preswap` POST (slot_id + recipients + notify)
   and sends it after an **explicit in-app confirm**. Most seamless, but: (a) needs the exact payload, (b) a
   recipient-picker UI, (c) it's "the app performs the post," a bigger step than accept (which completes on
   LB's own screen) — worth a ToS gut-check before shipping to the group.
2. **Safe shortcut:** open LB's own MY SCHEDULE / offer screen in a web view and let the user offer the shift
   there. Lower value (mostly a shortcut) and the deep-link renders empty, so it'd have to land on MY SCHEDULE,
   not the offer dialog.

## Cleanest way to unlock #1 next time
**Capture the real payload from a genuine offer:** next time you actually want to give a shift away, do it on
Lightning Bolt normally while the network panel is watched — the `/schedule/preswap` POST body reveals the
exact field names + how "specific person vs everyone" is encoded. Then the integrated feature is
straightforward to build. (No guessing, no test-posting.)

## Payload — cracked from the code (static, 2026-07-21)

- **Offer a shift = a "preswap" with `type: "preswap_create"`** (webpack model module 25131, base 23319,
  **`idAttribute: "slot_id"`**). Its icon in the UI is `fa-rss` (the "post to feed" icon) — confirms
  preswap_create = *post/offer*.
- The full swop-preswap family (base model 23319, all keyed by `slot_id`):
  `preswap_create` (offer), `preswap_accept`, `preswap_deny`, `preswap_delete` (withdraw), `preswap_finalize`.
- **Recipients are per-person:** a slot's `pending_info.preswaps` = list of `{emp_id, response}`
  (`response`: 1 = declined, 2 = accepted, 3 = finalized). So offering to N people creates N preswap entries;
  you can target **specific people** (and presumably "all" = everyone eligible).
- **Endpoint:** POST to `<prefix>/schedule/preswap` (Backbone collection 53126/88815 family, `sync("create")`).
  Prefix from `getPrefix()` = `https://lbapi.lightning-bolt.com`.
- **Auth:** `Bearer ` + `LbsAppData.AppContext.session.get('token')`.
- **Likely POST body skeleton (to CONFIRM via dry-run):**
  `{ slot_id, type:"preswap_create", pending_emp_id / recipient emp_id(s), + maybe assign_id, start/stop, notify }`.
  The exact required-field set + how "specific vs all" is encoded is the ONLY gap left.

## Confirm-the-payload plan (when Nicolaas is back — ~1 min, no real offer posted)
1. Nicolaas opens the real offer flow in LB (My Schedule / the offer dialog), picks the shift + a recipient,
   **stops before Submit**.
2. Claude injects a fetch/XHR interceptor on that page that, on `POST …/schedule/preswap`, **captures the body
   and aborts the send** (request never reaches LB → no offer created; expected "failed" toast).
3. Nicolaas hits Submit → exact payload captured → build the real feature.

## Two build approaches (decide after the capture)
- **A — safe (preferred if viable):** app opens LB's *own* offer dialog for the slot in a web view (like
  AcceptSheet); user picks recipients + submits on LB's screen. App never posts. Needs the offer dialog to
  render in the app's web-view context (it renders empty only in the lightweight `dashboard` app — should work
  in the viewer/maker context).
- **B — integrated (Matt's ideal):** app builds the `preswap_create` POST + a recipient picker, sends after an
  in-app **confirm dialog**. Reversible (cancel/withdraw = `preswap_delete`). Needs the confirmed payload +
  a ToS gut-check (app performs the post, a step beyond accept).

## Status
Mechanism ~90% mapped from code; **payload skeleton known, one dry-run to confirm exact fields.** Not built yet
(deliberately). No account changes were made — read-only throughout.
