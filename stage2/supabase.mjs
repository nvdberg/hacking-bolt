// Supabase (PostgREST) helper for the poller — uses the SERVICE_ROLE key (bypasses RLS).
// Secrets (env): SUPABASE_URL, SUPABASE_SERVICE_KEY. Both stay in encrypted CI secrets, never in the repo.
// Backend holds shift logistics only — no patient data.
const URL_BASE = (process.env.SUPABASE_URL || '').replace(/\/$/, '') + '/rest/v1';
const KEY      = process.env.SUPABASE_SERVICE_KEY || '';

export function supabaseConfigured() { return !!(process.env.SUPABASE_URL && KEY); }

async function rest(path, { method = 'GET', body, prefer } = {}) {
  const headers = {
    apikey: KEY,
    authorization: `Bearer ${KEY}`,
    'content-type': 'application/json',
    ...(prefer ? { prefer } : {}),
  };
  const r = await fetch(URL_BASE + path, { method, headers, body: body ? JSON.stringify(body) : undefined });
  const text = await r.text();
  if (!r.ok) { console.log(`supabase ${method} ${path} → ${r.status} ${text.slice(0, 200)}`); return { ok: false, data: null }; }
  let data = null; try { data = text ? JSON.parse(text) : null; } catch {}
  return { ok: true, data };
}

/** Replace the shared open-shift set with the current one: upsert present slots, delete departed ones. */
export async function syncOpenShifts(open, nowIso) {
  if (!supabaseConfigured() || !Array.isArray(open)) return false;
  const rows = open.map(o => ({
    slot_id: Number(o.id), date: o.iso, unit: o.short,
    start_time: o.start || null, stop_time: o.stop || null,
    offerer: o.offerer || null, offerer_emp: o.offererEmp ?? null, updated_at: nowIso,
  }));
  if (rows.length) {
    const up = await rest('/open_shifts?on_conflict=slot_id', {
      method: 'POST', body: rows, prefer: 'resolution=merge-duplicates,return=minimal',
    });
    if (!up.ok) return false;
  }
  // delete rows whose slot_id is no longer open (taken/cancelled)
  const keep = rows.map(r => r.slot_id).filter(Number.isFinite);
  const filter = keep.length ? `slot_id=not.in.(${keep.join(',')})` : 'slot_id=gte.0';
  await rest(`/open_shifts?${filter}`, { method: 'DELETE', prefer: 'return=minimal' });
  return true;
}

/** All registered APNs device tokens. */
export async function deviceTokens() {
  if (!supabaseConfigured()) return [];
  const { ok, data } = await rest('/devices?select=apns_token');
  if (!ok || !Array.isArray(data)) return [];
  return data.map(d => d.apns_token).filter(Boolean);
}

/** Drop dead tokens APNs rejected (410/BadDeviceToken/Unregistered). */
export async function pruneTokens(tokens) {
  if (!supabaseConfigured() || !tokens?.length) return;
  const list = tokens.map(t => `"${t}"`).join(',');
  await rest(`/devices?apns_token=in.(${list})`, { method: 'DELETE', prefer: 'return=minimal' });
}

// ── Pickups (Working-Bolt "My Posts"): shifts that changed hands through the pool ───────────────────

/** Upsert detected pickups. `notified` is intentionally omitted so existing rows keep their notified state
 *  across re-syncs (only new rows fall to the column default false). */
export async function syncPickups(rows) {
  if (!supabaseConfigured() || !Array.isArray(rows) || !rows.length) return false;
  const up = await rest('/pickups?on_conflict=slot_id', {
    method: 'POST', body: rows, prefer: 'resolution=merge-duplicates,return=minimal',
  });
  return up.ok;
}

/** Pickups not yet pushed to their giver (so we notify each one exactly once). */
export async function unnotifiedPickups() {
  if (!supabaseConfigured()) return [];
  const { ok, data } = await rest('/pickups?notified=eq.false&select=*');
  return (ok && Array.isArray(data)) ? data : [];
}

/** Flag pickups as notified so they never push again. */
export async function markPickupsNotified(slotIds) {
  if (!supabaseConfigured() || !slotIds?.length) return;
  await rest(`/pickups?slot_id=in.(${slotIds.join(',')})`, {
    method: 'PATCH', body: { notified: true }, prefer: 'return=minimal',
  });
}

// ── Calendar sync (live subscribable feed) ──────────────────────────────────────────────────────────
// Subscribers enroll from the app (cal_subs: emp_id → stable token, enabled). The poller regenerates each
// enabled subscriber's .ics from the group schedule and uploads it to the public `calendars` Storage bucket
// at <token>.ics, so a Google/Apple subscription keeps itself current. Unguessable token → nothing public.

/** Enabled calendar subscribers: [{ emp_id, token }]. */
export async function readCalSubs() {
  if (!supabaseConfigured()) return [];
  const { ok, data } = await rest('/cal_subs?enabled=eq.true&select=emp_id,token');
  if (!ok || !Array.isArray(data)) return [];
  return data.filter(s => s.emp_id != null && s.token);
}

/** Upload (overwrite) a subscriber's .ics to the public `calendars` bucket. */
export async function uploadCalendar(token, ics) {
  if (!supabaseConfigured()) return false;
  const base = (process.env.SUPABASE_URL || '').replace(/\/$/, '');
  const r = await fetch(`${base}/storage/v1/object/calendars/${encodeURIComponent(token)}.ics`, {
    method: 'POST',
    headers: { apikey: KEY, authorization: `Bearer ${KEY}`, 'content-type': 'text/calendar', 'x-upsert': 'true' },
    body: ics,
  }).catch(() => null);
  if (!r || !r.ok) { if (r) console.log(`storage upload ${token} → ${r.status} ${(await r.text().catch(()=> '')).slice(0,120)}`); return false; }
  return true;
}

/** emp_id → [apns_token] map, for pushing a pickup only to the person who posted it. */
export async function deviceTokensByEmp() {
  if (!supabaseConfigured()) return {};
  const { ok, data } = await rest('/devices?select=emp_id,apns_token');
  const map = {};
  if (ok && Array.isArray(data)) for (const d of data) {
    if (d.emp_id == null || !d.apns_token) continue;
    (map[d.emp_id] ||= []).push(d.apns_token);
  }
  return map;
}
