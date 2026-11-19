// lb-relay — lets the Working-Bolt web page (working-bolt.github.io) work with Lightning Bolt without the bookmark.
// Browsers only let Lightning Bolt's own site talk to Lightning Bolt, so a page anywhere else needs a relay.
//
// What it does, and nothing more:
//   login   {u, p}          → signs in exactly the way Lightning Bolt's own LOGIN button does (POST /api/v1/login),
//                              then trades that sign-in for Lightning Bolt's access + refresh keys, the way its site does.
//   refresh {rt}            → swaps a refresh key for fresh keys (Lightning Bolt's keys last about an hour).
//   api     {t, m, path, b} → passes one Lightning Bolt API call through with the person's own access key.
//                              Only the read and write calls Working-Bolt itself makes are allowed (see ROUTES).
//
// Safe by design: it stores nothing, logs nothing (never the password, keys or roster data), only answers the
// Working-Bolt pages, only talks to lightning-bolt.com, and every write is one the person confirmed in Working-Bolt.

const LBAPI = Deno.env.get('LB_API_BASE') || 'https://lbapi.lightning-bolt.com';      // overridable for local tests only
const LITE = Deno.env.get('LB_LITE_BASE') || 'https://lblite.lightning-bolt.com';
const CLIENT_ID_FALLBACK = '1bc4e40b-0373-42a8-bfed-979f10b0743a';                     // Lightning Bolt's public web app id (its env.js)
const ORIGINS = new Set(['https://working-bolt.github.io', 'https://nvdberg.github.io', ...(Deno.env.get('EXTRA_ORIGINS') || '').split(',').filter(Boolean)]);
const ROUTES: Record<string, RegExp[]> = {
  GET: [/^\/schedule\/range\/\?[\w=&%.-]*$/, /^\/request\/range\/\?[\w=&%.-]*$/, /^\/personnel\/$/, /^\/user\/check_token$/],
  POST: [/^\/schedule\/update$/, /^\/schedule\/preswap$/, /^\/schedule\/split$/, /^\/request$/],
};
const MAX_IN = 256 * 1024, MAX_OUT = 25 * 1024 * 1024, TIMEOUT = 60000;

const cors = (origin: string) => ({
  'Access-Control-Allow-Origin': origin, 'Vary': 'Origin', 'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Max-Age': '86400',
});
const json = (origin: string, status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors(origin), 'Content-Type': 'application/json', 'Cache-Control': 'no-store' } });

let clientId = '';
async function getClientId(): Promise<string> {
  if (clientId) return clientId;
  try {
    const r = await fetch(LITE + '/env.js', { signal: AbortSignal.timeout(8000) });
    const m = /"APPLICATION_CLIENT_ID"\s*:\s*"([\w-]+)"/.exec(await r.text());
    if (m) clientId = m[1];
  } catch { /* fall back */ }
  return clientId || CLIENT_ID_FALLBACK;
}

// Lightning Bolt's own key endpoint (OAuth): {grant_type, ...} → {access_token, refresh_token, expires_in}
async function tokenGrant(fields: Record<string, string>, ua: string) {
  const body = new URLSearchParams({ ...fields, client_id: await getClientId() });
  const r = await fetch(LBAPI + '/token', {
    method: 'POST', body, signal: AbortSignal.timeout(TIMEOUT),
    headers: { 'Content-Type': 'application/x-www-form-urlencoded;charset=UTF-8', Accept: 'application/json', 'User-Agent': ua },
  });
  if (!r.ok) return { status: r.status, keys: null };
  const j = await r.json().catch(() => null);
  if (!j || !j.access_token) return { status: 502, keys: null };
  return { status: 200, keys: { t: String(j.access_token), rt: j.refresh_token ? String(j.refresh_token) : '', exp: Number(j.expires_in) || 3600 } };
}

// Keep the cookies Lightning Bolt hands out during sign-in, the way a browser would (in memory, for this one request).
function eatCookies(jar: Map<string, string>, r: Response) {
  for (const c of r.headers.getSetCookie()) {
    const kv = c.split(';')[0], i = kv.indexOf('=');
    if (i > 0) jar.set(kv.slice(0, i).trim(), kv.slice(i + 1).trim());
  }
}
const cookieHeader = (jar: Map<string, string>) => [...jar].map(([k, v]) => `${k}=${v}`).join('; ');
const lbHost = (u: URL) => u.protocol === 'https:' && /(^|\.)lightning-bolt\.com$/.test(u.hostname) || LITE.startsWith('http://') && u.origin === new URL(LITE).origin;

async function login(u: string, p: string, ua: string) {
  const jar = new Map<string, string>();
  const r = await fetch(LITE + '/api/v1/login', {
    method: 'POST', redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT),
    headers: { 'Content-Type': 'application/json', Accept: 'application/json', 'User-Agent': ua, Origin: LITE, Referer: LITE + '/login' },
    body: JSON.stringify({ login_name: u, login_pwd: p }),
  });
  eatCookies(jar, r);
  if (r.status === 401 || r.status === 403) {
    const j = await r.json().catch(() => ({}));
    return { status: 401, body: { error: 'rejected', message: typeof j?.message === 'string' ? j.message.slice(0, 300) : '' } };
  }
  if (r.status !== 200) return { status: 502, body: { error: 'failed', where: 'login', lb: r.status } };
  const j = await r.json().catch(() => ({}));

  // Lightning Bolt's site then opens the page it was told to (j.url) and reads its refresh key from the LB_TKN cookie.
  // Follow the same pages (GET only, lightning-bolt.com only, a few hops) until that cookie shows up.
  let next: URL | null = null;
  try { next = new URL(j && j.url ? String(j.url) : '/dashboard/', LITE); } catch { next = null; }
  for (let hop = 0; hop < 6 && next && !jar.has('LB_TKN') && lbHost(next); hop++) {
    const g = await fetch(next, { redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT), headers: { 'User-Agent': ua, Cookie: cookieHeader(jar), Accept: 'text/html,application/json' } }).catch(() => null);
    if (!g) break;
    eatCookies(jar, g);
    await g.body?.cancel();
    const loc = g.status >= 300 && g.status < 400 ? g.headers.get('location') : null;
    next = loc ? new URL(loc, next) : null;
  }
  const rt = jar.get('LB_TKN');
  if (rt) {
    const g = await tokenGrant({ grant_type: 'refresh_token', refresh_token: decodeURIComponent(rt) }, ua);
    if (g.keys) return { status: 200, body: g.keys };
  }
  // Older route Lightning Bolt's site also has: the same username and password straight to the key endpoint.
  // Only tried after LB has just accepted them, so it can't add a failed attempt.
  const g = await tokenGrant({ grant_type: 'password', username: u, password: p }, ua);
  if (g.keys) return { status: 200, body: g.keys };
  return { status: 502, body: { error: 'failed', where: 'token', lb: g.status, cookie: !!rt } };
}

async function passThrough(origin: string, t: string, m: string, path: string, b: unknown, ua: string) {
  const ok = (ROUTES[m] || []).some(rx => rx.test(path));
  if (!ok) return json(origin, 400, { error: 'route' });
  const init: RequestInit = { method: m, redirect: 'manual', signal: AbortSignal.timeout(TIMEOUT), headers: { Authorization: 'Bearer ' + t, Accept: 'application/json', 'User-Agent': ua } };
  if (m === 'POST') { (init.headers as Record<string, string>)['Content-Type'] = 'application/json'; init.body = JSON.stringify(b ?? null); }
  const r = await fetch(LBAPI + path, init).catch(() => null);
  if (!r) return json(origin, 504, { error: 'unreachable' });
  if (Number(r.headers.get('content-length') || 0) > MAX_OUT) { await r.body?.cancel(); return json(origin, 413, { error: 'too large' }); }
  const text = await r.text();
  if (text.length > MAX_OUT) return json(origin, 413, { error: 'too large' });
  return new Response(text, { status: r.status, headers: { ...cors(origin), 'Content-Type': r.headers.get('content-type') || 'application/json', 'Cache-Control': 'no-store' } });
}

Deno.serve(async (req) => {
  const origin = req.headers.get('origin') || '';
  if (!ORIGINS.has(origin)) return new Response('Working-Bolt pages only', { status: 403 });
  if (req.method === 'OPTIONS') return new Response(null, { headers: cors(origin) });
  if (req.method !== 'POST') return json(origin, 405, { error: 'POST only' });
  if (Number(req.headers.get('content-length') || 0) > MAX_IN) return json(origin, 413, { error: 'too large' });
  let q: Record<string, unknown>;
  try { const raw = await req.text(); if (raw.length > MAX_IN) return json(origin, 413, { error: 'too large' }); q = JSON.parse(raw); } catch { return json(origin, 400, { error: 'bad request' }); }
  const ua = (req.headers.get('user-agent') || 'Working-Bolt web').slice(0, 300);
  const s = (k: string) => typeof q[k] === 'string' ? (q[k] as string) : '';
  try {
    if (q.op === 'login') {
      const u = s('u').trim(), p = s('p');
      if (!u || !p || u.length > 200 || p.length > 500) return json(origin, 400, { error: 'missing' });
      const r = await login(u, p, ua);
      return json(origin, r.status, r.body);
    }
    if (q.op === 'refresh') {
      if (!s('rt') || s('rt').length > 4000) return json(origin, 400, { error: 'missing' });
      const g = await tokenGrant({ grant_type: 'refresh_token', refresh_token: s('rt') }, ua);
      return g.keys ? json(origin, 200, g.keys) : json(origin, g.status === 400 || g.status === 401 ? 401 : 502, { error: 'expired', lb: g.status });
    }
    if (q.op === 'api') {
      const m = s('m') || 'GET';
      if (!s('t') || s('t').length > 8000 || !s('path')) return json(origin, 400, { error: 'missing' });
      return await passThrough(origin, s('t'), m, s('path'), q.b, ua);
    }
    return json(origin, 400, { error: 'op' });
  } catch {
    return json(origin, 502, { error: 'failed' });
  }
});
