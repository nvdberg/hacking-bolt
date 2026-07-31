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
