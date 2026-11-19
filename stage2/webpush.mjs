// Web Push for the Working-Bolt web version: the same alerts the apps get over APNs, sent to browsers that
// turned on notifications (Settings → Notifications on the web). Subscriptions live in Supabase `web_push`
// (no anon read; see web_push.sql). Secrets (env): VAPID_PRIVATE_KEY (CI secret) + SUPABASE_SERVICE_KEY.
import webpush from 'web-push';

export const VAPID_PUBLIC = 'BOu8Uld5q3LO65xqSF-YqTLMhTMfKaVspQYVxHiYEaIL-a-KKDgA83ry4nl0UDTwxJ6RKoD0X8q5UYCifmiqokc';
const SUBJECT = 'https://nvdberg.github.io/hacking-bolt/';
const BASE = (process.env.SUPABASE_URL || '').replace(/\/$/, '') + '/rest/v1';
const KEY = process.env.SUPABASE_SERVICE_KEY || '';

export function webPushConfigured() { return !!(process.env.VAPID_PRIVATE_KEY && process.env.SUPABASE_URL && KEY); }

async function rest(path, { method = 'GET', body } = {}) {
  const r = await fetch(BASE + path, { method, headers: { apikey: KEY, authorization: `Bearer ${KEY}`, 'content-type': 'application/json', prefer: 'return=minimal' }, body: body ? JSON.stringify(body) : undefined }).catch(() => null);
  if (!r || !r.ok) { if (r) console.log(`webpush: supabase ${method} ${path.split('?')[0]} → ${r.status}`); return null; }
  const t = await r.text(); try { return t ? JSON.parse(t) : []; } catch { return []; }
}

/** All browser subscriptions: [{ endpoint, p256dh, auth, emp_id }]. */
export async function webSubs() {
  if (!webPushConfigured()) return [];
  return (await rest('/web_push?select=endpoint,p256dh,auth,emp_id')) || [];
}
/** emp_id → [subscription]. */
export function bySubEmp(subs) {
  const m = {}; for (const s of subs) if (s.emp_id != null) (m[s.emp_id] ||= []).push(s); return m;
}

/**
 * Send one notification to many browsers.
 * @param {{endpoint:string,p256dh:string,auth:string}[]} subs
 * @param {{title:string, body:string, data?:object}} msg
 * @returns {Promise<{sent:number, failed:number, dead:string[]}>}  dead = endpoints the push service says are gone
 */
export async function webPushAll(subs, msg) {
  const out = { sent: 0, failed: 0, dead: [] };
  if (!subs?.length || !webPushConfigured()) return out;
  webpush.setVapidDetails(SUBJECT, VAPID_PUBLIC, process.env.VAPID_PRIVATE_KEY);
  const payload = JSON.stringify({ title: msg.title, body: msg.body, data: msg.data || {} });
  const one = async (s) => {
    try {
      await webpush.sendNotification({ endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } }, payload, { TTL: 6 * 3600, urgency: 'high' });
      out.sent++;
    } catch (e) {
      out.failed++;
      const code = e && e.statusCode;
      if (code === 404 || code === 410) out.dead.push(s.endpoint);
      console.log(`webpush: …${String(s.endpoint).slice(-8)} → ${code || (e && e.message) || 'error'}`);
    }
  };
  for (let i = 0; i < subs.length; i += 10) await Promise.all(subs.slice(i, i + 10).map(one));
  return out;
}

/** Drop subscriptions the push service rejected as gone. */
export async function pruneWebSubs(endpoints) {
  if (!endpoints?.length || !webPushConfigured()) return;
  for (const e of endpoints) await rest(`/web_push?endpoint=eq.${encodeURIComponent(e)}`, { method: 'DELETE' });
  console.log(`webpush: pruned ${endpoints.length} gone subscription(s)`);
}
