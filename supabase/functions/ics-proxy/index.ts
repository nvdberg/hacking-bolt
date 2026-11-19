// ics-proxy — lets the Working-Bolt web version read a person's own calendar link (Google / Apple / Outlook
// "secret iCal address"). Browsers can't fetch those directly (no CORS), so this relays the text — nothing more.
// Safe by design: only HTTPS calendar hosts on the allow-list, redirects re-checked, 5 MB cap, the reply must be
// a real iCalendar file, and nothing is logged or stored (the link is a private address, so never log it).
const ALLOW = [/^calendar\.google\.com$/, /^p\d+-caldav\.icloud\.com$/, /^(www\.)?icloud\.com$/, /^outlook\.(office365|live|office)\.com$/, /^outlook\.office365\.us$/];
const CORS = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Methods': 'POST, OPTIONS', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type', 'Access-Control-Max-Age': '86400' };
const MAX = 5 * 1024 * 1024;
const bad = (s: number, m: string) => new Response(m, { status: s, headers: { ...CORS, 'Content-Type': 'text/plain' } });
const okHost = (u: URL) => u.protocol === 'https:' && !u.username && !u.password && (u.port === '' || u.port === '443') && ALLOW.some(r => r.test(u.hostname));

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS });
  if (req.method !== 'POST') return bad(405, 'POST only');
  let url: URL;
  try { const b = await req.json(); url = new URL(String(b.url || '').trim().replace(/^webcals?:\/\//i, 'https://')); } catch { return bad(400, 'Send {"url": "<calendar link>"}'); }
  if (!okHost(url)) return bad(400, 'Only Google, Apple (iCloud) and Outlook calendar links are supported');
  let r: Response | null = null;
  for (let hop = 0; hop < 4; hop++) {
    r = await fetch(url, { redirect: 'manual', headers: { 'User-Agent': 'Working-Bolt calendar reader', Accept: 'text/calendar, */*;q=0.5' } }).catch(() => null);
    if (!r) return bad(502, 'Calendar server not reachable');
    if (r.status >= 300 && r.status < 400 && r.headers.get('location')) {
      const next = new URL(r.headers.get('location')!, url);
      if (!okHost(next)) return bad(400, 'Calendar link redirected somewhere unexpected');
      url = next; continue;
    }
    break;
  }
  if (!r || !r.ok) return bad(r && r.status === 404 ? 404 : 502, `Calendar server said ${r ? r.status : 'nothing'}`);
  if (Number(r.headers.get('content-length') || 0) > MAX) return bad(413, 'Calendar too large');
  const reader = r.body!.getReader(); const parts: Uint8Array[] = []; let n = 0;
  for (;;) { const { done, value } = await reader.read(); if (done) break; n += value.length; if (n > MAX) { reader.cancel(); return bad(413, 'Calendar too large'); } parts.push(value); }
  const buf = new Uint8Array(n); let o = 0; for (const p of parts) { buf.set(p, o); o += p.length; }
  const text = new TextDecoder().decode(buf);
  if (!/^﻿?\s*BEGIN:VCALENDAR/.test(text)) return bad(422, 'That link is not an iCal calendar');
  return new Response(text, { headers: { ...CORS, 'Content-Type': 'text/calendar; charset=utf-8', 'Cache-Control': 'no-store' } });
});
