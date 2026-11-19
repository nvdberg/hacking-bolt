/* Working-Bolt for the web.
 *
 * Runs inside a Lightning Bolt tab you are already signed in to (started from the "Working-Bolt" bookmark),
 * or on its own page with sample data. Read-only: it never accepts, declines or changes anything — every
 * action opens Lightning Bolt's own screen. It never sees your password; it reads with the session the
 * Lightning Bolt page already has, and nothing leaves your browser except the calls Lightning Bolt itself makes.
 */
(function () {
  'use strict';
  if (window.__WB && window.__WB.show) { window.__WB.show(); return; }

  // ───────────────────────────── basics ─────────────────────────────
  const LB_HOST = /(^|\.)lightning-bolt\.com$/.test(location.hostname);
  const DEMO = !LB_HOST || !!window.WB_DEMO;
  const LBAPI = 'https://lbapi.lightning-bolt.com';
  const LITE = 'https://lblite.lightning-bolt.com';

  const UNITS = {
    MICU:  { short: 'MICU',         full: 'Medical ICU',                      color: '#41A00E' },
    SICU:  { short: 'SICU',         full: 'Surgical ICU',                     color: '#3A70EE' },
    CCU:   { short: 'CCU',          full: 'Coronary Care',                    color: '#BF3654' },
    PHICU: { short: 'PICU',         full: 'Pasqua ICU',                       color: '#0A7B71' },
    RR:    { short: 'RGH-Rapid',    full: 'Rapid Response',                   color: '#ED8207' },
    PRR:   { short: 'Pasqua-Rapid', full: 'Pasqua Rapid Response',            color: '#14C28B' },
    MSU:   { short: 'Pasqua-MSU',   full: 'Pasqua Medical Surveillance Unit', color: '#14C28B' },
  };
  const WHO_ORDER = ['RR', 'SICU', 'MICU', 'CCU', 'PHICU', 'PRR', 'MSU'];
  function unitKey(raw) {
    const r = String(raw || '').toUpperCase();
    if (r.includes('BUDDY')) return null;
    if (r.includes('PASQUA RAPID')) return 'PRR';
    if (r.includes('RAPID RESPONSE')) return 'RR';
    if (r.startsWith('MSU')) return 'MSU';
    if (r.startsWith('PHICU') || r.startsWith('PICU')) return 'PHICU';
    if (r.startsWith('MICU')) return 'MICU';
    if (r.startsWith('SICU')) return 'SICU';
    if (r.startsWith('CCU')) return 'CCU';
    return null;
  }

  // dates — "today" and month stamps are Regina time, whatever the laptop's zone
  function reginaISO(d) {
    const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Regina', year: 'numeric', month: '2-digit', day: '2-digit' }).formatToParts(d || new Date());
    const g = t => p.find(x => x.type === t).value;
    return `${g('year')}-${g('month')}-${g('day')}`;
  }
  function reginaHM() {
    return new Intl.DateTimeFormat('en-GB', { timeZone: 'America/Regina', hour: '2-digit', minute: '2-digit', hour12: false }).format(new Date());
  }
  const ord = iso => { const [y, m, d] = iso.split('-').map(Number); return Math.round(Date.UTC(y, m - 1, d) / 86400000); };
  const fromOrd = n => new Date(n * 86400000).toISOString().slice(0, 10);
  const addDays = (iso, n) => fromOrd(ord(iso) + n);
  const dow = iso => new Date(ord(iso) * 86400000).getUTCDay();           // 0 = Sunday
  const ymOf = iso => iso.slice(0, 7);
  const addMonths = (ym, n) => { let [y, m] = ym.split('-').map(Number); m += n; y += Math.floor((m - 1) / 12); m = ((m - 1) % 12 + 12) % 12 + 1; return `${y}-${String(m).padStart(2, '0')}`; };
  const daysIn = ym => { const [y, m] = ym.split('-').map(Number); return new Date(Date.UTC(y, m, 0)).getUTCDate(); };
  const MON = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const MONTH = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
  const DAY = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
  const DAYL = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
  const fmtDay = iso => `${DAY[dow(iso)]} ${MON[+iso.slice(5, 7) - 1]} ${+iso.slice(8, 10)}`;
  const monthTitle = ym => `${MONTH[+ym.slice(5, 7) - 1]} ${ym.slice(0, 4)}`;
  const stamp = iso => iso.replace(/-/g, '');

  // ───────────────────────────── conflict engine (same rules as the app) ─────────────────────────────
  const toMin = hm => { const p = String(hm).split(':').map(Number); return p.length >= 2 ? p[0] * 60 + p[1] : 0; };
  function interval(iso, s, e, ov) {
    const base = ord(iso) * 1440, S = toMin(s), E0 = toMin(e);
    let E = base + E0; if (ov || E0 <= S) E += 1440;
    return { s: base + S, e: E };
  }
  function openInterval(iso, k) {
    if (k === 'RR' || k === 'PRR') return interval(iso, '08:00', '17:00', false);
    if (k === 'MSU') return interval(iso, '17:00', '08:00', true);
    return interval(iso, '08:00', '08:00', true);
  }
  function scheduleModel(mine) {
    const ivs = [], post = {};
    for (const s of mine) {
      ivs.push({ iv: interval(s.date, s.start, s.end, s.ov), short: UNITS[s.unit].short });
      if (s.ov) post[addDays(s.date, 1)] = UNITS[s.unit].short;
    }
    return {
      flag(iso, unit, exact) {
        if (post[iso]) return `Post-call · off ${post[iso]}`;
        const o = exact || openInterval(iso, unit);
        let best = null;
        for (const m of ivs) if (m.iv.s <= o.e && m.iv.e >= o.s) {
          const rank = (m.iv.s < o.e && m.iv.e > o.s) ? 3 : (m.iv.e === o.s ? 2 : 1);
          if (!best || rank > best.rank) best = { rank, short: m.short };
        }
        if (!best) return null;
        return best.rank === 3 ? `You're on ${best.short}` : best.rank === 2 ? `Post-call · off ${best.short}` : `Pre-call · before ${best.short}`;
      },
    };
  }
  const hoursOf = s => { const iv = interval(s.date, s.start, s.end, s.ov); return (iv.e - iv.s) / 60; };
  const hrsLabel = s => { const h = hoursOf(s); return `${s.start}–${s.end} · ${h < 1 ? Math.round(h * 60) + ' min' : (Math.round(h * 2) / 2) + 'h'}`; };
  const fmtH = h => (Math.round(h * 10) / 10).toString().replace(/\.0$/, '');

  // ───────────────────────────── state ─────────────────────────────
  const today = reginaISO();
  const store = {
    get(k, d) { try { const v = localStorage.getItem('wb_' + k); return v == null ? d : JSON.parse(v); } catch (e) { return d; } },
    set(k, v) { try { localStorage.setItem('wb_' + k, JSON.stringify(v)); } catch (e) {} },
  };
  const WIDGETS = {
    next: 'Next shift', oncall: 'Doctors on call', agenda: 'The week ahead', pool: 'Shifts open to you', onnow: "Who's on today",
    weather: 'Weather · Regina', cafe: 'Cafeteria', month: 'This month', timeoff: 'Time off', hennie: 'Hennie holiday',
  };
  // Today is two columns. Cards can be dragged within and between them, or hidden; the layout is remembered.
  const DEFAULT_LAYOUT = { main: ['next', 'oncall', 'agenda', 'pool'], side: ['weather', 'onnow', 'hennie', 'cafe', 'month', 'timeoff'] };
  const OLD_WIDGETS = ['next', 'agenda', 'pool', 'onnow', 'weather', 'month', 'timeoff'];
  function freshLayout() { return { main: DEFAULT_LAYOUT.main.slice(), side: DEFAULT_LAYOUT.side.slice(), seen: Object.keys(WIDGETS) }; }
  function loadLayout() {
    let L = store.get('wlayout', null);
    if (!L || !Array.isArray(L.main) || !Array.isArray(L.side)) {
      const old = store.get('widgets', null);                       // the first version kept one flat list
      if (!Array.isArray(old)) return freshLayout();
      L = { main: [], side: [], seen: OLD_WIDGETS };
      old.forEach(w => { if (WIDGETS[w]) (DEFAULT_LAYOUT.main.includes(w) ? L.main : L.side).push(w); });
    }
    L.main = L.main.filter(w => WIDGETS[w]); L.side = L.side.filter(w => WIDGETS[w] && !L.main.includes(w));
    const seen = new Set(L.seen || OLD_WIDGETS);
    for (const w of Object.keys(WIDGETS)) {                        // a widget added since: show it in its default spot
      if (seen.has(w) || L.main.includes(w) || L.side.includes(w)) continue;
      const col = DEFAULT_LAYOUT.main.includes(w) ? 'main' : 'side', def = DEFAULT_LAYOUT[col];
      let at = 0;
      for (let k = def.indexOf(w) - 1; k >= 0; k--) { const j = L[col].indexOf(def[k]); if (j >= 0) { at = j + 1; break; } }
      L[col].splice(at, 0, w);
    }
    L.seen = Object.keys(WIDGETS);
    return L;
  }
  const CAL_COLORS = ['#7C5CFC', '#E11D74', '#0EA5E9', '#B45309', '#64748B', '#9333EA'];
  const S = {
    whoFlip: store.get('whoFlip', true) !== false,
    tab: window.WB_TAB || (store.get('openTab', 'last') !== 'last' ? store.get('openTab', 'last') : store.get('tab', 'today')),
    layout: loadLayout(), cafeSite: store.get('cafeSite', 'RGH'),
    oncall: (store.get('oncall', null) || {}).rows || null, cafe: (store.get('cafe', null) || {}).pages || null,
    customizing: false, weather: null,
    cals: store.get('cals', []),
    theme: store.get('theme', 'system'),
    weekStart: store.get('weekStart', 0),
    me: '', emp: '',
    mine: [], open: [], group: [], requests: [],
    status: 'idle', note: '', updated: null,
    poolSeg: store.get('poolDefault', 'all'), unitsOff: new Set(store.get('unitsOff', [])), selPool: null,
    msMonth: ymOf(today), poolDay: null, msGo: ymOf(today), msTop: null, whoGo: addDays(today, -2), whoLeft: null, whoDate: null, whoStart: null, highlight: '', whoDocs: store.get('whoDocs', false),
    crew: store.get('crew', []), crewLeft: null, crewGo: null, crewQuery: '', crewOpen: false,
    busyDays: store.get('busyDays', {}),            // date → note — days you marked busy (this browser only, like the app)
    offerTargets: store.get('offerTargets', {}),
    multi: [],                                     // My Shifts: days picked together (drag / Shift / ⌘-click)
    taken: null, showTaken: store.get('showTaken', true) !== false, takenOpen: false,
    openTab: store.get('openTab', 'last'), poolDefault: store.get('poolDefault', 'all'), postsMode: store.get('postsMode', 'auto'), setPage: null,
    swapNotes: [], swapSeen: store.get('swapSeen', []), swapSettled: store.get('swapSettled', []), swapDismissed: store.get('swapDismissed', []),
    notOffered: null, myPickups: null, calSub: null, calSubState: 'idle', toNew: null,
    crewSeg: 'side', hist: store.get('hist', null), histBusy: false, histFailed: false,
    statsOrder: store.get('statsOrder', []), setOrder: store.get('setOrder', []), statsOpen: new Set([ymOf(today)]), statsReorder: false, statsYear: null, statsFrom: '', statsTo: '',
    exPeriod: 'year', exFrom: today.slice(0, 4) + '-01-01', exTo: today,
    keepMode: store.get('keepMode', 'off'), keepForm: null, keepNote: '', reauthAt: 0,   // Pool → "Recently taken" (last 2 days)    // slot → emp you offered it to (so it can be withdrawn later)
  };

  { const o = store.get('whoOrder', null); if (Array.isArray(o) && o.length === WHO_ORDER.length && WHO_ORDER.every(u => o.includes(u))) WHO_ORDER.splice(0, WHO_ORDER.length, ...o); }

  // ───────────────────────────── sample data (mirrors the app's DemoData) ─────────────────────────────
  function demoData() {
    const me = 'Demo User';
    const others = ['Priya Nair', 'Sarah Chen', 'James Okafor', 'Maria Santos', 'David Kim', 'Emily Novak', 'Raj Patel', 'Lena Fischer', 'Tom Wright', 'Anna Kowalski'];
    const units = ['SICU', 'MICU', 'CCU', 'PHICU', 'RR', 'PRR', 'MSU'];
    const times = u => (u === 'RR' || u === 'PRR') ? ['08:00', '17:00', false] : u === 'MSU' ? ['17:00', '08:00', true] : ['08:00', '08:00', true];
    const mine = [], group = [];
    const start = addDays(today, -400), end = addDays(today, 60);
    let dayIdx = ord(start) - ord('2024-01-01');
    for (let d = start; d <= end; d = addDays(d, 1), dayIdx++) {
      units.forEach((u, ui) => {
        const [s, e, ov] = times(u);
        const isMe = dayIdx % 5 === 0 && ui === Math.floor(dayIdx / 5) % units.length;
        const doc = isMe ? me : others[(dayIdx + ui) % others.length];
        const row = { date: d, unit: u, doc, emp: isMe ? 'demo' : 'e' + others.indexOf(doc), start: s, end: e, ov, slot: 800000 + dayIdx * 10 + ui, tpl: 6 };
        group.push(row); if (isMe) mine.push(row);
      });
    }
    [[0, 'SICU'], [1, 'MICU'], [2, 'CCU'], [4, 'RR']].forEach(([off, u]) => {
      const [s, e, ov] = times(u);
      group.push({ date: addDays(today, off), unit: u, doc: 'Jordan Ellis', start: s, end: e, ov, buddy: true });
    });
    const offers = [[2, 'RR', 'Sarah Chen'], [4, 'SICU', 'James Okafor'], [5, 'PRR', 'Maria Santos'], [8, 'MICU', 'David Kim'], [11, 'CCU', 'Emily Novak'], [14, 'MSU', 'Raj Patel']];
    const open = offers.map(([off, u, who], i) => {
      const [s, e, ov] = times(u);
      return { id: 'demo-' + i, date: addDays(today, off), unit: u, offerer: who, offererEmp: 'e' + others.indexOf(who), start: s, end: e, ov, directed: false };
    });
    // one aimed at you by name — a half hour at the start of one of your days
    const nextMine = mine.find(x => x.date > addDays(today, 2) && !x.ov);
    if (nextMine) open.push({ id: 'demo-d', date: nextMine.date, unit: nextMine.unit, offerer: 'Tom Wright', offererEmp: 'e8', start: '07:30', end: '08:00', ov: false, directed: true });
    const requests = [
      { id: -1, date: addDays(today, 40), status: 'pending', kind: 'Time Off', note: 'Family visit' },
      { id: -2, date: addDays(today, 41), status: 'pending', kind: 'Time Off', note: 'Family visit' },
      { id: -3, date: addDays(today, 42), status: 'pending', kind: 'Time Off', note: 'Family visit' },
      { id: -4, date: addDays(today, 18), status: 'pending', kind: 'Night Off', note: "Kids' concert" },
      { id: -5, date: addDays(today, 25), status: 'approved', kind: 'Time Off', note: 'Conference' },
    ];
    const posted = mine.find(x => x.date > addDays(today, 8));
    if (posted) { posted.pending = true; posted.pendingEmp = 'e2'; }
    return { me, emp: 'demo', mine, group, open, requests };
  }

  // ───────────────────────────── Lightning Bolt session + reads ─────────────────────────────
  let AUTH = '';
  function looksSignedOut() {
    const t = (document.body && document.body.innerText) || '';
    return /\/login/i.test(location.pathname) || /Sign in to access/i.test(t) || (!window.LbsAppData && /password/i.test(t) && !/Sign out/i.test(t));
  }
  function hookWindow(w) {
    try {
      if (!w || w.__wbHooked) return; w.__wbHooked = 1;
      const os = w.XMLHttpRequest.prototype.setRequestHeader;
      w.XMLHttpRequest.prototype.setRequestHeader = function (k, v) {
        try { if (/^authorization$/i.test(k) && /bearer/i.test(v)) AUTH = v; } catch (e) {}
        return os.apply(this, arguments);
      };
      if (w.fetch) {
        const of = w.fetch;
        w.fetch = function (input, init) {
          try {
            const h = init && init.headers;
            if (h) { const a = (h.get && h.get('authorization')) || h.Authorization || h.authorization; if (a && /bearer/i.test(a)) AUTH = a; }
          } catch (e) {}
          return of.apply(this, arguments);
        };
      }
    } catch (e) {}
  }
  // Load LB's own viewer in a hidden frame (same site, same session) and catch the Bearer it sends to lbapi.
  function captureToken() {
    return new Promise(resolve => {
      hookWindow(window);
      if (AUTH) return resolve(AUTH);
      const f = document.createElement('iframe');
      f.style.cssText = 'position:fixed;width:1px;height:1px;left:-9999px;top:0;opacity:0;pointer-events:none;border:0';
      f.setAttribute('aria-hidden', 'true');
      f.src = `${LITE}/viewer/?dt=${stamp(today).slice(0, 6)}01`;
      document.body.appendChild(f);
      const t0 = Date.now(); let nudged = false;
      const iv = setInterval(() => {
        let w = null; try { w = f.contentWindow; } catch (e) {}
        if (w) hookWindow(w);
        try {
          if (!AUTH && w && w.LbsAppData) {
            const D = w.LbsAppData;
            if (!S.emp) { const id = identity(D); if (id.emp) { S.emp = id.emp; S.me = id.me; } }
            if (!nudged && Date.now() - t0 > 2500 && D.Slots && D.Slots.fetch) { nudged = true; try { D.Slots.fetch(); } catch (e) {} }
          }
        } catch (e) {}
        if (AUTH || Date.now() - t0 > 25000) {
          clearInterval(iv);
          try { if (!S.emp && w && w.LbsAppData) { const id = identity(w.LbsAppData); S.emp = id.emp; S.me = id.me; } } catch (e) {}
          setTimeout(() => f.remove(), 500);
          resolve(AUTH);
        }
      }, 15);
    });
  }
  function identity(D) {
    let emp = null, me = '';
    try {
      if (D.User && D.User.emp_id) emp = D.User.emp_id;
      else if (D.User && D.User.attributes && D.User.attributes.emp_id) emp = D.User.attributes.emp_id;
      else if (D.MyPersonnel && D.MyPersonnel.models && D.MyPersonnel.models[0]) emp = D.MyPersonnel.models[0].attributes.emp_id;
    } catch (e) {}
    try {
      if (D.MyPersonnel && D.MyPersonnel.models && D.MyPersonnel.models[0]) { const a = D.MyPersonnel.models[0].attributes; me = a.display_name || `${a.first_name || ''} ${a.last_name || ''}`.trim(); }
      else if (D.User && D.User.attributes && D.User.attributes.display_name) me = D.User.attributes.display_name;
    } catch (e) {}
    return { emp: emp != null ? String(emp) : '', me };
  }
  async function api(path) {
    const r = await fetch(LBAPI + path, { headers: { Authorization: AUTH } });
    if (r.status === 401 || r.status === 403) { const e = new Error('session'); e.session = true; throw e; }
    if (!r.ok) throw new Error('http ' + r.status);
    const j = await r.json();
    return Array.isArray(j) ? j : (j.data || j.slots || []);
  }
  async function pool(n, items, fn) {
    const out = new Array(items.length); let i = 0;
    await Promise.all(Array.from({ length: Math.min(n, items.length) }, async () => { while (i < items.length) { const k = i++; out[k] = await fn(items[k]); } }));
    return out;
  }
  function norm(a) {
    if (!a || !a.start_time || !a.stop_time || a.start_time.length < 16) return null;
    const raw = a.assign_display_name || a.assign_compact_name || '';
    const buddy = /buddy/i.test(raw);
    const unit = buddy ? unitKey(raw.replace(/buddy/ig, ' ').trim()) : unitKey(raw);
    if (!unit && !buddy) return null;
    return {
      slot: a.slot_id, date: a.start_time.slice(0, 10), unit, buddy, raw,
      start: a.start_time.slice(11, 16), end: a.stop_time.slice(11, 16), ov: a.stop_time.slice(0, 10) > a.start_time.slice(0, 10),
      doc: a.display_name || a.compact_name || '—', emp: a.emp_id != null ? String(a.emp_id) : '',
      note: buddy && a.note ? String(a.note) : null,
      pending: !!a.is_pending, pendingEmp: a.pending_emp_id != null ? String(a.pending_emp_id) : null,
      tpl: a.template_id != null ? +a.template_id : null,
    };
  }
  async function loadLive() {
    const emp = S.emp, y = +today.slice(0, 4);
    // the next 14 months of open shifts, 4 at a time
    const months = Array.from({ length: 14 }, (_, i) => addMonths(ymOf(today), i));
    const pagesP = pool(4, months, async ym => {
      const s = ym.replace('-', '') + '01', e = ym.replace('-', '') + String(daysIn(ym)).padStart(2, '0');
      try { return await api(`/schedule/range/?start_date=${s}&end_date=${e}&listed=true&emp_id=${emp}&only_pending=true`); } catch (err) { if (err.session) throw err; return []; }
    });
    const mineP = Promise.all([y, y + 1].map(yy => api(`/schedule/range/?start_date=${yy}0101&end_date=${yy}1231&listed=true&emp_id=${emp}`)));
    // Who's On / Crew: two weeks back → four months ahead (a whole year is ~9 MB; this window is what you scan)
    const gs = addDays(today, -14), ge = addDays(today, 120);
    const groupP = api(`/schedule/range/?start_date=${stamp(gs)}&end_date=${stamp(ge)}&listed=true`).catch(e => { if (e.session) throw e; return null; });
    const reqP = api(`/request/range/?start_date=${y}0101&end_date=${y + 1}1231&listed=true&emp_id=${emp}`).catch(() => []);

    const [pages, mineRaw, groupRaw, reqRaw] = await Promise.all([pagesP, mineP, groupP, reqP]);
    const mine = [], seenM = {};
    for (const a of mineRaw.flat()) { const s = norm(a); if (s && s.unit && !s.buddy && s.emp === emp && !seenM[s.slot]) { seenM[s.slot] = 1; mine.push(s); } }
    mine.sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : toMin(a.start) - toMin(b.start));
    const open = [], seenO = {};
    for (const a of pages.flat()) {
      if (!a || !a.is_pending || !a.slot_id || seenO[a.slot_id]) continue;
      const s = norm(a); if (!s || !s.unit || s.buddy) continue; seenO[a.slot_id] = 1;
      const directedTo = s.pendingEmp && s.pendingEmp !== s.emp ? s.pendingEmp : null;
      if (directedTo && directedTo !== emp) continue;                    // aimed at someone else — not yours to see
      if (s.emp === emp) continue;                                        // your own post
      open.push({ id: String(a.slot_id), date: s.date, unit: s.unit, offerer: s.doc, offererEmp: s.emp, start: s.start, end: s.end, ov: s.ov, directed: !!directedTo });
    }
    const group = [];
    if (groupRaw) { const seenG = {}; for (const a of groupRaw) { const s = norm(a); if (s && !seenG[s.slot]) { seenG[s.slot] = 1; group.push(s); } } }
    const requests = [];
    for (const a of reqRaw) {
      if (!a || a.request_id == null) continue;
      if (a.emp_id != null && String(a.emp_id) !== emp) continue;
      requests.push({ id: a.request_id, date: String(a.request_date || '').slice(0, 10), status: String(a.status || '').toLowerCase(), kind: a.assign_display_name || 'Request', note: a.message || '', decision: a.decision_note || a.response_message || '' });
    }
    return { mine, open, group: groupRaw ? group : null, requests };
  }

  // ───────────────────────────── derived ─────────────────────────────
  function derive() {
    const sched = scheduleModel(S.mine);
    const busy = busyMap();
    S.open = S.open.map(o => {
      const flag = sched.flag(o.date, o.unit, interval(o.date, o.start, o.end, o.ov));
      return Object.assign(o, { flag: flag || 'Available', conflict: !!flag, busy: busy[o.date] || null });
    }).filter(o => o.date >= today).sort((a, b) => a.date !== b.date ? (a.date < b.date ? -1 : 1) : toMin(a.start) - toMin(b.start));
  }
  const pickable = o => o.directed || (!o.conflict && !o.busy);
  const canTake = o => !o.conflict && !o.busy;   // no "take it anyway": a shift that clashes with your days can't be taken from here
  const busyText = b => b.mine ? (b.kind === 'Busy' ? 'You marked this day busy' : `Busy — ${b.kind}`) : `${b.kind} ${b.status === 'approved' ? '(approved)' : 'requested'}`;
  function busyMap() {
    const m = {};
    for (const r of S.requests) if (r.status === 'pending' || r.status === 'approved') m[r.date] = r;
    for (const d in S.busyDays) if (!m[d]) m[d] = { kind: S.busyDays[d] || 'Busy', status: 'busy', mine: true };
    return m;
  }
  function myByDate() {
    const m = {};
    for (const s of S.mine) (m[s.date] = m[s.date] || []).push(s);
    return m;
  }
  function postCallMap() {
    const m = {};
    for (const s of S.mine) if (s.ov) m[addDays(s.date, 1)] = s;
    return m;
  }
  function monthStats(ym) {
    const shifts = S.mine.filter(s => ymOf(s.date) === ym);
    const std = k => (k === 'RR' || k === 'PRR') ? 9 : k === 'MSU' ? 15 : 24;
    const st = { shifts: 0, hours: 0, full24: 0, rr9: 0, msu: 0, half: 0 };
    const byDate = {}; shifts.forEach(s => (byDate[s.date] = byDate[s.date] || []).push(s));
    const used = new Set(); let combos = 0;
    for (const d in byDate) { const p = byDate[d].find(s => s.unit === 'PRR'), m = byDate[d].find(s => s.unit === 'MSU'); if (p && m) { combos++; used.add(p); used.add(m); } }
    st.full24 += combos;
    for (const s of shifts) {
      const h = hoursOf(s); st.hours += h;
      if (used.has(s)) continue;
      if (h < std(s.unit) - 1) { st.half++; continue; }
      if (s.unit === 'RR' || s.unit === 'PRR') st.rr9++; else if (s.unit === 'MSU') st.msu++; else st.full24++;
    }
    st.shifts = shifts.length - combos;
    return st;
  }
  const breakdown = st => [st.full24 && `24h ×${st.full24}`, st.rr9 && `9h ×${st.rr9}`, st.msu && `15h ×${st.msu}`, st.half && `half ×${st.half}`].filter(Boolean).join('   ');
  const surname = n => { const p = String(n).trim().split(/\s+/); return (p[p.length - 1] || '').toLowerCase(); };
  function weekStartOf(iso) { return addDays(iso, -((dow(iso) - S.weekStart + 7) % 7)); }

  // ───────────────────────────── your own calendars (.ics files, kept in this browser) ─────────────────────────────
  const unescICS = v => v.replace(/\\n/gi, ' ').replace(/\\([,;\\])/g, '$1').trim();
  function tzOffset(ms, tz) {          // ms the zone is ahead of UTC at that instant
    try {
      const p = new Intl.DateTimeFormat('en-US', { timeZone: tz, hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit', second: '2-digit' }).formatToParts(new Date(ms));
      const g = t => +p.find(x => x.type === t).value;
      return Date.UTC(g('year'), g('month') - 1, g('day'), g('hour') % 24, g('minute'), g('second')) - ms;
    } catch (e) { return 0; }
  }
  // an ICS date/time → { d:'YYYY-MM-DD', t:'HH:MM'|null } in Regina time
  function icsTime(v, P) {
    const m = /^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$/.exec(String(v || '').trim());
    if (!m) return null;
    const [, y, mo, d, hh, mi, ss, z] = m;
    if (hh == null || (P && P.VALUE === 'DATE')) return { d: `${y}-${mo}-${d}`, t: null };
    let ms = Date.UTC(+y, +mo - 1, +d, +hh, +mi, +(ss || 0));
    // a wall-clock time in its own zone (floating times count as Regina) → the real instant
    if (!z) { const tz = (P && P.TZID) ? P.TZID.replace(/^"|"$/g, '') : 'America/Regina'; ms -= tzOffset(ms, tz); }
    const p = new Intl.DateTimeFormat('en-CA', { timeZone: 'America/Regina', hourCycle: 'h23', year: 'numeric', month: '2-digit', day: '2-digit', hour: '2-digit', minute: '2-digit' }).formatToParts(new Date(ms));
    const g = t => p.find(x => x.type === t).value;
    return { d: `${g('year')}-${g('month')}-${g('day')}`, t: `${g('hour')}:${g('minute')}` };
  }
  function parseICS(text) {
    const lines = String(text).replace(/\r?\n[ \t]/g, '').split(/\r?\n/);
    const raw = []; let cur = null, name = '';
    for (const ln of lines) {
      if (ln === 'BEGIN:VEVENT') { cur = {}; continue; }
      if (ln === 'END:VEVENT') { if (cur) raw.push(cur); cur = null; continue; }
      const i = ln.indexOf(':'); if (i < 0) continue;
      const [nm, ...ps] = ln.slice(0, i).split(';'), val = ln.slice(i + 1), N = nm.toUpperCase();
      if (!cur) { if (N === 'X-WR-CALNAME') name = unescICS(val); continue; }
      const P = {}; ps.forEach(p => { const k = p.indexOf('='); if (k > 0) P[p.slice(0, k).toUpperCase()] = p.slice(k + 1); });
      if (N === 'DTSTART' || N === 'DTEND' || N === 'RECURRENCE-ID') cur[N] = { v: val, P };
      else if (N === 'SUMMARY') cur.title = unescICS(val);
      else if (N === 'RRULE') cur.rrule = val;
      else if (N === 'EXDATE') (cur.ex = cur.ex || []).push(...val.split(',').map(x => icsTime(x, P)).filter(Boolean).map(x => x.d));
      else if (N === 'STATUS') cur.status = val.toUpperCase();
      else if (N === 'UID') cur.uid = val;
    }
    const lo = addDays(today, -120), hi = addDays(today, 400), out = [];
    const moved = {};   // uid → dates that have their own edited copy
    raw.forEach(r => { if (r['RECURRENCE-ID'] && r.uid) { const x = icsTime(r['RECURRENCE-ID'].v, r['RECURRENCE-ID'].P); if (x) (moved[r.uid] = moved[r.uid] || new Set()).add(x.d); } });
    for (const r of raw) {
      if (r.status === 'CANCELLED' || !r.DTSTART) continue;
      const s = icsTime(r.DTSTART.v, r.DTSTART.P); if (!s) continue;
      const e = r.DTEND ? icsTime(r.DTEND.v, r.DTEND.P) : null;
      // all-day DTEND is exclusive; a timed event ending at midnight stays on its own day
      let span = 0;
      if (e) { span = ord(e.d) - ord(s.d); if (!s.t || (e.t === '00:00' && span > 0)) span -= 1; span = Math.max(0, Math.min(span, 60)); }
      const ev = d => ({ d, n: span, s: s.t, e: e && e.t ? e.t : null, t: (r.title || 'Busy').slice(0, 80) });
      if (!r.rrule || r['RECURRENCE-ID']) { if (s.d >= lo && s.d <= hi) out.push(ev(s.d)); continue; }
      const R = {}; r.rrule.split(';').forEach(p => { const [k, v] = p.split('='); R[k.toUpperCase()] = v; });
      const step = Math.max(1, +(R.INTERVAL || 1)), count = R.COUNT ? +R.COUNT : Infinity;
      const until = R.UNTIL ? (icsTime(R.UNTIL, {}) || {}).d : null;
      const skip = new Set((r.ex || []).concat([...(moved[r.uid] || [])]));
      const BD = { SU: 0, MO: 1, TU: 2, WE: 3, TH: 4, FR: 5, SA: 6 };
      const byday = R.BYDAY ? R.BYDAY.split(',').map(x => BD[x.slice(-2)]).filter(x => x != null) : null;
      let n = 0, guard = 0;
      const emit = d => { if (n >= count || (until && d > until) || d > hi) return false; n++; if (d >= lo && !skip.has(d)) out.push(ev(d)); return true; };
      if (R.FREQ === 'DAILY') { for (let d = s.d; guard++ < 4000; d = addDays(d, step)) if (!emit(d)) break; }
      else if (R.FREQ === 'WEEKLY') {
        const days = byday && byday.length ? byday.slice().sort((a, b) => a - b) : [dow(s.d)];
        let wk = addDays(s.d, -dow(s.d));
        outer: for (; guard++ < 1500; wk = addDays(wk, 7 * step)) for (const k of days) { const d = addDays(wk, k); if (d < s.d) continue; if (!emit(d)) break outer; }
      } else if (R.FREQ === 'MONTHLY') {
        const dd = +s.d.slice(8);
        for (let ym = ymOf(s.d); guard++ < 600; ym = addMonths(ym, step)) { if (dd > daysIn(ym)) continue; if (!emit(`${ym}-${String(dd).padStart(2, '0')}`)) break; }
      } else if (R.FREQ === 'YEARLY') {
        for (let y = +s.d.slice(0, 4); guard++ < 60; y += step) { const d = `${y}${s.d.slice(4)}`; if (+d.slice(8) > daysIn(d.slice(0, 7))) continue; if (!emit(d)) break; }
      } else if (s.d >= lo && s.d <= hi) out.push(ev(s.d));
    }
    out.sort((a, b) => a.d < b.d ? -1 : a.d > b.d ? 1 : (a.s || '') < (b.s || '') ? -1 : 1);
    return { name, events: out.slice(0, 4000) };
  }
  function saveCals() {
    try { store.set('cals', S.cals.filter(c => !c.demo)); } catch (e) {}
  }
  // sample-data mode: a made-up family calendar so the feature shows
  function demoCal() {
    const t = ['Dentist', 'School concert', 'Hockey practice', 'Dinner with friends', 'Book club', 'Car service', 'Swim lessons'];
    const events = [];
    for (let k = -20; k < 70; k += 3) { const i = (k + 21) % t.length; events.push({ d: addDays(today, k), n: 0, s: ['08:30', '18:00', '19:30', '17:15'][i % 4], e: null, t: t[i] }); }
    events.push({ d: addDays(today, 26), n: 3, s: null, e: null, t: 'Banff trip' });
    return { id: 'demo-cal', name: 'Family', color: CAL_COLORS[1], on: true, events, demo: true };
  }
  function addCalendarFiles(files) {
    [...files].filter(f => /\.ics$/i.test(f.name) || /calendar/i.test(f.type)).forEach(f => {
      const rd = new FileReader();
      rd.onload = () => {
        const p = parseICS(rd.result);
        const name = p.name || f.name.replace(/\.ics$/i, '').replace(/[_@].*$/, '') || 'Calendar';
        const used = new Set(S.cals.map(c => c.color));
        const color = CAL_COLORS.find(c => !used.has(c)) || CAL_COLORS[S.cals.length % CAL_COLORS.length];
        S.cals = S.cals.filter(c => c.name !== name).concat({ id: 'c' + Date.now() + Math.random().toString(36).slice(2, 6), name, color, on: true, events: p.events, added: today });
        saveCals();
        S.note = p.events.length ? '' : `“${esc(name)}” had no events in the next year.`;
        rerender(true);
      };
      rd.readAsText(f);
    });
  }
  // ── live calendar links (Google "secret address in iCal format", Apple public calendar, Outlook published ICS).
  // Re-read on open, when you come back to the tab, and every 30 min — so edits in Google show up here by themselves.
  // Calendar sites don't allow other pages to read them directly, so the link goes through Working-Bolt's own
  // tiny relay (a Supabase function that only fetches calendar addresses and keeps nothing). The link itself stays in this browser.
  const ICS_RELAY = 'https://qbtnxkzpddexczhcvxre.supabase.co/functions/v1/ics-proxy';
  const calURL = u => String(u || '').trim().replace(/^webcals?:\/\//i, 'https://');
  async function fetchICS(url) {
    const u = calURL(url);
    try { const r = await fetch(u, { cache: 'no-store' }); if (r.ok) { const t = await r.text(); if (/BEGIN:VCALENDAR/.test(t)) return t; } } catch (e) {}
    const r = await fetch(ICS_RELAY, { method: 'POST', headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY, 'Content-Type': 'application/json' }, body: JSON.stringify({ url: u }) });
    const t = await r.text();
    if (!r.ok || !/BEGIN:VCALENDAR/.test(t)) throw new Error(r.status === 404 ? 'relay' : (t.slice(0, 120) || 'status ' + r.status));
    return t;
  }
  async function addCalendarLink(url, name) {
    const text = await fetchICS(url), p = parseICS(text);
    const nm = String(name || '').trim() || p.name || 'Calendar';
    const used = new Set(S.cals.map(c => c.color));
    const color = CAL_COLORS.find(c => !used.has(c)) || CAL_COLORS[S.cals.length % CAL_COLORS.length];
    S.cals = S.cals.filter(c => c.name !== nm && calURL(c.url) !== calURL(url)).concat({ id: 'c' + Date.now() + Math.random().toString(36).slice(2, 6), name: nm, color, on: true, events: p.events, url: calURL(url), synced: stampNow(), added: today });
    saveCals(); rerender(true);
    return p.events.length;
  }
  let calSyncing = false;
  async function syncCals() {
    if (calSyncing) return; calSyncing = true;
    let changed = false;
    for (const c of S.cals) if (c.url) {
      try {
        const p = parseICS(await fetchICS(c.url));
        if (p.events.length || !c.events.length) { c.events = p.events; c.synced = stampNow(); c.err = null; changed = true; }   // never swap good events for an empty read
      } catch (e) { c.err = 'Couldn’t update — showing the last copy'; changed = true; }
    }
    calSyncing = false;
    if (changed) { saveCals(); rerender(true); }
  }
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible' && host.style.display !== 'none') syncCals(); });

  // date → [{ cal, ev }] for the calendars you have switched on (multi-day events land on every day)
  function calByDate() {
    const m = {};
    for (const c of S.cals) if (c.on) for (const ev of c.events) for (let k = 0; k <= (ev.n || 0); k++) {
      const d = k ? addDays(ev.d, k) : ev.d; (m[d] = m[d] || []).push({ c, ev });
    }
    return m;
  }
  const evLabel = ev => `${ev.s ? ev.s + ' ' : ''}${ev.t}`;

  // ───────────────────────────── weather (Open-Meteo: free, no key, no tracking) ─────────────────────────────
  function wx(code) {
    const c = +code;
    if (c === 0) return ['Clear', 'sun']; if (c <= 2) return ['Partly cloudy', 'part']; if (c === 3) return ['Overcast', 'cloud'];
    if (c === 45 || c === 48) return ['Fog', 'fog']; if (c >= 51 && c <= 67) return [c >= 56 && c <= 57 || c >= 66 ? 'Freezing rain' : 'Rain', 'rain'];
    if (c >= 71 && c <= 77) return ['Snow', 'snow']; if (c >= 80 && c <= 82) return ['Showers', 'rain']; if (c >= 85 && c <= 86) return ['Snow showers', 'snow'];
    if (c >= 95) return ['Thunderstorm', 'storm']; return ['—', 'cloud'];
  }
  const WXI = {
    sun: '<circle cx="12" cy="12" r="4.2" fill="#F0B24A"/><g stroke="#F0B24A" stroke-width="1.8" stroke-linecap="round"><path d="M12 2.5v2.2M12 19.3v2.2M2.5 12h2.2M19.3 12h2.2M5.3 5.3l1.6 1.6M17.1 17.1l1.6 1.6M5.3 18.7l1.6-1.6M17.1 6.9l1.6-1.6"/></g>',
    part: '<circle cx="9" cy="9" r="3.6" fill="#F0B24A"/><path d="M8 19.5h9.5a3.7 3.7 0 0 0 .3-7.4 5 5 0 0 0-9.5 1.3A3.1 3.1 0 0 0 8 19.5Z" fill="currentColor" opacity=".55"/>',
    cloud: '<path d="M6.5 19h11a4.2 4.2 0 0 0 .4-8.4 5.8 5.8 0 0 0-11 1.5A3.5 3.5 0 0 0 6.5 19Z" fill="currentColor" opacity=".55"/>',
    fog: '<g stroke="currentColor" stroke-width="2" stroke-linecap="round" opacity=".6"><path d="M4 9h16M6 13h12M4 17h16"/></g>',
    rain: '<path d="M6.5 15h11a4 4 0 0 0 .4-8 5.5 5.5 0 0 0-10.5 1.4A3.3 3.3 0 0 0 6.5 15Z" fill="currentColor" opacity=".55"/><g stroke="#3A9AEE" stroke-width="1.8" stroke-linecap="round"><path d="M8 18l-1 2.5M12 18l-1 2.5M16 18l-1 2.5"/></g>',
    snow: '<path d="M6.5 15h11a4 4 0 0 0 .4-8 5.5 5.5 0 0 0-10.5 1.4A3.3 3.3 0 0 0 6.5 15Z" fill="currentColor" opacity=".55"/><g fill="#7FB6E6"><circle cx="8" cy="19" r="1.3"/><circle cx="12" cy="20.5" r="1.3"/><circle cx="16" cy="19" r="1.3"/></g>',
    storm: '<path d="M6.5 14h11a4 4 0 0 0 .4-8 5.5 5.5 0 0 0-10.5 1.4A3.3 3.3 0 0 0 6.5 14Z" fill="currentColor" opacity=".55"/><path d="M12.5 14 10 18.5h2.5L11 22l4-5.2h-2.5l1.4-2.8Z" fill="#F0B24A"/>',
  };
  const wxIcon = (k, size) => `<svg viewBox="0 0 24 24" width="${size}" height="${size}" aria-hidden="true">${WXI[k] || WXI.cloud}</svg>`;
  async function loadWeather() {
    try {
      const r = await fetch('https://api.open-meteo.com/v1/forecast?latitude=50.45&longitude=-104.61&current=temperature_2m,apparent_temperature,weather_code,wind_speed_10m&daily=weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max&timezone=America%2FRegina&forecast_days=5');
      if (!r.ok) throw new Error();
      S.weather = await r.json(); S.weather.at = Date.now();
    } catch (e) { S.weather = { failed: true }; }
    if (S.tab === 'today') rerender(true);
  }

  // Doctors on call + cafeteria: the same public Supabase tables the app reads (publishable key, read-only here).
  // A failed or empty read never replaces what we already had.
  const SUPA = 'https://qbtnxkzpddexczhcvxre.supabase.co/rest/v1', SUPA_KEY = 'sb_publishable_uqqWXuhGAPqd85yXC4rLsA_q7RX1zAQ';
  const supaGet = async path => { const r = await fetch(SUPA + path, { headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY } }); if (!r.ok) throw new Error(r.status); return r.json(); };
  const ocLoaded = new Map();                // "from|to" → when we last read it
  async function loadOncall(from = addDays(today, -7), to = addDays(today, 2), force = true) {
    const k = from + '|' + to;
    if (!force && ocLoaded.has(k) && Date.now() - ocLoaded.get(k) < 10 * 60 * 1000) return;
    ocLoaded.set(k, Date.now());
    if (DEMO) { await null; S.oncall = demoOncall(from, to, S.oncall); if (S.tab === 'who' || S.tab === 'today') rerender(true); return; }
    try {
      const rows = await supaGet(`/oncall_roster?date=gte.${from}&date=lte.${to}&select=date,unit,role,name&limit=2000`);
      S.oncallFailed = false;
      if (rows.length) {                     // replace only the dates the server returned; keep the rest
        const got = new Set(rows.map(r => r.date));
        S.oncall = (S.oncall || []).filter(r => !got.has(r.date) && r.date >= addDays(today, -60)).concat(rows);
        store.set('oncall', { rows: S.oncall });
      } else if (S.oncall == null) S.oncall = [];
    } catch (e) { S.oncallFailed = true; ocLoaded.delete(k); if (S.oncall == null) S.oncall = []; }
    if (S.tab === 'today' || S.tab === 'who') rerender(true);
  }
  async function loadCafe() {
    if (DEMO) { S.cafe = demoCafe(); return; }
    try {
      const pages = await supaGet('/cafeteria_menu?select=site,page,first_date,days&order=site,page');
      S.cafeFailed = false;
      if (pages.length) { S.cafe = pages; store.set('cafe', { pages }); } else if (S.cafe == null) S.cafe = [];
    } catch (e) { S.cafeFailed = true; if (S.cafe == null) S.cafe = []; }
    if (S.tab === 'today') rerender(true);
  }
  // Recently taken: every shift that changed hands in the last 48 h (the poller's pickups table — LB's local time,
  // Regina has no DST so it's UTC−6). A Pasqua Rapid+MSU pair is one row. Proof the pool is live: gone = taken, not lost.
  async function loadTaken() {
    let rows;
    if (DEMO) {
      const at = (h, m) => new Date(Date.now() - (h * 60 + m) * 60000 - 6 * 3600000).toISOString().slice(0, 19);
      rows = [[2, 'MICU', 0, 25, 'Lena Fischer'], [5, 'PRR', 3, 10, 'Tom Wright'], [9, 'CCU', 20, 0, 'Raj Patel', 'swap'], [1, 'RR', 30, 5, 'Anna Kowalski']]
        .map(([o, unit, h, m, taker, kind], i) => ({ slot_id: 900 + i, date: addDays(today, o), unit, kind: kind || 'pickup', giver_emp: null, taker_emp: null, taker, picked_up_at: at(h, m) }));
    } else {
      const since = new Date(Date.now() - 48 * 3600000 - 6 * 3600000).toISOString().slice(0, 19);
      try { rows = await supaGet(`/pickups?picked_up_at=gte.${since}&select=slot_id,date,unit,kind,giver_emp,taker_emp,taker,picked_up_at&order=picked_up_at.desc&limit=40`); }
      catch (e) { return; }                     // keep what we had
    }
    const me = S.emp ? +S.emp : null, seen = new Set();
    S.taken = rows.filter(r => r.date && r.date >= today && UNITS[r.unit] && r.picked_up_at).filter(r => {
      const k = r.date + '|' + (r.unit === 'MSU' || r.unit === 'PRR' ? 'PASQ' : r.unit);
      if (seen.has(k)) return false; seen.add(k); return true;
    }).map(r => ({ id: r.slot_id, date: r.date, unit: r.unit, at: Date.parse(String(r.picked_up_at).slice(0, 19) + '-06:00'), swap: r.kind === 'swap',
      mine: me != null && (r.giver_emp === me || r.taker_emp === me), taker: me != null && r.taker_emp === me ? 'you' : (r.taker || '') }));
    if (S.tab === 'pool') rerender(true);
  }
  // under For me: only pool give-aways (not swaps, not mine) you could have worked — no clash, not a busy day
  function takenForMe() {
    const sched = scheduleModel(S.mine), busy = busyMap();
    const t = u => (u === 'RR' || u === 'PRR') ? ['08:00', '17:00', false] : u === 'MSU' ? ['17:00', '08:00', true] : ['08:00', '08:00', true];
    return (S.taken || []).filter(x => !x.swap && !x.mine && !busy[x.date] && !sched.flag(x.date, x.unit, interval(x.date, ...t(x.unit))));
  }
  function takenAgo(ms) {
    const m = Math.max(0, Math.round((Date.now() - ms) / 60000));
    if (m < 60) return m < 2 ? 'just now' : `${m} min ago`;
    const h = Math.floor(m / 60); return h < 24 ? `${h} h ago` : 'yesterday';
  }
  function takenCard(forMe) {
    const items = forMe ? takenForMe() : (S.taken || []);
    if (!items.length) return '';
    if (!S.showTaken) return `<button class="rtshow" data-taken="show" title="Show the shifts picked up in the last 2 days">${I.eye}Show recently taken</button>`;
    return `<div class="rt ${S.takenOpen ? 'open' : ''}"><div class="rth"><button class="rtt" data-taken="fold" aria-expanded="${S.takenOpen}">${I.check}Recently taken (${items.length})${I.chev}</button>
      <button class="eyeb" data-taken="hide" title="Hide recently taken (bring it back with the eye, or in Settings)" aria-label="Hide recently taken">${I.eyeOff}</button></div>
      ${S.takenOpen ? `<div class="rtl">${items.map(x => { const u = UNITS[x.unit], pq = x.unit === 'MSU' || x.unit === 'PRR';
        return `<div class="rtr"><span class="pill" style="--u:${u.color}">${pq ? 'Pasqua' : u.short}</span><span>${DAY[dow(x.date)]}, ${MONTH[+x.date.slice(5, 7) - 1].slice(0, 3)} ${+x.date.slice(8)}</span><span class="who">${x.taker ? `${esc(x.taker)} · ${takenAgo(x.at)}` : `taken ${takenAgo(x.at)}`}</span></div>`; }).join('')}
        <div class="fine">${forMe ? 'Last 2 days — only ones you could have picked up.' : 'Last 2 days. Your own pickups show in My Shifts once Lightning Bolt has them.'}</div></div>` : ''}</div>`;
  }
  function demoOncall(from, to, prev) {      // made-up tree names, like the app's sample mode
    const t = ['Maple', 'Birch', 'Cedar', 'Aspen', 'Willow', 'Rowan', 'Alder', 'Spruce', 'Larch', 'Poplar'];
    const rows = (prev || []).filter(r => r.date < addDays(from, -7) || r.date > to);
    for (let d = addDays(from, -7); d <= to; d = addDays(d, 1)) {
      const n = +d.slice(8), x = j => t[(n + j) % t.length];
      [['SICU', 'day', 0], ['SICU', 'oncall', 1], ['MICU', 'day', 1], ['MICU', 'oncall', 1], ['PHICU', 'day', 2], ['PHICU', 'oncall', 8],
       ['CCU', 'day', 4], ['CCU', 'oncall', 3], ['CCU', 'stemi_day', 5], ['CCU', 'stemi_oncall', 6], ['CCU', 'consults', 7]]
        .forEach(([unit, role, j]) => rows.push({ date: d, unit, role, name: x(j) }));
    }
    return rows;
  }
  function demoCafe() {
    const sun = addDays(today, -dow(today)), W = ['SUNDAY', 'MONDAY', 'TUESDAY', 'WEDNESDAY', 'THURSDAY', 'FRIDAY', 'SATURDAY'];
    const soups = ['Cream of Mushroom', 'Beef Barley', 'Chicken Noodle', 'Roasted Red Pepper', 'Split Pea', 'Clam Chowder', 'Minestrone'];
    const mains = ['Butter Chicken', 'Bacon Cheeseburger with choice of side', "Shepherd's Pie", 'Fish & Chips', 'Perogy Platter', 'Lasagna', 'Pork Schnitzel'];
    const page = site => ({ site, page: 1, first_date: sun, days: W.map((w, i) => ({ date: addDays(sun, i), weekday: w, sections: [
      { label: 'Café Pizza', items: [{ name: 'Pepperoni', price: '$3.75' }] },
      { label: "Today's Soup", items: [{ name: soups[i], price: 'Sm $2.25 · Lg $2.75' }] },
      { label: 'Lunch Feature', items: [{ name: mains[i], price: '$8.95' }] },
      { label: 'Side', items: [{ name: 'Mixed Greens with Carrots & Cucumber', price: '$2.50' }] },
      { label: 'Supper Feature', items: [{ name: mains[(i + 3) % 7], price: '$9.25' }] },
      { label: 'Side', items: [{ name: 'Roasted Potatoes', price: '$2.50' }, { name: 'Steamed Vegetables', price: '$2.25' }] }] })) });
    return [page('RGH'), page('PH')];
  }

  // ───────────────────────────── links (Lightning Bolt does every action) ─────────────────────────────
  const acceptURL = id => `${LITE}/dashboard/#/swop/${id}/accept`;
  const scheduleURL = iso => `${LITE}/viewer/me?dt=${stamp(iso)}`;

  // ───────────────────────────── DOM + styles ─────────────────────────────
  const esc = s => String(s == null ? '' : s).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const CSS2 = `
/* ── app parity: settings, posts, swaps, time off, stats, export ── */
.cobar{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:0 0 14px}
.cobar .sp{flex:1}
.cobar .seg{margin:0}
.xgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,380px),1fr));gap:14px;align-items:start}
.stgrid{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,460px),1fr));gap:14px;align-items:start}
.mgrid{row-gap:0;grid-auto-rows:2px}
.mgrid.xgrid{grid-template-columns:repeat(auto-fill,minmax(min(100%,400px),1fr))}
.mgrid>.xc{align-self:start}
.mgrid>.xc>h3{cursor:grab}
.mgrid>.xc>h3 button,.mgrid>.xc>h3 a{cursor:pointer}
.mgrid>.xc:hover>h3{color:var(--muted)}
.mgrid>.xc.mdrag{opacity:.6;outline:2px dashed color-mix(in srgb,var(--accent) 70%,transparent);outline-offset:-2px}
.mgrid.mdragging,.mgrid.mdragging *{cursor:grabbing!important;user-select:none;-webkit-user-select:none}
.xc{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px 18px;min-width:0}
.xc h3{display:flex;align-items:center;gap:8px;margin:0 0 10px;font-size:11.5px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase}
.xc h3 b{font-size:11px;color:var(--muted);background:var(--panel2);border:1px solid var(--line);border-radius:99px;padding:0 7px;letter-spacing:0}
.xc h3 .hsub{text-transform:none;letter-spacing:0;font-weight:600;color:var(--faint);font-size:12px}
.xc h3 .go{margin-left:auto;text-transform:none;letter-spacing:0;font-size:12.5px;font-weight:650;color:var(--accent);background:none;border:0;cursor:pointer;padding:0;font-family:inherit}
.xc h3 .ctl{margin-left:auto;display:flex;gap:4px}
.ctl button{width:26px;height:26px;border-radius:7px;border:1px solid var(--line);background:var(--panel2);display:grid;place-items:center;color:var(--muted);font-size:13px;cursor:pointer;font-family:inherit}
.ctl button:disabled{opacity:.35;cursor:default}
.ctl button:hover:not(:disabled){color:var(--accent);border-color:color-mix(in srgb,var(--accent) 50%,var(--line))}
.xp{margin:0 0 10px;font-size:13px;line-height:1.5;color:var(--muted);max-width:68ch}
.xr{display:flex;align-items:center;gap:10px;padding:9px 0;border-top:1px solid var(--line);font-size:13.5px;min-width:0;flex-wrap:wrap}
.xc h3+.xr,.xp+.xr{border-top:0}
.xr .l{flex:1;min-width:150px;color:var(--ink);font-weight:600}
.xr .l small{display:block;font-weight:500;color:var(--faint);font-size:12px;margin-top:2px;line-height:1.4}
.xr .seg.sm{margin:0}
.xr>.pill{flex:none}
.xr .ctl{display:flex;gap:4px}
.xbtns{display:flex;flex-wrap:wrap;gap:8px;margin-top:10px}
.xc select,.xin{font:inherit;font-size:13px;color:var(--ink);background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:6px 9px;min-width:0}
.xin.wide{width:100%;box-sizing:border-box;margin:0 0 4px}
.xc select:focus,.xin:focus{outline:2px solid color-mix(in srgb,var(--accent) 55%,transparent);outline-offset:1px}
.warnline{margin-top:8px;padding:6px 10px;border-radius:8px;font-size:12.5px;font-weight:650;background:color-mix(in srgb,var(--avail) 14%,transparent);color:var(--warn)}
.xtog{width:42px;height:24px;flex:none;border-radius:99px;border:1px solid var(--line);background:var(--segtrack);position:relative;cursor:pointer;transition:background .15s,border-color .15s;padding:0}
.xtog::after{content:"";position:absolute;top:2px;left:2px;width:18px;height:18px;border-radius:50%;background:var(--panel);box-shadow:0 1px 3px rgba(0,0,0,.25);transition:transform .15s}
.xtog[aria-checked="true"]{background:var(--accent);border-color:var(--accent)}
.xtog[aria-checked="true"]::after{transform:translateX(18px)}
.xtog:focus-visible{outline:2px solid var(--accent);outline-offset:2px}
.xc .tag.pending{background:color-mix(in srgb,var(--avail) 18%,transparent);color:var(--warn)}
.xc .tag.approved{background:color-mix(in srgb,var(--accent) 14%,transparent);color:var(--accent)}
.xc .tag.denied,.xc .tag.rejected,.xc .tag.declined{background:color-mix(in srgb,var(--posted) 14%,transparent);color:var(--posted)}
.tor .tag{flex:none;min-width:70px;text-align:center}
.tor .l small{font-style:normal}
/* swaps box (Pool) */
.swbox{margin:0 0 14px;padding:14px 16px;border-radius:14px;border:1px solid color-mix(in srgb,var(--accent) 35%,var(--line));background:color-mix(in srgb,var(--accent) 6%,var(--panel))}
.swbox h3{display:flex;align-items:center;gap:8px;margin:0 0 6px;font-size:11.5px;font-weight:750;color:var(--accent);letter-spacing:.07em;text-transform:uppercase}
.swbox h3 b{font-size:11px;background:var(--accent);color:var(--accent-ink);border-radius:99px;padding:0 7px;letter-spacing:0}
.swi{display:flex;align-items:center;gap:12px;padding:10px 0;border-top:1px solid color-mix(in srgb,var(--accent) 18%,var(--line));flex-wrap:wrap}
.swi:nth-of-type(1){border-top:0}
.swi .l{flex:1;min-width:220px;font-size:13.5px}
.swi .l b{display:block;color:var(--ink)}
.swi .l small{display:block;color:var(--muted);font-size:12.5px;margin-top:2px;line-height:1.4}
.swi .xbtns{margin:0}
.card.noto{opacity:.72}
.card.noto .flag.no{color:var(--faint)}
/* confirm box */
.sheet.xask{height:auto;width:min(440px,100%)}
.xab{padding:20px 20px 8px}
.xab b{display:block;font-size:16px;color:var(--ink);margin-bottom:8px}
.xab p{margin:0;font-size:13.5px;line-height:1.55;color:var(--muted)}
.xmsg{min-height:0;margin-top:8px;font-size:12.5px;font-weight:650;color:var(--posted)}
.xmsg:empty{display:none}
.sheet.pk{height:min(680px,100%)}
.sheet.pk .sb h3{margin:14px 0 2px;font-size:11.5px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase}
/* time off picker */
.tonew{margin:0 0 14px;border-color:color-mix(in srgb,var(--accent) 40%,var(--line))}
.mcnav{display:flex;align-items:center;gap:10px;margin:8px 0;font-size:13px;color:var(--muted);font-weight:600}
.mcnav span{flex:1;text-align:center}
.mcals{display:grid;grid-template-columns:repeat(auto-fill,minmax(min(100%,250px),1fr));gap:18px;margin-bottom:6px}
.mcal h4{margin:0 0 6px;font-size:13px;color:var(--ink)}
.mcal .g{display:grid;grid-template-columns:repeat(7,1fr);gap:3px}
.mcal .h{font-size:10.5px;color:var(--faint);text-align:center;font-weight:700;padding-bottom:2px}
.mcal .d{aspect-ratio:1;border:1px solid transparent;border-radius:8px;background:var(--panel2);font:inherit;font-size:12.5px;font-weight:650;color:var(--ink);cursor:pointer;padding:0}
.mcal .d:hover:not(:disabled){border-color:var(--accent)}
.mcal .d[aria-pressed="true"]{background:var(--accent);color:var(--accent-ink)}
.mcal .d:disabled{background:none;color:var(--faint);opacity:.55;cursor:default;text-decoration:line-through}
.mcal .d.today{box-shadow:inset 0 0 0 1.5px var(--accent)}
/* stats */
.sttiles{display:grid;grid-template-columns:repeat(4,1fr);gap:8px;margin-bottom:12px}
.sttiles div{background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:8px 10px;min-width:0}
.sttiles b{display:block;font-size:20px;font-weight:800;color:var(--ink);font-variant-numeric:tabular-nums;letter-spacing:-.01em}
.sttiles span{font-size:10.5px;color:var(--faint);font-weight:700;text-transform:uppercase;letter-spacing:.05em}
.stu{display:flex;flex-direction:column;gap:2px;font-size:13px}
.stu div{display:flex;align-items:center;gap:8px;padding:4px 0;border-top:1px solid var(--line)}
.stu div:first-child{border-top:0}
.stu i{width:9px;height:9px;border-radius:50%;background:var(--u);flex:none}
.stu b{flex:1;font-weight:650}
.stu span{color:var(--muted);font-variant-numeric:tabular-nums}
.chips{display:flex;flex-wrap:wrap;gap:5px;margin-top:10px}
.chip{display:inline-flex;align-items:center;gap:5px;font:inherit;font-size:12px;font-weight:650;color:var(--muted);background:var(--panel2);border:1px solid var(--line);border-radius:99px;padding:2px 9px}
button.chip{cursor:pointer}
button.chip[aria-pressed="true"]{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.udot,.chip .udot{display:inline-block;width:8px;height:8px;border-radius:50%;background:var(--u);margin-right:2px;vertical-align:0}
.stm{border-top:1px solid var(--line)}
.stm:first-of-type{border-top:0}
.stmh{display:flex;align-items:center;gap:10px;width:100%;padding:9px 0;background:none;border:0;font:inherit;color:var(--ink);cursor:pointer;text-align:left}
.stmh b{flex:1;font-size:13.5px}
.stmh span{font-size:12.5px;color:var(--muted);font-variant-numeric:tabular-nums}
.stmh svg{width:14px;height:14px;color:var(--faint);transition:transform .15s}
.stm.open .stmh svg{transform:rotate(180deg)}
.stmb{padding:2px 0 14px}
.xc[data-stsec="comingUp"]{border-color:color-mix(in srgb,var(--accent) 35%,var(--line));background:color-mix(in srgb,var(--accent) 5%,var(--panel))}
.cb2{display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-bottom:6px}
.cb2>div{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:9px 11px}
.cb2 span{display:block;font-size:10.5px;color:var(--faint);font-weight:700;text-transform:uppercase;letter-spacing:.05em}
.cb2 b{display:block;font-size:19px;font-weight:800;color:var(--ink);margin:2px 0}
.cb2 small{font-size:12px;color:var(--muted)}
.stbm{margin-top:10px;display:flex;flex-direction:column}
.stbm>div{display:flex;align-items:center;gap:10px;padding:5px 0;border-top:1px solid var(--line);font-size:13px}
.stbm>div>b{width:110px;flex:none;font-weight:650}
.stbm>div>span:first-of-type{width:22px;font-weight:750;color:var(--ink);font-variant-numeric:tabular-nums}
.stbm .chips{margin:0}
/* export / sync */
.xlink{display:flex;gap:8px;align-items:center;background:var(--panel2);border:1px solid var(--line);border-radius:10px;padding:6px 6px 6px 10px}
.xlink code{flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;font-size:12px;color:var(--muted)}
.keepf{display:flex;flex-direction:column;gap:8px;margin-top:8px;padding:12px;border:1px solid var(--line);border-radius:10px;background:var(--panel2)}
.keepf .xin{background:var(--panel)}
@media (max-width:760px){
  .sttiles{grid-template-columns:repeat(2,1fr)}
  .stbm>div>b{width:80px}
  .xr .l{min-width:0}
}
`;
  const CSS = `
:host{all:initial;position:fixed;inset:0;z-index:2147483000;display:block;
  --bg:#EEF3F3;--panel:#FFFFFF;--panel2:#F6F9F9;--segtrack:#E2EAEB;--segon:#FFFFFF;--segring:rgba(17,31,38,.16);--ink:#111F26;--muted:#5A6D75;--faint:#8A9BA2;--line:#E3E9EA;
  --accent:#0F766E;--accent-ink:#FFFFFF;--avail:#E19614;--posted:#7C5CFC;--warn:#B4541A;--shadow:0 1px 2px rgba(17,31,38,.05),0 6px 18px -10px rgba(17,31,38,.18);
  color-scheme:light}
:host([data-theme=dark]){--bg:#0A1216;--panel:#111F27;--panel2:#0E1A21;--segtrack:#070E12;--segon:#1E323C;--segring:rgba(231,239,242,.16);--ink:#E7EFF2;--muted:#9DB0B8;--faint:#6E838C;--line:#1E323B;
  --accent:#5EEAD4;--accent-ink:#06201D;--avail:#F0B24A;--posted:#9F87FF;--warn:#F2A06B;--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 22px -12px rgba(0,0,0,.6);color-scheme:dark}
@media (prefers-color-scheme:dark){:host(:not([data-theme=light])){--bg:#0A1216;--panel:#111F27;--panel2:#0E1A21;--segtrack:#070E12;--segon:#1E323C;--segring:rgba(231,239,242,.16);--ink:#E7EFF2;--muted:#9DB0B8;--faint:#6E838C;--line:#1E323B;
  --accent:#5EEAD4;--accent-ink:#06201D;--avail:#F0B24A;--posted:#9F87FF;--warn:#F2A06B;--shadow:0 1px 2px rgba(0,0,0,.3),0 8px 22px -12px rgba(0,0,0,.6);color-scheme:dark}}
*{box-sizing:border-box}
.app{position:absolute;inset:0;display:grid;grid-template-columns:232px minmax(0,1fr);background:var(--bg);color:var(--ink);
  font:14px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;font-variant-numeric:tabular-nums}
button{font:inherit;color:inherit;background:none;border:0;cursor:pointer;padding:0}
button:focus-visible,a:focus-visible,input:focus-visible{outline:2px solid var(--accent);outline-offset:2px;border-radius:6px}
a{color:inherit;text-decoration:none}
/* sidebar */
.side{display:flex;flex-direction:column;gap:4px;padding:20px 14px 16px;border-right:1px solid var(--line);background:var(--panel);min-height:0}
.brand{display:flex;align-items:center;gap:10px;padding:0 8px 18px}
.brand .logo{width:34px;height:34px;flex:none;border-radius:9px;box-shadow:0 0 0 1px rgba(0,0,0,.08)}
.word{font-family:"Chakra Petch",-apple-system,sans-serif;font-weight:700;font-size:19px;letter-spacing:.01em;line-height:1}
.word span{color:var(--accent)}
.brand small{display:block;font-size:11px;color:var(--muted);margin-top:4px;font-weight:500;letter-spacing:.02em}
.nav{display:flex;align-items:center;gap:11px;padding:9px 10px;border-radius:9px;color:var(--muted);font-weight:600;font-size:14px;text-align:left;width:100%;transition:background .15s,color .15s}
.nav svg{width:18px;height:18px;flex:none}
.nav:hover{background:var(--panel2);color:var(--ink)}
.nav[aria-current=page]{background:color-mix(in srgb,var(--accent) 11%,transparent);color:var(--accent)}
.nav .count{margin-left:auto;font-size:11.5px;font-weight:700;min-width:22px;text-align:center;padding:1px 7px;border-radius:99px;background:color-mix(in srgb,var(--avail) 18%,transparent);color:var(--avail)}
.nav kbd{opacity:0;transition:opacity .15s;margin-left:auto;font:600 10.5px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--faint);border:1px solid var(--line);border-radius:4px;padding:3px 5px}
.nav .count+kbd{margin-left:6px}
.nav:hover kbd,.nav:focus-visible kbd{opacity:1}
.sp{flex:1}
.foot{display:flex;flex-direction:column;gap:10px;padding:12px 8px 0;border-top:1px solid var(--line);font-size:12px;color:var(--muted)}
.who{font-weight:650;color:var(--ink);font-size:13px}
.row{display:flex;align-items:center;gap:8px}
.chipbtn{display:inline-flex;align-items:center;gap:6px;padding:6px 10px;border-radius:8px;border:1px solid var(--line);background:var(--panel);font-size:12.5px;font-weight:600;color:var(--ink);white-space:nowrap;transition:border-color .15s,background .15s}
.chipbtn:hover{border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}
.chipbtn svg{width:14px;height:14px}
.chipbtn.ghost{border-color:transparent;background:none;color:var(--muted);padding:6px 6px}
.chipbtn.ghost:hover{color:var(--ink)}
.chipbtn.primary{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
.chipbtn[disabled]{opacity:.45;cursor:default}
.theme{display:flex;border:1px solid var(--line);border-radius:8px;overflow:hidden}
.theme button{flex:1;padding:5px 0;font-size:11.5px;font-weight:600;color:var(--muted)}
.theme button[aria-pressed=true]{background:var(--panel2);color:var(--ink)}
.dot{width:7px;height:7px;border-radius:50%;background:var(--accent);flex:none}
.dot.busy{background:var(--avail);animation:pulse 1s ease-in-out infinite}
.dot.err{background:#D9534F}
@keyframes pulse{50%{opacity:.35}}
/* main */
.main{display:flex;flex-direction:column;min-width:0;min-height:0}
.top{display:flex;align-items:center;gap:14px;flex-wrap:wrap;padding:18px 28px 14px;border-bottom:1px solid var(--line);background:color-mix(in srgb,var(--bg) 85%,var(--panel))}
.top h1{margin:0;font-size:22px;font-weight:750;letter-spacing:-.01em;text-wrap:balance}
.top .sub{color:var(--muted);font-size:13px;font-weight:500}
.top .tools{margin-left:auto;display:flex;gap:8px;align-items:center;flex-wrap:wrap}
.view{flex:1;overflow:auto;padding:22px 28px 40px;min-height:0}
.banner{margin:0 0 16px;padding:10px 14px;border-radius:10px;font-size:13px;font-weight:600;display:flex;gap:10px;align-items:center;background:color-mix(in srgb,var(--accent) 9%,transparent);color:var(--accent)}
.banner.warn{background:color-mix(in srgb,var(--avail) 13%,transparent);color:var(--warn)}
.banner.demo{background:color-mix(in srgb,var(--posted) 10%,transparent);color:var(--posted)}
/* segmented */
.seg{display:inline-flex;padding:3px;border-radius:10px;background:var(--segtrack);border:1px solid var(--line);box-shadow:inset 0 1px 2px rgba(17,31,38,.06)}
.seg button{padding:5px 13px;border-radius:7px;font-size:13px;font-weight:650;color:var(--muted);transition:background .15s,color .15s,box-shadow .15s}
.seg button:not([aria-pressed=true]):hover{color:var(--ink);background:color-mix(in srgb,var(--segon) 45%,transparent)}
.seg button[aria-pressed=true]{background:var(--segon);color:var(--ink);box-shadow:0 0 0 1px var(--segring),0 2px 6px -2px rgba(17,31,38,.28)}
.seg b{font-weight:700;color:var(--faint);margin-left:4px}
.seg button[aria-pressed=true] b{color:var(--avail)}
/* unit chips */
.ufilter{display:flex;gap:6px;flex-wrap:wrap}
.uf{display:inline-flex;align-items:center;gap:6px;padding:4px 10px 4px 8px;border-radius:99px;border:1px solid var(--line);font-size:12px;font-weight:650;background:var(--panel)}
.uf i{width:9px;height:9px;border-radius:3px;display:block}
.uf[aria-pressed=false]{opacity:.42}
.uf[aria-pressed=false] i{background:var(--faint)!important}
/* pool */
.months{display:grid;grid-template-columns:repeat(auto-fill,minmax(196px,1fr));gap:12px;margin-bottom:20px}
.mm{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:10px 12px 12px}
.mm h3{margin:0 0 7px;font-size:12.5px;font-weight:700;color:var(--muted);letter-spacing:.02em}
.mm .g{display:grid;grid-template-columns:repeat(7,1fr);gap:3px}
.mm .h{font-size:9.5px;color:var(--faint);text-align:center;font-weight:700}
.mm .d{position:relative;height:22px;border-radius:5px;font-size:10.5px;display:flex;align-items:center;justify-content:center;color:var(--muted);font-weight:600}
.mm .d.on{color:#fff}
.mm .d.pc{color:var(--ink)}
.mm .d.open{box-shadow:inset 0 0 0 1.6px var(--avail);cursor:pointer}
.mm .d.open:hover{background:color-mix(in srgb,var(--avail) 16%,transparent)}
.mm .d.sel{outline:2px solid var(--avail);outline-offset:1px}
.pday{margin:-6px 0 20px;padding:12px 14px;border:1px solid color-mix(in srgb,var(--avail) 45%,var(--line));background:color-mix(in srgb,var(--avail) 6%,var(--panel));border-radius:14px}
.pday .pdh{display:flex;align-items:center;gap:12px;margin-bottom:10px;font-size:13px;color:var(--muted)}
.pday .pdh b{color:var(--ink);font-size:15px}
.pday .pdh .x{margin-left:auto;padding:5px;border-radius:8px;color:var(--muted);display:grid}
.pday .pdh .x:hover{background:var(--panel2);color:var(--ink)}
.pday .pdh .x svg{width:15px;height:15px}
.pday .pdc{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:10px}
.pday .pda{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
.mm .d.today{outline:1.5px solid var(--accent);outline-offset:-1px}
.mm .d.past{opacity:.45}
.legend{display:flex;gap:16px;flex-wrap:wrap;font-size:12px;color:var(--muted);margin:-8px 0 18px;align-items:center}
.legend span{display:inline-flex;gap:6px;align-items:center}
.legend i{width:12px;height:12px;border-radius:3px;display:block}
.poolwrap{display:grid;grid-template-columns:minmax(0,1fr);gap:22px;align-items:start}
.pbar{display:flex;gap:16px;align-items:center;flex-wrap:wrap;margin-bottom:12px}
.pbar .legend{margin:0}
.pbar .seg{padding:4px;border-radius:12px}
.pbar .seg button{padding:8px 18px;font-size:14.5px;border-radius:9px}
.pbar .seg b{margin-left:6px}
.pbar .legend{font-size:13px}
.ufrow{display:flex;justify-content:center;margin:-4px 0 18px}
.ufrow .ufilter{display:flex;flex-wrap:wrap;justify-content:center;gap:8px}
.pool3{display:grid;grid-template-columns:minmax(0,1fr) minmax(0,1fr);gap:18px;align-items:start}
@media (min-width:1280px){.pool3{grid-template-columns:minmax(0,1fr) minmax(0,1fr) 340px}}
@media (max-width:900px){.pool3{grid-template-columns:minmax(0,1fr)}}
.pcol{display:flex;flex-direction:column;gap:7px;min-width:0}
.pcol h3{margin:0 0 2px;font-size:15px;font-weight:750;display:flex;align-items:baseline;gap:7px}
.pcol h3 b{font-size:13px;font-weight:700;color:var(--avail)}
.pcol .dayhead{margin:8px 0 0}
.pcol .dayhead:nth-child(2){margin-top:0}
/* "For me": the clashing ones go; the For me list takes the room of both columns, cards two-up when there's space */
.pool3.one{grid-template-columns:minmax(0,1fr)}
@media (min-width:1280px){.pool3.one{grid-template-columns:minmax(0,1fr) 340px}}
.rt{margin-top:10px;border:1px solid var(--line);border-radius:12px;background:var(--panel);padding:2px 12px}
.rt .rth{display:flex;align-items:center;gap:8px}
.rt .rtt{flex:1;display:flex;align-items:center;gap:7px;background:none;border:0;padding:10px 0;font:inherit;font-size:13.5px;font-weight:680;color:var(--ink);cursor:pointer;text-align:left}
.rt .rtt svg{width:15px;height:15px;color:var(--muted)}
.rt .rtt .chev{margin-left:auto;transition:transform .15s}
.rt.open .rtt .chev{transform:rotate(180deg)}
.rt .eyeb{background:none;border:0;padding:6px;color:var(--muted);cursor:pointer;border-radius:6px;display:flex}
.rt .eyeb:hover{color:var(--ink);background:var(--panel2)}
.rt .eyeb svg{width:16px;height:16px}
.rt .rtl{display:flex;flex-direction:column;gap:6px;padding:0 0 10px}
.rt .rtr{display:flex;align-items:center;gap:8px;font-size:12.5px}
.rt .rtr .pill{font-size:10.5px;padding:2px 7px}
.rt .rtr .who{margin-left:auto;color:var(--muted);font-size:11.5px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.rtshow{align-self:flex-end;margin-top:8px;display:inline-flex;align-items:center;gap:5px;background:none;border:0;color:var(--muted);font:inherit;font-size:11.5px;cursor:pointer;padding:4px}
.rtshow:hover{color:var(--ink)}
.rtshow svg{width:14px;height:14px}
.empty.sm{padding:18px;font-size:13px}
.card.sm{grid-template-columns:34px minmax(0,1fr);gap:12px;padding:8px 12px 8px 15px;border-radius:10px}
.card.sm::before{width:4px}
.card.sm .dn{font-size:21px;margin:1px 0 0}
.card.sm .dw{font-size:10px}
.card.sm .ln1{gap:7px;flex-wrap:nowrap}
.card.sm .hrs{font-size:13px;font-weight:600;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
.card.sm .pill,.card.sm .tag{white-space:nowrap;flex:none}
.card.sm .flag{margin:0 0 0 auto;font-size:12px;white-space:nowrap;flex:none}
.card.sm .meta{margin-top:3px;font-size:12px;display:flex;gap:10px;align-items:baseline;min-width:0}
.card.sm .meta>span:first-child{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;min-width:0}
@media (min-width:1280px){.poolwrap{grid-template-columns:minmax(0,1fr) 340px}}
.cards{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:12px}
.dayhead{grid-column:1/-1;margin:10px 0 -2px;font-size:12px;font-weight:750;color:var(--muted);letter-spacing:.05em;text-transform:uppercase}
.dayhead:first-child{margin-top:0}
.card{position:relative;display:grid;grid-template-columns:58px minmax(0,1fr);gap:14px;align-items:center;padding:13px 14px 13px 18px;background:var(--panel);border:1px solid var(--line);border-radius:12px;text-align:left;width:100%;transition:border-color .15s,box-shadow .15s,transform .15s;overflow:hidden}
.card:hover{box-shadow:var(--shadow);border-color:color-mix(in srgb,var(--ink) 14%,var(--line))}
.card[aria-selected=true]{border-color:var(--accent);box-shadow:0 0 0 1px var(--accent)}
.card::before{content:"";position:absolute;left:0;top:0;bottom:0;width:5px;background:var(--u)}
.card.clash{opacity:.66}
.date{text-align:center;line-height:1}
.date .dw{font-size:11px;font-weight:700;color:var(--muted);text-transform:uppercase;letter-spacing:.05em}
.date .dn{font-size:28px;font-weight:780;margin:3px 0 2px;letter-spacing:-.02em}
.date .dm{font-size:11px;font-weight:700;color:var(--faint);text-transform:uppercase;letter-spacing:.06em}
.ln1{display:flex;align-items:center;gap:8px;flex-wrap:wrap}
.pill{display:inline-block;padding:2px 8px;border-radius:6px;font-size:11.5px;font-weight:750;color:#fff;background:var(--u);letter-spacing:.01em}
.full{font-weight:650;font-size:13.5px;min-width:0}
.meta{color:var(--muted);font-size:12.5px;margin-top:4px}
.flag{display:inline-flex;align-items:center;gap:5px;margin-top:7px;font-size:12px;font-weight:700}
.flag.ok{color:var(--avail)}
.flag.no{color:var(--muted);font-weight:600}
.tag{display:inline-block;font-size:10.5px;font-weight:750;padding:2px 7px;border-radius:99px;letter-spacing:.03em;text-transform:uppercase}
.tag.you{background:color-mix(in srgb,var(--posted) 14%,transparent);color:var(--posted)}
.empty{padding:50px 20px;text-align:center;color:var(--muted);background:var(--panel);border:1px dashed var(--line);border-radius:14px}
.empty b{display:block;color:var(--ink);font-size:15px;margin-bottom:4px}
/* detail panel */
.detail{position:sticky;top:0;background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:18px;display:none}
@media (min-width:1280px){.detail{display:block}}
.detail h2{margin:0;font-size:18px;font-weight:750}
.detail .k{font-size:11px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase;margin:18px 0 8px}
.tl{display:flex;flex-direction:column;gap:5px}
.tlr{display:grid;grid-template-columns:78px minmax(0,1fr);gap:10px;align-items:center;font-size:12.5px;padding:5px 8px;border-radius:7px}
.tlr.sel{background:color-mix(in srgb,var(--avail) 12%,transparent)}
.tlr .dd{color:var(--muted);font-weight:650}
.tlr.sel .dd{color:var(--ink)}
.mini{display:inline-flex;align-items:center;padding:2px 7px;border-radius:5px;font-size:11px;font-weight:750;color:#fff;background:var(--u);margin-right:4px}
.mini.pc{background:color-mix(in srgb,var(--u) 22%,transparent);color:var(--u)}
.mini.busy{background:none;border:1px dashed var(--muted);color:var(--muted)}
.off{color:var(--faint)}
.wl{display:flex;flex-direction:column;gap:4px;font-size:12.5px}
.wl div{display:flex;gap:8px;align-items:center}
.wl i{width:8px;height:8px;border-radius:2px;flex:none}
.wl .u{width:96px;color:var(--muted);font-weight:650;flex:none}
.act{display:flex;flex-direction:column;gap:8px;margin-top:18px}
.act .chipbtn{justify-content:center;padding:9px 12px}
.fine{font-size:11.5px;color:var(--faint);margin-top:10px;line-height:1.45}
/* month grid */
.msgrid{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(470px,100%),1fr));gap:26px}
.mhead{display:flex;align-items:baseline;gap:12px;margin:0 0 10px;flex-wrap:wrap}
.mhead h2{margin:0;font-size:18px;font-weight:750}
.mhead .st{font-size:13px;font-weight:650;color:var(--muted)}
.mhead .bd{font-size:12.5px;font-weight:700;color:var(--accent);white-space:pre}
.wk{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:4px}
.wk .h{font-size:11px;font-weight:750;color:var(--faint);text-align:center;padding-bottom:3px;text-transform:uppercase;letter-spacing:.04em}
.cell{position:relative;min-height:84px;background:var(--panel);border:1px solid var(--line);border-radius:9px;padding:5px 5px 6px;display:flex;flex-direction:column;gap:3px;overflow:hidden}
.cell.today{border-color:var(--accent);box-shadow:inset 0 0 0 1px var(--accent)}
.cell .n{font-size:12px;font-weight:650;color:var(--muted);padding-left:2px}
.cell.today .n{color:var(--accent);font-weight:850}
.cell.past .n{opacity:.6}
.blk{border-radius:6px;padding:3px 6px;font-size:11.5px;font-weight:750;color:#fff;background:var(--u);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.blk .t{font-weight:600;opacity:.85;font-size:10.5px;margin-left:4px}
.blk.pc{background:color-mix(in srgb,var(--u) 22%,transparent);color:var(--u);border-top-left-radius:0;border-bottom-left-radius:0;margin-left:-6px}
.blk.past{opacity:.5}
.busytag{border:1px dashed var(--muted);color:var(--muted);border-radius:6px;padding:2px 6px;font-size:11px;font-weight:650;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.busytag.approved{border-style:solid}
.osq{position:absolute;right:6px;bottom:6px;width:11px;height:11px;border-radius:3px;box-shadow:inset 0 0 0 1.6px var(--avail)}
.psq{position:absolute;left:6px;bottom:6px;width:11px;height:11px;border-radius:3px;background:var(--posted)}
.busytag.mine{border-color:var(--warn);color:var(--warn)}
.blk.posted{box-shadow:inset 0 0 0 2px color-mix(in srgb,var(--posted) 80%,#fff);background:repeating-linear-gradient(135deg,var(--u) 0 7px,color-mix(in srgb,var(--u) 82%,#fff) 7px 14px)}
.cell.clk{cursor:pointer;transition:border-color .12s,box-shadow .12s}
.cell.clk:hover{border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}
.cell.clk:focus-visible{outline:2px solid var(--accent);outline-offset:1px}
.cell.sel{border-color:var(--accent);box-shadow:0 0 0 3px color-mix(in srgb,var(--accent) 22%,transparent)}
.msview .cell{-webkit-user-select:none;user-select:none}
.cell.msel{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 9%,var(--panel));box-shadow:inset 0 0 0 1px var(--accent)}
.cell.msel .n{color:var(--accent);font-weight:800}
.mpick{display:flex;flex-wrap:wrap;align-items:center;gap:6px 16px;margin-top:12px;font-size:12.5px;color:var(--muted)}
.mpick b{color:var(--ink);font-size:15px;margin-right:3px;font-variant-numeric:tabular-nums}
.mpick .chipbtn{margin-left:auto}
.msstrip{flex:none;padding:12px 28px 12px;border-bottom:1px solid var(--line)}
.msstrip .banner{margin:0 0 10px}
.msstrip .quiet{margin:0;padding:0;border:0}
.msview section{scroll-margin-top:12px}
.msview section + section{margin-top:0}
.mslegend{display:flex;flex-wrap:wrap;gap:4px 18px;margin-top:8px;font-size:12px;color:var(--muted);align-items:center}
.mslegend span{display:inline-flex;align-items:center;gap:7px}
.mslegend i{width:11px;height:11px;border-radius:3px;display:inline-block}
.mslegend .lg-open{box-shadow:inset 0 0 0 1.6px var(--avail)}
.mslegend .lg-post{background:var(--posted)}
.mslegend .lg-busy{border:1px dashed var(--warn)}
.mslegend .hint{color:var(--faint);margin-left:auto}
.top .tools .tsep{width:1px;height:22px;background:var(--line);margin:0 4px}
.quiet{display:flex;flex-wrap:wrap;gap:6px 26px;margin:18px 0 0;padding-top:14px;border-top:1px solid var(--line);font-size:12.5px;color:var(--muted)}
.quiet b{font-size:10.5px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase;margin-right:8px}
.stat{background:var(--panel);border:1px solid var(--line);border-radius:12px;padding:12px 14px}
.stat .k{font-size:11px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase}
.stat .v{font-size:20px;font-weight:780;margin-top:4px;letter-spacing:-.01em}
.stat .s{font-size:12.5px;color:var(--muted);margin-top:2px}
/* who's on board */
.board{overflow:auto;border:1px solid var(--line);border-radius:14px;background:var(--panel)}
.board table{border-collapse:separate;border-spacing:0;width:100%;min-width:880px}
.board th,.board td{border-bottom:1px solid var(--line);border-right:1px solid var(--line);vertical-align:top}
.board tr:last-child td{border-bottom:0}
.board th:last-child,.board td:last-child{border-right:0}
.board thead th{position:sticky;top:0;background:var(--panel);z-index:1;padding:10px 8px;font-size:12px;font-weight:700;color:var(--muted);text-align:left}
.board thead th .big{display:block;font-size:20px;font-weight:780;color:var(--ink);letter-spacing:-.02em}
.board thead th.today{color:var(--accent)}
.board thead th.today .big{color:var(--accent)}
.board td.today,.board th.today{background:color-mix(in srgb,var(--accent) 5%,var(--panel))}
.board td.unit{position:sticky;left:0;background:var(--panel);z-index:1;padding:10px 12px;width:150px;min-width:150px}
.board td.unit b{display:block;font-size:13px;font-weight:780;color:var(--u)}
.board td.unit span{font-size:11.5px;color:var(--faint)}
.board td.c{padding:6px;min-width:112px}
.whov{display:flex;flex-direction:column;overflow:hidden;padding-bottom:22px}
.wweek{flex:1 1 0;min-height:0;overflow-x:auto;overflow-y:auto;position:relative;border:1px solid var(--line);border-radius:14px;background:var(--panel);overscroll-behavior-x:contain;container-type:inline-size}
.wgrid{display:grid;--lw:clamp(118px,13.5cqw,168px);grid-template-columns:var(--lw) repeat(var(--n),max(118px,calc((100cqw - var(--lw)) / 7)));grid-template-rows:auto repeat(var(--r),minmax(min-content,1fr));height:100%;width:max-content}
@media (max-height:560px){.whov{overflow:auto}.wweek{flex:none;height:460px}}
@media (max-height:820px){.whov{padding-top:14px;padding-bottom:14px}.wh{padding:5px 6px 4px}.wh b{font-size:19px}.wc{padding:3px 4px;gap:2px}.wr{min-height:30px;padding:2px 8px}.wr b{font-size:13px}.wr small{font-size:10px;line-height:1.15}.wr.bud{padding:1px 8px}.wlab{padding-top:4px;padding-bottom:4px;gap:2px}}
.wweek{cursor:grab}
.wweek.grabbing{cursor:grabbing;user-select:none;-webkit-user-select:none}
.wweek.grabbing *{cursor:grabbing!important}
.wmon{display:grid;grid-template-columns:1fr auto 1fr;align-items:baseline;padding:0 6px 10px;flex:none}
.wmon b{font-size:24px;font-weight:800;color:var(--ink);letter-spacing:-.02em;display:flex;align-items:baseline;gap:10px}
.wmon b i{font-style:normal;color:var(--muted);font-weight:700}
.wmon b em{font-style:normal;font-size:16px;color:var(--faint);font-weight:600}
.wmon span:last-child{justify-self:end;font-size:15px;font-weight:700;color:var(--muted);letter-spacing:.04em;font-variant-numeric:tabular-nums}
@media (max-height:820px){.wmon{padding-bottom:6px}.wmon b{font-size:20px}}
.wcorner,.wh,.wlab,.wc{border-bottom:1px solid var(--line)}
.wh,.wc{border-left:1px solid var(--line)}
.wcorner{position:sticky;left:0;top:0;z-index:3;background:var(--panel)}
.wh{position:sticky;top:0;z-index:2;background:var(--panel);display:flex;flex-direction:column;align-items:center;padding:8px 6px 7px;color:var(--muted)}
.wh small{font-size:12px;font-weight:650;letter-spacing:.03em}
.wh b{font-size:22px;font-weight:780;color:var(--ink);letter-spacing:-.02em;line-height:1.1}
.wh b i{font-style:normal;font-size:11px;font-weight:700;color:var(--muted);margin-left:3px;letter-spacing:0}
.wh.is-today{background:var(--accent);color:var(--accent-ink);border-left-color:var(--accent)}
.wh.is-today b,.wh.is-today b i{color:var(--accent-ink)}
.wh.past b{color:var(--muted)}
.wh.som{border-left:2px solid color-mix(in srgb,var(--ink) 30%,var(--line))}
.wlab{position:sticky;left:0;z-index:1;background:var(--panel);padding:8px 10px 8px 22px;display:flex;flex-direction:column;justify-content:center;gap:4px;box-shadow:1px 0 0 var(--line)}
.wlab::before{content:"";position:absolute;left:10px;top:9px;bottom:9px;width:4px;border-radius:2px;background:var(--u)}
.wlab b{font-size:14px;font-weight:780;color:var(--ink);line-height:1.15}
.wlab .ph{display:flex;flex-wrap:wrap;gap:2px 9px;font-size:11.5px;font-weight:600;color:var(--muted);font-variant-numeric:tabular-nums}
.wlab .ph span{display:inline-flex;align-items:center;gap:3px}
.wlab .ph svg{width:11px;height:11px;flex:none;opacity:.8}
.wc{display:flex;flex-direction:column;gap:3px;padding:4px 5px;min-width:0}
.wc.is-today{background:color-mix(in srgb,var(--accent) 7%,var(--panel))}
.wc.past>*{opacity:.55}
.wr{flex:1 0 auto;min-height:36px;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:0;width:100%;padding:3px 8px;border-radius:7px;text-align:center;
  background:color-mix(in srgb,var(--u) 13%,var(--panel));border:1px solid color-mix(in srgb,var(--u) 16%,transparent);transition:box-shadow .15s,opacity .15s}
.wr b{font-size:13.5px;font-weight:700;line-height:1.2;color:color-mix(in srgb,var(--u) 62%,var(--ink));max-width:100%;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.wr small{font-size:10.5px;color:var(--muted);white-space:nowrap;font-variant-numeric:tabular-nums}
.wc.is-today .wr{background:color-mix(in srgb,var(--u) 30%,var(--panel));border-color:color-mix(in srgb,var(--u) 55%,transparent)}
.wc.is-today .wr b{color:var(--ink)}
.wr.me{background:var(--u)!important;border-color:var(--u)!important}
.wr.me b,.wr.me small{color:#fff!important}
.wr.bud{background:none!important;border-style:dashed;flex:0 0 auto;min-height:0;flex-direction:row;gap:6px;padding:2px 8px}
.wr.hl{box-shadow:0 0 0 2px var(--avail)}
.wr.dim{opacity:.3}
.wr:hover{box-shadow:0 0 0 1px var(--u)}
.wr-doc{flex:none;display:flex;align-items:center;justify-content:center;gap:4px;font-size:12px;font-weight:650;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.wr-doc svg{flex:none;color:var(--posted)}
@container (max-width:1120px){.wc{padding:3px}.wr{padding:2px 4px}.wr b{font-size:12.5px;letter-spacing:-.01em}.wr small{font-size:10px}.wr.bud{padding:1px 4px}.wr.bud small{display:none}.wlab{padding-left:18px;padding-right:6px}.wlab::before{left:8px}.wlab b{font-size:13px}.wlab .ph{font-size:10.5px;gap:1px 6px}}
.wc.is-today .wr-doc{color:var(--ink)}
.wlab.oc::before{background:var(--posted)}
.wc.oc{background:color-mix(in srgb,var(--posted) 5%,var(--panel));justify-content:center;gap:2px;font-size:12.5px}
.wc.oc.is-today{background:color-mix(in srgb,var(--posted) 14%,var(--panel))}
.wc.oc span{display:flex;align-items:center;justify-content:center;gap:5px;font-weight:650;color:var(--ink);text-align:center;white-space:nowrap}
.wc.oc span svg{flex:none}
.wc.oc em{font-style:normal;font-weight:500;color:var(--muted);font-size:11px;overflow:hidden;text-overflow:ellipsis}
.wc.oc>span{max-width:100%;gap:4px!important}
.wc.oc .off{color:var(--faint);text-align:center}
.wbud{flex:none;padding:8px 2px 0;font-size:12px;color:var(--muted)}
/* take-a-shift sheet (Lightning Bolt's own accept page, in place) */
.sheetbg{position:fixed;inset:0;z-index:20;display:flex;align-items:center;justify-content:center;padding:24px;background:rgba(8,16,20,.5);
  font:14px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;color:var(--ink);-webkit-font-smoothing:antialiased}
.sheet{width:min(580px,100%);height:min(780px,100%);display:flex;flex-direction:column;overflow:hidden;background:var(--panel);border:1px solid var(--line);border-radius:16px;box-shadow:var(--shadow)}
.sheet header{display:flex;gap:14px;align-items:flex-start;padding:16px 18px 14px;border-bottom:1px solid var(--line)}
.sheet header h2{margin:6px 0 2px;font-size:19px;font-weight:750}
.sheet header .meta{color:var(--muted);font-size:13px}
.sheet header .x{margin-left:auto;padding:6px;border-radius:8px;color:var(--muted)}
.sheet header .x:hover{background:var(--panel2);color:var(--ink)}
.sheet header .x svg{width:16px;height:16px}
.sheet .warnline{margin-top:8px;padding:6px 10px;border-radius:8px;font-size:12.5px;font-weight:650;background:color-mix(in srgb,var(--avail) 14%,transparent);color:var(--warn)}
.sheet iframe{flex:1;width:100%;border:0;background:#fff}
.sheet .demo{flex:1;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:14px;padding:30px;text-align:center;color:var(--muted)}
.sheet footer{display:flex;gap:8px;align-items:center;padding:12px 16px;border-top:1px solid var(--line);font-size:12px;color:var(--faint)}
.sheet footer .sp{flex:1}
.sheetbg.drawer{background:transparent;pointer-events:none;justify-content:flex-end;align-items:stretch;padding:14px}
.sheetbg.drawer .sheet{pointer-events:auto;width:min(392px,100%);height:auto;max-height:100%;animation:slidein .18s ease-out}
/* the day panel docks (right or left) and the calendar makes room for it, or floats wherever you drag it */
.main{transition:padding .18s ease-out}
.app.dock-r .main{padding-right:406px}
.app.dock-l .main{padding-left:416px}
.app.dock-r .msgrid,.app.dock-l .msgrid{grid-template-columns:repeat(auto-fit,minmax(min(100%,max(330px,calc((100% - 21px) / 2))),1fr));gap:20px}
/* while the day panel is open the sidebar tucks away to a thin edge; hover (or Tab into) the left edge to slide it back */
.app.sidehide{grid-template-columns:0 minmax(0,1fr)}
.app.sidehide>.side{grid-column:1;position:absolute;top:0;bottom:0;left:0;width:232px;z-index:25;transform:translateX(calc(-100% + 10px));transition:transform .2s ease .3s,box-shadow .2s ease .3s}
.app.sidehide>.side>*{opacity:0;transition:opacity .15s ease .3s}
.app.sidehide>.side::after{content:"";position:absolute;top:50%;right:3px;width:4px;height:44px;margin-top:-22px;border-radius:2px;background:var(--line)}
.app.sidehide>.side:hover,.app.sidehide>.side:focus-within{transform:none;box-shadow:0 0 40px rgba(8,16,20,.18);transition-delay:.08s}
.app.sidehide>.side:hover>*,.app.sidehide>.side:focus-within>*{opacity:1;transition-delay:.08s}
.app.sidehide>.side:hover::after,.app.sidehide>.side:focus-within::after{display:none}
.app.sidehide>.main{grid-column:2}
@media (prefers-reduced-motion:reduce){.app.sidehide>.side,.app.sidehide>.side>*{transition:none}}
.sheetbg.drawer.dl{justify-content:flex-start;padding-left:24px}
.sheetbg.drawer.dl .sheet{animation-name:slideinl}
@keyframes slideinl{from{transform:translateX(-24px);opacity:0}to{transform:none;opacity:1}}
.sheetbg.drawer.fl{display:block;padding:0}
.sheetbg.drawer.fl .sheet{position:absolute;max-height:calc(100% - 28px);animation:none;box-shadow:0 14px 44px rgba(8,16,20,.22),0 0 0 1px var(--line)}
.sheetbg.drawer header{position:relative;cursor:grab;touch-action:none;user-select:none;-webkit-user-select:none}
.sheetbg.drawer header::before{content:"";position:absolute;top:6px;left:50%;width:34px;height:4px;border-radius:2px;background:var(--line);transform:translateX(-50%)}
.sheetbg.drawer header:hover::before{background:var(--faint)}
.sheetbg.drawer.dragging header{cursor:grabbing}
.sheetbg.drawer.dragging .sheet{opacity:.97;box-shadow:0 20px 60px rgba(8,16,20,.3),0 0 0 1px var(--accent)}
.dockhint{position:fixed;top:14px;bottom:14px;width:392px;border:2px dashed var(--accent);border-radius:16px;background:color-mix(in srgb,var(--accent) 7%,transparent);pointer-events:none;z-index:19}
@keyframes slidein{from{transform:translateX(24px);opacity:0}to{transform:none;opacity:1}}
@media (prefers-reduced-motion:reduce){.sheetbg.drawer .sheet{animation:none}}
.sheet .dnav{margin-left:auto;display:flex;gap:2px}
.sheet .dnav .x{margin:0;padding:6px;border-radius:8px;color:var(--muted)}
.sheet .dnav .x:hover{background:var(--panel2);color:var(--ink)}
.sheet .dnav .x svg{width:16px;height:16px}
.sheet .sb{flex:1;overflow:auto;padding:4px 18px 20px;min-height:0}
.sheet .sb h3{margin:18px 0 8px;font-size:10.5px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase}
.sheet .off{color:var(--muted);font-size:13px}
.dcard{display:flex;gap:12px;align-items:center;padding:10px 12px 10px 0;border:1px solid var(--line);border-radius:12px;background:var(--panel);overflow:hidden}
.dcard + .dcard{margin-top:8px}
.dcard .ubar{align-self:stretch;width:5px;flex:none;background:var(--u);border-radius:0 3px 3px 0}
.dcard .tx{flex:1;min-width:0;display:flex;flex-direction:column;gap:2px;font-size:13.5px}
.dcard .tx small{color:var(--muted);font-size:12.5px}
.dcard .acts{display:flex;flex-direction:column;align-items:stretch;gap:6px}
.dstat{font-size:11.5px;font-weight:700;margin-top:2px}
.dstat.posted{color:var(--posted)} .dstat.ok{color:var(--accent)} .dstat.no{color:var(--warn)}
.confirm{margin-top:8px;padding:12px 14px;border-radius:12px;background:color-mix(in srgb,var(--accent) 7%,var(--panel));border:1px solid color-mix(in srgb,var(--accent) 30%,var(--line));font-size:13px}
.confirm b{display:block;font-size:14px;margin-bottom:4px;color:var(--ink)}
.confirm p{margin:0 0 10px;color:var(--muted);line-height:1.45}
.confirm .row{display:flex;gap:8px;justify-content:flex-end}
.confirm input,.busyrow input,.sheet textarea,.partrow select{font:inherit;font-size:13.5px;color:var(--ink);background:var(--panel2);border:1px solid var(--line);border-radius:9px;padding:8px 10px;width:100%;box-sizing:border-box}
.sheet textarea{resize:vertical;min-height:54px}
.busyrow{display:flex;gap:8px}
.busyrow input{flex:1}
.acts2{display:flex;gap:8px;flex-wrap:wrap;margin-top:10px}
.chipbtn.danger{border-color:color-mix(in srgb,var(--warn) 60%,var(--line));color:var(--warn)}
.chipbtn.danger:hover{background:color-mix(in srgb,var(--warn) 10%,transparent)}
.evlist{display:flex;flex-direction:column;gap:4px}
.wl{display:flex;flex-direction:column;gap:5px;font-size:13px}
.wl div{display:flex;align-items:center;gap:8px}
.wl i{width:8px;height:8px;border-radius:2px;flex:none}
.wl .u{width:74px;flex:none;color:var(--muted);font-size:12px;font-weight:650}
.hrow{display:flex;align-items:center;gap:10px}
.sw{margin-left:auto;display:inline-flex;align-items:center;gap:7px;font:inherit;font-size:12px;font-weight:650;letter-spacing:0;text-transform:none;color:var(--muted);cursor:pointer;padding:2px 0}
.sw .trk{position:relative;width:28px;height:16px;border-radius:99px;background:color-mix(in srgb,var(--muted) 35%,var(--line));transition:background .15s}
.sw .trk i{position:absolute;top:2px;left:2px;width:12px;height:12px;border-radius:50%;background:#fff;box-shadow:0 1px 2px rgba(0,0,0,.25);transition:transform .15s}
.sw[aria-checked="true"]{color:var(--ink)}
.sw[aria-checked="true"] .trk{background:var(--accent)}
.sw[aria-checked="true"] .trk i{transform:translateX(12px)}
.sw:focus-visible{outline:2px solid var(--accent);outline-offset:3px;border-radius:6px}
@media (prefers-reduced-motion:reduce){.sw .trk,.sw .trk i{transition:none}}
.wl.ddocs{margin-bottom:12px;padding-bottom:10px;border-bottom:1px dashed var(--line)}
.wl.ddocs .u{width:96px;display:inline-flex;align-items:center;gap:4px}
.wl.ddocs .u svg{width:11px;height:11px}
.wl small{color:var(--muted);font-size:11.5px;font-weight:500}
.off.ddocs{margin-bottom:10px}
.sheet.give .seg{display:inline-flex}
.sheet.swap{width:min(1240px,100%);height:min(920px,100%)}
.swbody{display:grid;grid-template-columns:minmax(0,1fr) 360px;gap:22px;align-items:start}
.swside2{position:sticky;top:0;padding-top:2px}
.swside2 .swdayh{margin-top:4px;flex-wrap:wrap}
.swside2 .swo{grid-template-columns:minmax(0,1fr) auto}
.swside2 .swo .pill{grid-column:1/-1}
.swside2 .swo .acts{grid-column:1/-1;flex-wrap:wrap}
.swhint{font-size:13px;color:var(--muted);line-height:1.45;margin:6px 0 12px}
.swcur{display:flex;flex-direction:column;align-items:flex-start;gap:4px;padding:12px 14px;border:1px solid var(--line);border-left:3px solid var(--u);border-radius:10px}
.swcur small{color:var(--muted);font-size:12px}
.swcur .pill{background:color-mix(in srgb,var(--u) 15%,transparent);color:var(--u)}
.swcur b{color:var(--ink);font-size:14px}
.sheet header .swchg{display:flex;flex-wrap:wrap;align-items:center;gap:4px 10px;padding:3px 8px;margin:0 -8px;border-radius:8px;font:inherit;font-size:13px;color:var(--muted);text-align:left;cursor:pointer}
.sheet header .swchg:hover,.sheet header .swchg[aria-pressed="true"]{background:color-mix(in srgb,var(--accent) 8%,transparent)}
.swchg .chg{display:inline-flex;align-items:center;gap:3px;color:var(--accent);font-weight:700}
.swchg .chg svg{width:12px;height:12px}
.sc.dim{opacity:.42}
.sc.mk{cursor:pointer;border-color:color-mix(in srgb,var(--accent) 45%,var(--line))}
.sc.mk .n{color:var(--accent);font-weight:800}
.sc.mk.trade{box-shadow:inset 0 0 0 2px var(--accent)}
.sc .cnt{margin-top:auto;font-size:10px;font-weight:800;color:var(--accent);padding-left:1px;white-space:nowrap;font-variant-numeric:tabular-nums}
.sc .cnt.none{color:var(--faint);font-weight:650}
.swcal{margin-top:4px}
.swnav{display:flex;align-items:center;margin-bottom:-30px;position:relative;z-index:1;pointer-events:none}
.swnav .chipbtn{pointer-events:auto;width:30px;height:28px;padding:0;display:grid;place-items:center}
.swnav .sp{flex:1}
.smos{display:grid;grid-template-columns:repeat(auto-fill,minmax(330px,1fr));gap:22px 22px}
.smh{text-align:center;font-weight:750;font-size:14.5px;color:var(--ink);height:28px;line-height:28px;margin-bottom:6px}
.smg{display:grid;grid-template-columns:repeat(7,minmax(0,1fr));gap:3px}
.smg .h{text-align:center;font-size:10.5px;font-weight:700;color:var(--faint);letter-spacing:.04em;padding-bottom:2px}
.sc{display:flex;flex-direction:column;align-items:stretch;gap:2px;min-height:52px;padding:3px;border-radius:8px;border:1px solid var(--line);background:var(--panel);font:inherit;text-align:left;min-width:0;color:inherit}
.sc .n{font-size:11px;font-weight:650;color:var(--muted);font-variant-numeric:tabular-nums;padding-left:1px}
.sc.past{opacity:.5}
.sc.today{border-color:color-mix(in srgb,var(--accent) 55%,var(--line))}
.sc.today .n{color:var(--accent);font-weight:850}
.sc.av{cursor:pointer;transition:border-color .12s,background .12s}
.sc.av .n{color:var(--accent);font-weight:800}
.sc.av:hover{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 5%,var(--panel))}
.sc.sel{border-color:var(--accent);box-shadow:inset 0 0 0 1px var(--accent);background:color-mix(in srgb,var(--accent) 8%,var(--panel))}
.sc.trade{box-shadow:inset 0 0 0 1.5px var(--u)}
.sc.trade.sel{box-shadow:inset 0 0 0 1.5px var(--accent)}
.sc .mb{display:block;font-size:9px;font-weight:800;line-height:15px;height:15px;padding:0 3px;border-radius:4px;color:#fff;background:var(--u);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.sc .mb.pc{color:var(--u);background:color-mix(in srgb,var(--u) 20%,transparent)}
.sc .sq{display:flex;flex-wrap:wrap;gap:3px;margin-top:auto;padding:1px}
.sc .sq i{width:8px;height:8px;border-radius:2px;background:var(--u)}
.swkey{display:flex;flex-wrap:wrap;gap:6px 18px;margin:10px 0 2px;font-size:11.5px;color:var(--muted)}
.swkey span{display:inline-flex;align-items:center;gap:6px}
.swkey .kb{width:16px;height:9px;border-radius:3px;background:var(--accent)}
.swkey .kq{width:8px;height:8px;border-radius:2px;background:#ea7c1e;box-shadow:11px 0 0 #3b6fe0}
.swkey .kq{margin-right:11px}
.swdayh{display:flex;align-items:baseline;gap:10px;margin:18px 0 8px}
.swdayh b{font-size:15px;color:var(--ink)}
.swdayh span{font-size:12.5px;color:var(--muted)}
@media (max-width:999px){.swbody{grid-template-columns:1fr}.swside2{position:sticky;top:auto;bottom:-20px;z-index:2;max-height:44vh;overflow:auto;margin:0 -18px;padding:10px 18px 14px;background:var(--panel);border-top:1px solid var(--line);box-shadow:0 -10px 24px -14px rgba(0,0,0,.25)}}
@media (max-width:760px){.smos{grid-template-columns:1fr}}
.swlead{margin:14px 0 0;font-size:13.5px;color:var(--muted);line-height:1.45}
.swlead b{color:var(--ink)}
.swtools{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin:12px 0 10px}
.swtools .search{flex:1 1 200px}
.swu{display:flex;flex-wrap:wrap;gap:6px}
.swu .chipbtn{display:inline-flex;align-items:center;gap:6px}
.swu .dot{width:8px;height:8px;border-radius:2px;background:var(--u);flex:none}
.swlist{border:1px solid var(--line);border-radius:12px;overflow:hidden}
.swd{position:sticky;top:0;z-index:1;padding:7px 12px;font-size:11px;font-weight:750;letter-spacing:.06em;text-transform:uppercase;color:var(--muted);background:var(--panel2);border-top:1px solid var(--line)}
.swlist .swd:first-child{border-top:0}
.swo{display:grid;grid-template-columns:118px minmax(0,1fr) auto;gap:10px;align-items:center;padding:8px 12px;border-top:1px solid var(--line)}
.swd + .swo{border-top:0}
.swo .pill{justify-self:start;white-space:nowrap;background:color-mix(in srgb,var(--u) 15%,transparent);color:var(--u)}
.swo .tx b{display:block;font-size:13.5px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.swo .tx small{color:var(--muted);font-size:12px;font-variant-numeric:tabular-nums}
.swo .acts{display:flex;gap:6px}
.swpair{display:flex;align-items:stretch;gap:10px;margin-top:4px}
.swside{flex:1;display:flex;flex-direction:column;gap:3px;align-items:flex-start;padding:10px 12px;border-radius:12px;border:1px solid color-mix(in srgb,var(--u) 25%,var(--line));background:color-mix(in srgb,var(--u) 6%,var(--panel))}
.swside small{color:var(--muted);font-size:11.5px}
.swside .pill{background:color-mix(in srgb,var(--u) 15%,transparent);color:var(--u)}
.swarrow{align-self:center;font-size:20px;color:var(--muted)}
.linkbtn{background:none;border:0;padding:0;font:inherit;color:var(--accent);font-weight:650;cursor:pointer;text-decoration:underline;text-underline-offset:2px}
@media (max-width:560px){.swo{grid-template-columns:minmax(0,1fr) auto}.swo .pill{grid-column:1/-1}.swo .acts{flex-direction:column}.swpair{flex-direction:column}.swarrow{transform:rotate(90deg)}}
.partrow{display:flex;gap:12px;margin-top:10px;font-size:13px;color:var(--muted)}
.partrow label{display:flex;flex-direction:column;gap:4px;flex:1}
.pickall{display:flex;gap:10px;align-items:flex-start;width:100%;text-align:left;padding:10px 12px;border:1px solid var(--line);border-radius:12px;background:var(--panel);font:inherit;color:var(--ink);cursor:pointer}
.pickall small{display:block;color:var(--muted);font-size:12px;margin-top:2px}
.pickall .ck{width:16px;height:16px;border-radius:5px;border:1.5px solid var(--muted);flex:none;margin-top:1px}
.pickall.on{border-color:var(--accent);background:color-mix(in srgb,var(--accent) 7%,var(--panel))}
.pickall.on .ck{background:var(--accent);border-color:var(--accent);box-shadow:inset 0 0 0 3px var(--panel)}
.rlist{max-height:210px;overflow:auto;border:1px solid var(--line);border-radius:12px}
.rrow{display:flex;gap:10px;align-items:center;padding:8px 12px;font-size:13.5px;cursor:pointer;border-top:1px solid var(--line)}
.rrow:first-child{border-top:0}
.rrow label{flex:1;display:flex;gap:10px;align-items:center;cursor:pointer;min-width:0}
.rrow .txt.ic{width:28px;height:26px;padding:0;justify-content:center}
.chipbtn.txt{display:inline-flex;align-items:center;gap:6px;text-decoration:none;color:var(--accent)}
.chipbtn.txt svg{flex:none}
.swo .txt.ic2{padding-left:9px;padding-right:11px}
.txtrow{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:10px}
.swdayh .sp{flex:1}
.rrow:hover{background:var(--panel2)}
.rrow input{accent-color:var(--accent);width:15px;height:15px;margin:0}
.sheet .okc{width:52px;height:52px;border-radius:50%;display:grid;place-items:center;font-size:24px;font-weight:800;background:color-mix(in srgb,var(--accent) 14%,transparent);color:var(--accent)}
.sheet .okc.no{background:color-mix(in srgb,var(--warn) 14%,transparent);color:var(--warn)}
.sheet .quote{font-style:italic;color:var(--ink)}
.mp button.o{width:100%;text-align:left;cursor:pointer}
.mp button.o:hover{background:color-mix(in srgb,var(--avail) 12%,var(--panel2))}
.mp .take{font-size:12px;font-weight:750;color:var(--accent);white-space:nowrap}
.p{display:block;width:100%;text-align:left;padding:6px 8px;border-radius:7px;background:color-mix(in srgb,var(--u) 9%,transparent);margin-bottom:4px;font-size:12.5px;font-weight:650;line-height:1.25;transition:background .12s,box-shadow .12s}
.p:last-child{margin-bottom:0}
.p small{display:block;font-size:11px;font-weight:550;color:var(--muted);margin-top:1px}
.p.me{background:var(--u);color:#fff}
.p.me small{color:rgba(255,255,255,.85)}
.p.bud{background:none;border:1px dashed color-mix(in srgb,var(--u) 55%,transparent);font-weight:600;color:var(--muted)}
.p.hl{box-shadow:0 0 0 2px var(--avail)}
.p.dim{opacity:.3}
.search{display:flex;align-items:center;gap:8px;padding:6px 10px;border:1px solid var(--line);border-radius:8px;background:var(--panel);min-width:220px}
.search svg{width:14px;height:14px;color:var(--faint);flex:none}
.search input{border:0;background:none;outline:none;font:inherit;font-size:13px;color:var(--ink);width:100%}
input[type=date]{font:inherit;font-size:12.5px;font-weight:600;color:var(--ink);background:var(--panel);border:1px solid var(--line);border-radius:8px;padding:5px 8px}
/* crew */
.crewpick{display:flex;gap:8px;flex-wrap:wrap;margin-bottom:12px}
.who-chip{display:inline-flex;align-items:center;gap:6px;padding:5px 6px 5px 11px;border-radius:99px;background:color-mix(in srgb,var(--accent) 10%,transparent);color:var(--accent);font-size:12.5px;font-weight:700}
.who-chip button{width:18px;height:18px;border-radius:50%;display:grid;place-items:center;color:inherit}
.who-chip button:hover{background:color-mix(in srgb,var(--accent) 18%,transparent)}
.sugg{display:flex;gap:6px;flex-wrap:wrap;margin:-2px 0 16px}
.sugg button{padding:4px 10px;border-radius:99px;border:1px solid var(--line);font-size:12px;font-weight:600;color:var(--muted);background:var(--panel)}
.sugg button:hover{color:var(--ink);border-color:var(--accent)}
.cpick{position:relative}
.cpick .search .chev{color:var(--faint);margin-left:2px;flex:none}
.cdrop{position:absolute;top:calc(100% + 6px);left:0;z-index:30;width:max(100%,300px);background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:0 14px 40px -12px rgba(8,16,20,.28);overflow:hidden}
.cdh{display:flex;align-items:center;gap:10px;padding:9px 12px;border-bottom:1px solid var(--line);font-size:12px;color:var(--muted)}
.cdh span{margin-right:auto}
.cdh button{font-size:12px;font-weight:700;color:var(--muted);padding:3px 8px;border-radius:6px}
.cdh button:hover{background:var(--panel2);color:var(--ink)}
.cdh button.done{color:var(--accent)}
.cdl{max-height:320px;overflow:auto;padding:4px}
.cdl .opt{display:flex;align-items:center;gap:10px;width:100%;text-align:left;padding:7px 9px;border-radius:7px;font-size:13px;font-weight:600;color:var(--ink)}
.cdl .opt:hover{background:var(--panel2)}
.cdl .cb{flex:none;width:17px;height:17px;border-radius:5px;border:1.5px solid color-mix(in srgb,var(--muted) 60%,transparent);display:grid;place-items:center;font-size:11px;font-weight:900;color:var(--panel);line-height:1}
.cdl .opt[aria-selected=true] .cb{background:var(--accent);border-color:var(--accent)}
.cdl .none{padding:12px;font-size:12.5px;color:var(--faint)}
.crewtab{position:relative;overflow-x:auto;overscroll-behavior-x:contain;border:1px solid var(--line);border-radius:14px;background:var(--panel);cursor:grab}
.crewtab.grabbing{cursor:grabbing;user-select:none;-webkit-user-select:none}
.crewtab.grabbing *{cursor:grabbing!important}
.crewtab table{border-collapse:separate;border-spacing:0;table-layout:fixed;width:calc(190px + var(--nd) * 78px)}
.crewtab col.cn{width:190px}
.crewtab th,.crewtab td{padding:0 2px;text-align:center;vertical-align:middle;border-bottom:1px solid color-mix(in srgb,var(--line) 65%,transparent)}
.crewtab thead th{position:sticky;top:0;z-index:1;background:var(--panel);padding:12px 2px 9px;border-bottom:1px solid var(--line)}
.crewtab .dw{display:block;font-size:10.5px;font-weight:700;letter-spacing:.07em;text-transform:uppercase;color:var(--faint)}
.crewtab .dn{display:block;width:28px;height:28px;line-height:28px;margin:2px auto 0;border-radius:99px;font-size:15px;font-weight:720;color:var(--ink);font-variant-numeric:tabular-nums}
.crewtab .mo{display:block;min-height:13px;font-size:10.5px;font-weight:650;color:var(--muted)}
.crewtab th.today .dw{color:var(--accent)}
.crewtab th.today .dn{background:var(--accent);color:var(--panel)}
.crewtab .we{background:color-mix(in srgb,var(--ink) 2.5%,var(--panel))}
.crewtab .ws{box-shadow:inset 1px 0 0 var(--line)}
.crewtab .free{background:color-mix(in srgb,var(--accent) 8%,var(--panel))}
.crewtab td{height:46px}
.crewtab .nm{position:sticky;left:0;z-index:2;background:var(--panel);text-align:left;padding:0 14px;box-shadow:inset -1px 0 0 var(--line)}
.crewtab thead .nm{z-index:3}
.nmw{display:flex;align-items:center;gap:10px;min-width:0}
.crewtab .av{flex:none;width:26px;height:26px;border-radius:50%;display:grid;place-items:center;font-size:10px;font-weight:800;letter-spacing:.02em;background:color-mix(in srgb,var(--ink) 7%,transparent);color:var(--muted)}
.crewtab tr.me .av{background:color-mix(in srgb,var(--accent) 15%,transparent);color:var(--accent)}
.crewtab .pn{font-size:13px;font-weight:650;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.crewtab .pn.lbl{font-size:11px;font-weight:750;letter-spacing:.06em;text-transform:uppercase;color:var(--faint)}
.crewtab .you{font-size:10px;font-weight:750;letter-spacing:.06em;text-transform:uppercase;color:var(--faint)}
.crewtab tr.me td{border-bottom:2px solid var(--line)}
.crewtab .sh{display:block;max-width:70px;margin:0 auto;padding:4px 1px;border-radius:6px;font-size:10.5px;letter-spacing:-.01em;font-weight:750;color:#fff;background:var(--u);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
.crewtab .sh+.sh{margin-top:3px}
.crewtab .pcx{display:block;width:60%;max-width:40px;height:4px;margin:0 auto;border-radius:3px;background:color-mix(in srgb,var(--u) 45%,transparent)}
.crewtab tr.freerow td{height:38px;border-bottom:0}
.crewtab .fr{display:inline-grid;place-items:center;color:var(--accent)}
.crewtab .fr svg{width:18px;height:18px}
.crewfoot{display:flex;flex-wrap:wrap;align-items:center;gap:6px 18px;margin-top:12px;font-size:12px;color:var(--muted)}
.crewfoot .k{display:inline-flex;align-items:center;gap:7px}
.crewfoot i{display:inline-block}
.crewfoot .kfree{width:12px;height:12px;border-radius:3px;background:color-mix(in srgb,var(--accent) 18%,var(--panel));box-shadow:inset 0 0 0 1px color-mix(in srgb,var(--accent) 35%,transparent)}
.crewfoot .kpc{width:16px;height:4px;border-radius:3px;background:color-mix(in srgb,var(--muted) 45%,transparent)}
.crewfoot .sum{margin-left:auto;color:var(--faint)}
/* your calendars */
.ev{display:flex;align-items:center;gap:4px;font-size:10.5px;font-weight:600;color:var(--muted);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;padding:0 2px}
.ev i{width:6px;height:6px;border-radius:50%;background:var(--c);flex:none}
.ev span{overflow:hidden;text-overflow:ellipsis}
.more{font-size:10px;font-weight:700;color:var(--faint);padding:0 2px}
.cals{display:flex;align-items:center;gap:8px;flex-wrap:wrap;margin:0 0 18px}
.cals .lbl{font-size:11px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase;margin-right:2px}
.cal{display:inline-flex;align-items:center;gap:7px;padding:4px 5px 4px 10px;border-radius:99px;border:1px solid var(--line);background:var(--panel);font-size:12.5px;font-weight:650}
.cal>button{display:inline-flex;align-items:center;gap:7px}
.cal i{width:9px;height:9px;border-radius:50%;background:var(--c);display:block}
.cal[data-off] {opacity:.45}
.cal[data-off] i{background:none;box-shadow:inset 0 0 0 1.5px var(--c)}
.cal small{color:var(--faint);font-weight:600}
.cal .rm{width:20px;height:20px;border-radius:50%;display:grid;place-items:center;color:var(--faint)}
.cal .rm:hover{background:var(--panel2);color:var(--ink)}
.cal button em{font-style:normal;font-size:11px;color:var(--faint);margin-left:5px}
.cal button em.bad{color:var(--warn);font-weight:800}
.sheet.addcal{height:auto;max-height:100%}
.sheet.addcal input{font:inherit;font-size:13.5px;color:var(--ink);background:var(--panel2);border:1px solid var(--line);border-radius:9px;padding:9px 11px;width:100%;box-sizing:border-box}
.sheet.addcal input:focus{outline:2px solid color-mix(in srgb,var(--accent) 45%,transparent);border-color:var(--accent)}
.cmsg{font-size:12.5px;margin-top:8px;min-height:1px}
.cmsg.bad{color:var(--warn);font-weight:650}
.howto{display:grid;grid-template-columns:auto 1fr;gap:6px 12px;font-size:12.5px;color:var(--muted);line-height:1.45}
.howto b{color:var(--ink);font-weight:700}
.howto i{font-style:normal;color:var(--ink);font-weight:600}
.drop{outline:2px dashed var(--accent);outline-offset:-8px}
/* today */
.widgets{display:grid;grid-template-columns:minmax(0,1.75fr) minmax(300px,1fr);gap:18px;align-items:start;max-width:1500px}
.widgets.one{grid-template-columns:minmax(0,1fr)}
.wcol{display:flex;flex-direction:column;gap:18px;min-width:0}
@media (max-width:1020px){.widgets{grid-template-columns:minmax(0,1fr)}}
.w{background:var(--panel);border:1px solid var(--line);border-radius:14px;padding:16px 18px;min-width:0;container-type:inline-size;transition:opacity .15s}
.w.ghost{opacity:.35}
.w{position:relative}
.w h3 .grip{position:absolute;left:3px;top:13px;display:grid;place-items:center;width:14px;height:22px;color:var(--faint);cursor:grab;opacity:0;transition:opacity .15s;border-radius:4px}
.w h3 .grip:active{cursor:grabbing}
.w:hover h3 .grip,.w h3 .grip:focus-visible{opacity:1}
.w h3 .ctl2{margin-left:auto;display:flex;align-items:center;gap:6px}
.w h3 .ctl2 .go{margin-left:0}
.w h3 .wx{width:22px;height:22px;border-radius:6px;display:grid;place-items:center;color:var(--faint);opacity:0;transition:opacity .15s}
.w h3 .wx svg{width:13px;height:13px}
.w h3 .wx:hover{background:var(--panel2);color:var(--ink)}
.w:hover h3 .wx,.w h3 .wx:focus-visible{opacity:1}
@media (hover:none){.w h3 .grip,.w h3 .wx{opacity:.55}}
.wcol[data-wcol] > .w[draggable=true]{cursor:grab}
.wcol{min-height:40px}
.wempty{border:1.5px dashed var(--line);border-radius:14px;padding:30px 14px;text-align:center;color:var(--faint);font-size:13px}
.wempty.over{border-color:var(--accent);color:var(--accent)}
.wmark{height:0;margin:-9px 0;position:relative;pointer-events:none}
.wmark::after{content:'';position:absolute;left:4px;right:4px;top:-2px;height:4px;border-radius:2px;background:var(--accent)}
.tray{display:flex;flex-wrap:wrap;align-items:center;gap:8px;margin:0 0 10px;padding:10px 12px;border:1.5px dashed var(--line);border-radius:12px;transition:border-color .15s,background .15s}
.tray.over{border-color:var(--warn);background:color-mix(in srgb,var(--warn) 6%,transparent)}
.trayl{font-size:10.5px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase;margin-right:4px}
.hidezone{position:absolute;left:50%;bottom:22px;transform:translate(-50%,16px);display:flex;align-items:center;gap:8px;padding:12px 22px;border-radius:999px;background:var(--panel);border:1.5px dashed var(--faint);color:var(--muted);font-size:13px;font-weight:650;box-shadow:var(--shadow);opacity:0;pointer-events:none;transition:opacity .15s,transform .15s;z-index:4}
.hidezone svg{width:14px;height:14px}
.view.wdragging .hidezone{opacity:1;pointer-events:auto;transform:translate(-50%,0)}
.hidezone.over{border-color:var(--warn);color:var(--warn);background:color-mix(in srgb,var(--warn) 8%,var(--panel))}
.flash{position:fixed;left:50%;bottom:24px;transform:translate(-50%,20px);display:flex;align-items:center;gap:14px;padding:10px 12px 10px 18px;border-radius:12px;background:var(--ink);color:var(--bg);font:600 13px/1.3 system-ui,-apple-system,sans-serif;box-shadow:var(--shadow);opacity:0;pointer-events:none;transition:opacity .2s,transform .2s;z-index:10}
.flash.on{opacity:1;transform:translate(-50%,0);pointer-events:auto}
.flash button{font:inherit;color:var(--bg);background:color-mix(in srgb,var(--bg) 18%,transparent);border:0;border-radius:8px;padding:5px 12px;cursor:pointer}
/* doctors on call */
.oc-icu{display:grid;grid-template-columns:repeat(3,minmax(0,1fr));gap:10px}
.oc-u{padding:6px 11px 7px;border-radius:9px;background:color-mix(in srgb,var(--u) 7%,var(--panel2));border:1px solid color-mix(in srgb,var(--u) 22%,var(--line));display:grid;grid-template-columns:minmax(0,1fr) auto;align-items:baseline;column-gap:8px;row-gap:0;min-width:0;line-height:1.25}
.oc-u b{font-size:11px;font-weight:780;color:var(--u);letter-spacing:.02em}
.oc-n{grid-column:1/-1;grid-row:2;font-size:15px;font-weight:720;color:var(--ink);overflow:hidden;text-overflow:ellipsis;white-space:nowrap}
.oc-ph{grid-column:2;grid-row:1;font-size:11px;color:var(--muted);font-variant-numeric:tabular-nums;white-space:nowrap}
.oc-rows{display:flex;flex-direction:column;margin-top:10px}
.oc-r{display:grid;grid-template-columns:118px minmax(0,1fr);gap:10px;align-items:baseline;padding:9px 0;border-top:1px solid var(--line);font-size:13px}
.oc-r:first-child{border-top:0}
.oc-r.now{background:color-mix(in srgb,var(--posted) 7%,transparent);border-radius:9px;padding:9px 10px;margin:0 -10px;border-top-color:transparent}
.oc-l{display:inline-flex;align-items:center;gap:6px;font-size:11.5px;font-weight:750;letter-spacing:.04em;text-transform:uppercase}
.oc-v{display:flex;flex-wrap:wrap;gap:6px 16px;align-items:center;color:var(--ink);font-weight:600}
.oc-v>span{display:inline-flex;gap:6px;align-items:center}
.oc-v i{font-style:normal;font-size:11.5px;font-weight:700;color:var(--c,var(--muted))}
.oc-2{font-size:12px;color:var(--muted);font-weight:500}
.circ{padding:0 7px;border-radius:999px;box-shadow:inset 0 0 0 1.4px var(--c,var(--accent))}
@container (max-width:520px){.oc-icu{grid-template-columns:minmax(0,1fr)}.oc-u{display:flex;flex-direction:row;align-items:baseline;gap:10px}.oc-u b{width:74px;flex:none}.oc-ph{margin-left:auto}.oc-n{font-size:14px}.oc-r{grid-template-columns:minmax(0,1fr)}}
/* cafeteria */
.seg.sm{margin:0 0 12px}
.seg.sm button{padding:3px 11px;font-size:12px}
.cf{display:grid;grid-template-columns:104px minmax(0,1fr);font-size:13px}
.cf>div{padding:7px 0;border-top:1px solid var(--line)}
.cf>div:nth-child(-n+2){border-top:0;padding-top:0}
.cf-l{font-size:11px;font-weight:700;color:var(--faint);letter-spacing:.03em;padding-right:8px}
.cf-l.feat{color:var(--accent)}
.cf-i{display:flex;flex-direction:column;gap:3px;color:var(--ink)}
.lnk{background:none;border:0;padding:0;font:inherit;font-weight:650;color:var(--accent);cursor:pointer}
/* cafeteria page */
.cfday{display:flex;align-items:baseline;gap:10px;margin:2px 0 14px}
.cfday b{font-size:24px;font-weight:750;letter-spacing:-.01em;color:var(--ink)}
.cfday b.now{color:var(--accent)}
.cfday span{color:var(--muted);font-size:14px;font-weight:600}
.cfp{display:grid;grid-template-columns:minmax(0,1fr);gap:12px;max-width:640px}
.cfr.cfmain{font-size:16.5px;font-weight:650}
.cfside{margin-top:8px;padding-top:8px;border-top:1px solid var(--line)}
.cfside i{display:block;font-style:normal;font-size:11px;font-weight:700;letter-spacing:.06em;text-transform:uppercase;color:var(--faint);margin-bottom:2px}
.cfside .cfr{border-top:0;padding:4px 0;font-size:14px;color:var(--muted)}
.cfp .xc h3 svg{flex:none}
.cfp .xc.feat{border-color:color-mix(in srgb,var(--accent) 38%,var(--line));background:color-mix(in srgb,var(--accent) 4%,var(--panel))}
.cfp .xc.feat h3{color:var(--accent);font-size:12.5px}
.cfr{display:flex;align-items:baseline;gap:12px;padding:7px 0;border-top:1px solid var(--line);font-size:14.5px;color:var(--ink)}
.cfp h3+.cfr{border-top:0;padding-top:0}
.cfr span{flex:1;min-width:0}
.cfr em{font-style:normal;font-size:12.5px;color:var(--muted);font-variant-numeric:tabular-nums;text-align:right}
/* guide */
.gdq{flex:1 1 260px;max-width:420px}
.gd ul{list-style:none;margin:0;padding:0}
.gd li{padding:9px 0;border-top:1px solid var(--line)}
.gd li:first-child{border-top:0;padding-top:0}
.gd li b{display:block;font-size:13.5px;font-weight:700;color:var(--ink)}
.gd li p{margin:3px 0 0;font-size:13px;line-height:1.55;color:var(--muted);max-width:68ch}
.gd kbd{font:600 11px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ink);border:1px solid var(--line);border-bottom-width:2px;border-radius:4px;padding:2px 5px;background:var(--panel2)}
/* Who's On: hold your own shift */
.wr[data-wmine]{-webkit-touch-callout:none;-webkit-user-select:none;user-select:none}
.wr.pressing{transform:scale(.95);transition:transform .5s ease-out}
.wmenu{position:fixed;z-index:30;font:14px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased;color:var(--ink);min-width:210px;background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:0 12px 32px rgba(8,16,20,.22);padding:6px}
.wmh{padding:6px 10px 8px;margin:0 0 4px;border-bottom:1px solid var(--line);font-size:12px;font-weight:650;color:var(--muted);white-space:nowrap}
.wmenu button{display:flex;align-items:center;gap:8px;width:100%;padding:8px 10px;border:0;border-radius:8px;background:none;font:inherit;font-size:14px;font-weight:650;color:var(--ink);cursor:pointer;text-align:left}
.wmenu button:hover,.wmenu button:focus-visible{background:var(--panel2);outline:none}
.wmenu button svg{width:16px;height:16px;color:var(--accent)}
@media (prefers-reduced-motion:reduce){.wr.pressing{transition:none}}
.cf-i em{font-style:normal;color:var(--muted);font-size:11.5px;font-variant-numeric:tabular-nums;white-space:nowrap}
.nxw{display:grid;grid-template-columns:minmax(200px,.75fr) minmax(0,2.25fr);gap:28px;align-items:start}
.lst .nxg{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));column-gap:28px;padding:0;border:0}
.lst .nxg>div{display:flex;gap:10px;align-items:center;padding:5px 0;border-top:1px solid var(--line);min-width:0}
.lst .nxg .off,.lst .nxg .mini{white-space:nowrap}
.lst .nxg .dd{width:auto;min-width:80px}
.lst .nxsum{display:flex;flex-wrap:wrap;align-items:center;justify-content:space-between;gap:6px 18px;padding:2px 0 10px;font-variant-numeric:tabular-nums}
.lst .nxsum .eq{display:flex;align-items:baseline;gap:7px;font-size:14px;font-weight:700;color:var(--accent);white-space:nowrap}
.lst .nxsum .eq i{font-style:normal;color:var(--faint);font-weight:600}
.lst .nxsum .eq b{font-size:16px;font-weight:800;color:var(--ink)}
.lst .nxsum .sofar{display:flex;align-items:center;gap:7px;font-size:13px;color:var(--muted);white-space:nowrap}
.lst .nxsum .sofar b{color:var(--ink);font-weight:750}
.lst .nxsum .pbar2{width:64px;height:6px;border-radius:3px;background:var(--line);overflow:hidden;display:inline-block}
.lst .nxsum .pbar2 span{display:block;height:100%;background:var(--accent);border-radius:3px}
.lst .nxg>div.done{opacity:.4}
.lst .nxg>div.done .mini{filter:saturate(.35)}
.lst .nxg .ck{margin-left:auto;padding-left:6px;color:var(--faint);font-size:12px;font-weight:700}
.lst .nxg .nt{margin-left:auto;font-size:10.5px;font-weight:750;letter-spacing:.06em;text-transform:uppercase;color:var(--accent)}
.lst .nxg>div.isnext .dd{color:var(--ink);font-weight:750}
@media (max-width:1020px){.nxw{grid-template-columns:minmax(0,1fr)}}
.nxw .lst{margin-top:0}
.lh{font-size:10.5px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase;padding-bottom:4px}
@container (max-width:560px){.nxw{grid-template-columns:minmax(0,1fr);gap:14px}}
.w h3{display:flex;align-items:center;gap:8px;margin:0 0 12px;font-size:11.5px;font-weight:750;color:var(--faint);letter-spacing:.07em;text-transform:uppercase}
.w h3 .go{margin-left:auto;text-transform:none;letter-spacing:0;font-size:12.5px;font-weight:650;color:var(--accent)}
.w h3 .ctl{margin-left:auto;display:flex;gap:4px}
.w h3 .ctl button{width:26px;height:26px;border-radius:7px;border:1px solid var(--line);display:grid;place-items:center;color:var(--muted);font-size:13px;text-transform:none;letter-spacing:0}
.w h3 .ctl button:disabled{opacity:.35;pointer-events:none}
.w h3 .ctl button:hover{color:var(--ink);border-color:var(--accent)}
.big{font-size:30px;font-weight:800;letter-spacing:-.02em;line-height:1.05}
.nx{display:flex;gap:14px;align-items:center}
.nx .sw{width:8px;align-self:stretch;border-radius:4px;background:var(--u)}
.lst{display:flex;flex-direction:column;gap:2px;margin-top:12px;font-size:13px}
.lst div{display:flex;gap:10px;align-items:center;padding:5px 0;border-top:1px solid var(--line)}
.lst .dd{width:92px;color:var(--muted);font-weight:650;flex:none}
.ag{display:grid;grid-template-columns:96px minmax(0,1fr);gap:0;font-size:13px}
.ag>div{padding:8px 0;border-top:1px solid var(--line)}
.ag>div:nth-child(-n+2){border-top:0}
.ag .dd{font-weight:700;color:var(--muted)}
.ag .dd.t{color:var(--accent)}
.ag .it{display:flex;flex-wrap:wrap;gap:6px 10px;align-items:center}
.ag .ev{font-size:12.5px;font-weight:600}
.ag .ev i{width:8px;height:8px}
.mp{display:flex;flex-direction:column;gap:8px}
.mp a,.mp .o{display:grid;grid-template-columns:62px minmax(0,1fr) auto;gap:10px;align-items:center;padding:8px 10px;border-radius:9px;background:var(--panel2);font-size:13px}
.mp a:hover{background:color-mix(in srgb,var(--avail) 12%,var(--panel2))}
.wxnow{display:flex;align-items:center;gap:14px}
.wxdays{display:grid;grid-template-columns:repeat(4,1fr);gap:6px;margin-top:14px;text-align:center;font-size:12px;color:var(--muted)}
.wxdays svg{display:block;margin:4px auto 2px}
.wxdays b{display:block;color:var(--ink);font-size:13px}
.hidden-w{display:flex;gap:8px;flex-wrap:wrap;margin:0 0 16px}
.on-today{display:grid;grid-template-columns:auto minmax(0,1fr);gap:6px 12px;font-size:13px}
.on-today b{color:var(--u);font-weight:780}
/* keys sheet */
.keys{position:absolute;right:24px;bottom:24px;background:var(--panel);border:1px solid var(--line);border-radius:12px;box-shadow:var(--shadow);padding:14px 16px;font-size:12.5px;color:var(--muted);display:none;z-index:5;min-width:240px}
.keys.on{display:block}
.keys div{display:flex;justify-content:space-between;gap:20px;padding:3px 0}
.keys kbd{font:600 11px/1 ui-monospace,SFMono-Regular,Menlo,monospace;color:var(--ink);border:1px solid var(--line);border-radius:4px;padding:3px 6px}
.loading{display:flex;flex-direction:column;align-items:center;justify-content:center;gap:12px;padding:90px 20px;color:var(--muted);text-align:center}
.loading .logo{width:46px;height:46px;border-radius:12px}
.bar{width:180px;height:3px;border-radius:3px;background:var(--line);overflow:hidden}
.bar i{display:block;height:100%;width:40%;background:var(--accent);border-radius:3px;animation:slide 1.1s ease-in-out infinite}
@keyframes slide{0%{transform:translateX(-100%)}100%{transform:translateX(260%)}}
@media (prefers-reduced-motion:reduce){*{animation:none!important;transition:none!important}}
.app.dzon{user-select:none;-webkit-user-select:none}
.app.dzon *{cursor:default!important}
.dz{position:fixed;inset:0;z-index:60;pointer-events:none;font:14px/1.4 -apple-system,BlinkMacSystemFont,"SF Pro Text","Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;-webkit-font-smoothing:antialiased}
.dzhov{position:fixed;outline:1.5px dashed color-mix(in srgb,var(--accent) 70%,transparent);border-radius:4px;background:color-mix(in srgb,var(--accent) 5%,transparent)}
.dzbox{position:fixed;outline:2px solid var(--accent);border-radius:3px}
.dztag{position:absolute;left:-2px;bottom:100%;margin-bottom:4px;background:var(--accent);color:var(--accent-ink);font:650 11px/1 ui-monospace,SFMono-Regular,Menlo,monospace;padding:4px 7px;border-radius:5px;white-space:nowrap}
.dztag.in{bottom:auto;top:4px;left:4px;margin:0}
.dzh{position:absolute;width:11px;height:11px;margin:-6.5px 0 0 -6.5px;background:var(--panel);border:2px solid var(--accent);border-radius:3px;pointer-events:auto;box-sizing:border-box}
.dzh[data-dzh=n]{left:50%;top:0;cursor:ns-resize}.dzh[data-dzh=s]{left:50%;top:100%;cursor:ns-resize}.dzh[data-dzh=e]{left:100%;top:50%;cursor:ew-resize}.dzh[data-dzh=w]{left:0;top:50%;cursor:ew-resize}
.dzh[data-dzh=ne]{left:100%;top:0;cursor:nesw-resize}.dzh[data-dzh=nw]{left:0;top:0;cursor:nwse-resize}.dzh[data-dzh=se]{left:100%;top:100%;cursor:nwse-resize}.dzh[data-dzh=sw]{left:0;top:100%;cursor:nesw-resize}
.dzpanel{position:fixed;left:50%;bottom:14px;transform:translateX(-50%);pointer-events:auto;display:flex;flex-wrap:wrap;gap:6px 14px;align-items:center;justify-content:center;width:max-content;max-width:calc(100% - 32px);padding:8px 12px;background:var(--panel);color:var(--ink);border:1px solid var(--line);border-radius:14px;box-shadow:0 10px 34px -12px rgba(0,0,0,.35),var(--shadow);font-size:12.5px}
.dzpanel.top{bottom:auto;top:14px}
.dzpanel .dzt{font-weight:800;color:var(--accent);font-size:12px;letter-spacing:.04em;text-transform:uppercase}
.dzpanel .grp{display:inline-flex;align-items:center;gap:5px}
.dzpanel .grp + .grp{padding-left:14px;border-left:1px solid var(--line)}
.dzpanel b{font-weight:700;max-width:220px;overflow:hidden;text-overflow:ellipsis;white-space:nowrap;margin-right:4px}
.dzpanel .lbl{color:var(--faint);font-size:10.5px;font-weight:750;letter-spacing:.07em;text-transform:uppercase;margin-left:6px}
.dzpanel .v{min-width:38px;text-align:center;font-variant-numeric:tabular-nums;color:var(--muted);font-weight:650}
.dzpanel .hint{color:var(--muted)}
.dzpanel button{font:inherit;font-size:12px;font-weight:650;color:var(--ink);background:var(--panel2);border:1px solid var(--line);border-radius:8px;padding:5px 9px;cursor:pointer}
.dzpanel button:hover:not(:disabled){border-color:color-mix(in srgb,var(--accent) 50%,var(--line))}
.dzpanel button:disabled{opacity:.4;cursor:default}
.dzpanel button.pri{background:var(--accent);border-color:var(--accent);color:var(--accent-ink)}
/* phone / narrow */
@media (max-width:760px){
  .app{grid-template-columns:minmax(0,1fr);grid-template-rows:minmax(0,1fr) auto}
  .side{order:2;flex-direction:row;padding:6px 8px calc(6px + env(safe-area-inset-bottom));border-right:0;border-top:1px solid var(--line);gap:0}
  .brand,.foot,.sp,.nav kbd{display:none}
  .nav{flex-direction:column;gap:3px;font-size:10.5px;padding:6px 2px;justify-content:center;align-items:center}
  .nav .count{position:absolute;margin:0 0 0 26px;font-size:9.5px;padding:0 5px}
  .nav{position:relative}
  .nav span{white-space:nowrap}
}
@media (max-width:420px){
  .nav{font-size:9.5px;padding:6px 0}
  .top{padding:12px 16px 10px}
  .view{padding:14px 16px 30px}
  .cards{grid-template-columns:1fr}
  .msgrid{grid-template-columns:1fr}
  .top .tools{margin-left:0;width:100%}
  .top .tools .chipbtn .lbl2{display:none}
  .cals{flex-wrap:wrap}
  .msstrip{padding:10px 16px}
  .mslegend .hint{display:none}
  .sheetbg.drawer{padding:0;align-items:flex-end}
  .sheetbg.drawer .sheet{width:100%;max-height:78%;border-radius:16px 16px 0 0}
  .sheetbg.drawer header{cursor:default}
  .top .tools .tsep{display:none}
  .cell{min-height:58px;padding:3px;min-width:0}
    .cell .ev span{display:none}
  .blk .t{display:none}
  .keys{display:none!important}
  .months,.legend>span{display:none}
  .legend{margin:0 0 14px}
}`;

  // the app's own black icon (from the iOS AppIcon), inlined so the overlay needs no extra file
  const ICON = `<img class="logo" alt="" src="data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAGAAAABgCAIAAABt+uBvAAAAAXNSR0IArs4c6QAAAERlWElmTU0AKgAAAAgAAYdpAAQAAAABAAAAGgAAAAAAA6ABAAMAAAABAAEAAKACAAQAAAABAAAAYKADAAQAAAABAAAAYAAAAACpM19OAAAVwUlEQVR4Ae2c53YcOZJGWY6souhn5+xb7Nk/+/7v0UPKUo7em7JzvwCQMJllpJbY7D0DkQUgEA5REUAAmVTrf/73/9ZiaanZ4l9RlsAr7BphNfJyjVkqyndqsJXh7ZTbf9p1CxQGajJsnej/IyTxsaS5ttZdm6V9omu2lgJkCwNSZ3AXdAbK4POM95PBB28onYQai5UESyGPWMMXYAmwWxv3C1AGp2MLUwYMpkj1bkQIiD9Tt6zwLar8OIN5JII3jdVh3dWFQpzYIvZia3Veq2FinE6n0+12Mc5oNJpOp6vReax8trEXWyuwq0LM5v6j8dUgKrFhKh7OP17a7Xa/vzEYDO7v74bDqQVbwidp5rybBjysNiRAI9DDqxADSXPjt4Yu6W7e9aEa3PMRzZ8ruE9vfX1ra6s/6J+efGt3e9PJFFcCvpBxqWPZD8TL4H4838UaiRqBQczvqwmuwaD/Zmvz+fFhMhm3W63pdPKLxTVOLQcmIeaiIB+WQplT2bfXjBm+2MZoqrNdONdWu7Wxvj7o96eTyffv33q93mQymU2nwBfSpf7fJNLDkiE1k27FPcDLEKsQ0kZiIuhaYhiy7QbeNpqS0142rQJ9rdftsfSs93pfjo8fHx62tndG40kxkWbRJSffF7IniHSxlVAFoK+TEAsjCfJf02Rt3thgbd64u7v9dPyRXUx7Pbr8qJl/Wv3EFHmIWZKYqEEzwZW8mDQyEDCtTiOrIDIuAXmZ1q21Xq+7Oeiz6Lw9OmR3Z5/HZMqCZibR8qGahBpbj6EqQy4ACVqGGdCSEJspbJpMkgswTdxsM8GJho22mIec0KnZaXf67O39/tnZ6Zcvn//xj//qtNtrrZZLFBcz+YnROokg4ZcmiSK9xvl6W1XDUp9i/QTo0SIbh5Z9Nlosw3AdIklr82Awm04O//UHmSHLc7vdQcPpbNq0v6NIU8nA6nhAY+UZZDSB6YwQc+T1OTBQ8yiHVWeVw40yiFBdA6SDSZto6rP2rG8cH3/Ag7AUkJbiy4IfH89Ez+84ntl4IqaAq5uDfE9VFWIJ/YImJGa0GkvRpDbOBS7gGIe0NtvW/vz8dHT4L7zJjhlaoWf4j5aedJ2LhPXWPOmCJ2NJM/IogC7EwjCD6SwduwihVZBnkIQ60iSsQ3NO3e12BpsDVug//ji8ubkhuMgVKXwjsg45tLbcQoGCl0abMOqwAPF16Gb0AroQc2D5Bppkk2uyAHQBx5oZDqyaSiBoGhPMjl0cKjZub28+vH8nu7TaMg8LEDn0bBIkJQyk/7IiHI+XVDll0qvjLA4x8BtmVhrEsBxekFUjrAHSmUHbWycz7LPcHB0dPj0/kSiSNGOhdoctbE1nsGqijjJISvhkIHUygBALQOiGuoYAyeIQKzzKLAM3ZwxJNIgakh3Aro5SbTzD8JBQtbtdThVs7udnJ1+/fO52WHfaZh9ZCMfmkGH0gWeoA4O01lhtPABCHVE8JA4EYg+pQszYspFmuSJIYdbSwbqF0QBHKwnJo1GnpDYQZLuO/9TW3tPWzrHr6PCQrd2nznYZROiBp5sgxb7Uay4eXhtOAAlKAU1GHHf5qy95iAGXFnPVCFRVbQTWa6CKgxW+GoXdMAfBxf716dOH8/Mzt/oQX/yo3bYUMWgcFU9ZNkETmG8mEE/cDMmheYhByHAxgwKSdc0sBglgR0zPSoD6bg2mrX0D9+k/PT++e3uEN1lswUQtZyx0ms24LcNIgW3BLu2qXTdnIPT1nK5IHa+AkOxi1YByjcRE6mWQaBPHr3C5BDe3lRNQiaHBOMsNwcWS/O7o8Pb2VnkzPmPysR2jeBLTnU4xzvz4cop4ASiQFPXCrwOH8QAN/YgXIVDkIZZwntM0RZtsYnarVHC2iTzKvo3gLKzMLM83N9cfP37wwRUOFJgGiPZ4t4dFZr6VzaMGC/OPZAHi6erkdQjEtRAD5o0QWes78FNM7KDx2I0oFTABJU3PlhBaJ2/eHLBdEVzD4bDb09YeBK3ZHk82VG1hEMLGl9jKwL6TjYqiAFjXw5IqaYrICg8MKpUcBKyG7ztAfZ11g5UC0LOuDNXIlwSHpbm/sXF2evr121fdaWAeS5YdPmfU4EE6aGg7Q4CVUPuuqgSUNB1cAA8MzVAnHDySR3QDdAixDOQpgDVYKbDDpumCEJDNUMFaTl5g4mqTpKa5jx5XcJF69PaQNKdDZkgJEmhyy8EPEJmnmqEQjE1VRUAgLhfpgB/qnCJAQ11xcWj6WvxQHAEQNgIBbTwiqRV7yWiBV5HW8Gc6dnFq39j4+vXz5cUFh1JMkdhHpLgPFoKn2UcQE+slRwViy+PkGHmvUjwHW48PD/WMTKC7Ucz3KTdu6OErlc8UwQizdDRhHkbccBAaoDp2caHBneHT0+P7d29ZqjEEn5EfLdvDdBOkLYwscSbxQWBgGRS1mVgnHwnfsoeGwdANtWMTRrPebGYhxliYqxvWZwHMusUyXk+ujY0TaZwTW7WUGW4O+Hz79vDu/l7HLi09mQYWYjqvKgUiCUIdH3+OqVcwqUyifUseI6nUDL9JswHDcUlxlMiLujHQPAdDacIJ41bHD2NoGjneaZ9lpT9g9enf3l5/Pv6kKKJYdGGh6gdIlxBTGm0hJushwAvMWpJB8bCI4YGBxpAcnoE8YiOWxsJvdRaTU9itdOBkpLYcpxAR2nctfFqxG1wgQJyQPGXShTyn9k3m/+7tW7b2Xm9dwRVXZy8LoO4SW20eFuqkClN+Kgt5LKsEt7Gq8oBioOh6Fgb15A4U8Dww3cX8nD1phW72qPgV+1fRxUqgB4HWpBM4kBkrL+yvc536/eS7u04t1mYnSOuSroR0VaYVSDwD18i/oSUkjxiqUPsJNXQ9KEGIEBdibki8w7rWCBFZJLVmgm8j6TwqXEbkinrWzurD1o774BchtipZsWEGUuRpCdLzeC/aOBlabEWlPJLG1VQVat91VTbqMTxCwsJBqhDzpMaz8HikVBB5WRKJ8Et3QHVh5GSa38Qm7rOpC/n1408fr64uLTNk9wreVcm3hgzU7jJm9oFJ/kU6rsL0rRyQANVc0I10Hi9YVLytpCEWYPVQg086kUXdOjFsyYM7OrX3B0+Pjx8/vNcuruWZgEz5egVwHJ8E2V2i3MA2eQ3XZuRoPFhVxAiTDYOh9iQFsieN5A6Ns1i9FG4CgtwcG9lsYFF6jVTxo0LW+k1l2M4A9rB0k8/3748eHh44ds2zjtMG+ym+CC+42RGEroYcO28FdfyEDJGcyZELGAYiRK0wEuo4mkMcnE+9vIVYL7cCw0jTTOFCC+PFqB9KMGKTFvs1Zy7Ci1P7l8/HOoVykZocuwLbWHOCZ48Dkyxpc1OPW6ULvOzX4annCwvajFdkeE494R0iB0yQrZmgg6BZ+9IwaiOGQaIIajXxQBNJ0yGZLMGtdUWV4wvQ5tTOJDeZIY8rRqMxW3t16eMF1Sqmen11hR9tbW2v90iJeLialXx+2gHGk/HDwyOF96wCqs2dTqiTZsIgGQ2Eqg3Mk1U1zUjp5AWlKLISL5JJEhulXSfPnwfMSh7Cl8+dD8d2rlNPz05JoO1gkRrSyco+R6MhHjEcDU9PT3TUiMWxpe840NW1yc7uLjsAS7o5JvgeTVX4TZp+VJBklK4rAabancVopLP1eBV2MhtoagtQULYiE5J1sC7b1uZgczqevH//DnvLOonJK5KigVEoRBmfip8w4QKNLs61t7tnFyf9IS8Rjcc813ciND9KiKaiq5HkV5hWCiC7WFVMjVJ7GS4PnGTTh1TiKwRjZvgG5T0oHpay/vSOjz9dX9/gPlw0L159Km1o+KWqk+iYDktGi+D95z//e29vn6dpT49P4/FIt26mceEd4hKM5dgUCAGYiSt3sSKojEawaAQTIyNFvyoQzKbo2GmvE12DAYp/+sSxy1bnlRzIqapPExMlxQFrcXDZwzYHB/Rub26xkcnWJUnlHo6ksEUdIaBl1gFYhZhD0Ce8ksk7uOQu9KQCATGtXqf7ZqBT+9H7d0+PD1qbbfOOkv5cC26bb95gHdag6+ur+7s7ghEPFdf8ii34jZ/8fOtAWTNQCRD7JjeCMrMQdFqSE1OajfSdi0WXrZ1jF6f2m5tv3KjysFTWKa81hPqzZWOjj/dsb20/D4d3d3ej8QjhTqt0noV1kGaQct6NQJDzFD7qio1iJ7QKIBjzIDp2bXIh32p9+vhhPBq73McmEJj9uRrH3N7e3t/b5wshIWB/l+/oC5BWFe8w7TqkQlEjoGVA12kIsYDV7EflemTulq1QazPyO3vUrq39/OK8q0RG4RU4/9mahYm1meDiXunmhudpN6PhiBBGjepdapkk/Dp5oReN5eFhoFGthhwsx8uXZ43ZPMvJRjS057KZCfDdnp6ccP7iYKEQS6IxFcH3wF4+Ho+ruaWjTW0Sn43d3b2dnZ3hcHR1dfU8VHBNphPWbKQQ6kxZyUjiSuLjLeMrD6ijCTWWro47i4pWlnxqhl/sawjXP5nJvJw5TzhYcDe2s7vnHunME4J12OZub+94sayI2EYSEh/+PmF/f58U9PLikpMdFmaHBJn8W9dvtTkHQDnTBZFVie6SWRUGqMayRjNSdJyA3Jq21p6fn9l0sRHLRDdsXvpuLTEvrAAa0YcHDYfPuh1zHhrYFTVMSBz29w/Yv9i2+A6U+Fjm49jOeN/cLOQI55qG4SWeIQbwVB4k1s3zF5IvIJkj5bEl/8o2N3MkDlz3M/b17vTpeY0fo9GDi3bH4imcJ80YLLe8GYRHXF5eIGTxUsWxbncXp9zlIMKl0tPzMzxkerQMv0HjCpA5ju8ss44x00fIpGWkZVYyO1biQ8MHVxaGsyl/3YVTGE5UCRzxCJTIo0kmSTYwJDx4Z9wfSiNKhUtDic8mwXXAenx+dsYTEcIT96kmkyKbBbzoDE7HxlJg0TZjeFi2i5mXNCvn0ediNBjPiXE6OqZOsai1/KXNFrfe7Z0z28kkGKhQ2HdJfPb39zjf89cbV9dX7FwMyMi1CTeaDOR58FReah3gDUeNJY7kGNRDMsCldCIwaVszfgiJ/Kjb7UFw/3AvuUzX3Cph4JtcDO3sbO/u7XOLdnFxwc0kArFviulNX7MXOCuZRnieR8W2uHI19W2qc/QMhPBJph6gThGl3JTauNGYApUWbP6dboczOCdNZmvLbY0OVm2f+JBeXVyck/iMJxMWNWQowr3Ysopa+YlXYtMR384tEzEJsRTbdaQiBAtthBWFVsMxDvrQ4q1KH1XJhDGoE2y7MySTGY3MQBVm1uBRNYfSne0dzutXF5ekP7CVuznzgCvGBXPPIcy8edQhBZwGJpmLepZBEmSLuGpQzjYHhwGNOYRGHCbIokOS/cjfFGq51ayDDrEmCEl8OHbhX5eX5w+PJD58e/Zeg1SQFo3W8SOGEdnlrYDjoPTKUoRYNQyq6Wrzr7lJhUYDDNtl9ZWmcNc2kfpowMEieq2j3SLZQxpdSmEijMI2p1PF5iZH9uvr6xGJmyHZStAwJekUwbHVoFw2mHUq5CLEKrikWEeT1hfWMPkK2bOeE3QOrcKh63kputpdFl0uknVLrZ9SDH90uLer1Gc0HF6cnz+TVcl7LF+o5CeNYJrm2SaIqxqxMcQyPq6D4OUyhWJBtwRVaPyQOfKiEOkSmbdsU7MO4ffmjYKLZJK1+e7unvvXOlrUUHId83QKZVsYwnQltgIkq+eFWIoEC/til4dbFOm8iX5t1p4zYcL1NCZ4GnJPOqZRzJwuf1ZHhv1ma+v27vby6pJThVRJlmZ4rT5Vr1xmkKzjNcurBSGWIhojm6tTqIyEFNe3vWwCwgEKEpiRA7FCszHhdTpkAjIRDp87AM7ru3t7PMsnb35+5KRmaMY4ziyxUIMWCSiSAFyZqkwUE4a1Jkw1S/06YcWcawQGCKqIxBNYxQbfldeQFtPHPERZxYGl+w03PvsHPBQ5OTnhymfsn1Ww2K8U7RUrGplpfpB8lRBLZEkUv36vsVYyurTpNVVlz9877O5PT0/efRJybnzcder9wwNXblyqyn10H5A+I0sI5je9TBDUir35FNnIiiGW0UgMguwLrwTGb7/AndNl2yLAeFpMjqitPnmNStepO9sYCNKz05PH+wfdxpM3V8Lm8EzBJW5w5BRnlfbSXWweE2wU3mwyxVGo1GkeqdmWVRlDDJ+fOWdgnWqFpqHEZ3+fIz4XICQ+IPBlVAjzufqRRBNrYhr53eraZRJ+MMQyWjp+OdDGkjtUiZj3cQcWIBzn8ekJUmce54MsOiQ+rM6czngR7ZlbNFYou0jNeSzrKd8oSg1QjDd1fy7ESk6SbPqs+D2zhvE+FUSkiOYc3kSW+BBcB6SQX08/3+sOxG58f2RqDZYp9f2BPlr+iPBlnE05uUKyIzXQKIPu6naRFNHHl9mJsNo/2OM6ldtCiq7c/Na/XMngMMsxGxSaDyLEfnkRy6Cu7ew1axFcLEB2iTjCeZw57caHY8UeC/fpyXd2Nx4osHov0vDXekuTJX5NiDVx9rDMWvIsFV6BoTw86M4Uu2AjYuoNz5H39unyP1KQ+PAqFJjiklvo99skm80vDrGMd1OH6bFCt+0Qz60gKBZibV4g4sZna1unCh434kSO+oXNUVf5d4RYXUoGkX3cCk2KSGm3ePS6vb2zu7+PQ/HfKXH7wStBjOSukzF5sc5vD7H6TJQidrucsHg/CmMRXHqOTOKzscFrDjxoZwjH0s8rsNBLhxj24oDKFsYK7Q7xekmD58jbOw/392cnJ1iNFV43Pq/BPPG5WP2L/j0QAkfrc6dDBsQ23+31efq6t6+XNL59/8bJyx51vYrgcgZ46RDDQCxARJnOqK02ry9iHR7hn52d8Jd1uJWp9SqCKxjoZT2Ze7FujxcNZqSIvATCcy4SH15bOPn2DQhwrPZKgssb6IXXQQ5hHFJ5qkXhwHVwcNDrdnm7/PbujvdXbG12ir2WzxcNMfI+TqiEGKHEA1WeVfA8h7tU3qBWcOnA+4qC6y8IMZ1R9cZWm9fESXy4MByPJ9++fuFMz4L92oLrrwgxsh7dQ5P6dA92t9ngv379wn82pRsfO7S9lrhK9CDEXm4V4szFisNpa23Q4lR6f3fDoZQ7MwsuluaX0ySxwJKmLmVerHCI5+3XdZ609/t4DHmzThXzH3W9mGILBL3cWYwFiADjtTPFWafL+6+Xl1ck0/aoxE7tC9T864ZeMMSwkP1fUmxYrMqnp99JfOxwz871GoPLfSkvGmK8r6nH8O0O/4vt/b2dKv4611hRcmejv7ki6i9Bw2V4u0d/OTDSc2R3l/hLOP8mJi2y2d/Eus7WnVSBk0a7Q2kd57VBXjTEcB/dw1tR0vx3KC+3i/0drNGg4wvuYg3S/wagn370/DeY2y9R8T8GWmLGfwOAhpggzDFB2QAAAABJRU5ErkJggg==">`;
  const I = {
    stats: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="3.5" y="12" width="4.2" height="8.5" rx="1.4" opacity=".6"/><rect x="9.9" y="4" width="4.2" height="16.5" rx="1.4"/><rect x="16.3" y="8.5" width="4.2" height="12" rx="1.4" opacity=".6"/></svg>',
    cafe: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M4 9h12v5a5 5 0 0 1-5 5H9a5 5 0 0 1-5-5V9Z"/><path d="M16 10.5h1.5a2.5 2.5 0 0 1 0 5H16"/><path d="M8 3.5c-.7.8-.7 1.7 0 2.5M12 3.5c-.7.8-.7 1.7 0 2.5"/></svg>',
    eye: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M2 12s3.6-7 10-7 10 7 10 7-3.6 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/></svg>',
    eyeOff: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M10.6 5.1A10.4 10.4 0 0 1 12 5c6.4 0 10 7 10 7a17 17 0 0 1-2.6 3.4M6.6 6.6C3.7 8.4 2 12 2 12s3.6 7 10 7c1.9 0 3.5-.6 4.9-1.4M9.9 9.9a3 3 0 0 0 4.2 4.2M3 3l18 18"/></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="9"/><path d="m8 12.3 2.7 2.7L16 9.6"/></svg>',
    msg: '<svg viewBox="0 0 24 24" width="14" height="14" fill="currentColor" aria-hidden="true"><path d="M12 3C6.5 3 2 6.7 2 11.3c0 2.6 1.4 4.9 3.7 6.4-.2 1.2-.8 2.4-1.7 3.3 1.9-.1 3.6-.8 4.9-1.9 1 .3 2 .4 3.1.4 5.5 0 10-3.7 10-8.2S17.5 3 12 3z"/></svg>',
    chev: '<svg class="chev" viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="m6 9 6 6 6-6"/></svg>',
    pool: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M13.2 2.3 4.6 13.1c-.4.5 0 1.2.6 1.2h5.4l-1.4 7.1c-.1.7.8 1.1 1.2.5l8.6-10.8c.4-.5 0-1.2-.6-1.2H13l1.4-7.1c.1-.7-.8-1.1-1.2-.5Z"/></svg>',
    cal: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><rect x="3.5" y="5" width="17" height="15.5" rx="3"/><path d="M3.5 10h17M8 3v4M16 3v4"/></svg>',
    who: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="9" cy="8" r="3.6"/><path d="M2.5 19.2c0-3.4 2.9-5.8 6.5-5.8s6.5 2.4 6.5 5.8c0 .5-.4.8-.9.8H3.4c-.5 0-.9-.3-.9-.8Z"/><circle cx="17" cy="9" r="2.8" opacity=".55"/><path d="M16.6 13.6c2.9.2 4.9 2.3 4.9 5 0 .4-.3.7-.7.7h-3.6c.1-2.2-.2-4.1-.6-5.7Z" opacity=".55"/></svg>',
    crew: '<svg viewBox="0 0 24 24" fill="currentColor"><circle cx="12" cy="7.5" r="3.3"/><circle cx="5" cy="9.5" r="2.4" opacity=".6"/><circle cx="19" cy="9.5" r="2.4" opacity=".6"/><path d="M6.2 19.5c0-3.2 2.6-5.5 5.8-5.5s5.8 2.3 5.8 5.5c0 .3-.2.5-.5.5H6.7c-.3 0-.5-.2-.5-.5Z"/><path d="M1 18.5c0-2.2 1.7-3.8 4-3.9-.6 1.1-.9 2.5-.9 4.1v.4H1.5c-.3 0-.5-.2-.5-.6ZM23 18.5c0-2.2-1.7-3.8-4-3.9.6 1.1.9 2.5.9 4.1v.4h2.6c.3 0 .5-.2.5-.6Z" opacity=".6"/></svg>',
    refresh: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M20 11a8 8 0 1 0-2.3 5.7"/><path d="M20 4v7h-7"/></svg>',
    ext: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M14 4h6v6M20 4l-9 9M18 14v4a2 2 0 0 1-2 2H6a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h4"/></svg>',
    back: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M15 18l-6-6 6-6"/></svg>',
    fwd: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M9 18l6-6-6-6"/></svg>',
    dl: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round"><path d="M12 4v11M7 10l5 5 5-5M5 20h14"/></svg>',
    search: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><circle cx="11" cy="11" r="6.5"/><path d="M20 20l-4-4"/></svg>',
    x: '<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>',
    close: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round"><path d="M6 6l12 12M18 6 6 18"/></svg>',
    home: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="3" y="3" width="8" height="10" rx="2.2"/><rect x="13" y="3" width="8" height="6" rx="2.2" opacity=".6"/><rect x="3" y="15" width="8" height="6" rx="2.2" opacity=".6"/><rect x="13" y="11" width="8" height="10" rx="2.2"/></svg>',
    plus: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round"><path d="M12 5v14M5 12h14"/></svg>',
    gear: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><circle cx="12" cy="12" r="3"/><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 1 1-2.83 2.83l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 1 1-4 0v-.09A1.65 1.65 0 0 0 9 19.4a1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 1 1-2.83-2.83l.06-.06A1.65 1.65 0 0 0 4.68 15a1.65 1.65 0 0 0-1.51-1H3a2 2 0 1 1 0-4h.09A1.65 1.65 0 0 0 4.6 9a1.65 1.65 0 0 0-.33-1.82l-.06-.06a2 2 0 1 1 2.83-2.83l.06.06A1.65 1.65 0 0 0 9 4.68a1.65 1.65 0 0 0 1-1.51V3a2 2 0 1 1 4 0v.09a1.65 1.65 0 0 0 1 1.51 1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 1 1 2.83 2.83l-.06.06A1.65 1.65 0 0 0 19.4 9a1.65 1.65 0 0 0 1.51 1H21a2 2 0 1 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"/></svg>',
  };

  // fonts (the wordmark face) — must live in the document, not the shadow root
  if (!document.getElementById('wb-fonts')) {
    const l = document.createElement('link');
    l.id = 'wb-fonts'; l.rel = 'stylesheet';
    l.href = 'https://fonts.googleapis.com/css2?family=Chakra+Petch:wght@600;700&display=swap';
    document.head.appendChild(l);
  }
  const host = document.createElement('div');
  host.id = 'working-bolt';
  const root = host.attachShadow({ mode: 'open' });
  const prevOverflow = document.documentElement.style.overflow;
  document.documentElement.style.overflow = 'hidden';
  document.body.appendChild(host);
  root.innerHTML = `<style>${CSS + CSS2}</style><div class="app" part="app"></div><div class="flash" role="status" aria-live="polite"></div>`;
  const app = root.querySelector('.app');
  // a small undo toast that survives re-renders (it lives outside .app)
  let flashT = 0;
  function flash(msg, btn, act) {
    const f = root.querySelector('.flash');
    f.innerHTML = `<span>${esc(msg)}</span>${btn ? `<button data-act="${act}">${esc(btn)}</button>` : ''}`;
    f.classList.add('on'); clearTimeout(flashT); flashT = setTimeout(hideFlash, 6000);
  }
  function hideFlash() { const f = root.querySelector('.flash'); if (f) f.classList.remove('on'); }
  root.querySelector('.flash').addEventListener('click', e => { if (e.target.closest('[data-act="wundo"]')) { const u = S.undoHide; S.undoHide = null; hideFlash(); if (u) { placeWidget(u.w, u.col, u.before); rerender(true); } } });
  applyTheme();

  function applyTheme() {
    if (S.theme === 'light' || S.theme === 'dark') host.setAttribute('data-theme', S.theme); else host.removeAttribute('data-theme');
  }

  // ───────────────────────────── rendering ─────────────────────────────
  const TABS = [
    { id: 'today', label: 'Today', short: 'Today', icon: I.home, key: '1' },
    { id: 'pool', label: 'Shift Pool', short: 'Pool', icon: I.pool, key: '2' },
    { id: 'mine', label: 'My Shifts', short: 'My Shifts', icon: I.cal, key: '3' },
    { id: 'who', label: "Who's On", short: "Who's On", icon: I.who, key: '4' },
    { id: 'crew', label: 'Crew', short: 'Crew', icon: I.crew, key: '5' },
    { id: 'stats', label: 'My Stats', short: 'Stats', icon: I.stats, key: '6' },
    { id: 'cafe', label: 'Cafeteria', short: 'Cafe', icon: I.cafe, key: '7' },
    { id: 'settings', label: 'Settings', short: 'More', icon: I.gear, key: '8' },
  ];
  if (S.tab === 'crew' && store.get('crewSeg', 'side') === 'stats') { S.tab = 'stats'; store.set('crewSeg', 'side'); }
  if (!TABS.some(t => t.id === S.tab)) S.tab = 'today';
  function render() { render0(); if (S.tab === 'who') whoPlace(); if (S.tab === 'mine') minePlace(); if (S.tab === 'crew') crewPlace(); masonryAll(); applyDesign(); }
  function render0() {
    const forMe = S.open.filter(pickable).length;
    const statusDot = S.status === 'loading' ? 'busy' : S.status === 'error' ? 'err' : '';
    const upd = S.updated ? `Updated ${S.updated}` : S.status === 'loading' ? 'Reading Lightning Bolt…' : '';
    app.innerHTML = `
      <nav class="side" aria-label="Working-Bolt">
        <div class="brand">${ICON}<div><div class="word">Working<span>-</span>Bolt</div><small>${DEMO ? 'Sample data' : 'for the web'}</small></div></div>
        ${TABS.map(t => `<button class="nav" data-tab="${t.id}" ${S.tab === t.id ? 'aria-current="page"' : ''}>${t.icon}<span>${window.innerWidth <= 760 ? t.short : t.label}</span>${t.id === 'pool' && forMe ? `<span class="count" title="${forMe} you can take">${forMe}</span>` : ''}<kbd>${t.key}</kbd></button>`).join('')}
        <div class="sp"></div>
        <div class="foot">
          ${S.me ? `<div><div class="who">${esc(S.me)}</div></div>` : ''}
          <div class="row"><span class="dot ${statusDot}"></span><span>${esc(upd)}</span>${DEMO ? '' : `<button class="chipbtn ghost" data-act="refresh" title="Refresh (R)" style="margin-left:auto">${I.refresh}</button>`}</div>
          <div class="theme" role="group" aria-label="Appearance">${['system', 'light', 'dark'].map(t => `<button data-themeset="${t}" aria-pressed="${S.theme === t}">${t[0].toUpperCase() + t.slice(1)}</button>`).join('')}</div>
          <div class="row" style="justify-content:space-between">
            <button class="chipbtn ghost" data-act="design" title="${DZ.locked ? 'Layout locked — click to unlock and edit' : 'Move, resize and restyle any block (E)'}">${DZ.locked ? 'Layout locked' : dzOn ? 'Editing layout' : 'Edit layout'}</button>
          </div>
          <div class="row" style="justify-content:space-between">
            <button class="chipbtn ghost" data-act="keys" title="Keyboard shortcuts (?)">Shortcuts <kbd style="font:600 10px ui-monospace,monospace;border:1px solid var(--line);border-radius:4px;padding:2px 4px">?</kbd></button>
            <button class="chipbtn ghost" data-act="close" title="${LB_HOST ? 'Back to Lightning Bolt' : 'Close'} (Esc)">${I.close}${LB_HOST ? 'LB' : 'Close'}</button>
          </div>
        </div>
      </nav>
      <main class="main">${renderMain()}</main>
      <div class="keys" role="dialog" aria-label="Keyboard shortcuts">
        <div><span>Today · Pool · My Shifts · Who's On · Crew · My Stats · Cafeteria · Settings</span><span><kbd>1</kbd> – <kbd>8</kbd></span></div>
        <div><span>Previous / next month, week or day</span><span><kbd>←</kbd> <kbd>→</kbd></span></div>
        <div><span>Back to today</span><kbd>T</kbd></div>
        <div><span>Find a colleague (Who's On)</span><kbd>/</kbd></div>
        <div><span>Refresh</span><kbd>R</kbd></div>
        <div><span>Edit layout (move, resize, text size)</span><kbd>E</kbd></div>
        <div><span>Back to Lightning Bolt</span><kbd>Esc</kbd></div>
      </div>`;
  }
  function header(title, sub, tools) {
    return `<header class="top"><div><h1>${title}</h1>${sub ? `<div class="sub">${sub}</div>` : ''}</div><div class="tools">${tools || ''}</div></header>`;
  }
  function banners() {
    let b = '';
    if (DEMO) b += `<div class="banner demo">Sample data — made-up shifts and names, so you can look around. Nothing here is real.</div>`;
    if (S.note) b += `<div class="banner ${S.status === 'error' ? 'warn' : ''}">${S.note}</div>`;
    return b;
  }
  function renderMain() {
    if (!S.loaded) {
      return header('Working-Bolt', '') + `<div class="view"><div class="loading">${ICON}<b style="color:var(--ink);font-size:15px">${S.status === 'error' ? 'Couldn’t read your schedule' : 'Reading your schedule from Lightning Bolt…'}</b>
        ${S.status === 'error' ? `<div style="max-width:420px">${S.note}</div>` : '<div class="bar"><i></i></div><div>A few seconds. Nothing changes in Lightning Bolt unless you confirm it.</div>'}</div></div>`;
    }
    if (S.tab === 'today') return viewToday();
    if (S.tab === 'mine') return viewMine();
    if (S.tab === 'who') return viewWho();
    if (S.tab === 'crew') return viewCrew();
    if (S.tab === 'stats') return viewStats();
    if (S.tab === 'cafe') return viewCafe();
    if (S.tab === 'settings') return viewSettings();
    return viewPool();
  }

  // ── Today (widgets) ──
  const nowMin = () => ord(today) * 1440 + toMin(reginaHM());
  const GRIP = '<svg viewBox="0 0 10 16" width="8" height="13" fill="currentColor" aria-hidden="true"><circle cx="2.5" cy="3" r="1.4"/><circle cx="7.5" cy="3" r="1.4"/><circle cx="2.5" cy="8" r="1.4"/><circle cx="7.5" cy="8" r="1.4"/><circle cx="2.5" cy="13" r="1.4"/><circle cx="7.5" cy="13" r="1.4"/></svg>';
  function viewToday() {
    const L = S.layout, shown = L.main.concat(L.side);
    const hidden = Object.keys(WIDGETS).filter(w => !shown.includes(w));
    const tools = `${!S.customizing && hidden.length ? `<button class="chipbtn ghost" data-act="custom" title="Show hidden widgets">${hidden.length} hidden</button>` : ''}<button class="chipbtn ${S.customizing ? 'primary' : ''}" data-act="custom">${S.customizing ? 'Done' : 'Customize'}</button>`;
    let body = banners();
    if (S.customizing) body += `<div class="tray" data-wdrop="hide"><span class="trayl">Hidden</span>${hidden.length
      ? hidden.map(w => `<button class="chipbtn" data-wadd="${w}" draggable="true" data-wdrag="${w}" title="Click to add, or drag it into place">${I.plus}${WIDGETS[w]}</button>`).join('')
      : '<span class="fine" style="margin:0">Nothing hidden. Drag a card here to hide it.</span>'}
      <button class="chipbtn ghost" data-act="wreset" style="margin-left:auto">Reset layout</button></div>
      <p class="fine" style="margin:0 0 14px">Drag a card by its header to move it, across columns too. ↑ ↓ ← → do the same from the keyboard.</p>`;
    const card = (w, col, k, n) => {
      const go = { pool: ['pool', 'Pool'], next: ['mine', 'My Shifts'], onnow: ['who', "Who's On"], month: ['mine', 'My Shifts'], oncall: ['who', "Who's On"] }[w];
      const other = col === 'main' ? 'right' : 'left';
      const ctl = S.customizing
        ? `<span class="ctl"><button data-wmove="${w}" data-dir="up" title="Move up" ${k === 0 ? 'disabled' : ''}>↑</button><button data-wmove="${w}" data-dir="down" title="Move down" ${k === n - 1 ? 'disabled' : ''}>↓</button><button data-wmove="${w}" data-dir="${other}" title="Move to the ${other} column">${other === 'right' ? '→' : '←'}</button><button data-whide="${w}" title="Hide">${I.x}</button></span>`
        : `<span class="ctl2">${go ? `<button class="go" data-tab="${go[0]}">${go[1]} ›</button>` : ''}<button class="wx" data-whide="${w}" title="Hide this widget" aria-label="Hide ${esc(WIDGETS[w])}">${I.x}</button></span>`;
      return `<section class="w w-${w}" data-w="${w}"${S.customizing ? ' draggable="true"' : ''}><h3><span class="grip" draggable="true" data-wdrag="${w}" title="Drag to move">${GRIP}</span><span class="wt">${WIDGETS[w]}</span>${ctl}</h3>${widget(w)}</section>`;
    };
    const colHTML = c => `<div class="wcol" data-wcol="${c}">${L[c].map((w, k) => card(w, c, k, L[c].length)).join('')}${S.customizing && !L[c].length ? '<div class="wempty">Drop a widget here</div>' : ''}</div>`;
    if (shown.length || S.customizing) body += `<div class="widgets ${!S.customizing && (!L.main.length || !L.side.length) ? 'one' : ''}">${colHTML('main')}${colHTML('side')}</div>`;
    if (!shown.length && !S.customizing) body += `<div class="empty"><b>No widgets showing</b>Click Customize to add some back.</div>`;
    body += `<div class="hidezone" data-wdrop="hide">${I.x}Drop here to hide</div>`;
    return header('Today', `${DAYL[dow(today)]}, ${MONTH[+today.slice(5, 7) - 1]} ${+today.slice(8)}${S.me ? ' · ' + esc(S.me) : ''}`, tools) + `<div class="view">${body}</div>`;
  }
  // layout moves (drag, buttons, hide, add) — every change is saved straight away
  const saveLayout = () => store.set('wlayout', S.layout);
  function placeWidget(w, col, before) {
    const L = { main: S.layout.main.filter(x => x !== w), side: S.layout.side.filter(x => x !== w), seen: S.layout.seen };
    const i = before ? L[col].indexOf(before) : -1;
    L[col].splice(i < 0 ? L[col].length : i, 0, w);
    S.layout = L; saveLayout();
  }
  function nudgeWidget(w, dir) {
    const L = S.layout, col = L.main.includes(w) ? 'main' : 'side', arr = L[col].slice(), i = arr.indexOf(w);
    if (dir === 'up' || dir === 'down') {
      const j = i + (dir === 'up' ? -1 : 1); if (j < 0 || j >= arr.length) return;
      [arr[i], arr[j]] = [arr[j], arr[i]]; S.layout = { ...L, [col]: arr };
    } else {
      const to = col === 'main' ? 'side' : 'main';
      placeWidget(w, to, L[to][Math.min(i, L[to].length)] || null); return;
    }
    saveLayout();
  }
  function hideWidget(w) {
    const col = S.layout.main.includes(w) ? 'main' : 'side', arr = S.layout[col], k = arr.indexOf(w);
    if (k < 0) return;
    S.undoHide = { w, col, before: arr[k + 1] || null };
    S.layout = { ...S.layout, [col]: arr.filter(x => x !== w) }; saveLayout();
    flash(`${WIDGETS[w]} hidden`, 'Undo', 'wundo');
  }
  function dayItems(d, by, pc, busy, cal, limit) {
    const m = by[d] || [], p = !m.length && pc[d], b = busy[d], ev = cal[d] || [];
    let h = m.map(s => `<span class="mini" style="--u:${UNITS[s.unit].color}">${UNITS[s.unit].short}</span><span class="off">${s.start}–${s.end}</span>`).join(' ');
    if (p) h += `<span class="mini pc" style="--u:${UNITS[p.unit].color}">Post-call</span>`;
    if (b) h += `<span class="mini busy">${esc(b.kind)}${b.status === 'pending' ? ' ?' : ''}</span>`;
    const shown = limit ? ev.slice(0, limit) : ev;
    h += shown.map(x => `<span class="ev" style="--c:${x.c.color}" title="${esc(x.c.name)}"><i></i><span>${esc(evLabel(x.ev))}</span></span>`).join('');
    if (limit && ev.length > limit) h += `<span class="more">+${ev.length - limit} more</span>`;
    return h;
  }
  function widget(w) {
    const by = myByDate(), pc = postCallMap(), busy = busyMap();
    if (w === 'next') {
      const now = nowMin();
      const cur = S.mine.find(s => { const iv = interval(s.date, s.start, s.end, s.ov); return iv.s <= now && iv.e > now; });
      const up = S.mine.filter(s => interval(s.date, s.start, s.end, s.ov).s > now);
      const n = cur || up[0];
      if (!n) return '<div class="off">Nothing booked ahead.</div>';
      const u = UNITS[n.unit], inD = ord(n.date) - ord(today);
      const when = cur ? `On now · until ${n.end}${n.ov ? ' tomorrow' : ''}` : inD === 0 ? `Today at ${n.start}` : inD === 1 ? `Tomorrow at ${n.start}` : `In ${inD} days`;
      return `<div class="nxw"><div class="nx" style="--u:${u.color}"><span class="sw"></span><div><div class="big">${u.short}</div>
        <div class="meta">${fmtDay(n.date)} · ${hrsLabel(n)}</div><div class="flag" style="color:var(--accent)">${when}</div></div></div>
        ${(() => {
          // the whole calendar month: shifts already done fade out, the next one is marked; in the last week the next month follows
          const ym = ymOf(today), months = [ym];
          if (daysIn(ym) - +today.slice(8) < 7) months.push(addMonths(ym, 1));
          return months.map(m => {
            const list = S.mine.filter(s => ymOf(s.date) === m);
            if (!list.length) return `<div class="lst"><span class="lh">${monthTitle(m)}</span><div><span class="off">No shifts booked.</span></div></div>`;
            // the month's sum the way the app shows it (24h ×3 + 9h ×2 … = total), plus the hours worked so far (a shift you're on counts up to now)
            const st = monthStats(m);
            const parts = [st.full24 && `24h ×${st.full24}`, st.rr9 && `9h ×${st.rr9}`, st.msu && `15h ×${st.msu}`, st.half && `part ×${st.half}`].filter(Boolean);
            const doneH = list.reduce((t, s) => { const iv = interval(s.date, s.start, s.end, s.ov); return t + Math.max(0, Math.min(now, iv.e) - iv.s) / 60; }, 0);
            const pct = st.hours ? Math.round(doneH / st.hours * 100) : 0;
            return `<div class="lst nxl"><span class="lh">${monthTitle(m)} · ${st.shifts} shift${st.shifts > 1 ? 's' : ''}</span>
              <div class="nxsum"><span class="eq">${parts.map(p => `<span>${p}</span>`).join('<i>+</i>')}<i>=</i><b>${fmtH(st.hours)}h</b></span>
                <span class="sofar" title="${pct}% of this month's hours worked"><span class="pbar2"><span style="width:${pct}%"></span></span><b>${fmtH(doneH)}h</b> done · ${fmtH(Math.max(0, st.hours - doneH))}h to go</span></div><div class="nxg">${list.map(s => {
              const iv = interval(s.date, s.start, s.end, s.ov), past = iv.e <= now, on = iv.s <= now && iv.e > now;
              return `<div class="${past ? 'done' : ''} ${s === n ? 'isnext' : ''}" title="${past ? 'Done' : on ? 'On now' : s === n ? 'Next shift' : ''}"><span class="dd">${fmtDay(s.date)}</span><span class="mini" style="--u:${UNITS[s.unit].color}">${UNITS[s.unit].short}</span><span class="off">${s.start}–${s.end}</span>${past ? `<span class="ck" aria-label="done">✓</span>` : s === n ? `<span class="nt">${on ? 'now' : 'next'}</span>` : ''}</div>`;
            }).join('')}</div></div>`;
          }).join('');
        })()}</div>`;
    }
    if (w === 'agenda') {
      const cal = calByDate();
      let h = '<div class="ag">';
      for (let k = 0; k < 7; k++) {
        const d = addDays(today, k), it = dayItems(d, by, pc, busy, cal, 4);
        h += `<div class="dd ${k === 0 ? 't' : ''}">${k === 0 ? 'Today' : k === 1 ? 'Tomorrow' : fmtDay(d)}</div><div class="it">${it || '<span class="off">Off</span>'}</div>`;
      }
      h += '</div>';
      if (!S.cals.length) h += `<div class="fine">Add your own calendar (Google, Apple, Outlook) in My Shifts to see it here too.</div>`;
      return h;
    }
    if (w === 'pool') {
      const mine = S.open.filter(canTake).slice(0, 5);
      if (!mine.length) return `<div class="off">Nothing you can take right now${S.open.length ? ` — ${S.open.length} open, but they clash with your days.` : '.'}</div>`;
      return `<div class="mp">${mine.map(o => {
        const u = UNITS[o.unit], inner = `<b>${fmtDay(o.date).replace(/^\w+ /, '')}<br><span class="off" style="font-weight:600">${DAY[dow(o.date)]}</span></b>
          <span><span class="pill" style="--u:${u.color}">${u.short}</span> ${o.directed ? '<span class="tag you">To you</span>' : ''}<div class="meta" style="margin-top:3px">${hrsLabel(o)} · ${esc(o.offerer)}</div></span><span class="take">Take it</span>`;
        return `<button class="o" data-take="${o.id}" title="Take this shift">${inner}</button>`;
      }).join('')}</div>`;
    }
    if (w === 'weather') {
      const W = S.weather;
      if (!W) return '<div class="off">Loading…</div>';
      if (W.failed || !W.current) return '<div class="off">Weather didn’t load.</div>';
      const [lbl, ic] = wx(W.current.weather_code);
      const days = (W.daily.time || []).slice(1, 5).map((d, i) => {
        const [l, k] = wx(W.daily.weather_code[i + 1]);
        return `<div title="${l}">${DAY[dow(d)]}${wxIcon(k, 26)}<b>${Math.round(W.daily.temperature_2m_max[i + 1])}°</b>${Math.round(W.daily.temperature_2m_min[i + 1])}°</div>`;
      }).join('');
      return `<div class="wxnow">${wxIcon(ic, 52)}<div><div class="big">${Math.round(W.current.temperature_2m)}°</div>
        <div class="meta">${lbl} · feels ${Math.round(W.current.apparent_temperature)}° · wind ${Math.round(W.current.wind_speed_10m)} km/h</div>
        <div class="meta">Today ${Math.round(W.daily.temperature_2m_max[0])}° / ${Math.round(W.daily.temperature_2m_min[0])}°${W.daily.precipitation_probability_max[0] ? ` · ${W.daily.precipitation_probability_max[0]}% rain or snow` : ''}</div></div></div>
        <div class="wxdays">${days}</div>`;
    }
    if (w === 'onnow') {
      const rows = S.group.filter(g => g.date === today && g.unit && !g.buddy);
      if (!rows.length) return '<div class="off">Today’s roster didn’t load.</div>';
      return `<div class="on-today">${WHO_ORDER.map(u => {
        const r = rows.filter(g => g.unit === u); if (!r.length) return '';
        return `<b style="--u:${UNITS[u].color}">${UNITS[u].short}</b><span>${r.map(g => { const me = g.emp && S.emp ? g.emp === S.emp : g.doc === S.me; return me ? `<b style="--u:var(--accent)">${esc(g.doc)}</b>` : esc(g.doc); }).join(' · ')}</span>`;
      }).join('')}</div>`;
    }
    if (w === 'oncall') return oncallWidget();
    if (w === 'cafe') return cafeWidget();
    if (w === 'month') {
      const st = monthStats(ymOf(today)), left = S.mine.filter(s => ymOf(s.date) === ymOf(today) && s.date >= today).length;
      return `<div class="big">${st.shifts} <span style="font-size:16px;font-weight:650;color:var(--muted)">shifts · ${fmtH(st.hours)} h</span></div>
        <div class="meta" style="color:var(--accent);font-weight:700;white-space:pre">${breakdown(st) || '—'}</div>
        <div class="meta">${left ? `${left} still to come in ${MONTH[+today.slice(5, 7) - 1]}` : `All done for ${MONTH[+today.slice(5, 7) - 1]}`}</div>`;
    }
    if (w === 'hennie') return hennieWidget();
    if (w === 'timeoff') {
      const r = S.requests.filter(x => x.date >= today).sort((a, b) => a.date < b.date ? -1 : 1);
      if (!r.length) return '<div class="off">No time off coming up.</div>';
      return `<div class="lst" style="margin-top:0">${r.slice(0, 6).map(x => `<div><span class="dd">${fmtDay(x.date)}</span><span>${esc(x.kind)}</span><span class="tag ${x.status === 'approved' ? '' : 'you'}" style="margin-left:auto;${x.status === 'approved' ? 'background:color-mix(in srgb,var(--accent) 12%,transparent);color:var(--accent)' : ''}">${esc(x.status)}</span></div>`).join('')}</div>`;
    }
    return '';
  }

  // ── Doctors on call (intensivists from PetalMD, cardiology from the RGH monthly PDF; synced into Supabase
  //    from the hospital network by the Unit Board — the same rows the app reads. Names never live in this file.)
  const ICU_DOCS = [['SICU', '4268'], ['MICU', '4265'], ['PHICU', '4249']];
  const ocName = (d, u, r) => { const x = (S.oncall || []).find(o => o.date === d && o.unit === u && o.role === r); return x && x.name && String(x.name).trim() ? String(x.name).trim() : null; };
  function ocNight(d) {                     // one intensivist covers every ICU overnight; anyone else on call = 2nd call
    const count = new Map();
    for (const [u] of ICU_DOCS) { const n = ocName(d, u, 'oncall'); if (n) count.set(n, (count.get(n) || 0) + 1); }
    const ranked = [...count.keys()].sort((a, b) => count.get(b) - count.get(a));
    return ranked.length ? { name: ranked[0], second: ranked.slice(1) } : null;
  }
  const ocInCCU = d => ocName(d, 'CCU', 'ccu') || ocName(addDays(d, -((dow(d) + 2) % 7)), 'CCU', 'day');   // Fri → Thu week
  const MOON = '<svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor" aria-hidden="true"><path d="M20.2 14.6A8.5 8.5 0 0 1 9.4 3.8a8.5 8.5 0 1 0 10.8 10.8Z"/></svg>';
  const HEART = '<svg viewBox="0 0 24 24" width="13" height="13" fill="currentColor" aria-hidden="true"><path d="M12 20.5s-8-4.9-8-10.6A4.4 4.4 0 0 1 12 7.4a4.4 4.4 0 0 1 8 2.5c0 5.7-8 10.6-8 10.6Z"/></svg>';
  function oncallWidget() {
    if (S.oncall == null) return '<div class="off">Checking who’s on call…</div>';
    const d = today;
    if (!S.oncall.some(o => o.date === d)) return `<div class="off">${S.oncallFailed ? 'Couldn’t reach the on-call list just now.' : 'Today’s doctors aren’t in yet. The list is synced from the hospital network.'}</div>`;
    const evening = toMin(reginaHM()) >= 17 * 60;
    const pair = (a, b) => (a && a !== b ? `<span>${esc(a)}</span>` : '') + (b ? `<span class="circ" title="On call from 17:00">${esc(b)}</span>` : '') + (!a && !b ? '<span class="off">—</span>' : '');
    const icu = ICU_DOCS.map(([u, ph]) => {
      const n = ocName(d, u, 'day');
      return `<div class="oc-u" style="--u:${UNITS[u].color}"><b>${u === 'PHICU' ? 'Pasqua ICU' : UNITS[u].short}</b><span class="oc-n">${n ? esc(n) : '—'}</span><span class="oc-ph">On call ☎ ${ph}</span></div>`;
    }).join('');
    const night = ocNight(d), ccuC = UNITS.CCU.color;
    const inCCU = ocInCCU(d), cons = ocName(d, 'CCU', 'consults');
    const hasCCU = (S.oncall || []).some(o => o.date === d && o.unit === 'CCU');
    return `<div class="oc-icu">${icu}</div>
      <div class="oc-rows">
        ${night ? `<div class="oc-r ${evening ? 'now' : ''}"><span class="oc-l" style="color:var(--posted)">${MOON}ICU tonight</span><span class="oc-v"><span class="circ" style="--c:var(--posted)">${esc(night.name)}</span>${night.second.length ? `<span class="oc-2">2nd call ${night.second.map(esc).join(', ')}</span>` : ''}</span></div>` : ''}
        ${hasCCU ? `<div class="oc-r"><span class="oc-l" style="color:${ccuC}">${HEART}Cardiology</span><span class="oc-v" style="--c:${ccuC}">
          ${inCCU ? `<span><i>In CCU</i>${esc(inCCU)}</span>` : ''}${cons ? `<span><i>Consults 8–5</i>${esc(cons)}</span>` : ''}
          <span><i>On call</i>${pair(ocName(d, 'CCU', 'day'), ocName(d, 'CCU', 'oncall'))}</span>
          <span><i>STEMI</i>${pair(ocName(d, 'CCU', 'stemi_day'), ocName(d, 'CCU', 'stemi_oncall'))}</span></span></div>` : ''}
      </div>
      <div class="meta">A circled name is on call from 17:00.</div>`;
  }
  // ── Cafeteria (RGH / Pasqua rotating weekly menus, captured by the Unit Board) ──
  function cafeMenu(iso, site) {
    const ps = (S.cafe || []).filter(p => p.site === site).sort((a, b) => a.page - b.page);
    if (!ps.length) return null;
    for (let i = 0; i < ps.length; i++) { const d = (ps[i].days || []).find(x => x.date === iso); if (d) return { day: d, week: i + 1, of: ps.length }; }
    const ai = ps.findIndex(p => p.first_date); if (ai < 0) return null;
    const diff = ord(iso) - ord(ps[ai].first_date), idx = (((ai + Math.floor(diff / 7)) % ps.length) + ps.length) % ps.length;
    const days = ps[idx].days || [], wd = DAYL[dow(iso)].toUpperCase(), off = ((diff % 7) + 7) % 7;
    const day = days.find(x => (x.weekday || '').toUpperCase().startsWith(wd.slice(0, 3))) || days[off];
    return day ? { day, week: idx + 1, of: ps.length } : null;
  }
  function cafeWidget() {
    const seg = `<div class="seg sm" role="group" aria-label="Cafeteria">${[['RGH', 'RGH'], ['PH', 'Pasqua']].map(([k, l]) => `<button data-cafe="${k}" aria-pressed="${S.cafeSite === k}">${l}</button>`).join('')}</div>`;
    if (S.cafe == null) return seg + '<div class="off">Checking the specials…</div>';
    const m = cafeMenu(today, S.cafeSite);
    if (!m) return seg + `<div class="off">${S.cafeFailed ? 'Couldn’t reach the menu just now.' : 'No menu captured for this site yet.'}</div>`;
    let secs = (m.day.sections || []).filter(x => (x.items || []).length);
    const has = (x, w) => (x.label || '').toLowerCase().includes(w);
    const lead = toMin(reginaHM()) >= 14 * 60 ? 'supper' : 'lunch';        // lunch first, supper first after 2 pm
    const li = secs.findIndex(x => has(x, lead));
    if (li > 0) { let e = li + 1; while (e < secs.length && has(secs[e], 'side')) e++; secs = secs.slice(li, e).concat(secs.slice(0, li), secs.slice(e)); }
    return seg + `<div class="cf">${secs.map(x => `<div class="cf-l ${has(x, 'lunch') || has(x, 'supper') ? 'feat' : ''}">${esc(x.label)}</div><div class="cf-i">${x.items.map(it => `<span>${esc(it.name)}${it.price ? ` <em>${esc(it.price)}</em>` : ''}</span>`).join('')}</div>`).join('')}</div>
      <div class="meta">Menu week ${m.week} of ${m.of} · prices as printed · <button class="lnk" data-x="cafepage">Full menu ›</button></div>`;
  }

  // ── Pool ──
  function viewPool() {
    const all = S.open.filter(o => !S.unitsOff.has(o.unit));
    const forMe = all.filter(pickable);
    const onlyMe = S.poolSeg === 'me', shown = onlyMe ? forMe : all;
    if (S.selPool && !shown.some(o => o.id === S.selPool)) S.selPool = null;
    if (!S.selPool && shown.length && window.innerWidth >= 1280) S.selPool = (forMe[0] || all[0]).id;
    const present = [...new Set(S.open.map(o => o.unit))];
    const seg = `<div class="seg" role="group" aria-label="Ring on the calendars">
        <button data-seg="all" aria-pressed="${S.poolSeg === 'all'}" title="Show every open shift">All<b>${all.length}</b></button>
        <button data-seg="me" aria-pressed="${S.poolSeg === 'me'}" title="Show only the ones you can take">For me<b>${forMe.length}</b></button>${postsSegShown() || S.poolSeg === 'posts' ? `<button data-seg="posts" aria-pressed="${S.poolSeg === 'posts'}" title="Shifts you posted">My posts<b>${myPosts().length}</b></button>` : ''}</div>`;
    let body = banners() + `<div class="pbar">${seg}<div class="legend"><span><i style="background:var(--accent)"></i>Your shift</span><span><i style="background:color-mix(in srgb,var(--accent) 25%,transparent)"></i>Post-call</span><span><i style="box-shadow:inset 0 0 0 1.6px var(--avail)"></i>Open shift — click to see it</span></div></div>` + miniMonths() + `${present.length > 1 ? `<div class="ufrow"><span class="ufilter">${present.sort((a, b) => WHO_ORDER.indexOf(a) - WHO_ORDER.indexOf(b)).map(u => `<button class="uf" data-unit="${u}" aria-pressed="${!S.unitsOff.has(u)}"><i style="background:${UNITS[u].color}"></i>${UNITS[u].short}</button>`).join('')}</span></div>` : ''}`;
    body += swapsBox();
    if (S.poolSeg === 'posts') { const pb = banners() + `<div class="pbar">${seg}</div>`; return header('Shift Pool', `${plural(myPosts().length, 'shift')} waiting for pickup`, '') + `<div class="view" data-scroll="pool">${pb + swapsBox() + postsView()}</div>`; }
    const card = o => {
      if (o.notOffered) return noCard(o);
      const u = UNITS[o.unit], ok = pickable(o) && !o.conflict && !o.busy;
      const flag = o.busy ? busyText(o.busy) : o.flag;
      return `<button class="card sm ${ok ? '' : 'clash'}" style="--u:${u.color}" data-open="${o.id}" aria-selected="${S.selPool === o.id}">
          <div class="date"><div class="dw">${DAY[dow(o.date)]}</div><div class="dn">${+o.date.slice(8)}</div></div>
          <div style="min-width:0"><div class="ln1"><span class="pill">${u.short}</span><span class="hrs">${hrsLabel(o)}</span>${o.directed ? '<span class="tag you">For you</span>' : ''}</div>
            <div class="meta"><span>Offered by ${esc(o.offerer)}</span><span class="flag ${ok ? 'ok' : 'no'}">${ok ? 'Available' : esc(flag)}</span></div></div></button>`;
    };
    const col = (title, list, empty, foot) => {
      let last = '', h = `<section class="pcol"><h3>${title}<b>${list.length}</b></h3>`;
      if (!list.length) return h + `<div class="empty sm">${empty}</div>${foot || ''}</section>`;
      for (const o of list) { if (ymOf(o.date) !== last) { last = ymOf(o.date); h += `<div class="dayhead">${monthTitle(last)}</div>`; } h += card(o); }
      return h + (foot || '') + '</section>';
    };
    if (S.poolDay) {
      const day = all.filter(o => o.date === S.poolDay && (S.poolSeg !== 'me' || pickable(o)));
      if (!day.length) S.poolDay = null;
      else {
        const mineThat = (myByDate()[S.poolDay] || []).map(s => UNITS[s.unit].short).join(' + ');
        body += `<div class="pday"><div class="pdh"><b>${DAYL[dow(S.poolDay)]}, ${MONTH[+S.poolDay.slice(5, 7) - 1]} ${+S.poolDay.slice(8)}</b><span>${day.length} open${mineThat ? ` · you’re on ${mineThat}` : ''}</span>
          <button class="x" data-pday="${S.poolDay}" title="Close" aria-label="Close">${I.close}</button></div>
          <div class="pdc">${day.map(o => card(o).replace('</button>', `</button>`) + '').join('')}</div>
          <div class="pda">${day.filter(canTake).map(o => `<button class="chipbtn primary" data-take="${o.id}">Take ${UNITS[o.unit].short}</button>`).join('')}</div></div>`;
      }
    }
    const meCol = col('For me', forMe, all.length ? `Nothing you can take — the ${all.length} open clash with your roster or a day off.` : 'Nothing to take right now.', onlyMe ? takenCard(true) : '');
    if (onlyMe) body += `<div class="pool3 one">${meCol}${forMe.length ? poolDetail() : ''}</div>`;
    else body += `<div class="pool3">${col('All open', withNotOffered(all), 'No open shifts right now. New posts show up here as soon as they’re offered.', takenCard(false))}${meCol}${all.length ? poolDetail() : ''}</div>`;
    return header('Shift Pool', `${forMe.length} you can take · ${all.length} open`, '') + `<div class="view" data-scroll="pool">${body}</div>`;
  }
  function miniMonths() {
    const by = myByDate(), pc = postCallMap(), openDays = new Set(S.open.filter(o => !S.unitsOff.has(o.unit) && (S.poolSeg !== 'me' || pickable(o))).map(o => o.date));
    // as many months as fit the row (6 on a wide screen), stretched so the row ends flush
    const mainW = (root.querySelector('.main') || {}).clientWidth || window.innerWidth - 232;
    const n = Math.max(2, Math.min(6, Math.floor((mainW - 56 + 12) / (205 + 12))));
    let out = `<div class="months" style="grid-template-columns:repeat(${n},minmax(0,1fr))">`;
    for (let i = 0; i < n; i++) {
      const ym = addMonths(ymOf(today), i), first = ym + '-01', pad = (dow(first) - S.weekStart + 7) % 7;
      out += `<div class="mm"><h3>${monthTitle(ym)}</h3><div class="g">`;
      for (let k = 0; k < 7; k++) out += `<div class="h">${DAY[(k + S.weekStart) % 7][0]}</div>`;
      for (let k = 0; k < pad; k++) out += '<div></div>';
      for (let d = 1; d <= daysIn(ym); d++) {
        const iso = `${ym}-${String(d).padStart(2, '0')}`, m = by[iso], p = !m && pc[iso];
        const cls = ['d']; let st = '';
        if (m) { cls.push('on'); st = `background:${UNITS[m[0].unit].color}`; }
        else if (p) { cls.push('pc'); st = `background:color-mix(in srgb,${UNITS[p.unit].color} 24%,transparent)`; }
        if (openDays.has(iso)) cls.push('open');
        if (iso === today) cls.push('today');
        if (iso < today) cls.push('past');
        if (iso === S.poolDay) cls.push('sel');
        out += `<div class="${cls.join(' ')}" style="${st}" ${openDays.has(iso) ? `data-pday="${iso}" title="Open shift on ${fmtDay(iso)} — click to see it"` : (m ? `title="${m.map(x => UNITS[x.unit].short).join(' + ')}"` : '')}>${d}</div>`;
      }
      out += '</div></div>';
    }
    return out + '</div>';
  }
  function poolDetail() {
    const o = S.open.find(x => x.id === S.selPool);
    if (!o) return '<aside class="detail"><div class="fine">Pick a shift to see your days around it and who else is on.</div></aside>';
    const u = UNITS[o.unit], by = myByDate(), pc = postCallMap(), busy = busyMap();
    let tl = '';
    const cal = calByDate();
    for (let k = -3; k <= 3; k++) {
      const d = addDays(o.date, k), items = dayItems(d, by, pc, busy, cal, 3);
      tl += `<div class="tlr ${k === 0 ? 'sel' : ''}"><span class="dd">${fmtDay(d)}</span><span>${k === 0 ? `<span class="mini" style="--u:${u.color}">${u.short}</span><span>${o.start}–${o.end} · open</span>` + (items ? `<br>${items}` : '') : (items || '<span class="off">Off</span>')}</span></div>`;
    }
    const sameDay = S.group.filter(g => g.date === o.date && g.unit && !g.buddy).sort((a, b) => WHO_ORDER.indexOf(a.unit) - WHO_ORDER.indexOf(b.unit));
    const who = sameDay.length ? sameDay.map(g => `<div><i style="background:${UNITS[g.unit].color}"></i><span class="u">${UNITS[g.unit].short}</span><span>${esc(g.doc)}${g.emp && g.emp === S.emp || g.doc === S.me ? ' (you)' : ''}</span></div>`).join('') : '<div class="off">Not loaded for this day.</div>';
    const ok = !o.conflict && !o.busy;
    return `<aside class="detail" style="--u:${u.color}">
      <div class="ln1"><span class="pill">${u.short}</span>${o.directed ? '<span class="tag you">Offered to you</span>' : ''}</div>
      <h2 style="margin-top:8px">${DAYL[dow(o.date)]}, ${MONTH[+o.date.slice(5, 7) - 1]} ${+o.date.slice(8)}</h2>
      <div class="meta">${hrsLabel(o)} · from ${esc(o.offerer)}</div>
      <div class="flag ${ok ? 'ok' : 'no'}">${ok ? 'Available — nothing clashes' : esc(o.busy ? busyText(o.busy) : o.flag)}</div>
      <div class="k">Your days around it</div><div class="tl">${tl}</div>
      <div class="k">Who's on that day</div><div class="wl">${who}</div>
      <div class="act">
        ${ok ? `<button class="chipbtn primary" data-take="${o.id}">Take it</button>` : ''}
        ${DEMO ? '' : `<a class="chipbtn" href="${scheduleURL(o.date)}" target="_blank" rel="noopener">Open that day in Lightning Bolt ${I.ext}</a>`}
      </div>
      <div class="fine">Taking a shift opens Lightning Bolt’s own accept page right here — you confirm it there.</div>
    </aside>`;
  }

  // ── My Shifts ──
  // My Shifts: every month from a year back to 14 months ahead in one scrolling column (wheel / trackpad / arrows);
  // opens on this month. Click any day → the day panel (give away, swap, pick up, busy, time off, who's on).
  const msRange = () => [addMonths(ymOf(today), -12), addMonths(ymOf(today), 14)];
  function viewMine() {
    const [m0, m1] = msRange(), months = [];
    for (let ym = m0; ym <= m1; ym = addMonths(ym, 1)) months.push(ym);
    const upcoming = S.mine.filter(s => s.date > today || (s.date === today && s.start > reginaHM()));
    const next = upcoming[0];
    const yr = S.mine.filter(s => s.date.slice(0, 4) === today.slice(0, 4));
    const yrH = yr.reduce((a, s) => a + hoursOf(s), 0), yrDone = yr.filter(s => s.date < today).length;
    const pend = S.requests.filter(r => r.status === 'pending' && r.date >= today).length;
    const inDays = next ? ord(next.date) - ord(today) : 0;
    const appr = S.requests.filter(r => r.status === 'approved' && r.date >= today).length;
    const posts = S.mine.filter(s => s.pending && s.date >= today).length;
    const stats = `<div class="quiet">
      <span><b>Next</b>${next ? `${UNITS[next.unit].short} · ${fmtDay(next.date)} · ${inDays === 0 ? 'today' : inDays === 1 ? 'tomorrow' : `in ${inDays} days`}` : 'nothing booked ahead'}</span>
      <span><b>${today.slice(0, 4)} so far</b>${yrDone} of ${yr.length} shifts · ${fmtH(yrH)} h</span>
      ${posts ? `<span><b>Offered</b>${posts} shift${posts > 1 ? 's' : ''} waiting for pickup</span>` : ''}
      ${pend || appr ? `<span><b>Time off</b>${[pend ? `${pend} pending` : '', appr ? `${appr} approved` : ''].filter(Boolean).join(' · ')}</span>` : ''}
    </div>`;
    const tools = `${S.cals.map(c => `<span class="cal ${c.url ? 'live' : ''}" style="--c:${c.color}" ${c.on ? '' : 'data-off'}><button data-cal="${c.id}" title="${c.on ? 'Hide' : 'Show'} ${esc(c.name)} · ${c.events.length} events · ${c.url ? (c.err ? esc(c.err) : `live link, updated ${c.synced || '—'}`) : `file copy from ${c.added || '—'} (doesn’t update)`}" aria-pressed="${c.on}"><i></i>${esc(c.name)}${c.url ? `<em class="${c.err ? 'bad' : ''}" aria-hidden="true">${c.err ? '!' : '↻'}</em>` : ''}</button><button class="rm" data-calrm="${c.id}" title="Remove ${esc(c.name)}">${I.x}</button></span>`).join('')}
      <button class="chipbtn" data-act="addcal" title="Add a calendar — a live link from Google, Apple or Outlook">${I.plus}<span class="lbl2">${S.cals.length ? 'Calendar' : 'Add your calendar'}</span></button>
      <input type="file" accept=".ics,text/calendar" multiple data-file="cal" hidden>
      <span class="tsep"></span>
      <button class="chipbtn" data-act="mprev" title="Previous month (←)" aria-label="Previous month">${I.back}</button>
      <button class="chipbtn" data-act="mtoday" title="This month (T)">This month</button>
      <button class="chipbtn" data-act="mnext" title="Next month (→)" aria-label="Next month">${I.fwd}</button>
      <button class="chipbtn" data-act="ics" title="Download your shifts for Calendar, Outlook or Google">${I.dl}<span class="lbl2">Calendar file</span></button>`;
    const legend = `<div class="mslegend"><span><i class="lg-open"></i>Open shift</span><span><i class="lg-post"></i>You offered it</span><span><i class="lg-busy"></i>Busy</span><span class="hint">Click a day to give away, pick up or mark busy · drag across days (or Shift / ${MODK}-click) to pick several</span></div>`;
    return header('My Shifts', `<span data-mssub>${monthTitle(S.msMonth)}</span>`, tools) + `<div class="msstrip">${banners()}${stats}${legend}</div><div class="view msview"><div class="msgrid">${months.map(monthGrid).join('')}</div>
      <div class="fine">24 h calls run 08:00 → 08:00; the faint block the next morning is post-call.</div></div>`;
  }
  function monthGrid(ym) {
    const by = myByDate(), pc = postCallMap(), req = {}, openDays = new Set(S.open.map(o => o.date)), cal = calByDate();
    for (const r of S.requests) if (r.status === 'pending' || r.status === 'approved') req[r.date] = r;
    const st = monthStats(ym), first = ym + '-01', pad = (dow(first) - S.weekStart + 7) % 7, ms = new Set(S.multi);
    let g = `<section data-ym="${ym}"><div class="mhead"><h2>${monthTitle(ym)}</h2><span class="st">${st.shifts} shift${st.shifts === 1 ? '' : 's'} · ${fmtH(st.hours)} h</span><span class="bd">${breakdown(st)}</span></div><div class="wk">`;
    for (let k = 0; k < 7; k++) g += `<div class="h">${DAY[(k + S.weekStart) % 7]}</div>`;
    for (let k = 0; k < pad; k++) g += '<div></div>';
    for (let d = 1; d <= daysIn(ym); d++) {
      const iso = `${ym}-${String(d).padStart(2, '0')}`, past = iso < today;
      let inner = `<div class="n">${d}</div>`;
      const p = pc[iso];
      if (p) inner += `<div class="blk pc ${past ? 'past' : ''}" style="--u:${UNITS[p.unit].color}">${UNITS[p.unit].short}</div>`;
      let posted = false;
      for (const s of by[iso] || []) {
        const std = !(s.start === '08:00' && (s.end === '08:00' || s.end === '17:00')) && !(s.start === '17:00' && s.end === '08:00');
        if (s.pending && !past) posted = true;
        inner += `<div class="blk ${past ? 'past' : ''} ${s.pending && !past ? 'posted' : ''}" style="--u:${UNITS[s.unit].color}" title="${UNITS[s.unit].full} · ${hrsLabel(s)}${s.pending ? ' · offered, waiting for pickup' : ''}">${UNITS[s.unit].short}${std ? `<span class="t">${s.start}–${s.end}</span>` : ''}</div>`;
      }
      const r = req[iso];
      if (r) inner += `<div class="busytag ${r.status}" title="${esc(r.kind)} · ${esc(r.status)}${r.note ? ' · ' + esc(r.note) : ''}">${esc(r.kind)}${r.status === 'pending' ? ' ?' : ''}</div>`;
      if (S.busyDays[iso] != null) inner += `<div class="busytag mine" title="You marked this day busy">${esc(S.busyDays[iso] || 'Busy')}</div>`;
      const ev = cal[iso] || [];
      inner += ev.slice(0, 2).map(x => `<div class="ev" style="--c:${x.c.color}" title="${esc(x.c.name)} · ${esc(evLabel(x.ev))}"><i></i><span>${esc(evLabel(x.ev))}</span></div>`).join('');
      if (ev.length > 2) inner += `<div class="more" title="${esc(ev.slice(2).map(x => evLabel(x.ev)).join('\n'))}">+${ev.length - 2} more</div>`;
      if (openDays.has(iso) && !past) inner += `<span class="osq" title="Open shift — click the day to pick it up"></span>`;
      if (posted) inner += `<span class="psq" title="You offered a shift on this day"></span>`;
      g += `<div class="cell clk ${iso === today ? 'today' : ''} ${past ? 'past' : ''} ${S.daySel === iso ? 'sel' : ''} ${ms.has(iso) ? 'msel' : ''}" data-day="${iso}" tabindex="0" role="button" aria-label="${fmtDay(iso)}">${inner}</div>`;
    }
    return g + '</div></section>';
  }
  // keep the header's month in step with the scroll; land on S.msGo when asked
  function minePlace() {
    const v = root.querySelector('.msview'); if (!v) return;
    if (S.msGo) { msScrollTo(S.msGo, false); S.msGo = null; } else if (S.msTop != null) v.scrollTop = S.msTop;
    let raf = 0;
    v.addEventListener('scroll', () => { S.msTop = v.scrollTop; if (!raf) raf = requestAnimationFrame(() => { raf = 0; msSub(); }); }, { passive: true });
    msSub();
  }
  function msScrollTo(ym, smooth) {
    const v = root.querySelector('.msview'), sec = v && v.querySelector(`section[data-ym="${ym}"]`); if (!sec) return;
    const top = sec.offsetTop - v.offsetTop - 12;
    if (smooth) v.scrollTo({ top, behavior: 'smooth' }); else { v.scrollTop = top; S.msTop = top; }
    S.msMonth = ym;
  }
  function msSub() {
    const v = root.querySelector('.msview'), sub = root.querySelector('[data-mssub]'); if (!v || !sub) return;
    const y = v.scrollTop + v.offsetTop + 60;
    let cur = null;
    for (const sec of v.querySelectorAll('section[data-ym]')) { if (sec.offsetTop <= y && sec.offsetTop + sec.offsetHeight > y) { cur = sec.dataset.ym; break; } }
    if (cur) { S.msMonth = cur; sub.textContent = monthTitle(cur); }
  }

  // ───────────────────────────── writes to Lightning Bolt (only ever after an explicit confirm) ─────────────────────────────
  // The same calls the app makes (LBWebSource): success = HTTP ok AND no errors/warnings message in the body.
  // No token or a 401 → re-capture the session once and retry; a network failure is NOT retried (it may have gone out).
  function lbMessage(text) {
    try {
      const j = JSON.parse(text), d = Array.isArray(j) ? j[0] : j;
      const first = x => Array.isArray(x) ? (x.map(m => m && m.message).find(Boolean) || null) : null;
      return d ? first(d.errors) || first(d.warnings) : null;
    } catch (e) { return null; }
  }
  async function lbPost(path, payload) {
    if (DEMO) return { ok: false, message: 'Sample data — nothing is sent.' };
    const body = JSON.stringify(payload);
    const once = async () => {
      if (!AUTH) return { status: 401 };
      try { const r = await fetch(LBAPI + path, { method: 'POST', headers: { Authorization: AUTH, 'Content-Type': 'application/json' }, body }); return { ok: r.ok, status: r.status, text: await r.text() }; }
      catch (e) { return { ok: false, status: -1, text: String(e) }; }
    };
    let r = await once();
    if (r.status === 401) { AUTH = ''; await captureToken(); r = await once(); }
    if (r.status === 401) return { ok: false, message: 'Couldn’t reconnect to Lightning Bolt, so nothing was sent. Refresh (sign in if asked), then try again.' };
    if (r.status === -1) return { ok: false, message: 'Couldn’t reach Lightning Bolt. Check your connection, refresh, and look before trying again.' };
    const msg = lbMessage(r.text || '');
    return { ok: r.ok && !msg, message: r.ok ? msg : (msg || `Lightning Bolt rejected it (status ${r.status}).`) };
  }
  async function putOfferNote(slot, note, reason) {
    if (DEMO || !note) return;
    try {
      await fetch(SUPA + '/offer_notes?on_conflict=slot_id', { method: 'POST', headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY, 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates,return=minimal' },
        body: JSON.stringify([{ slot_id: +slot, note, reason: reason || null, by_emp: S.emp ? +S.emp : null }]) });
    } catch (e) {}
  }
  const offerToPerson = (s, emp, note) => lbPost('/schedule/update', [{ slot_id: +s.slot, emp_id: +emp, note: note || '', template_id: s.tpl || 6, type: 'replace personnel' }]);
  const offerToGroup = (s, emps) => lbPost('/schedule/preswap', [{ slot_id: +s.slot, emp_ids: emps.map(Number), type: 'preswap_create' }]);
  const cancelOfferLB = (slot, emp) => lbPost('/schedule/update', [{ type: 'delete swap', slot_id: +slot, emp_id: +emp, decision_note: null }]);
  const REQ_KIND = { 'Time Off': [20248, 343], 'Night Off': [20251, 346] };
  const submitRequest = (kind, dates, note) => lbPost('/request', dates.map(d => ({ type: 'new', emp_id: +S.emp, date: d + 'T00:00:00', assign_id: REQ_KIND[kind][0], assign_structure_id: REQ_KIND[kind][1], assign_name: kind, template_id: 6, command_type: 0, note: note || '', start_date: null, end_date: null })));
  const deleteRequests = ids => lbPost('/request', ids.map(id => ({ type: 'delete', request_id: +id, decision_note: null })));
  function rememberTarget(slot, emp) { S.offerTargets[slot] = String(emp); store.set('offerTargets', S.offerTargets); }

  // colleagues (emp → name) from the roster we read, and who could work a given shift — the app's rules:
  // not already on that day (buddy included), not post-call or pre-call, not on the next day for an overnight,
  // and SICU only for people who have worked SICU.
  const realDoc = n => n && n !== '—' && !/^empty$/i.test(n) && !/no mri/i.test(n);
  function colleagues() {
    const m = new Map();
    for (const g of S.group) if (g.emp && g.emp !== S.emp && realDoc(g.doc) && g.doc !== S.me) m.set(g.emp, g.doc);
    return [...m].map(([emp, name]) => ({ emp, name })).sort((a, b) => surname(a.name).localeCompare(surname(b.name)));
  }
  function sicuDocs() {
    const seen = new Set(store.get('sicuDocs', []));
    let grew = false;
    for (const g of S.group) if (g.unit === 'SICU' && g.date < today && realDoc(g.doc) && !seen.has(g.doc)) { seen.add(g.doc); grew = true; }
    if (grew && !DEMO) store.set('sicuDocs', [...seen]);
    return seen;
  }
  function eligibleFor(s) {
    const by = groupByDay(), d = s.date;
    const names = (iso, f) => new Set((by[iso] || []).filter(f || (() => true)).map(g => g.doc));
    const busy = names(d), post = names(addDays(d, -1), g => g.ov), pre = names(addDays(d, 1), g => g.ov), next = s.ov ? names(addDays(d, 1)) : new Set();
    const sicu = s.unit === 'SICU' ? sicuDocs() : null;
    return colleagues().filter(c => !busy.has(c.name) && !post.has(c.name) && !pre.has(c.name) && !next.has(c.name) && (!sicu || sicu.has(c.name)));
  }
  const nameOfEmp = emp => { const g = S.group.find(x => x.emp === String(emp)); return g ? g.doc : ''; };
  const firstName = n => String(n || '').split(/\s+/)[0];
  // ── Texting, like the app: colleagues' cell numbers from LB's /personnel (a read), kept in memory only ──
  let DIR = null, dirLoading = null;
  function loadDirectory() {
    if (DIR) return Promise.resolve(DIR);
    if (dirLoading) return dirLoading;
    if (DEMO) { DIR = {}; colleagues().forEach((c, i) => { if (i % 6 !== 5) DIR[c.emp] = `306-555-01${String(10 + i).slice(-2)}`; }); return Promise.resolve(DIR); }
    dirLoading = fetch(LBAPI + '/personnel/', { headers: { Authorization: AUTH } }).then(r => r.ok ? r.json() : null).then(j => {
      const arr = Array.isArray(j) ? j : j ? (j.data || j.personnel || j.people || []) : [];
      const d = {};
      for (const a of arr) { if (!a || a.emp_id == null) continue; const c = String(a.phone_cell || a.cell || a.phone_mobile || a.mobile || a.phone || '').replace(/[^\d+]/g, ''); if (c) d[a.emp_id] = c; }
      if (Object.keys(d).length) DIR = d;
      dirLoading = null; return DIR;
    }).catch(() => { dirLoading = null; return null; });
    return dirLoading;
  }
  const cellOf = emp => DIR && emp != null ? DIR[emp] || null : null;
  const APPLE = /Mac|iPhone|iPad|iPod/.test(navigator.platform || navigator.userAgent);
  function smsHref(cells, msg) {
    const nums = cells.filter(Boolean).map(c => String(c).replace(/[^\d+]/g, '')).filter(Boolean);
    if (!nums.length) return null;
    const b = encodeURIComponent(msg);
    if (nums.length > 1 && APPLE) return `sms://open?addresses=${nums.join(',')}&body=${b}`;
    return `sms:${nums.join(',')}${/Android/i.test(navigator.userAgent) ? '?' : '&'}body=${b}`;
  }
  // A Text button (opens Messages with the text filled in) — or nothing when we have no number.
  function textBtn(cells, msg, label, cls) {
    const h = smsHref([].concat(cells), msg); if (!h) return '';
    return `<a class="chipbtn txt ${cls || ''}" href="${esc(h)}" data-txtcopy="${esc(msg)}" title="Opens Messages with the text filled in">${I.msg}${label}</a>`;
  }

  // ── the day panel: docked on the right (or left) with the calendar shrinking to make room, or floating where you drag it ──
  let dayEl = null, dock = store.get('dayDock', { m: 'r' }) || { m: 'r' };
  const wideScreen = () => window.innerWidth > 760;
  function dockApply() {
    const on = !!dayEl && wideScreen();
    app.classList.toggle('dock-r', on && dock.m === 'r');
    app.classList.toggle('dock-l', on && dock.m === 'l');
    app.classList.toggle('sidehide', on);
    if (!dayEl) return;
    dayEl.classList.toggle('dl', on && dock.m === 'l');
    dayEl.classList.toggle('fl', on && dock.m === 'f');
    const sh = dayEl.querySelector('.sheet'); if (!sh) return;
    if (on && dock.m === 'f') {
      const w = sh.offsetWidth || 392;
      sh.style.left = Math.max(8, Math.min(window.innerWidth - w - 8, dock.x || 0)) + 'px';
      const t = Math.max(8, Math.min(window.innerHeight - 254, dock.y || 0));
      sh.style.top = t + 'px'; sh.style.maxHeight = (window.innerHeight - t - 14) + 'px';
    } else { sh.style.left = sh.style.top = sh.style.maxHeight = ''; }
  }
  window.addEventListener('resize', () => { if (dayEl) dockApply(); });
  // drag the panel by its header: drop it near the right or left edge to dock it there, anywhere else to float it
  function dayDragStart(e) {
    const hd = e.target.closest('.sheet header');
    if (!hd || e.button !== 0 || e.target.closest('button,input,a') || !wideScreen()) return;
    const sh = hd.closest('.sheet'), r = sh.getBoundingClientRect();
    const g = { dx: e.clientX - r.left, dy: e.clientY - r.top, x0: e.clientX, y0: e.clientY, moved: false, side: null };
    let hint = null;
    const move = ev => {
      if (!g.moved) { if (Math.hypot(ev.clientX - g.x0, ev.clientY - g.y0) < 5) return; g.moved = true; dayEl.classList.add('fl', 'dragging'); dayEl.classList.remove('dl'); }
      g.x = ev.clientX - g.dx; g.y = ev.clientY - g.dy;
      sh.style.left = Math.max(0, Math.min(window.innerWidth - sh.offsetWidth, g.x)) + 'px';
      const t = Math.max(0, Math.min(window.innerHeight - 60, g.y));
      sh.style.top = t + 'px'; sh.style.maxHeight = Math.max(200, window.innerHeight - t - 14) + 'px';
      const side = ev.clientX > window.innerWidth - 90 ? 'r' : ev.clientX < 100 ? 'l' : null;
      if (side !== g.side) {
        g.side = side; if (hint) { hint.remove(); hint = null; }
        if (side) { hint = document.createElement('div'); hint.className = 'dockhint'; hint.style[side === 'r' ? 'right' : 'left'] = (side === 'r' ? 14 : 24) + 'px'; root.appendChild(hint); }
      }
    };
    const up = () => {
      window.removeEventListener('pointermove', move); window.removeEventListener('pointerup', up); window.removeEventListener('pointercancel', up);
      if (hint) hint.remove();
      if (!dayEl) return;
      dayEl.classList.remove('dragging');
      if (!g.moved) return;
      dock = g.side ? { m: g.side } : { m: 'f', x: parseFloat(sh.style.left), y: parseFloat(sh.style.top) };
      store.set('dayDock', dock); dockApply(); daySelVisible();
    };
    window.addEventListener('pointermove', move); window.addEventListener('pointerup', up); window.addEventListener('pointercancel', up);
  }
  function daySelVisible() { requestAnimationFrame(() => setTimeout(() => { const c = root.querySelector('.cell.sel'); if (c) c.scrollIntoView({ block: 'nearest', inline: 'nearest', behavior: 'smooth' }); }, 200)); }
  function openDay(iso) {
    if (S.multi.length) { S.multi = []; paintMulti(); }
    S.daySel = iso; S.dayAsk = null;
    ensureDayEl();
    S.busyDraft = S.busyDays[iso] || ''; S.reqDraft = '';
    drawDay();
    root.querySelectorAll('.cell.sel').forEach(c => c.classList.remove('sel'));
    const c = root.querySelector(`.cell[data-day="${iso}"]`); if (c) c.classList.add('sel');
    const x = dayEl.querySelector('[data-dx]'); if (x) x.focus({ preventScroll: true });
    daySelVisible();
  }
  function ensureDayEl() {
    if (!dayEl) {
      dayEl = document.createElement('div'); dayEl.className = 'sheetbg drawer';
      dayEl.addEventListener('click', onDayClick);
      dayEl.addEventListener('pointerdown', dayDragStart);
      dayEl.addEventListener('dblclick', e => { if (e.target.closest('.sheet header') && !e.target.closest('button') && wideScreen()) { dock = { m: 'r' }; store.set('dayDock', dock); dockApply(); } });
      dayEl.addEventListener('input', e => { if (e.target.dataset.busynote != null) S.busyDraft = e.target.value; if (e.target.dataset.reqnote != null) S.reqDraft = e.target.value; });
      dayEl.addEventListener('keydown', e => { if (e.key === 'Enter' && e.target.dataset.busynote != null) { e.preventDefault(); const b = dayEl.querySelector('[data-busy="save"],[data-mbusy="save"]'); if (b) b.click(); } });
      root.appendChild(dayEl);
    }
  }
  function closeDay() {
    if (!dayEl) return;
    dayEl.remove(); dayEl = null; S.daySel = null; dockApply();
    root.querySelectorAll('.cell.sel').forEach(c => c.classList.remove('sel'));
    if (S.multi.length) { S.multi = []; paintMulti(); }
  }
  function drawDay() {
    if (!dayEl) return;
    const sc = dayEl.querySelector('.sb'), y = sc ? sc.scrollTop : 0;
    dayEl.innerHTML = S.multi.length > 1 ? multiHTML() : dayHTML(S.daySel);
    dockApply();
    const sc2 = dayEl.querySelector('.sb'); if (sc2) sc2.scrollTop = y;
  }
  function askBox(title, text, yes, act, danger) {
    return `<div class="confirm" role="alertdialog"><b>${title}</b><p>${text}</p><div class="row"><button class="chipbtn" data-ask="no">Back</button><button class="chipbtn ${danger ? 'danger' : 'primary'}" data-ask="${act}">${yes}</button></div></div>`;
  }
  function dayHTML(iso) {
    const past = iso < today, rel = ord(iso) - ord(today);
    const mine = (myByDate()[iso] || []), pc = postCallMap()[iso], ask = S.dayAsk || {};
    const open = S.open.filter(o => o.date === iso);
    const reqs = S.requests.filter(r => r.date === iso && r.status !== 'denied' && r.status !== 'cancelled');
    const relTxt = rel === 0 ? 'Today' : rel === 1 ? 'Tomorrow' : rel === -1 ? 'Yesterday' : rel > 0 ? `In ${rel} days` : `${-rel} days ago`;
    let h = `<div class="sheet" role="dialog" aria-modal="false" aria-label="${fmtDay(iso)}">
      <header title="Drag to move · drop on the right or left edge to dock · double-click to dock right"><div style="min-width:0"><div class="meta">${relTxt}</div><h2>${DAYL[dow(iso)]}, ${MONTH[+iso.slice(5, 7) - 1]} ${+iso.slice(8)}</h2></div>
        <div class="dnav"><button class="x" data-dnav="-1" title="Previous day (←)" aria-label="Previous day">${I.back}</button><button class="x" data-dnav="1" title="Next day (→)" aria-label="Next day">${I.fwd}</button><button class="x" data-dx title="Close (Esc)" aria-label="Close">${I.close}</button></div></header><div class="sb">`;
    if (S.dayMsg) { h += `<div class="banner ${S.dayMsg.ok ? '' : 'warn'}" style="margin:12px 0 0">${esc(S.dayMsg.text)}</div>`; }
    // your shifts
    h += `<h3>Your shift${mine.length > 1 ? 's' : ''}</h3>`;
    if (!mine.length) h += `<div class="off">${pc ? `Post-call from ${UNITS[pc.unit].short}.` : 'You’re off.'}</div>`;
    const pasq = mine.find(s => s.unit === 'PRR') && mine.find(s => s.unit === 'MSU');
    for (const s of mine) {
      const u = UNITS[s.unit], to = s.pending ? (s.pendingEmp && s.pendingEmp !== S.emp ? nameOfEmp(s.pendingEmp) : '') : '';
      const canGive = !past && s.slot && !s.pending && !(pasq && s.unit === 'MSU');
      h += `<div class="dcard" style="--u:${u.color}"><span class="ubar"></span><div class="tx"><b>${u.full}${pasq && s.unit === 'PRR' ? ' <span class="off">+ MSU = 24 h</span>' : ''}</b><small>${hrsLabel(s)}</small>
        ${s.pending ? `<span class="dstat posted">${to ? `Offered to ${esc(to)}` : 'Offered — waiting for pickup'}</span>` : ''}</div>
        <div class="acts">${canGive ? `<button class="chipbtn primary" data-give="${s.slot}">Give away…</button><button class="chipbtn" data-swap="${s.slot}">Ask to swap…</button>` : ''}
        ${s.pending && !past ? `<button class="chipbtn" data-ask-open="withdraw:${s.slot}">Withdraw</button>` : ''}</div></div>`;
      if (ask.k === 'withdraw' && String(ask.v) === String(s.slot)) {
        const tgt = s.pendingEmp && s.pendingEmp !== S.emp ? s.pendingEmp : S.offerTargets[s.slot];
        h += tgt ? askBox(`Withdraw your ${u.short} offer?`, `${to ? esc(to) + ' won’t' : 'Nobody will'} be able to take it any more. The shift stays yours.`, 'Withdraw offer', 'withdraw', true)
          : `<div class="confirm"><b>Withdraw it in Lightning Bolt</b><p>This offer wasn’t sent from here, so Working-Bolt doesn’t know who it went to. Open the day in Lightning Bolt and cancel it there.</p><div class="row"><button class="chipbtn" data-ask="no">OK</button></div></div>`;
      }
    }
    // open shifts that day
    if (open.length && !past) {
      h += `<h3>Open shift${open.length > 1 ? 's' : ''} you could pick up</h3>`;
      for (const o of open) {
        const u = UNITS[o.unit], ok = !o.conflict && !o.busy;
        h += `<div class="dcard" style="--u:${u.color}"><span class="ubar"></span><div class="tx"><b>${u.full}${o.directed ? ' <span class="tag you">For you</span>' : ''}</b><small>${hrsLabel(o)} · from ${esc(o.offerer)}</small>
          <span class="dstat ${ok ? 'ok' : 'no'}">${ok ? 'Nothing clashes' : esc(o.busy ? busyText(o.busy) : o.flag)}</span></div>
          ${ok ? `<div class="acts"><button class="chipbtn primary" data-take="${o.id}">Take it</button></div>` : ''}</div>`;
      }
    }
    // busy + time off
    if (!past) {
      h += `<h3>This day</h3>`;
      const b = S.busyDays[iso];
      if (b != null && ask.k !== 'busyedit') {
        h += `<div class="dcard"><span class="ubar" style="background:var(--warn)"></span><div class="tx"><b>Marked busy${b ? ` — ${esc(b)}` : ''}</b><small>Open shifts on this day don’t count as “for you”.</small></div>
          <div class="acts"><button class="chipbtn" data-busy="edit">Edit</button><button class="chipbtn" data-busy="clear">Clear</button></div></div>`;
      } else {
        h += `<div class="busyrow"><input data-busynote maxlength="24" placeholder="Busy — what’s on? (optional)" value="${esc(S.busyDraft || '')}" aria-label="Busy note"><button class="chipbtn" data-busy="save">${b != null ? 'Save' : 'Mark busy'}</button></div>
          <div class="fine" style="margin-top:6px">A course, STARS, a family thing… Busy days keep the Pool’s “For me” honest. Kept in this browser only — like the app.</div>`;
      }
      for (const r of reqs) {
        const canCancel = r.status === 'pending' && r.id != null;
        h += `<div class="dcard" style="margin-top:10px"><span class="ubar" style="background:var(--muted)"></span><div class="tx"><b>${esc(r.kind)} · ${esc(r.status)}</b>${r.note ? `<small>${esc(r.note)}</small>` : ''}</div>
          <div class="acts">${canCancel ? `<button class="chipbtn" data-ask-open="unreq:${r.id}">Cancel request</button>` : ''}</div></div>`;
        if (ask.k === 'unreq' && String(ask.v) === String(r.id)) h += askBox(`Cancel this ${esc(r.kind)} request?`, 'It comes off the schedulers’ list. You can ask again later.', 'Cancel request', 'unreq', true);
      }
      const rosterOut = iso <= rosterThrough();
      if (!reqs.length && (mine.length || rosterOut)) {
        h += `<div class="fine" style="margin-top:10px">${mine.length ? 'You’re working this day — swap it or give it away instead of asking for it off.' : `The roster is out up to ${fmtDay(rosterThrough())}, so day-off requests only go in for later days. To get out of a day that’s already rostered, swap or give it away.`}</div>`;
      } else if (!reqs.length) {
        if (ask.k === 'req') {
          h += `<div class="confirm"><b>Ask for ${ask.v === 'Night Off' ? 'the night' : 'the day'} off on ${fmtDay(iso)}?</b><p>Sends a ${ask.v} request to Lightning Bolt. A scheduler approves it; you can cancel while it’s pending.</p>
            <input data-reqnote maxlength="120" placeholder="Note for the scheduler (optional)" value="${esc(S.reqDraft || '')}" aria-label="Note"><div class="row" style="margin-top:10px"><button class="chipbtn" data-ask="no">Back</button><button class="chipbtn primary" data-ask="req">Send request</button></div></div>`;
        } else h += `<div class="acts2"><button class="chipbtn" data-ask-open="req:Time Off">Ask for the day off</button><button class="chipbtn" data-ask-open="req:Night Off">Night off</button></div>`;
      }
    }
    // your calendars
    const ev = calByDate()[iso] || [];
    if (ev.length) h += `<h3>Your calendar</h3><div class="evlist">${ev.map(x => `<div class="ev" style="--c:${x.c.color}"><i></i><span>${esc(evLabel(x.ev))}</span></div>`).join('')}</div>`;
    // who's on
    const rows = S.group.filter(g => g.date === iso && g.unit && realDoc(g.doc)).sort((a, b) => WHO_ORDER.indexOf(a.unit) - WHO_ORDER.indexOf(b.unit));
    // On-call doctors (intensivists + cardiology) — a switch, shared with Who's On's "On call" (owner, 2026-11-17)
    h += `<h3 class="hrow">Who’s on<button class="sw" role="switch" data-daydocs aria-checked="${!!S.whoDocs}" title="Show the intensivists and cardiologists on call this day"><span class="trk"><i></i></span>On-call doctors</button></h3>`;
    if (S.whoDocs) h += dayDocs(iso);
    h += (rows.length ? `<div class="wl">${rows.map(g => `<div><i style="background:${UNITS[g.unit].color}"></i><span class="u">${UNITS[g.unit].short}${g.buddy ? ' buddy' : ''}</span><span>${esc(g.doc)}${(g.emp && g.emp === S.emp) || g.doc === S.me ? ' (you)' : ''}</span></div>`).join('')}</div>` : '<div class="off">Not loaded for this day (Who’s On covers two weeks back to four months ahead).</div>');
    return h + `</div></div>`;
  }
  // The day panel's on-call block: ICU intensivists by unit, who has the ICUs overnight, and cardiology.
  function dayDocs(d) {
    const have = (S.oncall || []).some(o => o.date === d);
    if (!have) {
      if (!ocLoaded.has(addDays(d, -7) + '|' + addDays(d, 7))) loadOncall(addDays(d, -7), addDays(d, 7), false).then(() => { if (dayEl && S.daySel === d) drawDay(); });
      return `<div class="off ddocs">${S.oncall == null ? 'Checking who’s on call…' : S.oncallFailed ? 'Couldn’t reach the on-call list just now.' : 'The doctors’ schedule isn’t out for this day yet.'}</div>`;
    }
    const row = (c, label, val) => `<div><i style="background:${c}"></i><span class="u">${label}</span><span>${val}</span></div>`;
    const pair = (a, b) => [a ? esc(a) : '', b && b !== a ? `${esc(b)} <small>from 17:00</small>` : ''].filter(Boolean).join(' · ') || '—';
    let r = ICU_DOCS.map(([u, ph]) => { const n = ocName(d, u, 'day'); return n ? row(UNITS[u].color, u === 'PHICU' ? 'Pasqua ICU' : UNITS[u].short, `${esc(n)} <small>☎ ${ph}</small>`) : ''; }).join('');
    const night = ocNight(d);
    if (night) r += row('var(--posted)', `${MOON} Tonight`, `${esc(night.name)}${night.second.length ? ` <small>2nd call ${night.second.map(esc).join(', ')}</small>` : ''}`);
    const cc = UNITS.CCU.color, inCCU = ocInCCU(d), cons = ocName(d, 'CCU', 'consults'), oc = [ocName(d, 'CCU', 'day'), ocName(d, 'CCU', 'oncall')], st = [ocName(d, 'CCU', 'stemi_day'), ocName(d, 'CCU', 'stemi_oncall')];
    if (inCCU) r += row(cc, `${HEART} In CCU`, esc(inCCU));
    if (cons) r += row(cc, 'Consults', `${esc(cons)} <small>8–5</small>`);
    if (oc[0] || oc[1]) r += row(cc, 'Cardio call', pair(oc[0], oc[1]));
    if (st[0] || st[1]) r += row(cc, 'STEMI', pair(st[0], st[1]));
    return `<div class="wl ddocs">${r}</div>`;
  }
  async function onDayClick(e) {
    if (e.target === dayEl) return closeDay();
    const el = e.target.closest('[data-dx],[data-dnav],[data-give],[data-swap],[data-take],[data-busy],[data-mbusy],[data-mclear],[data-ask-open],[data-ask],[data-daydocs]'); if (!el) return;
    const d = el.dataset, iso = S.daySel;
    if (d.daydocs != null) { S.whoDocs = !S.whoDocs; store.set('whoDocs', S.whoDocs); drawDay(); if (S.tab === 'who') rerender(true); return; }
    if (d.dx != null) return closeDay();
    if (d.dnav) { S.dayMsg = null; return openDay(addDays(iso, +d.dnav)); }
    if (d.take) return openTake(d.take);
    if (d.give) return openGive(d.give);
    if (d.swap) return openSwap(d.swap);
    if (d.busy === 'edit') { S.dayAsk = { k: 'busyedit' }; S.busyDraft = S.busyDays[iso] || ''; drawDay(); const i = dayEl.querySelector('[data-busynote]'); if (i) i.focus(); return; }
    if (d.busy === 'save') { S.busyDays[iso] = String(S.busyDraft || '').trim().slice(0, 24); return busyChanged(); }
    if (d.busy === 'clear') { delete S.busyDays[iso]; S.busyDraft = ''; return busyChanged(); }
    if (d.mclear != null) return closeDay();
    if (d.mbusy === 'save') { const n = String(S.busyDraft || '').trim().slice(0, 24); multiFuture().forEach(x => { S.busyDays[x] = n; }); S.busyDraft = ''; S.dayMsg = { ok: true, text: 'Marked busy — kept in this browser only.' }; return busyChanged(); }
    if (d.mbusy === 'clear') { multiFuture().forEach(x => { delete S.busyDays[x]; }); S.dayMsg = { ok: true, text: 'Busy cleared.' }; return busyChanged(); }
    if (d.askOpen) { const i = d.askOpen.indexOf(':'); S.dayAsk = { k: d.askOpen.slice(0, i), v: d.askOpen.slice(i + 1) }; S.dayMsg = null; drawDay(); const n = dayEl.querySelector('[data-reqnote]'); if (n) n.focus(); return; }
    if (d.ask === 'no') { S.dayAsk = null; return drawDay(); }
    const ask = S.dayAsk || {}; S.dayAsk = null;
    if (d.ask === 'withdraw') {
      const s = S.mine.find(x => String(x.slot) === String(ask.v)); if (!s) return drawDay();
      const tgt = s.pendingEmp && s.pendingEmp !== S.emp ? s.pendingEmp : S.offerTargets[s.slot];
      if (DEMO) { s.pending = false; s.pendingEmp = null; return afterWrite({ ok: true, text: 'Sample: offer withdrawn (nothing was sent).' }); }
      busyBtn(el); const r = await cancelOfferLB(s.slot, tgt);
      return afterWrite(r.ok ? { ok: true, text: 'Offer withdrawn — the shift is yours again.', reload: true } : { ok: false, text: r.message || 'Lightning Bolt didn’t take that.' });
    }
    if (d.ask === 'unreq') {
      if (DEMO) { S.requests = S.requests.filter(r => String(r.id) !== String(ask.v)); derive(); return afterWrite({ ok: true, text: 'Sample: request cancelled (nothing was sent).' }); }
      busyBtn(el); const r = await deleteRequests([ask.v]);
      return afterWrite(r.ok ? { ok: true, text: 'Request cancelled.', reload: true } : { ok: false, text: r.message || 'Lightning Bolt didn’t take that.' });
    }
    if (d.ask === 'mreq') {
      const days = multiPlan().can, note = String(S.reqDraft || '').trim(); if (!days.length) return drawDay();
      if (DEMO) { days.forEach((x, i) => S.requests.push({ id: -Date.now() - i, date: x, status: 'pending', kind: ask.v, note })); derive(); return afterWrite({ ok: true, text: `Sample: ${ask.v} requested for ${days.length} days (nothing was sent).` }); }
      busyBtn(el); const r = await submitRequest(ask.v, days, note);
      return afterWrite(r.ok ? { ok: true, text: `${ask.v} requested for ${days.length} day${days.length > 1 ? 's' : ''} — a scheduler will look at it.`, reload: true } : { ok: false, text: r.message || 'Lightning Bolt didn’t take that.' });
    }
    if (d.ask === 'munreq') {
      const ids = multiPlan().pend.map(r => r.id); if (!ids.length) return drawDay();
      if (DEMO) { const set = new Set(ids.map(String)); S.requests = S.requests.filter(r => !set.has(String(r.id))); derive(); return afterWrite({ ok: true, text: `Sample: ${ids.length} requests cancelled (nothing was sent).` }); }
      busyBtn(el); const r = await deleteRequests(ids);
      return afterWrite(r.ok ? { ok: true, text: `${ids.length} request${ids.length > 1 ? 's' : ''} cancelled.`, reload: true } : { ok: false, text: r.message || 'Lightning Bolt didn’t take that.' });
    }
    if (d.ask === 'req') {
      const note = String(S.reqDraft || '').trim();
      if (DEMO) { S.requests.push({ id: -Date.now(), date: iso, status: 'pending', kind: ask.v, note }); derive(); return afterWrite({ ok: true, text: `Sample: ${ask.v} requested (nothing was sent).` }); }
      busyBtn(el); const r = await submitRequest(ask.v, [iso], note);
      return afterWrite(r.ok ? { ok: true, text: `${ask.v} requested — a scheduler will look at it.`, reload: true } : { ok: false, text: r.message || 'Lightning Bolt didn’t take that.' });
    }
  }
  // ── several days at once (My Shifts): drag across days — a whole week row in one sweep — Shift-click for a run,
  // ⌘/Ctrl-click to add or drop a day. Lightning Bolt takes a request as a list, one entry per day, in ONE call
  // (that's how its own site and the app send a multi-day request), and cancels the same way — so a pick of
  // days goes out as a single request, after one confirm.
  let mAnchor = null, mDrag = null, mSwallow = false;
  const MODK = /Mac|iPhone|iPad/.test(navigator.platform || navigator.userAgent || '') ? '⌘' : 'Ctrl';
  function rangeDays(a, b) { if (a > b) [a, b] = [b, a]; const out = []; for (let d = a; d <= b && out.length < 400; d = addDays(d, 1)) out.push(d); return out; }
  function paintMulti() { const set = new Set(S.multi); root.querySelectorAll('.cell[data-day]').forEach(c => c.classList.toggle('msel', set.has(c.dataset.day))); }
  function setMulti(days) {
    const list = [...new Set(days)].sort();
    if (list.length === 1) { S.multi = []; paintMulti(); S.dayMsg = null; return openDay(list[0]); }
    if (!list.length) return closeDay();
    S.multi = list; paintMulti();
    S.daySel = null; S.dayAsk = null; S.dayMsg = null; S.busyDraft = ''; S.reqDraft = '';
    root.querySelectorAll('.cell.sel').forEach(c => c.classList.remove('sel'));
    ensureDayEl(); drawDay();
    const x = dayEl.querySelector('[data-dx]'); if (x) x.focus({ preventScroll: true });
  }
  function pickDay(iso, e) {
    const base = S.multi.length ? S.multi : (S.daySel ? [S.daySel] : []);
    if (e.shiftKey) { const r = rangeDays(mAnchor || S.daySel || iso, iso); return setMulti((e.metaKey || e.ctrlKey) ? base.concat(r) : r); }
    mAnchor = iso;
    return setMulti(base.includes(iso) ? base.filter(x => x !== iso) : base.concat(iso));
  }
  const multiFuture = () => S.multi.filter(d => d >= today);
  function multiPlan() {
    const by = myByDate(), rt = rosterThrough(), reqOn = {};
    for (const r of S.requests) if (r.status === 'pending' || r.status === 'approved') reqOn[r.date] = r;
    const can = [], skip = { past: 0, work: 0, roster: 0, asked: 0 };
    for (const d of S.multi) {
      if (d < today) skip.past++;
      else if (reqOn[d]) skip.asked++;
      else if ((by[d] || []).length) skip.work++;
      else if (d <= rt) skip.roster++;
      else can.push(d);
    }
    const pend = S.multi.map(d => reqOn[d]).filter(r => r && r.status === 'pending' && r.id != null && r.date >= today);
    return { by, rt, can, skip, pend };
  }
  // "Jul 14 – 20" for a run, "Jul 14, 16, 19 · Aug 2" otherwise
  function dayList(days) {
    if (!days.length) return '';
    const a = days[0], z = days[days.length - 1];
    if (days.length > 2 && ord(z) - ord(a) === days.length - 1) return `${fmtDay(a)} – ${fmtDay(z)}`;
    const g = []; let cur = null;
    for (const d of days) { const m = MON[+d.slice(5, 7) - 1]; if (!cur || cur.m !== m) g.push(cur = { m, ds: [] }); cur.ds.push(+d.slice(8)); }
    return g.map(x => `${x.m} ${x.ds.join(', ')}`).join(' · ');
  }
  function multiHTML() {
    const days = S.multi, ask = S.dayAsk || {}, P = multiPlan(), fut = multiFuture();
    const shifts = days.flatMap(d => P.by[d] || []), hrs = shifts.reduce((a, s) => a + hoursOf(s), 0);
    let h = `<div class="sheet" role="dialog" aria-modal="false" aria-label="${days.length} days picked">
      <header title="Drag to move · drop on the right or left edge to dock"><div style="min-width:0"><div class="meta">${days.length} days picked</div><h2>${esc(dayList(days))}</h2></div>
        <div class="dnav"><button class="x" data-dx title="Clear the pick (Esc)" aria-label="Close">${I.close}</button></div></header><div class="sb">`;
    if (S.dayMsg) h += `<div class="banner ${S.dayMsg.ok ? '' : 'warn'}" style="margin:12px 0 0">${esc(S.dayMsg.text)}</div>`;
    h += `<div class="mpick"><span><b>${days.length}</b> days</span><span><b>${shifts.length}</b> shift${shifts.length === 1 ? '' : 's'} of yours</span>${hrs ? `<span><b>${fmtH(hrs)}</b> h</span>` : ''}<button class="chipbtn ghost" data-mclear>Clear pick</button></div>`;
    // time off — one request for every day that can take one
    h += `<h3>Time off</h3>`;
    if (P.can.length) {
      if (ask.k === 'mreq') {
        h += `<div class="confirm"><b>Ask for ${ask.v === 'Night Off' ? 'nights' : 'days'} off on ${P.can.length} day${P.can.length > 1 ? 's' : ''}?</b><p>One ${ask.v} request to Lightning Bolt covering ${esc(dayList(P.can))}. A scheduler approves it; you can cancel any day while it’s pending.</p>
          <input data-reqnote maxlength="120" placeholder="Note for the scheduler (optional)" value="${esc(S.reqDraft || '')}" aria-label="Note"><div class="row" style="margin-top:10px"><button class="chipbtn" data-ask="no">Back</button><button class="chipbtn primary" data-ask="mreq">Send request</button></div></div>`;
      } else h += `<div class="acts2"><button class="chipbtn primary" data-ask-open="mreq:Time Off">Ask for ${P.can.length === days.length ? 'these' : 'the'} ${P.can.length} day${P.can.length > 1 ? 's' : ''} off</button><button class="chipbtn" data-ask-open="mreq:Night Off">Nights off</button></div>`;
    } else h += `<div class="off">None of these days can be asked off from here.</div>`;
    const sk = [P.skip.work && `${P.skip.work} you work (swap or give ${P.skip.work > 1 ? 'them' : 'it'} away)`, P.skip.roster && `${P.skip.roster} inside the published roster (out to ${fmtDay(P.rt)})`, P.skip.asked && `${P.skip.asked} already asked for`, P.skip.past && `${P.skip.past} in the past`].filter(Boolean);
    if (sk.length && (P.can.length || days.length > 1)) h += `<div class="fine" style="margin-top:8px">${P.can.length ? 'Left out' : 'Why'}: ${sk.join(' · ')}.</div>`;
    if (P.pend.length) {
      if (ask.k === 'munreq') h += askBox(`Cancel ${P.pend.length} pending request${P.pend.length > 1 ? 's' : ''}?`, `${esc(dayList(P.pend.map(r => r.date)))} come${P.pend.length > 1 ? '' : 's'} off the schedulers’ list in one go. You can ask again later.`, 'Cancel requests', 'munreq', true);
      else h += `<div class="acts2" style="margin-top:10px"><button class="chipbtn" data-ask-open="munreq:all">Cancel ${P.pend.length} pending request${P.pend.length > 1 ? 's' : ''}</button></div>`;
    }
    // busy — local only
    if (fut.length) {
      const nb = fut.filter(d => S.busyDays[d] != null).length;
      h += `<h3>Busy</h3><div class="busyrow"><input data-busynote maxlength="24" placeholder="Busy — what’s on? (optional)" value="${esc(S.busyDraft || '')}" aria-label="Busy note"><button class="chipbtn" data-mbusy="save">Mark ${fut.length} busy</button></div>
        ${nb ? `<div class="acts2" style="margin-top:8px"><button class="chipbtn" data-mbusy="clear">Clear busy on ${nb} day${nb > 1 ? 's' : ''}</button></div>` : ''}
        <div class="fine" style="margin-top:6px">Kept in this browser only — like the app.</div>`;
    }
    // your shifts in the pick — offers go one shift at a time
    const mineFut = shifts.filter(s => s.date >= today && s.slot);
    if (mineFut.length) {
      h += `<h3>Your shifts</h3>`;
      for (const s of mineFut) {
        const u = UNITS[s.unit], pasq = s.unit === 'MSU' && (P.by[s.date] || []).some(x => x.unit === 'PRR');
        h += `<div class="dcard" style="--u:${u.color}"><span class="ubar"></span><div class="tx"><b>${u.short} · ${fmtDay(s.date)}</b><small>${hrsLabel(s)}</small>${s.pending ? `<span class="dstat posted">Offered — waiting for pickup</span>` : ''}</div>
          <div class="acts">${!s.pending && !pasq ? `<button class="chipbtn primary" data-give="${s.slot}">Give away…</button><button class="chipbtn" data-swap="${s.slot}">Swap…</button>` : ''}</div></div>`;
      }
    }
    h += `<div class="fine" style="margin-top:14px">Drag across days to pick a run — a whole week in one sweep. Shift-click extends, ${MODK}-click adds or drops a day. Esc clears.</div>`;
    return h + `</div></div>`;
  }
  // the last day the published roster covers: the latest real assignment we read (everyone's, or mine)
  function rosterThrough() {
    let t = '';
    for (const g of S.group) if (!g.buddy && g.unit && realDoc(g.doc) && g.date > t) t = g.date;
    for (const s of S.mine) if (s.date > t) t = s.date;
    return t || addDays(today, -1);
  }
  function busyBtn(el) { el.disabled = true; el.textContent = 'Sending…'; }
  function busyChanged() {
    store.set('busyDays', S.busyDays); S.dayAsk = null; derive(); drawDay(); rerender(true);
  }
  function afterWrite(m) {
    S.dayMsg = m; drawDay(); rerender(true);
    if (m.reload) refresh().then(() => drawDay());
  }

  // ── give a shift away: whole or part, to one person, several, or everyone who can work it (the app's wizard) ──
  let giveEl = null;
  function openGive(slot) {
    const s = S.mine.find(x => String(x.slot) === String(slot)); if (!s) return;
    const twin = s.unit === 'PRR' ? S.mine.find(x => x.date === s.date && x.unit === 'MSU' && x.slot) : null;
    const tl = timeline(s);
    S.G = { s, twin, pasq: twin ? 'both' : null, whole: true, from: tl.length > 2 ? tl[Math.floor(tl.length / 2)].iso : '', until: tl.length ? tl[tl.length - 1].iso : '', everyone: false, sel: new Set(), q: '', note: '', phase: 'form', msg: '' };
    if (giveEl) giveEl.remove();
    giveEl = document.createElement('div'); giveEl.className = 'sheetbg';
    giveEl.addEventListener('click', onGiveClick);
    giveEl.addEventListener('input', e => {
      const t = e.target.dataset;
      if (t.gq != null) { S.G.q = e.target.value; drawGive(true); }
      if (t.gnote != null) S.G.note = e.target.value;
    });
    giveEl.addEventListener('change', e => {
      const t = e.target.dataset;
      if (t.gfrom != null) { S.G.from = e.target.value; if (S.G.until <= S.G.from) { const tl2 = timeline(S.G.s); S.G.until = tl2[tl2.length - 1].iso; } drawGive(); }
      if (t.guntil != null) { S.G.until = e.target.value; drawGive(); }
      if (t.gpick != null) { e.target.checked ? S.G.sel.add(t.gpick) : S.G.sel.delete(t.gpick); S.G.everyone = false; drawGive(); }
    });
    root.appendChild(giveEl); drawGive();
    if (!DIR) loadDirectory().then(() => { if (giveEl && S.G && S.G.phase === 'form') drawGive(); });
  }
  function closeGive() { if (giveEl) { giveEl.remove(); giveEl = null; S.G = null; } }
  function timeline(s) {
    const st = toMin(s.start), en = toMin(s.end), span = s.ov ? 1440 - st + en : en - st, out = [];
    for (let t = 0; t <= span && span > 0; t += 30) {
      const abs = st + t, off = Math.floor(abs / 1440), clk = abs % 1440, date = off ? addDays(s.date, off) : s.date;
      const hm = `${String(Math.floor(clk / 60)).padStart(2, '0')}:${String(clk % 60).padStart(2, '0')}`;
      out.push({ iso: `${date}T${hm}:00`, label: hm + (off ? ` (+${off})` : '') });
    }
    return out;
  }
  function giveCalc() {
    const G = S.G, s = G.s, many = G.sel.size >= 2 && !G.everyone;
    const whole = G.pasq ? true : (G.whole || many);
    const chosen = G.everyone || G.sel.size > 0, isGroup = G.everyone || G.sel.size >= 2;
    const partOk = whole || (G.from && G.until && G.from < G.until);
    const one = !G.everyone && G.sel.size === 1 ? [...G.sel][0] : null, oneName = one ? nameOfEmp(one) || 'them' : '';
    const tl = timeline(s), lab = iso => (tl.find(x => x.iso === iso) || {}).label || iso.slice(11, 16);
    const unitShort = G.pasq === 'both' ? 'Pasqua 24 h' : G.pasq === 'msu' ? 'MSU' : UNITS[s.unit].short;
    const hours = G.pasq === 'both' ? `${s.start}–${G.twin.end}` : G.pasq === 'msu' ? `${G.twin.start}–${G.twin.end}` : whole ? `${s.start}–${s.end}` : `${lab(G.from)}–${lab(G.until)}`;
    const phrase = G.everyone ? 'the pool' : isGroup ? `${G.sel.size} colleagues` : oneName;
    const sendLabel = G.everyone ? 'Post to the pool' : isGroup ? `Offer to ${G.sel.size} colleagues` : one ? `Give away to ${oneName}` : 'Give away';
    const what = whole ? `your ${unitShort} shift` : `the ${hours} part of your ${unitShort} shift`;
    return { whole, chosen, isGroup, partOk, one, oneName, unitShort, hours, phrase, sendLabel, what, sendable: chosen && partOk };
  }
  const giveWhen = c => `${fmtDay(S.G.s.date)}`;
  const giveAskOne = (name, c) => `Hi ${firstName(name)}, are you able to take my ${c.unitShort}${c.whole ? '' : ` (${c.hours})`} on ${giveWhen(c)}? I’m offering it to you — let me know. Thanks!`;
  const giveAskGroup = c => `Hi — are any of you able to take my ${c.unitShort}${c.whole ? '' : ` (${c.hours})`} on ${giveWhen(c)}? Let me know if you can, thanks!`;
  function drawGive(keepFocus) {
    if (!giveEl) return;
    const G = S.G, s = G.s, u = UNITS[s.unit], c = giveCalc();
    const f = keepFocus && root.activeElement && root.activeElement.dataset && root.activeElement.dataset.gq != null;
    const ls = giveEl.querySelector('.rlist'), ly = ls ? ls.scrollTop : 0, sb = giveEl.querySelector('.sb'), sy = sb ? sb.scrollTop : 0;
    const shiftForElig = G.pasq === 'msu' ? G.twin : G.pasq === 'both' ? Object.assign({}, s, { ov: true }) : s;
    const elig = eligibleFor(shiftForElig);
    const q = G.q.trim().toLowerCase(), list = elig.filter(x => !q || x.name.toLowerCase().includes(q));
    const niceDate = `${DAYL[dow(s.date)]}, ${MONTH[+s.date.slice(5, 7) - 1]} ${+s.date.slice(8)}`;
    let body = '';
    if (G.phase === 'form' || G.phase === 'confirm') {
      if (G.pasq) {
        body += `<h3>Which part?</h3><div class="seg" role="group">${[['both', 'Both (24 h)'], ['rapid', 'Rapid 08–17'], ['msu', 'MSU 17–08']].map(([k, l]) => `<button data-gpasq="${k}" aria-pressed="${G.pasq === k}">${l}</button>`).join('')}</div>
          <div class="fine">${G.pasq === 'both' ? 'Gives away the whole 24 h (Rapid + MSU).' : `Gives away just the ${G.pasq === 'rapid' ? 'Rapid' : 'MSU'} half; you keep the other.`}</div>`;
      } else {
        const tl = timeline(s);
        body += `<h3>How much?</h3><div class="seg" role="group"><button data-gwhole="1" aria-pressed="${G.whole}">Whole shift</button><button data-gwhole="0" aria-pressed="${!G.whole}">Just a part</button></div>`;
        if (!G.whole) body += `<div class="partrow"><label>From <select data-gfrom>${tl.slice(0, -1).map(x => `<option value="${x.iso}" ${x.iso === G.from ? 'selected' : ''}>${x.label}</option>`).join('')}</select></label>
            <label>until <select data-guntil>${tl.filter(x => x.iso > G.from).map(x => `<option value="${x.iso}" ${x.iso === G.until ? 'selected' : ''}>${x.label}</option>`).join('')}</select></label></div>
          <div class="fine">You keep the rest. Heads-up: Lightning Bolt only lets a scheduler merge pieces back — so split when you mean it.${G.sel.size >= 2 && !G.everyone ? ' <b>Several people picked → the whole shift goes.</b>' : ''}</div>`;
      }
      body += `<h3>Give it to</h3>
        <button class="pickall ${G.everyone ? 'on' : ''}" data-gall aria-pressed="${G.everyone}"><span class="ck"></span><span><b>Everyone who can work it</b><small>${elig.length} colleague${elig.length === 1 ? '' : 's'} free that day — whoever’s eligible can grab it</small></span></button>
        <label class="search" style="margin:10px 0 6px">${I.search}<input type="search" data-gq placeholder="Find a colleague" value="${esc(G.q)}" aria-label="Find a colleague"></label>
        <div class="rlist">${list.length ? list.map(x => `<div class="rrow"><label><input type="checkbox" data-gpick="${x.emp}" ${G.sel.has(x.emp) ? 'checked' : ''}><span>${esc(x.name)}</span></label>${textBtn(cellOf(x.emp), giveAskOne(x.name, c), '', 'ic')}</div>`).join('') : `<div class="off" style="padding:10px">${elig.length ? 'No match.' : 'Nobody is free that day by the roster (busy, post-call, pre-call' + (s.unit === 'SICU' ? ', or no SICU yet' : '') + ').'}</div>`}</div>
        ${(() => { const pickedC = [...G.sel].map(cellOf).filter(Boolean), allC = elig.map(x => cellOf(x.emp)).filter(Boolean);
          return pickedC.length || allC.length > 1 ? `<div class="acts2 txtrow">${pickedC.length ? textBtn(pickedC, pickedC.length === 1 ? giveAskOne(nameOfEmp([...G.sel].find(e => cellOf(e))), c) : giveAskGroup(c), pickedC.length === 1 ? `Text ${esc(firstName(nameOfEmp([...G.sel].find(e => cellOf(e)))))}` : `Text the ${pickedC.length} picked`) : ''}${allC.length > 1 ? textBtn(allC, giveAskGroup(c), `Text everyone free (${allC.length})`) : ''}<span class="fine" style="margin:0">Opens Messages — a quick heads-up before (or instead of) offering it in LB.</span></div>` : ''; })()}
        <div class="fine">Only people who are free: not working that day, not post-call or pre-call${s.ov ? ', not on the next day' : ''}${s.unit === 'SICU' ? ', and who have worked SICU' : ''}.</div>
        <h3>Note (optional)</h3><textarea data-gnote rows="2" maxlength="300" placeholder="Add a note">${esc(G.note)}</textarea>
        ${G.everyone ? '<div class="fine">Posted to the pool. Lightning Bolt can’t attach a note to a pool post — Working-Bolt keeps yours and shows it in the Pool.</div>' : ''}`;
    }
    let foot = '';
    if (G.phase === 'form') foot = `<span class="sp"></span><button class="chipbtn" data-gx>Cancel</button><button class="chipbtn primary" data-gsend ${c.sendable ? '' : 'disabled'}>${!c.chosen ? 'Choose who gets it' : !c.partOk ? 'Set the times' : c.sendLabel}</button>`;
    if (G.phase === 'confirm') {
      const msg = (c.whole ? '' : 'This splits your shift in Lightning Bolt (you keep the rest). ') + (c.isGroup ? 'Anyone eligible you offered it to can pick it up. You can withdraw it from My Shifts.' : 'They get it as a pending offer. You can withdraw it until they accept.');
      body += `<div class="confirm" style="margin-top:16px" role="alertdialog"><b>${G.everyone ? `Post ${c.what} on ${fmtDay(s.date)} to the pool?` : `Offer ${c.what} on ${fmtDay(s.date)} to ${esc(c.phrase)}?`}</b><p>${msg}${DEMO ? ' <b>Sample data — nothing is sent.</b>' : ''}</p></div>`;
      foot = `<span class="sp"></span><button class="chipbtn" data-gback>Back</button><button class="chipbtn ${c.whole ? 'primary' : 'danger'}" data-gyes>${esc(c.sendLabel)}</button>`;
    }
    if (G.phase === 'sending') body = `<div class="demo"><div class="bar"><i></i></div><div>${c.isGroup ? 'Offering…' : `Offering to ${esc(c.oneName)}…`}</div></div>`;
    if (G.phase === 'done') {
      body = `<div class="demo"><div class="okc">✓</div><b style="color:var(--ink);font-size:17px">${G.everyone ? 'Posted to the pool' : c.isGroup ? `Offered to ${G.sel.size} colleagues` : `Offered to ${esc(c.oneName)}`}</b>
        <div>${c.unitShort} · ${fmtDay(s.date)}. ${c.isGroup ? 'Whoever’s eligible can pick it up.' : 'Pending until they accept — you can withdraw it from the day panel.'}${DEMO ? '<br><b>Sample data — nothing was sent.</b>' : ''}</div>
        ${G.note ? `<div class="quote">“${esc(G.note)}”</div>` : ''}${c.one && cellOf(c.one) ? `<div style="margin-top:12px">${textBtn(cellOf(c.one), giveAskOne(c.oneName, c), `Text ${esc(firstName(c.oneName))}`)}</div>` : ''}</div>`;
      foot = `<span class="sp"></span><button class="chipbtn primary" data-gx>Done</button>`;
    }
    if (G.phase === 'failed') {
      body = `<div class="demo"><div class="okc no">!</div><b style="color:var(--ink);font-size:17px">Couldn’t give it away</b><div>${esc(G.msg || 'Nothing was changed. Check your connection and try again.')}</div>${G.partial ? '' : '<div class="fine">Nothing was changed on your schedule.</div>'}</div>`;
      foot = `<span class="sp"></span><button class="chipbtn primary" ${G.partial ? 'data-gx' : 'data-gback'}>${G.partial ? 'Done' : 'Back'}</button>`;
    }
    giveEl.innerHTML = `<div class="sheet give" role="dialog" aria-modal="true" aria-label="Give away shift" style="--u:${u.color}">
      <header><div style="min-width:0"><div class="ln1"><span class="pill">${c.unitShort}</span></div><h2>Give away shift</h2><div class="meta">${niceDate} · ${c.hours}</div></div>
        <button class="x" data-gx aria-label="Close">${I.close}</button></header>
      <div class="sb">${body}</div><footer>${foot}</footer></div>`;
    const ls2 = giveEl.querySelector('.rlist'); if (ls2) ls2.scrollTop = ly;
    const sb2 = giveEl.querySelector('.sb'); if (sb2) sb2.scrollTop = sy;
    if (f) { const i = giveEl.querySelector('[data-gq]'); if (i) { i.focus(); i.setSelectionRange(i.value.length, i.value.length); } }
  }
  function onGiveClick(e) {
    if (e.target === giveEl && S.G.phase !== 'sending') return closeGive();
    const el = e.target.closest('[data-gx],[data-gpasq],[data-gwhole],[data-gall],[data-gsend],[data-gback],[data-gyes]'); if (!el) return;
    const d = el.dataset, G = S.G;
    if (d.gx != null) { const done = G.phase === 'done'; closeGive(); if (done) drawDay(); return; }
    if (d.gpasq) { G.pasq = d.gpasq; return drawGive(); }
    if (d.gwhole) { G.whole = d.gwhole === '1'; return drawGive(); }
    if (d.gall != null) { G.everyone = !G.everyone; if (G.everyone) G.sel.clear(); return drawGive(); }
    if (d.gsend != null) { if (giveCalc().sendable) { G.phase = 'confirm'; drawGive(); } return; }
    if (d.gback != null) { G.phase = 'form'; return drawGive(); }
    if (d.gyes != null) return sendGive();
  }
  async function sendGive() {
    const G = S.G, c = giveCalc();
    const targets = G.pasq === 'both' ? [G.s, G.twin] : G.pasq === 'msu' ? [G.twin] : [G.s];
    const shiftForElig = G.pasq === 'msu' ? G.twin : G.s;
    const emps = G.everyone ? eligibleFor(shiftForElig).map(x => x.emp) : [...G.sel];
    G.phase = 'sending'; drawGive();
    if (DEMO) {
      await new Promise(r => setTimeout(r, 500));
      if (!c.whole) {                               // sample split: keep the rest, offer the part
        const s = G.s, from = G.from.slice(11, 16), until = G.until.slice(11, 16);
        const part = Object.assign({}, s, { slot: s.slot + '-p', start: from, end: until, ov: G.until.slice(0, 10) > s.date && G.from.slice(0, 10) === s.date, pending: true, pendingEmp: c.one });
        const rest = [];
        if (G.from.slice(11) !== s.start + ':00' || G.from.slice(0, 10) !== s.date) rest.push(Object.assign({}, s, { slot: s.slot + '-a', end: from, ov: G.from.slice(0, 10) > s.date }));
        if (G.until.slice(11, 16) !== s.end) rest.push(Object.assign({}, s, { slot: s.slot + '-b', start: until, ov: s.ov && G.until.slice(0, 10) === s.date }));
        S.mine = S.mine.filter(x => x !== s).concat(rest, [part]).sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : toMin(a.start) - toMin(b.start));
      } else for (const t of targets) { t.pending = true; t.pendingEmp = c.one; }
      derive(); G.phase = 'done'; drawGive(); drawDay(); rerender(true); return;
    }
    let out = { ok: false, message: 'No recipient chosen.' };
    const offer = async t => {
      const r = c.isGroup ? await offerToGroup(t, emps) : await offerToPerson(t, c.one, G.note);
      if (r.ok) { rememberTarget(t.slot, c.isGroup ? emps[0] : c.one); putOfferNote(t.slot, G.note, null); }
      return r;
    };
    if (!c.whole) {
      // LB has no one-step partial give-away: split the shift (all parts stay mine), re-read, then offer the new part
      const s = G.s, end = `${s.ov ? addDays(s.date, 1) : s.date}T${s.end}:00`, start = `${s.date}T${s.start}:00`;
      const parts = [];
      if (G.from > start) parts.push({ start_time: start, end_time: G.from, emp_ids: [+S.emp] });
      parts.push({ start_time: G.from, end_time: G.until, emp_ids: [+S.emp] });
      if (G.until < end) parts.push({ start_time: G.until, end_time: end, emp_ids: [+S.emp] });
      const sp = await lbPost('/schedule/split', { slot_id: +s.slot, splits: parts, note: G.note || '' });
      if (!sp.ok) out = { ok: false, message: sp.message || 'Couldn’t split the shift.' };
      else {
        await new Promise(r => setTimeout(r, 1500)); await refresh();
        const gd = G.from.slice(0, 10), gs = G.from.slice(11, 16), ge = G.until.slice(11, 16);
        const part = S.mine.find(x => (x.date === gd || x.date === s.date) && x.start === gs && x.end === ge && x.slot);
        out = part ? await offer(part) : { ok: false, partial: true, message: 'The shift was split, but the new part didn’t show up yet — give that part away from its day in My Shifts.' };
      }
    } else {
      out = await offer(targets[0]);
      if (out.ok && targets[1]) {
        const o2 = await offer(targets[1]);
        if (!o2.ok) out = { ok: false, partial: true, message: `Only the Rapid half was offered — the MSU half failed (${o2.message || 'no reason given'}). Withdraw the Rapid half from its day, then try again.` };
      }
    }
    if (out.ok) { G.phase = 'done'; refresh().then(() => drawDay()); }
    else { G.phase = 'failed'; G.msg = out.message; G.partial = !!out.partial; if (out.partial) refresh().then(() => drawDay()); }
    drawGive();
  }
  // ── ask to swap (the app's Swap Finder): every colleague's future shift where BOTH sides work ──
  //   they can take mine: not post/pre-call, not on my next day if mine runs overnight, SICU only if they've done SICU
  //   I can take theirs: I'm free that day, not post/pre-call, not working the next day if theirs runs overnight
  // Same-day = trade units with someone already on that day. A swap goes as a plain offer to them, tagged
  // "swap:<emp>:<their slots>" in the shared notes; when they accept in Working-Bolt their shift comes back to you.
  function mergePasq(rows) {
    const by = {}, out = [];
    for (const g of rows) (by[g.doc + '|' + g.date] = by[g.doc + '|' + g.date] || []).push(g);
    for (const k in by) {
      const g = by[k], p = g.find(x => x.unit === 'PRR'), m = g.find(x => x.unit === 'MSU');
      if (p && m) { out.push(Object.assign({}, p, { end: m.end, ov: true, slot2: m.slot, pasq: true })); out.push(...g.filter(x => x !== p && x !== m)); }
      else out.push(...g);
    }
    return out;
  }
  function swapOptions(mine) {
    const by = groupByDay(), d = mine.date, sicu = sicuDocs(), iDoSICU = sicu.has(S.me);
    const docs = (iso, f) => new Set((by[iso] || []).filter(f || (() => true)).map(g => g.doc));
    const post = docs(addDays(d, -1), g => g.ov), pre = docs(addDays(d, 1), g => g.ov), next = mine.ov ? docs(addDays(d, 1)) : new Set();
    const theyCan = n => !post.has(n) && !pre.has(n) && !next.has(n) && (mine.unit !== 'SICU' || sicu.has(n));
    const myBusy = new Set(S.mine.map(s => s.date)), myNights = new Set(S.mine.filter(s => s.ov).map(s => s.date));
    const iCan = a => { const x = a.date; return !myBusy.has(x) && S.busyDays[x] == null && !myNights.has(addDays(x, -1)) && !myNights.has(addDays(x, 1)) && !(a.ov && myBusy.has(addDays(x, 1))); };
    const emps = new Map(colleagues().map(c => [c.name, c.emp]));
    const real = g => g.slot && !g.buddy && g.unit && realDoc(g.doc) && g.doc !== S.me && emps.has(g.doc);
    const out = [];
    // same day: someone else on another unit that day — we trade units
    if (!myNights.has(addDays(d, -1)) && !myNights.has(addDays(d, 1)))
      for (const r of mergePasq((by[d] || []).filter(real))) {
        if (r.unit === mine.unit || (r.unit === 'SICU' && !iDoSICU) || (r.ov && myBusy.has(addDays(d, 1))) || !theyCan(r.doc)) continue;
        out.push({ emp: emps.get(r.doc), name: r.doc, r, same: true });
      }
    // other days: someone free on my day takes mine, I take one of theirs
    const onMyDay = docs(d), now = reginaHM();
    const fut = mergePasq(S.group.filter(g => real(g) && g.date !== d && (g.date > today || (g.date === today && g.start > now)))).filter(iCan);
    for (const r of fut) {
      if (onMyDay.has(r.doc) || !theyCan(r.doc) || (r.unit === 'SICU' && !iDoSICU)) continue;
      out.push({ emp: emps.get(r.doc), name: r.doc, r, same: false });
    }
    return out.sort((a, b) => a.r.date < b.r.date ? -1 : a.r.date > b.r.date ? 1 : surname(a.name).localeCompare(surname(b.name)));
  }
  const uShort = r => r.pasq ? 'Pasqua 24 h' : UNITS[r.unit].short;
  let swapEl = null;
  // The shift being traded. An MSU half of a Pasqua 24 h goes as the whole 24 h, like the app.
  function swapBase(slot) {
    let s = S.mine.find(x => String(x.slot) === String(slot)); if (!s) return null;
    if (s.unit === 'MSU') { const p = S.mine.find(x => x.date === s.date && x.unit === 'PRR' && x.slot && !x.pending); if (p) s = p; }
    const twin = s.unit === 'PRR' ? S.mine.find(x => x.date === s.date && x.unit === 'MSU' && x.slot && !x.pending) : null;
    const mine = twin ? Object.assign({}, s, { end: twin.end, ov: true, slot2: twin.slot, pasq: true }) : s;
    return { s, twin, mine, opts: swapOptions(mine) };
  }
  // My shifts that can still be swapped: not started, not already offered.
  function swappableMine() {
    const now = reginaHM();
    return S.mine.filter(x => x.slot && !x.pending && UNITS[x.unit] && (x.date > today || (x.date === today && x.start > now))
      && !(x.unit === 'MSU' && S.mine.some(y => y.date === x.date && y.unit === 'PRR' && y.slot && !y.pending)));
  }
  function openSwap(slot) {
    const b = swapBase(slot); if (!b) return;
    S.W = Object.assign(b, { q: '', units: new Set(), limit: 80, pick: null, kind: null, note: '', phase: 'list', msg: '', change: false });
    if (swapEl) swapEl.remove();
    swapEl = document.createElement('div'); swapEl.className = 'sheetbg';
    swapEl.addEventListener('click', onSwapClick);
    swapEl.addEventListener('input', e => {
      if (e.target.dataset.swq != null) { S.W.q = e.target.value; S.W.limit = 80; drawSwap(true); }
      if (e.target.dataset.swnote != null) { S.W.note = e.target.value; const b = swapEl.querySelector('[data-swsend]'); if (b) b.disabled = !S.W.note.trim(); }
    });
    root.appendChild(swapEl); drawSwap();
    if (!DIR) loadDirectory().then(() => { if (swapEl && S.W && S.W.phase === 'list') drawSwap(); });
  }
  function closeSwap() { if (swapEl) { swapEl.remove(); swapEl = null; S.W = null; } }
  const swapText = (m, o) => `Hi ${firstName(o.name)}, any chance we could swap — I take your ${uShort(o.r)} on ${fmtDay(o.r.date)}, you take my ${uShort(m)} on ${fmtDay(m.date)}? Thanks!`;
  const swapFeeler = m => `Hi — I’m looking to move my ${uShort(m)} on ${fmtDay(m.date)}. Any of you keen to swap or take it? Let me know, thanks!`;
  function swapNote(W) {
    const m = uShort(W.mine), o = W.pick;
    return W.kind === 'pick' ? `Hi ${firstName(o.name)}, could you pick up my ${m} on ${fmtDay(W.mine.date)}? Thanks!`
      : `Swap? I'll take your ${uShort(o.r)} on ${fmtDay(o.r.date)} if you take my ${m} on ${fmtDay(W.mine.date)}.`;
  }
  function drawSwap(keepFocus) {
    if (!swapEl) return;
    const W = S.W, m = W.mine, u = UNITS[m.unit], o = W.pick, f = keepFocus && root.activeElement && root.activeElement.dataset && root.activeElement.dataset.swq != null;
    const sb = swapEl.querySelector('.sb'), sy = sb ? sb.scrollTop : 0;
    let body = '', foot = '', title = 'Ask to swap';
    if (W.phase === 'list') {
      const q = W.q.trim().toLowerCase();
      const unitsHere = [...new Set(W.opts.map(x => x.r.unit))].sort((a, b) => WHO_ORDER.indexOf(a) - WHO_ORDER.indexOf(b));
      const list = W.opts.filter(x => (!q || x.name.toLowerCase().includes(q)) && (!W.units.size || W.units.has(x.r.unit)));
      const people = new Set(W.opts.map(x => x.emp)).size;
      body += `<p class="swlead">${W.opts.length ? `<b>${W.opts.length}</b> shift${W.opts.length === 1 ? '' : 's'} from <b>${people}</b> colleague${people === 1 ? '' : 's'} where you could both swap — they’re free for yours, you’re free for theirs, nobody ends up post-call.` : 'Nobody on the roster can swap for this one right now — everyone free that day either works around it or you can’t take theirs.'}</p>`;
      if (W.opts.length && !W.change) body += `<div class="swtools"><label class="search">${I.search}<input type="search" data-swq placeholder="Find a colleague" value="${esc(W.q)}" aria-label="Find a colleague"></label>
        <div class="swu">${unitsHere.map(k => `<button class="chipbtn ${W.units.has(k) ? 'primary' : ''}" data-swu="${k}" aria-pressed="${W.units.has(k)}" style="--u:${UNITS[k].color}"><i class="dot"></i>${UNITS[k].short}</button>`).join('')}</div></div>`;
      // Like the app: mini month calendars — your shifts as coloured blocks, small squares = units you could swap
      // into that day. Click a day → who's working it, with Ask to swap / Ask to pick up.
      const avail = {};
      for (const x of list) (avail[x.r.date] = avail[x.r.date] || []).push(x);
      const adays = Object.keys(avail).sort();
      if (W.day && !avail[W.day]) W.day = null;
      if (!W.day && adays.length) W.day = adays[0];
      // Every month the roster is out for, all at once (owner, 2026-11-17).
      const ym0 = ymOf(today);
      let lastYm = ymOf(rosterThrough()); if (adays.length && ymOf(adays[adays.length - 1]) > lastYm) lastYm = ymOf(adays[adays.length - 1]);
      let nMo = 1; while (addMonths(ym0, nMo - 1) < lastYm && nMo < 13) nMo++;
      const by = myByDate(), pc = postCallMap();
      // Change mode: your own upcoming shifts become clickable, each with how many swaps it has.
      const mineOK = W.change ? new Map(swappableMine().map(x => [x.date, x])) : null;
      if (W.change && !W.counts) { W.counts = {}; for (const x of mineOK.values()) { const b = x.slot === W.s.slot ? W : swapBase(x.slot); W.counts[x.date] = b ? b.opts.length : 0; } }
      const mini = ym => {
        const pad = (dow(ym + '-01') - S.weekStart + 7) % 7;
        let g = `<div class="smo"><div class="smh">${monthTitle(ym)}</div><div class="smg">`;
        for (let k = 0; k < 7; k++) g += `<div class="h">${DAY[(k + S.weekStart) % 7].slice(0, 2)}</div>`;
        for (let k = 0; k < pad; k++) g += '<div></div>';
        for (let d = 1; d <= daysIn(ym); d++) {
          const iso = `${ym}-${String(d).padStart(2, '0')}`, past = iso < today, av = !past && !W.change && avail[iso], mk = W.change && mineOK.get(iso);
          const units = av ? [...new Set(av.map(x => x.r.unit))].sort((a, b) => WHO_ORDER.indexOf(a) - WHO_ORDER.indexOf(b)) : [];
          let inner = `<span class="n">${d}</span>`;
          for (const x of by[iso] || []) if (!x.pending || true) inner += `<span class="mb" style="--u:${UNITS[x.unit].color}">${UNITS[x.unit].short.replace('Pasqua-', 'P-').replace('RGH-', '')}</span>`;
          if (pc[iso] && !(by[iso] || []).length) inner += `<span class="mb pc" style="--u:${UNITS[pc[iso].unit].color}">${UNITS[pc[iso].unit].short.replace('Pasqua-', 'P-').replace('RGH-', '')}</span>`;
          if (mk) inner += `<span class="cnt${W.counts[iso] ? '' : ' none'}" title="${W.counts[iso] || 'No'} possible swap${W.counts[iso] === 1 ? '' : 's'}">${W.counts[iso] ? `⇄ ${W.counts[iso]}` : 'none'}</span>`;
          if (units.length) inner += `<span class="sq">${units.slice(0, 5).map(u => `<i style="--u:${UNITS[u].color}" title="${UNITS[u].full}"></i>`).join('')}</span>`;
          const cls = ['sc', past ? 'past' : '', av || mk ? 'av' : '', mk ? 'mk' : '', W.change && !mk && !past ? 'dim' : '', !W.change && iso === W.day ? 'sel' : '', iso === today ? 'today' : '', iso === m.date ? 'trade' : ''].join(' ');
          g += mk ? `<button class="${cls}" data-swmine="${mk.slot}" aria-pressed="${iso === m.date}" aria-label="Swap your ${UNITS[mk.unit].short} on ${fmtDay(iso)} instead">${inner}</button>` : av ? `<button class="${cls}" data-swday="${iso}" aria-pressed="${iso === W.day}" aria-label="${fmtDay(iso)}: ${av.length} you could take">${inner}</button>` : `<div class="${cls}">${inner}</div>`;
        }
        return g + '</div></div>';
      };
      const months = Array.from({ length: nMo }, (_, k) => mini(addMonths(ym0, k))).join('');
      const key = W.change ? `<div class="swkey"><span><i class="kb"></i>Your shifts — click one to swap that one instead</span></div>`
        : `<div class="swkey"><span><i class="kb"></i>Your shifts</span><span><i class="kq"></i>Units you could swap into — click the day for who</span></div>`;
      let side = '';
      if (W.change) {
        side = `<div class="swdayh"><b>Which shift?</b></div><p class="swhint">Click one of your shifts on the calendar. Each one shows how many swaps it has right now.</p>
          <div class="swcur" style="--u:${u.color}"><small>Now swapping</small><span class="pill">${uShort(m)}</span><b>${fmtDay(m.date)}</b><small>${m.start}–${m.end}${m.ov ? ' (+1)' : ''} · ${W.opts.length} swap${W.opts.length === 1 ? '' : 's'}</small></div>
          <div class="acts2"><button class="chipbtn" data-swchg="0">Keep this one</button></div>`;
      } else if (!W.opts.length) {
        side = `<p class="swhint">Nobody can swap this one. <button class="linkbtn" data-swchg="1">Pick another of your shifts</button> or <button class="linkbtn" data-swgive>give it away</button>.</p>`;
      } else {
        const dl = W.day ? avail[W.day] : null;
        if (dl) {
          const same = W.day === m.date;
          const tc = [...new Set(dl.map(x => cellOf(x.emp)).filter(Boolean))];
          side += `<div class="swdayh"><b>${same ? 'Same day — trade units' : `${DAYL[dow(W.day)]}, ${MONTH[+W.day.slice(5, 7) - 1]} ${+W.day.slice(8)}`}</b><span>${dl.length} ${same ? 'you could trade with' : 'you could take'}</span>${tc.length > 1 ? `<span class="sp"></span>${textBtn(tc, swapFeeler(m), `Text all ${tc.length}`)}` : ''}</div>`;
          side += `<div class="swlist">${dl.map(x => { const i = W.opts.indexOf(x), ru = UNITS[x.r.unit];
            return `<div class="swo" style="--u:${ru.color}"><span class="pill">${uShort(x.r)}</span><div class="tx"><b>${esc(x.name)}</b><small>${x.r.start}–${x.r.end}${x.r.ov ? ' (+1)' : ''}</small></div>
            <div class="acts">${textBtn(cellOf(x.emp), swapText(m, x), 'Text', 'ic2')}<button class="chipbtn primary" data-swpick="${i}:swap">Ask to swap</button>${x.same ? '' : `<button class="chipbtn" data-swpick="${i}:pick" title="One-way: they take yours, you don’t take one of theirs">Ask to pick up</button>`}</div></div>`; }).join('')}</div>`;
        } else side += `<div class="off" style="padding:14px 2px">No match — clear the search or unit filter.</div>`;
      }
      body += `<div class="swbody${W.change ? ' changing' : ''}"><div class="swcal"><div class="smos">${months}</div>${key}</div><aside class="swside2">${side}</aside></div>`;
      body += `<div class="fine">Shows every month the roster is out for. “Ask to pick up” is one-way: they take yours, you don’t take one of theirs. Rather give it to anyone? <button class="linkbtn" data-swgive>Give away instead</button></div>`;
      foot = `<span class="sp"></span><button class="chipbtn" data-swx>Close</button>`;
    } else {
      const pick = W.kind === 'pick', ou = UNITS[o.r.unit];
      title = pick ? 'Pickup request' : 'Swap request';
      if (W.phase === 'compose' || W.phase === 'confirm') {
        body += `<h3>${pick ? `Ask ${esc(o.name)} to pick up` : `Ask ${esc(o.name)} to swap`}</h3>
          <div class="swpair"><div class="swside" style="--u:${u.color}"><small>${pick ? 'They take' : 'They take yours'}</small><span class="pill">${uShort(m)}</span><b>${fmtDay(m.date)}</b><small>${m.start}–${m.end}${m.ov ? ' (+1)' : ''}</small></div>
          ${pick ? '' : `<div class="swarrow">⇄</div><div class="swside" style="--u:${ou.color}"><small>You take theirs</small><span class="pill">${uShort(o.r)}</span><b>${fmtDay(o.r.date)}</b><small>${o.r.start}–${o.r.end}${o.r.ov ? ' (+1)' : ''}</small></div>`}</div>
          <h3>Note</h3><textarea data-swnote rows="3" maxlength="300">${esc(W.note)}</textarea>
          <div class="acts2" style="margin-top:8px">${textBtn(cellOf(o.emp), W.kind === 'pick' ? swapNote(W) : swapText(m, o), `Text ${esc(firstName(o.name))}`)}<button class="chipbtn" data-swcopy>${I.copy || ''}Copy as a text message</button></div>
          <div class="fine">${pick ? 'They get your shift offered with this note.' : 'They get your shift offered with this note. If they accept in Working-Bolt, their shift comes back to you as a “For you” offer in the Pool — taking it finishes the swap.'}</div>`;
        if (W.phase === 'compose') foot = `<button class="chipbtn" data-swback>Back</button><span class="sp"></span><button class="chipbtn primary" data-swsend ${W.note.trim() ? '' : 'disabled'}>${pick ? 'Send pickup request' : 'Send swap request'}</button>`;
        else {
          body += `<div class="confirm" style="margin-top:16px" role="alertdialog"><b>${pick ? `Ask ${esc(o.name)} to pick up your ${uShort(m)} on ${fmtDay(m.date)}?` : `Send this swap to ${esc(o.name)}?`}</b>
            <p>${pick ? 'It goes to them as a pending offer. You can withdraw it from the day until they accept.' : `Your ${uShort(m)} on ${fmtDay(m.date)} for their ${uShort(o.r)} on ${fmtDay(o.r.date)}. Yours goes to them as a pending offer; you can withdraw it until they accept.`}${DEMO ? ' <b>Sample data — nothing is sent.</b>' : ''}</p></div>`;
          foot = `<button class="chipbtn" data-swback2>Not yet</button><span class="sp"></span><button class="chipbtn primary" data-swyes>${pick ? 'Send pickup request' : 'Send swap request'}</button>`;
        }
      }
      if (W.phase === 'sending') body = `<div class="demo"><div class="bar"><i></i></div><div>Sending to ${esc(o.name)}…</div></div>`;
      if (W.phase === 'done') {
        body = `<div class="demo"><div class="okc">✓</div><b style="color:var(--ink);font-size:17px">${pick ? `Sent to ${esc(o.name)}` : `Swap sent to ${esc(o.name)}`}</b>
          <div>${pick ? 'They’ll see your shift offered with the note.' : `When ${esc(firstName(o.name))} accepts, their ${uShort(o.r)} on ${fmtDay(o.r.date)} comes back to you — take it from the Pool.`}${DEMO ? '<br><b>Sample data — nothing was sent.</b>' : ''}</div>
          <div class="quote">“${esc(W.note)}”</div>${cellOf(o.emp) ? `<div style="margin-top:12px">${textBtn(cellOf(o.emp), pick ? swapNote(W) : swapText(m, o), `Text ${esc(firstName(o.name))} a heads-up`)}</div>` : ''}</div>`;
        foot = `<span class="sp"></span><button class="chipbtn primary" data-swx>Done</button>`;
      }
      if (W.phase === 'failed') {
        body = `<div class="demo"><div class="okc no">!</div><b style="color:var(--ink);font-size:17px">Couldn’t send it</b><div>${esc(W.msg || 'Nothing was changed. Check your connection and try again.')}</div></div>`;
        foot = `<span class="sp"></span><button class="chipbtn primary" ${W.partial ? 'data-swx' : 'data-swback2'}>${W.partial ? 'Done' : 'Back'}</button>`;
      }
    }
    swapEl.innerHTML = `<div class="sheet give swap" role="dialog" aria-modal="true" aria-label="${title}" style="--u:${u.color}">
      <header><div style="min-width:0"><div class="ln1"><span class="pill">${uShort(m)}</span></div><h2>${title}</h2>${W.phase === 'list' ? `<button class="meta swchg" data-swchg="${W.change ? 0 : 1}" aria-pressed="${!!W.change}" title="Swap a different one of your shifts">Your shift · ${DAYL[dow(m.date)]}, ${MONTH[+m.date.slice(5, 7) - 1]} ${+m.date.slice(8)} · ${m.start}–${m.end}${m.ov ? ' (+1)' : ''}<span class="chg">${W.change ? 'Pick on the calendar' : 'Change'}${I.chev}</span></button>` : `<div class="meta">Your shift · ${DAYL[dow(m.date)]}, ${MONTH[+m.date.slice(5, 7) - 1]} ${+m.date.slice(8)} · ${m.start}–${m.end}${m.ov ? ' (+1)' : ''}</div>`}</div>
        <button class="x" data-swx aria-label="Close">${I.close}</button></header>
      <div class="sb">${body}</div><footer>${foot}</footer></div>`;
    const sb2 = swapEl.querySelector('.sb'); if (sb2 && W.phase === 'list') sb2.scrollTop = sy;
    if (f) { const i = swapEl.querySelector('[data-swq]'); if (i) { i.focus(); i.setSelectionRange(i.value.length, i.value.length); } }
  }
  function onSwapClick(e) {
    const W = S.W;
    if (e.target === swapEl && W.phase !== 'sending') return closeSwap();
    const el = e.target.closest('[data-swday],[data-swmine],[data-swchg],[data-swx],[data-swu],[data-swpick],[data-swmore],[data-swgive],[data-swback],[data-swback2],[data-swsend],[data-swyes],[data-swcopy]'); if (!el) return;
    const d = el.dataset;
    if (d.swx != null) { const done = W.phase === 'done'; closeSwap(); if (done) drawDay(); return; }
    if (d.swu) { W.units.has(d.swu) ? W.units.delete(d.swu) : W.units.add(d.swu); return drawSwap(); }
    if (d.swday) { W.day = d.swday; drawSwap(); if (window.innerWidth < 1000) { const a = swapEl.querySelector('.swside2'); if (a) a.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); } return; }
    if (d.swchg != null) { W.change = d.swchg === '1'; if (W.change) W.counts = null; return drawSwap(); }
    if (d.swmine) {
      if (String(d.swmine) !== String(W.s.slot)) { const b = swapBase(d.swmine); if (b) { Object.assign(W, b); W.day = null; } }
      W.change = false; return drawSwap();
    }
    if (d.swgive != null) { const slot = W.s.slot; closeSwap(); return openGive(slot); }
    if (d.swpick) { const [i, k] = d.swpick.split(':'); W.pick = W.opts[+i]; W.kind = k; W.note = swapNote(W); W.phase = 'compose'; drawSwap(); const t = swapEl.querySelector('[data-swnote]'); if (t) t.focus(); return; }
    if (d.swback != null) { W.phase = 'list'; W.pick = null; return drawSwap(); }
    if (d.swback2 != null) { W.phase = 'compose'; return drawSwap(); }
    if (d.swsend != null) { if (W.note.trim()) { W.phase = 'confirm'; drawSwap(); } return; }
    if (d.swcopy != null) {
      const txt = W.kind === 'pick' ? swapNote(W) : swapText(W.mine, W.pick);
      try { navigator.clipboard.writeText(txt).then(() => flash('Copied — paste it into a text'), () => flash('Couldn’t copy')); } catch (err) { flash('Couldn’t copy'); }
      return;
    }
    if (d.swyes != null) return sendSwap();
  }
  async function sendSwap() {
    const W = S.W, o = W.pick, note = W.note.trim();
    const tag = W.kind === 'pick' ? null : `swap:${o.emp}:${[o.r.slot, o.r.slot2].filter(Boolean).join(',')}`;
    const targets = W.twin ? [W.s, W.twin] : [W.s];
    W.phase = 'sending'; drawSwap();
    if (DEMO) {
      await new Promise(r => setTimeout(r, 500));
      for (const t of targets) { t.pending = true; t.pendingEmp = o.emp; }
      derive(); W.phase = 'done'; drawSwap(); drawDay(); rerender(true); return;
    }
    let out = { ok: false };
    for (let i = 0; i < targets.length; i++) {
      const t = targets[i], r = await offerToPerson(t, o.emp, note);
      if (!r.ok) { out = i ? { ok: false, partial: true, message: `Only the Rapid half was sent — the MSU half failed (${r.message || 'no reason given'}). Withdraw the Rapid half from its day, then try again.` } : r; break; }
      rememberTarget(t.slot, o.emp); putOfferNote(t.slot, note, tag); out = { ok: true };
    }
    if (out.ok) { W.phase = 'done'; refresh().then(() => drawDay()); }
    else { W.phase = 'failed'; W.msg = out.message; W.partial = !!out.partial; if (out.partial) refresh().then(() => drawDay()); }
    drawSwap();
  }

  function downloadICS() {
    const lines = ['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//Working-Bolt//web//EN', 'CALSCALE:GREGORIAN', 'X-WR-CALNAME:My shifts (Working-Bolt)'];
    const pad = n => String(n).padStart(2, '0');
    const loc = (iso, hm) => `${stamp(iso)}T${hm.replace(':', '')}00`;
    const nowStamp = new Date().toISOString().replace(/[-:]/g, '').slice(0, 15) + 'Z';
    for (const s of S.mine.filter(x => x.date >= addDays(today, -31))) {
      const iv = interval(s.date, s.start, s.end, s.ov), endISO = fromOrd(Math.floor(iv.e / 1440)), endHM = `${pad(Math.floor((iv.e % 1440) / 60))}:${pad(iv.e % 60)}`;
      lines.push('BEGIN:VEVENT', `UID:wb-${s.slot || s.date + s.unit}@working-bolt`, `DTSTAMP:${nowStamp}`,
        `DTSTART;TZID=America/Regina:${loc(s.date, s.start)}`, `DTEND;TZID=America/Regina:${loc(endISO, endHM)}`,
        `SUMMARY:${UNITS[s.unit].short} — ${UNITS[s.unit].full}`, 'END:VEVENT');
    }
    lines.push('END:VCALENDAR');
    const blob = new Blob([lines.join('\r\n')], { type: 'text/calendar' });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = 'my-shifts.ics';
    document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }

  // ── Who's On ──
  function groupByDay() {
    const m = {};
    for (const g of S.group) (m[g.date] = m[g.date] || []).push(g);
    return m;
  }
  // Who's On: one page tall, every unit a row, days running sideways — scroll left/right through the roster.
  const whoRange = () => [addDays(today, -14), addDays(today, 120)];
  function viewWho() {
    const [a, b] = whoRange(), days = [];
    for (let d = a; d <= b; d = addDays(d, 1)) days.push(d);
    const by = groupByDay(), q = S.highlight.trim().toLowerCase();
    const tools = `<button class="chipbtn ${S.whoDocs ? 'primary' : ''}" data-act="whodocs" title="Show the intensivists and cardiologists on call, with their numbers (D)" aria-pressed="${S.whoDocs}">${STETH}On call</button>
      <label class="search">${I.search}<input type="search" placeholder="Find a colleague" value="${esc(S.highlight)}" data-input="hl" aria-label="Find a colleague — highlights their shifts" title="Highlights their shifts (or click a name)"></label>
      <button class="chipbtn ghost" data-act="whoflip" title="Which way scrolling moves the days — click to flip" aria-pressed="${S.whoFlip}">Scroll ${S.whoFlip ? '⇠ drag' : '⇢ wheel'}</button>
      <button class="chipbtn" data-act="wprev" title="Back a week (←)">${I.back}</button>
      <button class="chipbtn" data-act="wtoday" title="Today (T)">Today</button>
      <button class="chipbtn" data-act="wnext" title="Forward a week (→)">${I.fwd}</button>
      <input type="date" value="${S.whoDate || today}" min="${a}" max="${b}" data-input="wdate" aria-label="Go to date">`;
    const sub = `<span data-whosub>${MONTH[+today.slice(5, 7) - 1]} ${today.slice(0, 4)}</span>`;
    if (!S.group.length) return header("Who's On", sub, tools) + `<div class="view">${banners()}<div class="empty"><b>The group roster didn’t load</b>Refresh to try again.</div></div>`;
    if (S.whoDocs) loadOncall(a, b, false);
    return header("Who's On", sub, tools) + `<div class="view whov">${banners()}${whoDays(days, by, q)}</div>`;
  }

  // Unit phones (as in the app's DocTag): desk, CCA call room, on-call intensivist.
  const UNIT_PHONES = {
    SICU: { desk: '3990', room: '3971', doc: '4268' }, MICU: { desk: '4291', room: '4823', doc: '4265' },
    CCU: { desk: '4266', room: '4241' }, PHICU: { desk: '8555', room: '8556', doc: '4249' },
    PRR: { room: '2417' }, MSU: { room: '2417' },
  };
  const PHONE = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M6.6 10.8a15.1 15.1 0 0 0 6.6 6.6l2.2-2.2c.3-.3.7-.4 1-.2 1.1.4 2.3.6 3.6.6.6 0 1 .4 1 1V20c0 .6-.4 1-1 1A17 17 0 0 1 3 4c0-.6.4-1 1-1h3.5c.6 0 1 .4 1 1 0 1.3.2 2.5.6 3.6.1.3 0 .7-.2 1z"/></svg>';
  const BED = '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M3 6a1 1 0 0 1 2 0v6h6V8h7a3 3 0 0 1 3 3v8a1 1 0 0 1-2 0v-2H5v2a1 1 0 0 1-2 0z"/><circle cx="8" cy="9.5" r="2"/></svg>';
  const STETH = '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M5 3v5a5 5 0 0 0 10 0V3"/><path d="M10 13v2a5 5 0 0 0 10 0v-2"/><circle cx="20" cy="11" r="2"/></svg>';
  function whoDays(days, by, q) {
    const docs = S.whoDocs, ICU = { SICU: 1, MICU: 1, PHICU: 1 };
    const cls = d => `${d === today ? 'is-today' : ''} ${d < today ? 'past' : ''}`;
    const label = u => {
      const ph = UNIT_PHONES[u] || {};
      const bits = (ph.desk ? `<span title="Unit desk">${PHONE}${ph.desk}</span>` : '') +
        (ph.room ? `<span title="CCA call room${u === 'PRR' || u === 'MSU' ? ' (Pasqua wards)' : ''}">${BED}${ph.room}</span>` : '') +
        (ph.doc && docs ? `<span title="On-call intensivist">${STETH}${ph.doc}</span>` : '');
      return `<div class="wlab" style="--u:${UNITS[u].color}"><b>${UNITS[u].short}</b>${bits ? `<div class="ph">${bits}</div>` : ''}</div>`;
    };
    const cell = (d, u) => {
      const info = UNITS[u];
      const rows = (by[d] || []).filter(g => g.unit === u).sort((a, b) => (a.buddy - b.buddy) || toMin(a.start) - toMin(b.start));
      let h = rows.map(g => {
        const me = g.emp && S.emp ? g.emp === S.emp : g.doc === S.me;
        const hit = q && g.doc.toLowerCase().includes(q);
        const ms = me && !g.buddy ? (S.mine.find(x => x.date === d && x.unit === u && x.slot && !x.pending && x.start === g.start) || S.mine.find(x => x.date === d && x.unit === u && x.slot && !x.pending)) : null;
        const hold = ms && notStarted(ms) ? ` data-wmine="${esc(ms.slot)}"` : '';
        return `<button${hold} class="wr ${me ? 'me' : ''} ${g.buddy ? 'bud' : ''} ${hit ? 'hl' : ''} ${q && !hit ? 'dim' : ''}" style="--u:${info.color}" data-doc="${esc(g.doc)}" title="${esc(info.short)} · ${esc(g.doc)} · ${g.start}–${g.end}${g.buddy ? ' · buddy' : ''}${g.note ? ' · ' + esc(g.note) : ''}${hold ? ' · Hold or right-click to swap or give away' : ''}"><b>${esc(g.doc)}</b><small>${g.buddy ? 'buddy' : `${g.start}–${g.end}`}</small></button>`;
      }).join('');
      if (docs) {
        const n = ICU[u] ? ocName(d, u, 'day') : u === 'CCU' ? ocInCCU(d) : null;
        if (n) { const night = ICU[u] && (ocNight(d) || {}).name === n; h += `<div class="wr-doc" title="${u === 'CCU' ? 'Cardiologist in CCU' : 'Intensivist' + (night ? ' · on call tonight' : '')}">${u === 'CCU' ? HEART : night ? MOON : STETH}${esc(n)}</div>`; }
      }
      return `<div class="wc ${cls(d)}">${h}</div>`;
    };
    const R = WHO_ORDER.length + (docs ? 1 : 0);
    let h = `<div class="wmon" aria-live="polite"><span></span><b data-wmon>${MONTH[+today.slice(5, 7) - 1]}</b><span data-wyear>${today.slice(0, 4)}</span></div><div class="wweek"><div class="wgrid" style="--n:${days.length};--r:${R}"><div class="wcorner"></div>`;
    for (const d of days) h += `<div class="wh ${cls(d)} ${+d.slice(8) === 1 ? 'som' : ''}" data-day="${d}"><small>${DAY[dow(d)]}</small><b>${+d.slice(8)}${+d.slice(8) === 1 || d === days[0] ? `<i>${MON[+d.slice(5, 7) - 1]}</i>` : ''}</b></div>`;
    for (const u of WHO_ORDER) { h += label(u); for (const d of days) h += cell(d, u); }
    if (docs) {
      h += `<div class="wlab oc" style="--u:var(--posted)"><b>On call tonight</b><div class="ph"><span>${MOON}ICU</span><span>${HEART}Cardiology</span></div></div>`;
      for (const d of days) {
        const night = ocNight(d), on = ocName(d, 'CCU', 'oncall') || ocName(d, 'CCU', 'day'), st = ocName(d, 'CCU', 'stemi_oncall') || ocName(d, 'CCU', 'stemi_day');
        h += `<div class="wc oc ${cls(d)}">${night ? `<span><span style="color:var(--posted);display:flex">${MOON}</span>${esc(night.name)}${night.second.length ? `<em title="Second on call">· 2nd ${night.second.map(esc).join(', ')}</em>` : ''}</span>` : ''}${on ? `<span><span style="color:${UNITS.CCU.color};display:flex">${HEART}</span>${esc(on)}${st ? `<em title="STEMI on call">· STEMI ${esc(st)}</em>` : ''}</span>` : ''}${!night && !on ? '<span class="off">—</span>' : ''}</div>`;
      }
    }
    h += '</div></div>';
    const loose = days.filter(d => d >= addDays(today, -1)).flatMap(d => (by[d] || []).filter(g => g.buddy && !g.unit).map(x => `${fmtDay(d)}: ${esc(x.doc)}${x.note ? ` (${esc(x.note)})` : ''}`));
    if (loose.length) h += `<div class="wbud">Buddy shifts: ${loose.join(' · ')}</div>`;
    return h;
  }
  // Keep the sideways position across re-renders; jump to a day on Today / date pick / tab open.
  function whoPlace() {
    const w = root.querySelector('.wweek'); if (!w) return;
    if (S.whoGo) { whoScrollTo(S.whoGo, false); S.whoGo = null; } else if (S.whoLeft != null) w.scrollLeft = S.whoLeft;
    let raf = 0;
    w.addEventListener('scroll', () => { S.whoLeft = w.scrollLeft; if (!raf) raf = requestAnimationFrame(() => { raf = 0; whoSub(); }); }, { passive: true });
    sideWheel(w);
    whoSub();
  }
  // Who's On scrolls sideways only: the mouse wheel / a vertical swipe moves through the days (the "Scroll" button flips the
  // direction so it feels like dragging the page), and you can grab the board with the mouse and drag it left/right.
  // flip: Who's On follows its "Scroll" button; the crew board scrolls the plain way (down / swipe left = later days),
  // and lets a trackpad's own sideways swipe through untouched.
  function sideWheel(w, crew) {
    w.addEventListener('wheel', e => {
      if (e.ctrlKey || dzOn) return;
      const vert = Math.abs(e.deltaY) > Math.abs(e.deltaX);
      // Trackpad (fine-grained deltas, Chrome/Safari report wheelDelta = −3 × delta; or any sideways component):
      // sideways swipes scroll natively; up/down swipes do nothing (Who's On scrolls sideways only). A mouse wheel
      // still turns up/down into sideways.
      const pad = e.deltaMode === 0 && ((e.wheelDeltaY && e.wheelDeltaY === -3 * e.deltaY) || (e.wheelDeltaX && e.wheelDeltaX === -3 * e.deltaX) || (e.deltaX !== 0 && e.deltaY !== 0) || (!Number.isInteger(e.deltaY)));
      if (!vert) { clearTimeout(w._snap); w._snap = setTimeout(() => whoSnap(w), 220); return; }
      if (pad && !crew && !e.altKey) { e.preventDefault(); return; }
      if (vert && e.shiftKey === false && w.scrollHeight > w.clientHeight + 2 && w.matches(':hover') && e.altKey) return;   // ⌥-wheel still scrolls down on a tiny window
      e.preventDefault();
      const unit = e.deltaMode === 1 ? 32 : e.deltaMode === 2 ? w.clientWidth : 1;
      let d = (vert ? e.deltaY : e.deltaX) * unit;
      if (S.whoFlip && !crew) d = -d;
      w.scrollLeft += d;
      clearTimeout(w._snap); w._snap = setTimeout(() => whoSnap(w), 160);
    }, { passive: false });
    let g = null;
    w.addEventListener('pointerdown', e => {
      if (e.pointerType !== 'mouse' || e.button !== 0 || dzOn || e.target.closest('input,select,textarea,a')) return;
      g = { x: e.clientX, y: e.clientY, l: w.scrollLeft, t: w.scrollTop, moved: false, id: e.pointerId };
    });
    w.addEventListener('pointermove', e => {
      if (!g) return;
      const dx = e.clientX - g.x, dy = e.clientY - g.y;
      if (!g.moved) { if (Math.hypot(dx, dy) < 6) return; g.moved = true; w.classList.add('grabbing'); try { w.setPointerCapture(g.id); } catch (_) {} }
      w.scrollLeft = g.l - dx; w.scrollTop = g.t - dy;
    });
    const end = () => { if (!g) return; const moved = g.moved; g = null; w.classList.remove('grabbing'); if (moved) { whoSnap(w); const stop = ev => { ev.stopPropagation(); ev.preventDefault(); }; w.addEventListener('click', stop, { capture: true, once: true }); setTimeout(() => w.removeEventListener('click', stop, true), 50); } };
    w.addEventListener('pointerup', end); w.addEventListener('pointercancel', end);
  }
  function whoSnap(w) {
    const c = w.querySelector('.wh, thead th[data-day]'); if (!c) return;
    const col = c.getBoundingClientRect().width, max = w.scrollWidth - w.clientWidth;
    const left = Math.min(max, Math.round(w.scrollLeft / col) * col);
    if (Math.abs(left - w.scrollLeft) > 1) w.scrollTo({ left, behavior: 'smooth' });
  }
  function whoScrollTo(iso, smooth) {
    const w = root.querySelector('.wweek'); if (!w) return;
    const [a, b] = whoRange(); iso = iso < a ? a : iso > b ? b : iso;
    const el = w.querySelector(`.wh[data-day="${iso}"]`), lab = w.querySelector('.wcorner');
    if (!el) return;
    const left = Math.max(0, el.offsetLeft - (lab ? lab.offsetWidth : 160));
    if (smooth) w.scrollTo({ left, behavior: 'smooth' }); else { w.scrollLeft = left; S.whoLeft = left; }
  }
  function whoSub() {
    const w = root.querySelector('.wweek'), sub = root.querySelector('[data-whosub]'); if (!w || !sub) return;
    const lw = (w.querySelector('.wcorner') || {}).offsetWidth || 160;
    const vis = [...w.querySelectorAll('.wh')].filter(e => e.offsetLeft + e.offsetWidth / 2 >= w.scrollLeft + lw && e.offsetLeft + e.offsetWidth / 2 <= w.scrollLeft + w.clientWidth);
    if (!vis.length) return;
    const f = vis[0].dataset.day, l = vis[vis.length - 1].dataset.day;
    const m = iso => MONTH[+iso.slice(5, 7) - 1], y = iso => iso.slice(0, 4);
    // the month bar over the board: the month that fills most of the view in the centre (both when it's split evenly), the year on the right
    const cnt = {}; for (const e of vis) { const k = e.dataset.day.slice(0, 7); cnt[k] = (cnt[k] || 0) + 1; }
    const ks = Object.keys(cnt).sort(), top = ks.reduce((a, k) => cnt[k] > cnt[a] ? k : a, ks[0]);
    const mb = root.querySelector('[data-wmon]'), yb = root.querySelector('[data-wyear]');
    if (mb) mb.innerHTML = ks.length > 1 && Math.min(...ks.map(k => cnt[k])) * 2 >= vis.length - 1 ? ks.map(k => k === top ? MONTH[+k.slice(5) - 1] : `<i>${MONTH[+k.slice(5) - 1]}</i>`).join('<em>→</em>') : MONTH[+top.slice(5) - 1];
    if (yb) yb.textContent = y(f) === y(l) ? y(f) : `${y(f)} – ${y(l)}`;
    sub.textContent = f.slice(0, 7) === l.slice(0, 7) ? `${m(f)} ${y(f)}` : y(f) === y(l) ? `${m(f)} – ${m(l)} ${y(l)}` : `${m(f)} ${y(f)} – ${m(l)} ${y(l)}`;
  }

  // ── Crew ──
  function activeDocs() {
    const cutoff = today.slice(0, 4) + '-01-01', set = new Set();
    for (const g of S.group) if (g.date >= addDays(today, -14) && g.unit && !g.buddy) {
      const u = g.doc.toUpperCase(); if (g.doc && g.doc !== '—' && u !== 'EMPTY' && !u.includes('NO MRI')) set.add(g.doc);
    }
    return [...set].sort((a, b) => surname(a).localeCompare(surname(b)));
  }
  function viewCrew() {
    const [ca, cb] = crewRange(), days = [];
    for (let d = ca; d <= cb; d = addDays(d, 1)) days.push(d);
    const by = groupByDay(), docs = activeDocs();
    const chosen = S.crew.filter(Boolean);
    const q = S.crewQuery.trim().toLowerCase();
    const list = docs.filter(d => d !== S.me && (!q || d.toLowerCase().includes(q)));
    const tools = `<button class="chipbtn" data-act="cprev" title="Back a week (←) · or scroll / drag sideways">${I.back}</button>
      <button class="chipbtn" data-act="ctoday" title="This week (T)">Today</button>
      <button class="chipbtn" data-act="cnext" title="Next week (→)">${I.fwd}</button>`;
    let body = banners() + crewBar() + `<div class="crewpick">
        ${chosen.map(c => `<span class="who-chip">${esc(c)}<button data-uncrew="${esc(c)}" aria-label="Remove ${esc(c)}">${I.x}</button></span>`).join('')}
        <div class="cpick"><label class="search" style="min-width:260px">${I.search}<input type="search" placeholder="Add colleagues…" value="${esc(S.crewQuery)}" data-input="crew" aria-label="Add colleagues" aria-expanded="${!!S.crewOpen}" autocomplete="off">${I.chev}</label>
        ${S.crewOpen ? `<div class="cdrop" role="listbox" aria-multiselectable="true" aria-label="Colleagues">
          <div class="cdh"><span>${chosen.length ? `${chosen.length} picked` : 'Tick everyone you want side by side'}</span>${chosen.length ? '<button data-crewact="clear">Clear</button>' : ''}<button class="done" data-crewact="done">Done</button></div>
          <div class="cdl">${list.length ? list.map(d => { const on = chosen.includes(d); return `<button class="opt" role="option" aria-selected="${on}" data-crewtog="${esc(d)}"><span class="cb">${on ? '✓' : ''}</span>${esc(d)}</button>`; }).join('') : `<div class="none">Nobody called “${esc(S.crewQuery)}” on the roster lately.</div>`}</div>
        </div>` : ''}</div></div>`;
    if (!chosen.length) {
      body += `<div class="empty"><b>Pick a few colleagues</b>See when they work side by side with you — and the days you’re all off, for planning time away together.</div>`;
      return header('Crew', 'Plan around each other', tools) + `<div class="view">${body}</div>`;
    }
    const people = [{ name: S.me || 'You', me: true }].concat(chosen.map(c => ({ name: c })));
    const isMe = g => g.emp && S.emp ? g.emp === S.emp : g.doc === S.me;
    const workOn = (p, d) => (by[d] || []).filter(g => g.unit && !g.buddy && (p.me ? isMe(g) : g.doc === p.name));
    // post-call days count as not free
    const pcOf = (p, d) => (by[addDays(d, -1)] || []).filter(g => g.unit && !g.buddy && g.ov && (p.me ? isMe(g) : g.doc === p.name));
    const freeDay = d => people.every(p => !workOn(p, d).length && !pcOf(p, d).length);
    const ini = n => String(n).replace(/\(.*?\)/g, '').trim().split(/\s+/).filter(Boolean).map(w => w[0]).slice(0, 2).join('').toUpperCase() || '?';
    const short = u => UNITS[u].short.replace('Pasqua-', 'P-').replace('RGH-', '');
    const cls = d => [d === today ? 'today' : '', dow(d) === 0 || dow(d) === 6 ? 'we' : '', d !== days[0] && dow(d) === S.weekStart ? 'ws' : '', freeDay(d) ? 'free' : ''].join(' ');
    let t = `<div class="crewtab" style="--nd:${days.length}"><table><colgroup><col class="cn">${days.map(() => '<col>').join('')}</colgroup><thead><tr><th class="nm"></th>`;
    for (const d of days) t += `<th class="${cls(d)}" data-day="${d}"><span class="dw">${DAY[dow(d)].slice(0, 2)}</span><span class="dn">${+d.slice(8)}</span><span class="mo">${+d.slice(8) === 1 || d === days[0] ? MON[+d.slice(5, 7) - 1] : ''}</span></th>`;
    t += '</tr></thead><tbody>';
    for (const p of people) {
      t += `<tr class="${p.me ? 'me' : ''}"><td class="nm"><div class="nmw"><span class="av">${esc(ini(p.name))}</span><span class="pn">${esc(p.name)}</span>${p.me ? '<span class="you">you</span>' : ''}</div></td>`;
      for (const d of days) {
        const w = workOn(p, d), pc = !w.length && pcOf(p, d)[0];
        t += `<td class="${cls(d)}">${w.map(g => `<span class="sh" style="--u:${UNITS[g.unit].color}" title="${UNITS[g.unit].full} · ${g.start}–${g.end}">${short(g.unit)}</span>`).join('')}${pc ? `<span class="pcx" style="--u:${UNITS[pc.unit].color}" title="Post-call from ${UNITS[pc.unit].short}"></span>` : ''}</td>`;
      }
      t += '</tr>';
    }
    t += `<tr class="freerow"><td class="nm"><div class="nmw"><span class="pn lbl">All off</span></div></td>${days.map(d => `<td class="${cls(d)}">${freeDay(d) ? `<span class="fr" title="Everyone’s off ${fmtDay(d)}">${I.check}</span>` : ''}</td>`).join('')}</tr>`;
    t += '</tbody></table></div>';
    const free = days.filter(d => d >= today && freeDay(d)), FN = 8;
    body += t + `<div class="crewfoot"><span class="k"><i class="kfree"></i>Everyone off</span><span class="k"><i class="kpc"></i>Post-call</span><span class="sum">${free.length ? `Next all off: ${free.slice(0, FN).map(fmtDay).join(' · ')}${free.length > FN ? ` · +${free.length - FN} more` : ''}` : 'No day in the coming months where you’re all off.'}</span></div>`;
    return header('Crew', `${people.length} people · <span data-crewsub>${fmtDay(days[0])} – ${fmtDay(days[days.length - 1])}</span>`, tools) + `<div class="view">${body}</div>`;
  }

  // The crew board scrolls sideways like Who's On (wheel, trackpad, drag); it opens on this week.
  const crewRange = () => [weekStartOf(addDays(today, -14)), addDays(today, 120)];
  function crewScrollTo(iso, smooth) {
    const w = root.querySelector('.crewtab'); if (!w) return;
    const el = w.querySelector(`th[data-day="${iso}"]`), nm = w.querySelector('thead th.nm'); if (!el) return;
    const left = Math.max(0, el.offsetLeft - (nm ? nm.offsetWidth : 190));
    if (smooth) w.scrollTo({ left, behavior: 'smooth' }); else { w.scrollLeft = left; S.crewLeft = left; }
  }
  function crewSub() {
    const w = root.querySelector('.crewtab'), sub = root.querySelector('[data-crewsub]'); if (!w || !sub) return;
    const lw = (w.querySelector('thead th.nm') || {}).offsetWidth || 190;
    const vis = [...w.querySelectorAll('thead th[data-day]')].filter(e => e.offsetLeft + e.offsetWidth / 2 >= w.scrollLeft + lw && e.offsetLeft + e.offsetWidth / 2 <= w.scrollLeft + w.clientWidth);
    if (vis.length) sub.textContent = `${fmtDay(vis[0].dataset.day)} – ${fmtDay(vis[vis.length - 1].dataset.day)}`;
  }
  function crewPlace() {
    const w = root.querySelector('.crewtab'); if (!w) return;
    if (S.crewGo || S.crewLeft == null) { crewScrollTo(S.crewGo || weekStartOf(today), false); S.crewGo = null; } else w.scrollLeft = S.crewLeft;
    let raf = 0;
    w.addEventListener('scroll', () => { S.crewLeft = w.scrollLeft; if (!raf) raf = requestAnimationFrame(() => { raf = 0; crewSub(); }); }, { passive: true });
    sideWheel(w, true);
    crewSub();
  }

  // ── Packed cards (My Stats, Settings): each card spans as many 2 px grid rows as it is tall, so cards sit close
  // under each other instead of leaving holes. Drag a card by its title to move it; the order is saved in this browser.
  function masonry(g) {
    for (const c of g.children) c.style.gridRowEnd = 'span ' + Math.max(1, Math.ceil((c.getBoundingClientRect().height + 14) / 2));
  }
  let mRO = null;
  function masonryAll() {
    if (mRO) { mRO.disconnect(); mRO = null; }
    const gs = root.querySelectorAll('.mgrid'); if (!gs.length) return;
    gs.forEach(masonry);
    if (window.ResizeObserver) {
      mRO = new ResizeObserver(es => new Set(es.map(e => e.target.parentElement)).forEach(g => g && g.isConnected && masonry(g)));
      gs.forEach(g => { for (const c of g.children) mRO.observe(c); });
    }
  }
  function mSave(g) {
    const o = [...g.children].map(c => c.dataset.card).filter(Boolean);
    if (g.dataset.mgrid === 'stats') { S.statsOrder = o; store.set('statsOrder', o); }
    if (g.dataset.mgrid === 'settings') { S.setOrder = o; store.set('setOrder', o); }
  }
  app.addEventListener('pointerdown', e => {
    if (e.button !== 0 || e.pointerType === 'touch' || dzOn) return;
    const h = e.target.closest('.mgrid > .xc > h3'); if (!h || e.target.closest('button,a,input,select,label')) return;
    const card = h.parentElement, g = card.parentElement, st = { x: e.clientX, y: e.clientY, on: false, last: null };
    e.preventDefault();
    const inside = (c, ev) => { const r = c.getBoundingClientRect(); return ev.clientX >= r.left && ev.clientX <= r.right && ev.clientY >= r.top && ev.clientY <= r.bottom; };
    const move = ev => {
      if (!st.on) { if (Math.hypot(ev.clientX - st.x, ev.clientY - st.y) < 6) return; st.on = true; card.classList.add('mdrag'); g.classList.add('mdragging'); }
      const over = [...g.children].find(c => c !== card && inside(c, ev));
      if (!over) { st.last = null; return; }
      if (over === st.last) return;   // just swapped with it: wait until the pointer leaves, so the two don't flip back and forth
      const kids = [...g.children];
      g.insertBefore(card, kids.indexOf(card) > kids.indexOf(over) ? over : over.nextSibling);
      st.last = over; masonry(g);
    };
    const up = () => {
      window.removeEventListener('pointermove', move, true); window.removeEventListener('pointerup', up, true); window.removeEventListener('pointercancel', up, true);
      if (!st.on) return;
      card.classList.remove('mdrag'); g.classList.remove('mdragging'); masonry(g); mSave(g);
      if (g.dataset.mgrid === 'settings') { const r = root.querySelector('[data-x="setorder"]'); if (!r) rerender(true); }
      const stop = ev => { ev.stopPropagation(); ev.preventDefault(); }; window.addEventListener('click', stop, { capture: true, once: true }); setTimeout(() => window.removeEventListener('click', stop, true), 0);
    };
    window.addEventListener('pointermove', move, true); window.addEventListener('pointerup', up, true); window.addEventListener('pointercancel', up, true);
  });

  // ── Take a shift: Lightning Bolt's own accept page in a sheet, like the app's AcceptSheet. The user's click on
  // LB's Accept button is the only thing that takes it; Working-Bolt just refreshes when the sheet closes.
  let takeEl = null, takeLive = false;
  function openTake(id) {
    const o = S.open.find(x => String(x.id) === String(id));
    if (!o) { flash('That shift is gone — someone took it.'); return; }
    if (!canTake(o)) { flash('That shift clashes with your days, so it can’t be taken from here.'); return; }
    closeTake(true);
    const u = UNITS[o.unit], clash = o.conflict || o.busy;
    takeEl = document.createElement('div'); takeEl.className = 'sheetbg';
    takeEl.innerHTML = `<div class="sheet" role="dialog" aria-modal="true" aria-label="Take this shift" style="--u:${u.color}">
      <header><div style="min-width:0">
        <div class="ln1"><span class="pill">${u.short}</span>${o.directed ? ' <span class="tag you">Offered to you</span>' : ''}</div>
        <h2>${DAYL[dow(o.date)]}, ${MONTH[+o.date.slice(5, 7) - 1]} ${+o.date.slice(8)}</h2>
        <div class="meta">${hrsLabel(o)} · from ${esc(o.offerer)}</div>
        ${clash ? `<div class="warnline">Heads up: ${esc(o.busy ? busyText(o.busy) : o.flag)}</div>` : ''}
      </div><button class="x" data-tx aria-label="Close">${I.close}</button></header>
      ${DEMO ? `<div class="demo"><div>On the live page, Lightning Bolt’s own accept screen opens here. You press Accept there; Working-Bolt refreshes when you close this.</div>
          <button class="chipbtn primary" data-tdemo>Pretend I took it</button></div>`
        : `<iframe src="${acceptURL(o.id)}" title="Lightning Bolt — accept this shift"></iframe>`}
      <footer>${DEMO ? 'Sample data — nothing is sent.' : `<a class="chipbtn ghost" href="${acceptURL(o.id)}" target="_blank" rel="noopener">Open in a new tab ${I.ext}</a>`}<span class="sp"></span><button class="chipbtn" data-tx>Done</button></footer></div>`;
    takeEl.addEventListener('click', e => {
      if (e.target === takeEl || e.target.closest('[data-tx]')) return closeTake();
      if (e.target.closest('[data-tdemo]')) {
        S.open = S.open.filter(x => x !== o);
        S.mine.push({ slot: o.id, date: o.date, unit: o.unit, start: o.start, end: o.end, ov: o.ov, doc: S.me, emp: S.emp, raw: {} });
        derive(); closeTake(true); rerender(true); flash(`Sample: ${u.short} on ${fmtDay(o.date)} is yours.`);
      }
    });
    root.appendChild(takeEl); takeLive = !DEMO;
    const btn = takeEl.querySelector('[data-tx]'); if (btn) btn.focus();
  }
  function closeTake(quiet) {
    if (!takeEl) return;
    takeEl.remove(); takeEl = null;
    if (!quiet && takeLive) { flash('Checking Lightning Bolt…'); refresh(); }
    takeLive = false;
  }


  // ── add a calendar: paste a live link (preferred) or pick a file
  let calEl = null;
  function openAddCal() {
    if (calEl) calEl.remove();
    calEl = document.createElement('div'); calEl.className = 'sheetbg';
    calEl.innerHTML = `<div class="sheet addcal" role="dialog" aria-modal="true" aria-label="Add a calendar">
      <header><div><h2>Add your calendar</h2><div class="meta">See your own events next to your shifts. Paste the calendar’s private link and it keeps itself up to date.</div></div><button class="x" data-cx aria-label="Close">${I.close}</button></header>
      <div class="sb">
        <h3>Calendar link</h3>
        <input data-curl type="url" placeholder="https://calendar.google.com/calendar/ical/…/basic.ics" aria-label="Calendar link" autocomplete="off" spellcheck="false">
        <input data-cname placeholder="Name (optional) — e.g. Family" aria-label="Name" style="margin-top:8px" maxlength="30">
        <div class="cmsg" data-cmsg></div>
        <h3>Where to find the link</h3>
        <div class="howto"><b>Google</b><span>calendar.google.com → ⚙ Settings → click the calendar on the left → <i>Integrate calendar</i> → copy <i>Secret address in iCal format</i>.</span>
          <b>Apple</b><span>Calendar app → right-click the calendar → <i>Sharing Settings</i> → tick <i>Public Calendar</i> → copy the link.</span>
          <b>Outlook</b><span>Settings → Calendar → <i>Shared calendars</i> → <i>Publish a calendar</i> → copy the ICS link.</span></div>
        <div class="fine">The link is private to you: it stays in this browser and is only used to read the calendar. Anyone with the link can see that calendar, so don’t share it.</div>
        <h3>Or a file</h3>
        <div class="fine" style="margin-top:0">An exported <b>.ics</b> file works too (or drop one on the page) — but it’s a snapshot and won’t update. <button class="chipbtn" data-cfile style="margin-left:6px">Choose a file…</button></div>
      </div>
      <footer><span class="sp"></span><button class="chipbtn" data-cx>Cancel</button><button class="chipbtn primary" data-cadd>Add calendar</button></footer></div>`;
    calEl.addEventListener('click', async e => {
      if (e.target === calEl || e.target.closest('[data-cx]')) return closeAddCal();
      if (e.target.closest('[data-cfile]')) { const f = root.querySelector('[data-file="cal"]'); closeAddCal(); if (f) f.click(); return; }
      const b = e.target.closest('[data-cadd]'); if (!b) return;
      const url = calEl.querySelector('[data-curl]').value, name = calEl.querySelector('[data-cname]').value, msg = calEl.querySelector('[data-cmsg]');
      if (!/^(https?|webcals?):\/\/\S+$/i.test(url.trim())) { msg.textContent = 'Paste the full link — it starts with https:// or webcal://'; msg.className = 'cmsg bad'; return; }
      b.disabled = true; b.textContent = 'Reading…'; msg.textContent = ''; msg.className = 'cmsg';
      try { const n = await addCalendarLink(url, name); closeAddCal(); flash(`Calendar added — ${n} event${n === 1 ? '' : 's'} in the coming year. It updates by itself.`); }
      catch (err) {
        b.disabled = false; b.textContent = 'Add calendar'; msg.className = 'cmsg bad';
        msg.textContent = String(err && err.message) === 'relay' ? 'The calendar relay isn’t switched on yet, so links can’t be read. Use a file for now.' : 'Couldn’t read that link. Check it’s the private iCal / ICS address (not the normal web page), then try again.';
      }
    });
    calEl.addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); const b = calEl.querySelector('[data-cadd]'); if (b && !b.disabled) b.click(); } });
    root.appendChild(calEl);
    setTimeout(() => { const i = calEl && calEl.querySelector('[data-curl]'); if (i) i.focus(); }, 30);
  }
  function closeAddCal() { if (calEl) { calEl.remove(); calEl = null; } }


  // ═════════════════════════════ app parity: Settings, My posts, swaps, Time Off, Stats, Export, sync, Hennie ═════════════════════════════
  const dLong = iso => `${DAY[dow(iso)]}, ${MON[+iso.slice(5, 7) - 1]} ${+iso.slice(8, 10)}`;
  const dYear = iso => `${MON[+iso.slice(5, 7) - 1]} ${+iso.slice(8, 10)}, ${iso.slice(0, 4)}`;
  const uName = u => (UNITS[u] || { short: u }).short;
  const plural = (n, w) => `${n} ${w}${n === 1 ? '' : 's'}`;
  const notStarted = s => s.date > today || (s.date === today && s.start > reginaHM());
  const tog = (on, k, label) => `<button class="xtog" role="switch" aria-checked="${!!on}" aria-label="${esc(label)}" data-x="tog" data-k="${k}"></button>`;
  const segX = (k, cur, opts) => `<div class="seg sm" role="group">${opts.map(([v, l]) => `<button data-x="set" data-k="${k}" data-v="${v}" aria-pressed="${String(cur) === String(v)}">${l}</button>`).join('')}</div>`;
  // a run of dates as short ranges: "Dec 22–24, Jan 3"
  function dateRuns(dates) {
    const ds = [...new Set(dates)].sort(), out = [];
    for (const d of ds) { const r = out[out.length - 1]; if (r && addDays(r[1], 1) === d) r[1] = d; else out.push([d, d]); }
    return out.map(([a, b]) => a === b ? `${MON[+a.slice(5, 7) - 1]} ${+a.slice(8)}` : `${MON[+a.slice(5, 7) - 1]} ${+a.slice(8)}–${a.slice(0, 7) === b.slice(0, 7) ? '' : MON[+b.slice(5, 7) - 1] + ' '}${+b.slice(8)}`).join(', ');
  }

  // ── a small confirm box (its own overlay, so it works on any screen). Every Lightning Bolt write goes through one.
  let xEl = null;
  function xAsk(o) {
    xClose();
    xEl = document.createElement('div'); xEl.className = 'sheetbg';
    xEl.innerHTML = `<div class="sheet xask" role="alertdialog" aria-modal="true" aria-label="${esc(o.title)}">
      <div class="xab"><b>${esc(o.title)}</b><p>${esc(o.text).replace(/\n/g, '<br>')}</p><div class="xmsg" role="status"></div></div>
      <footer>${o.foot ? `<span>${esc(o.foot)}</span>` : ''}<span class="sp"></span>${o.okOnly ? '' : `<button class="chipbtn" data-xa="no">${esc(o.no || 'Cancel')}</button>`}<button class="chipbtn ${o.danger ? 'danger' : 'primary'}" data-xa="yes">${esc(o.yes || 'OK')}</button></footer></div>`;
    xEl.addEventListener('click', async e => {
      if (e.target === xEl || e.target.closest('[data-xa="no"]')) return xClose();
      const b = e.target.closest('[data-xa="yes"]'); if (!b || b.disabled) return;
      if (!o.onYes) return xClose();
      const lbl = b.textContent; b.disabled = true; b.textContent = o.busy || 'Sending…';
      let r; try { r = await o.onYes(); } catch (err) { r = { ok: false, message: 'Something went wrong — nothing was changed. Try again.' }; }
      if (!xEl) return;
      if (r && r.ok === false) { xEl.querySelector('.xmsg').textContent = r.message || 'That didn’t go through.'; b.disabled = false; b.textContent = r.message ? 'Try again' : lbl; return; }
      xClose(); if (r && r.text) flash(r.text);
    });
    root.appendChild(xEl);
    const y = xEl.querySelector('[data-xa="yes"]'); if (y) y.focus();
  }
  function xClose() { if (xEl) { xEl.remove(); xEl = null; } }

  // ── Lightning Bolt's own page in a sheet (accept / decline a swap). The user's click there is the only approval.
  let lbEl = null, lbLive = false;
  function openLB(url, title, sub, demoNote) {
    lbClose(true);
    lbEl = document.createElement('div'); lbEl.className = 'sheetbg';
    lbEl.innerHTML = `<div class="sheet" role="dialog" aria-modal="true" aria-label="${esc(title)}">
      <header><div style="min-width:0"><h2>${esc(title)}</h2><div class="meta">${esc(sub || '')}</div></div><button class="x" data-lbx aria-label="Close">${I.close}</button></header>
      ${DEMO ? `<div class="demo"><div>${esc(demoNote || 'On the live page, Lightning Bolt’s own screen opens here. You answer there; Working-Bolt refreshes when you close this.')}</div></div>`
        : `<iframe src="${url}" title="${esc(title)}"></iframe>`}
      <footer>${DEMO ? 'Sample data — nothing is sent.' : `<a class="chipbtn ghost" href="${url}" target="_blank" rel="noopener">Open in a new tab ${I.ext}</a>`}<span class="sp"></span><button class="chipbtn" data-lbx>Done</button></footer></div>`;
    lbEl.addEventListener('click', e => { if (e.target === lbEl || e.target.closest('[data-lbx]')) lbClose(); });
    root.appendChild(lbEl); lbLive = !DEMO;
    const b = lbEl.querySelector('[data-lbx]'); if (b) b.focus();
  }
  function lbClose(quiet) {
    if (!lbEl) return;
    lbEl.remove(); lbEl = null;
    if (!quiet && lbLive) { flash('Checking Lightning Bolt…'); refresh().then(loadSwapNotes); }
    lbLive = false;
  }

  // ───── extra reads (Supabase, read-only unless noted). A failed read always keeps what we had.
  async function loadSwapNotes() {
    if (DEMO) { S.swapNotes = demoSwapNotes(); trackSwaps(); if (S.tab === 'pool') rerender(true); return; }
    try { const rows = await supaGet('/offer_notes?reason=like.swap*&select=slot_id,note,reason,by_emp'); S.swapNotes = rows; trackSwaps(); }
    catch (e) { return; }
    if (S.tab === 'pool') rerender(true);
  }
  function demoSwapNotes() {
    const fut = S.mine.filter(s => s.date > addDays(today, 3) && !s.pending && s.slot);
    const n = [];
    if (fut[1]) n.push({ slot_id: 'demo-0', by_emp: 'e1', reason: `swap:demo:${fut[1].slot}`, note: 'Swap?' });          // Sarah offers her Rapid for your shift
    if (fut[3]) n.push({ slot_id: fut[3].slot, by_emp: 'demo', reason: 'swap:e4:777001', note: '' });                     // yours to David — he declined
    n.push({ slot_id: 'demo-gone', by_emp: 'demo', reason: 'swap:e2:demo-1', note: '' });                                  // James took yours and sent his SICU back
    if (fut[3]) { S.swapSeen = [String(fut[3].slot)]; S.swapSettled = [String(fut[3].slot)]; }
    return n;
  }
  const parseTag = s => { const p = String(s || '').split(':'); if (p.length !== 3 || (p[0] !== 'swap' && p[0] !== 'swapback')) return null; const slots = p[2].split(',').filter(Boolean); return slots.length ? { back: p[0] === 'swapback', to: p[1], slots } : null; };
  const histRows = () => (S.hist && S.hist.rows) || [];
  const mySlots = () => new Set(S.mine.concat(histRows()).map(s => String(s.slot)).filter(x => x && x !== 'undefined'));
  const mySlot = id => S.mine.find(s => String(s.slot) === String(id));
  const openIds = () => new Set(S.open.map(o => String(o.id)));
  const nameOf = emp => nameOfEmp(emp) || (DEMO ? ['Priya Nair', 'Sarah Chen', 'James Okafor', 'Maria Santos', 'David Kim', 'Emily Novak', 'Raj Patel', 'Lena Fischer', 'Tom Wright', 'Anna Kowalski'][+String(emp).slice(1)] : '') || 'A colleague';
  function myProposals() { return (S.swapNotes || []).filter(n => String(n.by_emp) === String(S.emp)).map(n => ({ slot: String(n.slot_id), tag: parseTag(n.reason) })).filter(p => p.tag && !p.tag.back); }
  // remember which of my swap offers were seen waiting, then seen gone — so a declined one can be told apart
  function trackSwaps() {
    let ch = false;
    for (const p of myProposals()) {
      const m = mySlot(p.slot);
      if (m && m.pending) { if (!S.swapSeen.includes(p.slot)) { S.swapSeen.push(p.slot); ch = true; } }
      else if (S.swapSeen.includes(p.slot) && !S.swapSettled.includes(p.slot)) { S.swapSettled.push(p.slot); ch = true; }
    }
    if (ch && !DEMO) { store.set('swapSeen', S.swapSeen.slice(-200)); store.set('swapSettled', S.swapSettled.slice(-200)); }
  }
  function incomingSwaps() {
    const open = openIds(), mine = mySlots(), out = [];
    const sentBack = new Set((S.swapNotes || []).filter(n => (parseTag(n.reason) || {}).back).map(n => String(n.slot_id)));
    for (const n of S.swapNotes || []) {
      const t = parseTag(n.reason), from = String(n.by_emp);
      if (!t || t.back || t.to !== String(S.emp) || from === String(S.emp)) continue;
      const ret = mySlot(t.slots[0]); if (!ret || !notStarted(ret)) continue;
      const o = S.open.find(x => String(x.id) === String(n.slot_id) && String(x.offererEmp) === from);
      if (o) out.push({ slot: String(n.slot_id), from, name: nameOf(from), date: o.date, unit: o.unit, mine: ret, taken: false });
      else if (mine.has(String(n.slot_id)) && !ret.pending && !sentBack.has(String(ret.slot)) && !open.has(String(ret.slot))) {
        const th = mySlot(n.slot_id); if (th) out.push({ slot: String(n.slot_id), from, name: nameOf(from), date: th.date, unit: th.unit, mine: ret, taken: true });
      }
    }
    return out.sort((a, b) => a.date < b.date ? -1 : 1);
  }
  function swapReturns() {
    const open = openIds(), mine = mySlots(), props = myProposals();
    return S.open.filter(o => o.offererEmp && props.some(p => p.tag.to === String(o.offererEmp) && p.tag.slots.includes(String(o.id)) && !open.has(p.slot) && !mine.has(p.slot)));
  }
  function declinedSwaps() {
    const mine = mySlots(), out = [];
    for (const p of myProposals()) {
      const m = mySlot(p.slot);
      if (!m || m.pending || !S.swapSeen.includes(p.slot) || !S.swapSettled.includes(p.slot) || S.swapDismissed.includes(p.slot)) continue;
      if (p.tag.slots.some(x => mine.has(x)) || !notStarted(m)) continue;
      out.push({ slot: p.slot, mine: m, name: nameOf(p.tag.to) });
    }
    return out;
  }
  function swapsBox() {
    const inc = incomingSwaps(), ret = swapReturns(), dec = declinedSwaps();
    if (!inc.length && !ret.length && !dec.length) return '';
    const row = (pill, title, sub, btns) => `<div class="swi">${pill}<div class="l"><b>${title}</b><small>${sub}</small></div><div class="xbtns">${btns}</div></div>`;
    const pl = u => `<span class="pill" style="--u:${UNITS[u].color}">${uName(u)}</span>`;
    let h = `<section class="swbox"><h3>Swaps<b>${inc.length + ret.length + dec.length}</b></h3>`;
    for (const s of inc) h += s.taken
      ? row(pl(s.unit), `You took ${esc(firstName(s.name))}’s ${uName(s.unit)} on ${dLong(s.date)}`, `Your ${uName(s.mine.unit)} on ${dLong(s.mine.date)} still has to go back to finish the swap.`,
          `<button class="chipbtn primary" data-x="swback" data-slot="${esc(s.slot)}">Send it back</button>`)
      : row(pl(s.unit), `${esc(s.name)} wants to swap`, `You take their ${uName(s.unit)} on ${dLong(s.date)}; your ${uName(s.mine.unit)} on ${dLong(s.mine.date)} goes to them.`,
          `<button class="chipbtn primary" data-x="swacc" data-slot="${esc(s.slot)}">Accept swap</button><button class="chipbtn" data-x="swdec" data-slot="${esc(s.slot)}">Decline</button>`);
    for (const o of ret) h += row(pl(o.unit), `${esc(o.offerer)} sent their ${uName(o.unit)} on ${dLong(o.date)} back`, 'The return half of your swap. Take it to finish.',
      `<button class="chipbtn primary" data-x="swret" data-slot="${esc(o.id)}">Take it</button>`);
    for (const d of dec) h += row(pl(d.mine.unit), `Swap with ${esc(d.name)} didn’t go through`, `It was declined or cancelled. Your ${uName(d.mine.unit)} on ${dLong(d.mine.date)} is still yours.`,
      `<button class="chipbtn" data-x="swok" data-slot="${esc(d.slot)}">OK</button>`);
    return h + '</section>';
  }
  function swapAct(kind, slot) {
    if (kind === 'swok') { S.swapDismissed.push(String(slot)); if (!DEMO) store.set('swapDismissed', S.swapDismissed.slice(-200)); return rerender(true); }
    if (kind === 'swret') {
      const o = S.open.find(x => String(x.id) === String(slot)); if (!o) return flash('That shift is gone from the pool.');
      return openLB(acceptURL(o.id), 'Finish your swap', `${uName(o.unit)} · ${dLong(o.date)} · from ${o.offerer}`, 'On the live page, Lightning Bolt’s accept screen opens here. Tap Accept there to take it; Working-Bolt refreshes when you close this.');
    }
    const s = incomingSwaps().find(x => x.slot === String(slot)); if (!s) return rerender(true);
    const fn = firstName(s.name), theirs = `${uName(s.unit)} on ${dLong(s.date)}`, yours = `${uName(s.mine.unit)} on ${dLong(s.mine.date)}`;
    if (kind === 'swacc') return xAsk({ title: 'Accept this swap?', yes: 'Open Lightning Bolt',
      text: `Lightning Bolt opens on your schedule — tap ${fn}’s ${theirs}, then Accept and Submit. Once it’s yours, send your ${yours} back to ${fn} from the Swaps box here.`,
      onYes: async () => { openLB(acceptURL(s.slot), `Accept ${fn}’s ${uName(s.unit)}`, dLong(s.date)); return {}; } });
    if (kind === 'swdec') return xAsk({ title: 'Decline this swap?', yes: 'Open Lightning Bolt',
      text: `Lightning Bolt opens on your schedule — tap ${fn}’s ${theirs}, then Deny. Add a note for ${fn} if you like, then tap Submit there — nothing is declined until you do.`,
      onYes: async () => { openLB(`${LITE}/dashboard/#/swop/${s.slot}/decline`, `Decline ${fn}’s swap`, `${uName(s.unit)} · ${dLong(s.date)}`); return {}; } });
    if (kind === 'swback') return xAsk({ title: 'Send it back?', yes: 'Send it back',
      text: `Offers your ${yours} to ${s.name} — the return half of the swap. ${fn} takes it in Lightning Bolt.`,
      onYes: async () => {
        const m = s.mine, twin = m.unit === 'PRR' ? S.mine.find(x => x.date === m.date && x.unit === 'MSU' && x.slot && !x.pending) : null;
        if (DEMO) { m.pending = true; m.pendingEmp = s.from; if (twin) { twin.pending = true; twin.pendingEmp = s.from; } rerender(true); return { text: 'Sample: sent back (nothing was sent).' }; }
        const note = `Swap: my ${uName(m.unit)} on ${dLong(m.date)} for your ${uName(s.unit)} on ${dLong(s.date)}.`;
        const r = await offerToPerson(m, s.from, note); if (!r.ok) return r;
        rememberTarget(m.slot, s.from);
        if (twin) { const r2 = await offerToPerson(twin, s.from, note); if (r2.ok) rememberTarget(twin.slot, s.from); }
        await putOfferNote(m.slot, note, `swapback:${s.from}:${s.slot}`);
        refresh().then(loadSwapNotes);
        return { text: `Sent — your ${uName(m.unit)} is offered to ${fn}.` };
      } });
  }

  // ── "Not offered to you": shifts Lightning Bolt sent to a set list of people (the poller's open_shifts table)
  async function loadNotOffered() {
    let rows;
    if (DEMO) {
      rows = [[6, 'CCU', 'Lena Fischer', 'e7', '08:00', '08:00'], [9, 'RR', 'Anna Kowalski', 'e9', '08:00', '17:00'], [17, 'Pasqua-MSU', 'Raj Patel', 'e6', '17:00', '08:00']].map(([o, unit, offerer, oe, s, e], i) => {
        const d = addDays(today, o), d2 = e <= s ? addDays(d, 1) : d;
        return { slot_id: 'no-' + i, date: d, unit, offerer, offerer_emp: oe, start_time: `${d}T${s}:00`, stop_time: `${d2}T${e}:00` };
      });
    } else {
      try { rows = await supaGet('/open_shifts?select=*'); } catch (e) { return; }
    }
    const map = { 'Pasqua RR': 'PRR', 'Pasqua-Rapid': 'PRR', 'Pasqua-MSU': 'MSU', PICU: 'PHICU' };
    const out = [];
    for (const r of rows || []) {
      if (!r || !r.start_time || !r.stop_time || r.start_time.length < 16) continue;
      const u = map[r.unit] || (UNITS[r.unit] ? r.unit : unitKey(r.unit)); if (!u) continue;
      const date = r.start_time.slice(0, 10); if (date < today) continue;
      out.push({ id: String(r.slot_id), date, unit: u, offerer: r.offerer || 'A colleague', offererEmp: r.offerer_emp != null ? String(r.offerer_emp) : null,
        start: r.start_time.slice(11, 16), end: r.stop_time.slice(11, 16), ov: r.stop_time.slice(0, 10) > date, notOffered: true });
    }
    S.notOffered = out;
    if (S.tab === 'pool') rerender(true);
  }
  function notOfferedList() {
    const open = openIds(), mine = mySlots();
    return (S.notOffered || []).filter(o => !open.has(o.id) && !mine.has(o.id) && String(o.offererEmp) !== String(S.emp) && !S.unitsOff.has(o.unit) && o.date >= today);
  }
  function withNotOffered(list) { return list.concat(notOfferedList()).sort((a, b) => a.date !== b.date ? (a.date < b.date ? -1 : 1) : toMin(a.start) - toMin(b.start)); }
  function noCard(o) {
    const u = UNITS[o.unit];
    return `<button class="card sm clash noto" style="--u:${u.color}" data-x="noto">
      <div class="date"><div class="dw">${DAY[dow(o.date)]}</div><div class="dn">${+o.date.slice(8)}</div></div>
      <div style="min-width:0"><div class="ln1"><span class="pill">${u.short}</span><span class="hrs">${hrsLabel(o)}</span></div>
        <div class="meta"><span>Offered by ${esc(o.offerer)}</span><span class="flag no">Not offered to you</span></div></div></button>`;
  }

  // ── Pool → My posts
  const myPosts = () => S.mine.filter(s => s.pending && s.date >= today).sort((a, b) => a.date < b.date ? -1 : 1);
  function postsSegShown() {
    const m = S.postsMode, n = myPosts().length;
    return m === 'always' || (m === 'awaiting' ? n > 0 : n > 0 || (S.myPickups || []).length > 0);
  }
  async function loadMyPickups() {
    if (DEMO) {
      const at = d => d + 'T' + '10:15:00';
      S.myPickups = [[-3, 'MICU', 'Lena Fischer', 'pickup'], [-12, 'RR', 'Tom Wright', 'swap'], [-41, 'CCU', 'Raj Patel', 'pickup'], [-70, 'SICU', 'Anna Kowalski', 'pickup']]
        .map(([o, unit, taker, kind], i) => ({ slot_id: 950 + i, date: addDays(today, o + 5), unit, taker, kind, picked_up_at: at(addDays(today, o)) }));
      return;
    }
    if (!S.emp) return;
    try { const rows = await supaGet(`/pickups?giver_emp=eq.${encodeURIComponent(S.emp)}&select=slot_id,date,unit,kind,taker,picked_up_at&order=picked_up_at.desc&limit=200`); if (rows.length || !S.myPickups) S.myPickups = rows; }
    catch (e) { return; }
    if (S.tab === 'pool') rerender(true);
  }
  function postsView() {
    const posts = myPosts(), picks = S.myPickups || [];
    if (!posts.length && !picks.length) return `<div class="empty"><b>You haven’t posted any shifts.</b>Give one away or offer a swap and it’ll show up here.</div>`;
    const who = s => { const t = s.pendingEmp && s.pendingEmp !== S.emp ? s.pendingEmp : S.offerTargets[s.slot]; return t ? `Offered to ${esc(nameOf(t))}` : 'Offered to the group'; };
    let h = `<div class="xgrid"><section class="xc"><h3>Waiting for pickup<b>${posts.length}</b></h3>`;
    h += posts.length ? posts.map(s => `<div class="xr"><span class="pill" style="--u:${UNITS[s.unit].color}">${uName(s.unit)}</span><div class="l">${dLong(s.date)}<small>${hrsLabel(s)} · ${who(s)}</small></div>
        <button class="chipbtn danger" data-x="withdraw" data-slot="${esc(s.slot)}">Withdraw</button></div>`).join('') : '<div class="off">Nothing waiting — everything you posted was picked up.</div>';
    h += '</section><section class="xc"><h3>Picked up<b>' + picks.length + '</b></h3>';
    if (!picks.length) h += '<div class="off">None yet.</div>';
    let last = '';
    for (const p of picks) {
      const ym = String(p.picked_up_at || p.date).slice(0, 7);
      if (ym !== last) { last = ym; h += `<div class="dayhead">${monthTitle(ym)}</div>`; }
      const u = UNITS[p.unit] ? p.unit : (p.unit === 'Pasqua' ? 'PRR' : unitKey(p.unit));
      h += `<div class="xr"><span class="pill" style="--u:${u ? UNITS[u].color : 'var(--faint)'}">${u ? uName(u) : esc(p.unit)}</span><div class="l">${p.date ? dLong(p.date) : ''}<small>${p.kind === 'swap' ? 'Swapped with' : 'Taken by'} ${esc(p.taker || 'a colleague')} · ${p.picked_up_at ? dYear(String(p.picked_up_at).slice(0, 10)) : ''}</small></div></div>`;
    }
    return h + '</section></div>';
  }
  function withdrawPost(slot) {
    const s = S.mine.find(x => String(x.slot) === String(slot)); if (!s) return;
    xAsk({ title: 'Withdraw this shift?', yes: 'Withdraw', danger: true, no: 'Keep it posted',
      text: `${uName(s.unit)} · ${dLong(s.date)}. This withdraws it from the pool.`,
      onYes: async () => {
        const tgt = s.pendingEmp && s.pendingEmp !== S.emp ? s.pendingEmp : S.offerTargets[s.slot];
        if (DEMO) { s.pending = false; s.pendingEmp = null; rerender(true); return { text: 'Sample: offer withdrawn (nothing was sent).' }; }
        if (!tgt) return { ok: false, message: 'Couldn’t tell who it was offered to — withdraw it on Lightning Bolt instead.' };
        const r = await cancelOfferLB(s.slot, tgt); if (!r.ok) return r;
        refresh(); return { text: 'Withdrawn — the shift is yours again.' };
      } });
  }

  // ── Time Off: the full screen
  const reqLabel = st => st === 'approved' ? 'Approved' : st === 'pending' ? 'Pending' : st ? st[0].toUpperCase() + st.slice(1) : '';
  function reqGroups() {
    const rs = S.requests.slice().sort((a, b) => a.date < b.date ? -1 : 1), out = [];
    for (const r of rs) {
      const g = out[out.length - 1];
      if (g && g.kind === r.kind && g.status === r.status && g.note === r.note && addDays(g.end, 1) === r.date) { g.end = r.date; g.ids.push(r.id); g.decision = g.decision || r.decision; }
      else out.push({ kind: r.kind, status: r.status, note: r.note, decision: r.decision || '', start: r.date, end: r.date, ids: [r.id] });
    }
    return out;
  }
  const rangeTxt = g => g.start === g.end ? dLong(g.start) : `${dLong(g.start)} – ${dLong(g.end)}`;
  function viewTimeOff() {
    const gs = reqGroups(), up = gs.filter(g => g.end >= today), past = gs.filter(g => g.end < today).reverse().slice(0, 30);
    const row = (g, canCancel) => `<div class="xr tor"><span class="tag ${g.status}">${reqLabel(g.status)}</span><div class="l"><b>${esc(g.kind)}</b> · ${rangeTxt(g)}${g.ids.length > 1 ? ` · ${g.ids.length} days` : ''}
        ${g.note ? `<small>“${esc(g.note)}”</small>` : ''}${g.decision ? `<small>Decision: ${esc(g.decision)}</small>` : ''}</div>
        ${canCancel && (g.status === 'pending' || g.status === 'approved') ? `<button class="chipbtn danger" data-x="tocancel" data-i="${gs.indexOf(g)}">${g.ids.length > 1 ? `Cancel all ${g.ids.length} days` : 'Cancel'}</button>` : ''}</div>`;
    let body = banners() + `<div class="cobar"><button class="chipbtn ghost" data-x="page" data-v="">${I.back}Settings</button><span class="sp"></span>${S.toNew ? '' : `<button class="chipbtn primary" data-x="tonew">${I.plus}New request</button>`}</div>`;
    if (S.toNew) body += toNewForm();
    body += `<div class="xgrid"><section class="xc"><h3>Upcoming<b>${up.length}</b></h3>${up.length ? up.map(g => row(g, true)).join('') : '<div class="off">No time off coming up.</div>'}</section>
      <section class="xc"><h3>Past</h3>${past.length ? past.map(g => row(g, false)).join('') : '<div class="off">Nothing yet this year.</div>'}</section></div>`;
    return header('Time Off', 'Your day-off and night-off requests', '') + `<div class="view">${body}</div>`;
  }
  function toNewForm() {
    const N = S.toNew, rt = rosterThrough(), by = myByDate(), pc = postCallMap(), req = {};
    for (const r of S.requests) if (r.status === 'pending' || r.status === 'approved') req[r.date] = r;
    const first = addDays(rt, 1); if (!N.ym || N.ym < ymOf(first)) N.ym = ymOf(first);
    let cal = '';
    for (let i = 0; i < 2; i++) {
      const ym = addMonths(N.ym, i), pad = (dow(ym + '-01') - S.weekStart + 7) % 7;
      cal += `<div class="mcal"><h4>${monthTitle(ym)}</h4><div class="g">${Array.from({ length: 7 }, (_, k) => `<span class="h">${DAY[(k + S.weekStart) % 7].slice(0, 2)}</span>`).join('')}${'<span></span>'.repeat(pad)}`;
      for (let d = 1; d <= daysIn(ym); d++) {
        const iso = `${ym}-${String(d).padStart(2, '0')}`, why = iso <= rt ? 'The roster is already out for this day — swap or give away instead' : by[iso] ? 'You’re working this day' : req[iso] ? `Already requested: ${req[iso].kind}` : '';
        cal += `<button class="d${iso === today ? ' today' : ''}" data-x="todate" data-d="${iso}" aria-pressed="${N.dates.includes(iso)}" ${why ? `disabled title="${esc(why)}"` : ''}>${d}</button>`;
      }
      cal += '</div></div>';
    }
    const clash = N.dates.filter(d => by[d] || pc[d]).map(d => `You’re rostered ${(by[d] || [pc[d]]).map(s => uName(s.unit)).join(' + ')}${by[d] ? '' : ' (post-call)'} on ${dLong(d)}`);
    return `<section class="xc tonew"><h3>New request<button class="go" data-x="tonewx">Cancel</button></h3>
      <div class="xr"><div class="l">Kind</div>${segX('tokind', N.kind, [['Time Off', 'Time Off'], ['Night Off', 'Night Off']])}</div>
      <div class="mcnav"><button class="chipbtn ghost" data-x="tonav" data-v="-1" ${N.ym <= ymOf(first) ? 'disabled' : ''} aria-label="Earlier">${I.back}</button><span>${N.dates.length ? `${plural(N.dates.length, 'day')}: ${dateRuns(N.dates)}` : 'Pick the days — click again to unpick'}</span><button class="chipbtn ghost" data-x="tonav" data-v="1" aria-label="Later">${I.fwd}</button></div>
      <div class="mcals">${cal}</div>
      ${clash.map(c => `<div class="warnline">${esc(c)}</div>`).join('')}
      <label class="xr"><div class="l">Reason <small>Optional — Lightning Bolt shows it to whoever approves.</small></div></label>
      <input class="xin wide" data-xin="tonote" value="${esc(N.note)}" placeholder="e.g. Family visit" maxlength="200">
      <div class="fine">A request doesn’t move a shift you already have — swap or give it away separately. Days up to ${fmtDay(rt)} are on the published roster, so they can’t be picked.</div>
      <div class="xbtns" style="justify-content:flex-end"><button class="chipbtn primary" data-x="toreview" ${N.dates.length ? '' : 'disabled'}>Review &amp; send</button></div></section>`;
  }
  function toReview() {
    const N = S.toNew, dates = N.dates.slice().sort(), n = dates.length; if (!n) return;
    xAsk({ title: 'Review & send', yes: 'Send to Lightning Bolt',
      text: `${N.kind} · ${dateRuns(dates)}\n${N.note.trim() ? `Reason: “${N.note.trim()}”` : 'No reason given'}\n\nSent to Lightning Bolt for your own roster only.`,
      onYes: async () => {
        if (DEMO) {
          dates.forEach((d, i) => S.requests.push({ id: -100 - S.requests.length - i, date: d, status: 'pending', kind: N.kind, note: N.note.trim() }));
          S.toNew = null; derive(); rerender(true); return { text: `Sample: ${N.kind} for ${plural(n, 'day')} added (nothing was sent).` };
        }
        const r = await submitRequest(N.kind, dates, N.note.trim()); if (!r.ok) return r;
        S.toNew = null; refresh(); return { text: `Sent — ${N.kind} for ${plural(n, 'day')} is pending approval.` };
      } });
  }
  function toCancel(i) {
    const g = reqGroups()[+i]; if (!g) return;
    xAsk({ title: g.ids.length > 1 ? `Cancel all ${g.ids.length} days?` : 'Cancel this request?', yes: 'Cancel request', no: 'Keep it', danger: true,
      text: `Asks Lightning Bolt to delete your ${g.kind} request for ${rangeTxt(g)}. Nothing else changes.`,
      onYes: async () => {
        if (DEMO) { S.requests = S.requests.filter(r => !g.ids.includes(r.id)); derive(); rerender(true); return { text: 'Sample: request cancelled (nothing was sent).' }; }
        const r = await deleteRequests(g.ids); if (!r.ok) return r;
        refresh(); return { text: `Cancelled — ${g.kind} for ${rangeTxt(g)}.` };
      } });
  }

  // ── history (past years) for Stats and Export — read once, kept in this browser, refreshed weekly
  let histLoading = null;
  function loadHist() {
    if (DEMO) { if (!S.hist) S.hist = { at: Date.now(), rows: [] }; return Promise.resolve(); }
    if (histLoading) return histLoading;
    if (S.hist && Date.now() - S.hist.at < 7 * 864e5) return Promise.resolve();
    const y = +today.slice(0, 4), years = []; for (let yy = 2022; yy < y; yy++) years.push(yy);
    S.histBusy = true;
    histLoading = (async () => {
      const rows = [], seen = {};
      try {
        const pages = await pool(2, years, yy => api(`/schedule/range/?start_date=${yy}0101&end_date=${yy}1231&listed=true&emp_id=${S.emp}`).catch(e => { if (e.session) throw e; return null; }));
        if (pages.some(p => p === null)) throw new Error('partial');
        for (const a of pages.flat()) { const s = norm(a); if (s && s.unit && !s.buddy && s.emp === S.emp && !seen[s.slot]) { seen[s.slot] = 1; rows.push({ slot: s.slot, date: s.date, unit: s.unit, start: s.start, end: s.end, ov: s.ov }); } }
        if (rows.length || !S.hist || !histRows().length) { S.hist = { at: Date.now(), rows }; store.set('hist', S.hist); }
      } catch (e) { S.histFailed = true; }
      S.histBusy = false; histLoading = null;
      if (S.tab === 'crew' || S.tab === 'settings') rerender(true);
    })();
    return histLoading;
  }
  function allLog() {
    const y0 = today.slice(0, 4) + '-01-01', seen = new Set(), out = [];
    for (const s of histRows().filter(r => r.date < y0).concat(S.mine)) { const k = s.slot ? String(s.slot) : s.date + s.unit; if (seen.has(k) || !UNITS[s.unit]) continue; seen.add(k); out.push(s); }
    return out.sort((a, b) => a.date < b.date ? -1 : a.date > b.date ? 1 : toMin(a.start) - toMin(b.start));
  }

  // ── stats (the app's ShiftStats: a Pasqua Rapid + MSU on one day is ONE 24 h shift)
  function statsOf(log, from, to) {
    const by = {};
    for (const s of log) if (s.date >= from && s.date <= to && UNITS[s.unit]) (by[s.date] = by[s.date] || []).push(s);
    let count = 0, hours = 0, nights = 0, weekends = 0; const len = {}, unit = {};
    const we = d => dow(d) === 0 || dow(d) === 6;
    const addLen = (k, h) => { const v = len[k] = len[k] || { n: 0, h: 0 }; v.n++; v.h += h; };
    const addUnit = (k, name, color, h) => { const v = unit[k] = unit[k] || { name, color, n: 0, h: 0 }; v.n++; v.h += h; };
    for (const d in by) {
      let rem = by[d];
      const pi = rem.findIndex(s => s.unit === 'PRR'), mi = rem.findIndex(s => s.unit === 'MSU');
      if (pi >= 0 && mi >= 0) {
        const h = hoursOf(rem[pi]) + hoursOf(rem[mi]);
        count++; hours += h; nights++; if (we(d)) weekends++; addLen(24, h); addUnit('PRR+MSU', 'Pasqua Rapid+MSU', UNITS.PRR.color, h);
        rem = rem.filter((_, i) => i !== pi && i !== mi);
      }
      for (const s of rem) { const h = hoursOf(s); count++; hours += h; if (s.ov) nights++; if (we(d)) weekends++; addLen(Math.round(h), h); addUnit(s.unit, UNITS[s.unit].short, UNITS[s.unit].color, h); }
    }
    const months = Math.max(1, (ord(to) - ord(from) + 1) / 30.4375);
    return { count, hours, nights, weekends, months, from, to,
      byLen: Object.keys(len).map(k => ({ h: +k, n: len[k].n, hrs: len[k].h })).sort((a, b) => b.h - a.h),
      byUnit: Object.values(unit).sort((a, b) => b.n - a.n || b.h - a.h) };
  }
  const f1 = x => (Math.round(x * 10) / 10).toFixed(1);
  function statsBody(st) {
    if (!st.count) return '<div class="off">No shifts in this range.</div>';
    return `<div class="sttiles"><div><b>${st.count}</b><span>Shifts</span></div><div><b>${fmtH(st.hours)}</b><span>Hours</span></div><div><b>${f1(st.count / st.months)}</b><span>Shifts / mo</span></div><div><b>${Math.round(st.hours / st.months)}</b><span>Hours / mo</span></div></div>
      <div class="stu">${st.byUnit.map(u => `<div><i style="--u:${u.color}"></i><b>${esc(u.name)}</b><span>×${u.n} · ${f1(u.n / st.months)}/mo · ${Math.round(u.h)}h</span></div>`).join('')}</div>
      <div class="chips">${st.byLen.map(l => `<span class="chip">${l.h}h ×${l.n}</span>`).join('')}</div>
      <div class="fine" style="margin-top:8px">${plural(st.nights, 'overnight')} · ${st.weekends} weekend day${st.weekends === 1 ? '' : 's'}</div>`;
  }
  const STAT_SECTIONS = { perMonth: 'Month by month', monthlyAvg: 'Monthly average', comingUp: 'Coming up', ytd: 'Year to date', years: 'Past years', custom: 'Custom range' };
  function statOrder() { const o = (S.statsOrder || []).filter(k => STAT_SECTIONS[k]); for (const k of Object.keys(STAT_SECTIONS)) if (!o.includes(k)) o.push(k); return o; }
  function crewBar() {
    return `<div class="cobar"><span class="sp"></span><button class="chipbtn" data-x="pick" title="Pick one of your shifts to swap or give away">${I.fwd}Swap or give away</button></div>`;
  }
  function viewStats() {
    if (!S.hist && !S.histBusy) setTimeout(loadHist);
    const log = allLog(), y = today.slice(0, 4), first = log.length ? log[0].date : today, reorder = S.statsReorder;
    const order = statOrder();
    const sec = (k, inner, sub) => `<section class="xc" data-stsec="${k}" data-card="${k}"><h3>${STAT_SECTIONS[k]}${sub ? `<span class="hsub">${sub}</span>` : ''}${reorder ? `<span class="ctl"><button data-x="stmove" data-k="${k}" data-v="-1" ${order.indexOf(k) === 0 ? 'disabled' : ''} aria-label="Move up">↑</button><button data-x="stmove" data-k="${k}" data-v="1" ${order.indexOf(k) === order.length - 1 ? 'disabled' : ''} aria-label="Move down">↓</button></span>` : ''}</h3>${reorder ? '' : inner()}</section>`;
    const parts = {
      perMonth: () => sec('perMonth', () => {
        const cur = ymOf(today), yms = [...new Set(log.map(s => ymOf(s.date)))].filter(ym => ym <= cur).sort().reverse();
        if (!yms.length) return '<div class="off">No shifts yet.</div>';
        return yms.slice(0, 48).map(ym => {
          const st = statsOf(log, ym + '-01', `${ym}-${daysIn(ym)}`), open = S.statsOpen.has(ym);
          return `<div class="stm ${open ? 'open' : ''}"><button class="stmh" data-x="stm" data-v="${ym}" aria-expanded="${open}"><b>${monthTitle(ym)}</b><span>${plural(st.count, 'shift')} · ${fmtH(st.hours)} h</span>${I.chev}</button>${open ? `<div class="stmb">${statsBody(st)}</div>` : ''}</div>`;
        }).join('');
      }),
      monthlyAvg: () => sec('monthlyAvg', () => statsBody(statsOf(log, first, today)), `since ${dYear(first)}`),
      ytd: () => sec('ytd', () => statsBody(statsOf(log, y + '-01-01', today)), `Jan 1 ${y} – today`),
      comingUp: () => sec('comingUp', () => {
        const fut = log.filter(s => s.date >= today), eoy = y + '-12-31', end = log.length ? log[log.length - 1].date : today;
        if (!fut.length) return '<div class="off">Nothing on the roster after today yet.</div>';
        const a = statsOf(fut, today, eoy), b = statsOf(fut, today, end), n = fut.find(notStarted) || fut[0];
        const byM = {}; fut.forEach(s => (byM[ymOf(s.date)] = byM[ymOf(s.date)] || []).push(s));
        return `<div class="cb2"><div><span>To end of ${y}</span><b>${plural(a.count, 'shift')}</b><small>${fmtH(a.hours)} h · by Dec 31</small></div><div><span>To roster end</span><b>${plural(b.count, 'shift')}</b><small>${fmtH(b.hours)} h · ends ${dYear(end)}</small></div></div>
          <div class="fine"><i class="udot" style="--u:${UNITS[n.unit].color}"></i>Next: ${uName(n.unit)} · ${dLong(n.date)} · ${n.start}–${n.end}</div>
          <div class="stbm">${Object.keys(byM).sort().map(ym => { const c = {}; byM[ym].forEach(s => c[s.unit] = (c[s.unit] || 0) + 1);
            return `<div><b>${MONTH[+ym.slice(5, 7) - 1]}${ym.slice(0, 4) !== y ? ' ' + ym.slice(0, 4) : ''}</b><span>${statsOf(byM[ym], ym + '-01', `${ym}-${daysIn(ym)}`).count}</span><span class="chips">${WHO_ORDER.filter(u => c[u]).map(u => `<span class="chip" style="--u:${UNITS[u].color}"><i class="udot"></i>${uName(u)} ${c[u]}</span>`).join('')}</span></div>`; }).join('')}</div>`;
      }),
      years: () => sec('years', () => {
        const ys = [...new Set(log.map(s => s.date.slice(0, 4)))].filter(x => x < y).sort().reverse();
        if (!ys.length) return S.histBusy ? '<div class="off">Reading your past years from Lightning Bolt…</div>' : `<div class="off">No earlier years read${S.histFailed ? ' — Lightning Bolt didn’t answer. Open this page again to retry.' : '.'}</div>`;
        const sel = ys.includes(S.statsYear) ? S.statsYear : ys[0];
        return `<div class="chips" style="margin-bottom:12px">${ys.map(x => `<button class="chip" data-x="styear" data-v="${x}" aria-pressed="${x === sel}">${x}</button>`).join('')}</div>${statsBody(statsOf(log, sel + '-01-01', sel + '-12-31'))}`;
      }),
      custom: () => sec('custom', () => `<div class="xr" style="border:0;padding-top:0"><input type="date" class="xin" data-xin="stFrom" value="${S.statsFrom}" aria-label="From"><span>to</span><input type="date" class="xin" data-xin="stTo" value="${S.statsTo}" aria-label="To"></div>
          ${S.statsFrom && S.statsTo && S.statsFrom <= S.statsTo ? statsBody(statsOf(log, S.statsFrom, S.statsTo)) : '<div class="off">Pick a start and an end date.</div>'}`),
    };
    let body = banners() + `<div class="cobar"><span class="fine" style="margin:0">${S.histBusy ? 'Reading your past years from Lightning Bolt…' : `${plural(log.length, 'shift')} on file since ${dYear(first)}`}${window.innerWidth > 760 ? ' · drag a card by its title to move it' : ''}</span><span class="sp"></span>
      <button class="chipbtn ghost" data-x="page2" data-v="export">${I.dl}Export</button><button class="chipbtn ${reorder ? 'primary' : ''}" data-x="streorder">${reorder ? 'Done' : 'Reorder'}</button></div>`;
    body += `<div class="stgrid mgrid" data-mgrid="stats">${order.map(k => parts[k]()).join('')}</div>`;
    return header('My Stats', DEMO ? 'Sample data' : esc(S.me || ''), '') + `<div class="view">${body}</div>`;
  }

  // ── Export: shift list (CSV / printable PDF), stats (PDF / CSV), and the .ics snapshot
  function exRange() {
    const y = today.slice(0, 4), log = allLog();
    if (S.exPeriod === 'all') return { from: log.length ? log[0].date : today, to: log.length ? log[log.length - 1].date : today, label: 'All time' };
    if (S.exPeriod === 'custom') return { from: S.exFrom, to: S.exTo, label: `${dYear(S.exFrom)} – ${dYear(S.exTo)}` };
    return { from: y + '-01-01', to: y + '-12-31', label: y };
  }
  function saveFile(name, text, type) {
    const blob = new Blob([text], { type });
    const a = document.createElement('a'); a.href = URL.createObjectURL(blob); a.download = name;
    document.body.appendChild(a); a.click(); setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 1000);
  }
  const csvCell = v => /[",\n]/.test(String(v)) ? `"${String(v).replace(/"/g, '""')}"` : String(v);
  function exShifts() { const r = exRange(); return allLog().filter(s => s.date >= r.from && s.date <= r.to); }
  function printDoc(title, inner) {
    const w = window.open('', '_blank');
    if (!w) { flash('Your browser blocked the print window — allow pop-ups for this page and try again.'); return; }
    w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${esc(title)}</title><style>
      body{font:12px/1.4 -apple-system,"Segoe UI",Roboto,Arial,sans-serif;color:#111F26;margin:28px 34px}
      h1{font-size:20px;margin:0 0 2px}.sub{color:#5A6D75;margin:0 0 18px}h2{font-size:12px;text-transform:uppercase;letter-spacing:.06em;color:#0F766E;margin:18px 0 6px;break-after:avoid}
      table{width:100%;border-collapse:collapse;font-variant-numeric:tabular-nums}td,th{padding:4px 6px;border-bottom:1px solid #E3E9EA;text-align:left}th{color:#5A6D75;font-weight:600}
      td.n,th.n{text-align:right}.dot{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px;vertical-align:0}
      .tiles{display:flex;gap:10px;margin:6px 0 10px}.tiles div{flex:1;border:1px solid #E3E9EA;border-radius:8px;padding:8px 10px}.tiles b{display:block;font-size:18px}.tiles span{color:#5A6D75;font-size:10px;text-transform:uppercase;letter-spacing:.05em}
      @media print{body{margin:0}}</style></head><body>${inner}<script>setTimeout(function(){window.print()},300)<\/script></body></html>`);
    w.document.close();
  }
  function exportAs(kind) {
    const r = exRange(), name = S.me || 'Me', gen = dYear(today);
    if (kind === 'ics') return downloadICS();
    if ((S.exPeriod !== 'year') && !S.hist && !DEMO) { loadHist().then(() => exportAs(kind)); return flash('Reading your past years first…'); }
    const list = exShifts();
    if (kind === 'csv') {
      const rows = [['Date', 'Weekday', 'Unit', 'Start', 'End', 'Hours', 'Overnight']].concat(list.map(s => [s.date, DAYL[dow(s.date)], UNITS[s.unit].short, s.start, s.end, f1(hoursOf(s)), s.ov ? 'Yes' : 'No']));
      return saveFile('shift-log.csv', rows.map(x => x.map(csvCell).join(',')).join('\r\n'), 'text/csv');
    }
    const st = statsOf(allLog(), r.from, r.to);
    if (kind === 'scsv') {
      const rows = [['Metric', 'Value'], ['Shifts', st.count], ['Hours', f1(st.hours)], ['Shifts/month', f1(st.count / st.months)], ['Hours/month', f1(st.hours / st.months)], [],
        ['Unit', 'Count', 'Hours']].concat(st.byUnit.map(u => [u.name, u.n, f1(u.h)]), [[], ['Length', 'Count']], st.byLen.map(l => [l.h + 'h', l.n]));
      return saveFile('my-stats.csv', rows.map(x => x.map(csvCell).join(',')).join('\r\n'), 'text/csv');
    }
    if (kind === 'pdf') {
      let h = `<h1>My shifts — ${esc(name)}</h1><p class="sub">${plural(list.length, 'shift')} · ${esc(r.label)} · generated ${gen}</p>`, last = '';
      for (const s of list) {
        if (ymOf(s.date) !== last) { if (last) h += '</table>'; last = ymOf(s.date); h += `<h2>${monthTitle(last)}</h2><table>`; }
        h += `<tr><td style="width:70px">${DAY[dow(s.date)]} ${+s.date.slice(8)}</td><td><span class="dot" style="background:${UNITS[s.unit].color}"></span>${UNITS[s.unit].short}</td><td>${s.start}–${s.end}</td><td class="n">${fmtH(hoursOf(s))} h</td></tr>`;
      }
      if (last) h += '</table>';
      return printDoc('My shifts', h);
    }
    if (kind === 'spdf') {
      const h = `<h1>My stats — ${esc(name)}</h1><p class="sub">${plural(st.count, 'shift')} · ${esc(r.label)} · generated ${gen}</p>
        <div class="tiles"><div><b>${st.count}</b><span>Shifts</span></div><div><b>${fmtH(st.hours)}</b><span>Hours</span></div><div><b>${f1(st.count / st.months)}</b><span>Shifts / month</span></div><div><b>${Math.round(st.hours / st.months)}</b><span>Hours / month</span></div></div>
        <h2>By unit</h2><table><tr><th>Unit</th><th class="n">Count</th><th class="n">Per month</th><th class="n">Hours</th></tr>${st.byUnit.map(u => `<tr><td><span class="dot" style="background:${u.color}"></span>${esc(u.name)}</td><td class="n">${u.n}</td><td class="n">${f1(u.n / st.months)}</td><td class="n">${Math.round(u.h)}</td></tr>`).join('')}</table>
        <h2>By length</h2><table><tr><th>Length</th><th class="n">Count</th></tr>${st.byLen.map(l => `<tr><td>${l.h}h</td><td class="n">${l.n}</td></tr>`).join('')}</table>
        <p class="sub" style="margin-top:14px">${plural(st.nights, 'overnight')} · ${st.weekends} weekend day${st.weekends === 1 ? '' : 's'}</p>`;
      return printDoc('My stats', h);
    }
  }
  function exportCard() {
    const r = exRange(), n = S.exPeriod === 'year' || S.hist || DEMO ? exShifts().length : null;
    return `<section class="xc" id="x-export"><h3>Export</h3>
      <div class="xr"><div class="l">Period</div>${segX('exPeriod', S.exPeriod, [['year', 'This year'], ['all', 'All time'], ['custom', 'Custom']])}</div>
      ${S.exPeriod === 'custom' ? `<div class="xr"><input type="date" class="xin" data-xin="exFrom" value="${S.exFrom}" aria-label="From"><span>to</span><input type="date" class="xin" data-xin="exTo" value="${S.exTo}" aria-label="To"></div>` : ''}
      <p class="xp">${n == null ? 'Your past years are read when you export.' : `${plural(n, 'shift')} · ${esc(r.label)}`}</p>
      <div class="xr"><div class="l">My shifts</div><div class="xbtns" style="margin:0"><button class="chipbtn" data-x="export" data-v="csv">${I.dl}Spreadsheet (CSV)</button><button class="chipbtn" data-x="export" data-v="pdf">Print / PDF</button></div></div>
      <div class="xr"><div class="l">Stats summary</div><div class="xbtns" style="margin:0"><button class="chipbtn" data-x="export" data-v="scsv">${I.dl}CSV</button><button class="chipbtn" data-x="export" data-v="spdf">Print / PDF</button></div></div>
      <div class="xr"><div class="l">Calendar file<small>A one-off .ics snapshot from last month on. For a calendar that keeps itself up to date, use Calendar sync.</small></div><button class="chipbtn" data-x="export" data-v="ics">${I.dl}.ics</button></div></section>`;
  }

  // ── Calendar sync: a private subscribe link the poller keeps filled (Supabase cal_subs)
  const FEED = t => `https://qbtnxkzpddexczhcvxre.supabase.co/storage/v1/object/public/calendars/${t}.ics`;
  async function calSubLoad(create) {
    if (DEMO) { S.calSub = create || S.calSub ? { token: '3f6c1a2e-demo-4b8e-9d1f-sample000000' } : null; S.calSubState = 'ok'; return rerender(true); }
    if (!S.emp) { S.calSubState = 'nosession'; return rerender(true); }
    S.calSubState = 'loading'; rerender(true);
    try {
      const rows = await supaGet(`/cal_subs?emp_id=eq.${encodeURIComponent(S.emp)}&select=emp_id,token,enabled`);
      if (rows.length && rows[0].token) S.calSub = { token: rows[0].token, enabled: rows[0].enabled !== false };
      else if (create) {
        const token = crypto.randomUUID();
        const r = await fetch(SUPA + '/cal_subs?on_conflict=emp_id', { method: 'POST', headers: { apikey: SUPA_KEY, Authorization: 'Bearer ' + SUPA_KEY, 'Content-Type': 'application/json', Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify({ emp_id: +S.emp, token }) });
        if (!r.ok) throw new Error(r.status);
        S.calSub = { token, enabled: true };
      }
      S.calSubState = 'ok';
    } catch (e) { S.calSubState = 'error'; }
    rerender(true);
  }
  function calSyncCard() {
    const st = S.calSubState, url = S.calSub && FEED(S.calSub.token);
    let h = `<section class="xc"><h3>Calendar sync</h3><p class="xp">Turns your roster into a live calendar feed. Subscribe once in Google or Apple Calendar and it updates itself — every new shift, swap and pickup appears automatically. Colour-tagged titles, 24-hour calls folded, Pasqua Rapid/MSU merged, just like Export.</p>`;
    if (st === 'nosession') h += `<div class="warnline">Sign in to Lightning Bolt first, so Working-Bolt knows whose roster to publish.</div><div class="xbtns"><button class="chipbtn" data-x="calsub" data-v="0">Try again</button></div>`;
    else if (st === 'error') h += `<div class="warnline">Couldn’t reach the server. Check your connection and try again.</div><div class="xbtns"><button class="chipbtn" data-x="calsub" data-v="${S.calSub ? 0 : 1}">Try again</button></div>`;
    else if (st === 'loading' || st === 'idle') h += '<div class="off">Checking for your link…</div>';
    else if (!url) h += `<div class="xbtns"><button class="chipbtn primary" data-x="calsub" data-v="1">Turn on — make my link</button></div>`;
    else h += `<div class="xr" style="border:0"><div class="l"><b>Your subscribe link</b><small>Private to you — the link contains a random token. Just turned on? Give it a few minutes to fill in the first time.</small></div></div>
      <div class="xlink"><code>${esc(url)}</code><button class="chipbtn primary" data-x="calcopy">Copy</button></div>
      <div class="xbtns"><a class="chipbtn" href="https://calendar.google.com/calendar/render?cid=${encodeURIComponent(url.replace(/^https:/, 'webcal:'))}" target="_blank" rel="noopener">Add to Google ${I.ext}</a><a class="chipbtn" href="${url.replace(/^https:/, 'webcal:')}">Add to Apple Calendar</a></div>
      <div class="xr"><div class="l"><b>Google Calendar</b><small>Google refreshes subscribed calendars on its own schedule — usually every 8–24 hours — so a brand-new shift can take up to a day to appear there. That’s a Google limit, not the app.</small></div></div>
      <div class="xr"><div class="l"><b>Apple Calendar</b><small>iPhone Settings → Calendar → Accounts → Add Account → Other → Add Subscribed Calendar → paste the link. Apple refreshes much faster than Google (you can set it to hourly).</small></div></div>`;
    return h + '</section>';
  }

  // ── Keep me signed in: the Lightning Bolt login, typed by the user, encrypted in this browser only.
  //    With Touch ID / Face ID the key comes from a passkey (WebAuthn PRF) — it can't be read without the fingerprint/face.
  //    Without it, the key sits in this browser's storage. Only ever sent to Lightning Bolt's own login, when its session ends.
  const b64 = buf => btoa(String.fromCharCode(...new Uint8Array(buf)));
  const unb64 = s => Uint8Array.from(atob(s), c => c.charCodeAt(0));
  function idb(op, val) {
    return new Promise((res, rej) => {
      const q = indexedDB.open('wb-keep', 1);
      q.onupgradeneeded = () => q.result.createObjectStore('k');
      q.onerror = () => rej(q.error);
      q.onsuccess = () => { const tx = q.result.transaction('k', op === 'get' ? 'readonly' : 'readwrite'), st = tx.objectStore('k');
        const r = op === 'get' ? st.get('key') : op === 'put' ? st.put(val, 'key') : st.delete('key'); r.onsuccess = () => res(r.result); r.onerror = () => rej(r.error); };
    });
  }
  async function prfKey(secret) {
    const base = await crypto.subtle.importKey('raw', secret, 'HKDF', false, ['deriveKey']);
    return crypto.subtle.deriveKey({ name: 'HKDF', hash: 'SHA-256', salt: new TextEncoder().encode('working-bolt-keep'), info: new Uint8Array(0) }, base, { name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
  }
  async function prfGet(rawId, salt) {
    const a = await navigator.credentials.get({ publicKey: { challenge: crypto.getRandomValues(new Uint8Array(32)), allowCredentials: [{ type: 'public-key', id: rawId }], userVerification: 'required', timeout: 60000, extensions: { prf: { eval: { first: salt } } } } });
    const r = a && a.getClientExtensionResults().prf; if (!r || !r.results || !r.results.first) throw new Error('noprf'); return r.results.first;
  }
  async function keepSave(mode, u, p) {
    let key, extra = {};
    if (mode === 'bio') {
      if (!window.PublicKeyCredential) throw new Error('noprf');
      const salt = crypto.getRandomValues(new Uint8Array(32));
      const cred = await navigator.credentials.create({ publicKey: { rp: { name: 'Working-Bolt' }, user: { id: crypto.getRandomValues(new Uint8Array(16)), name: 'Working-Bolt sign-in', displayName: 'Working-Bolt' },
        challenge: crypto.getRandomValues(new Uint8Array(32)), pubKeyCredParams: [{ type: 'public-key', alg: -7 }, { type: 'public-key', alg: -257 }],
        authenticatorSelection: { userVerification: 'required', residentKey: 'discouraged' }, timeout: 60000, extensions: { prf: { eval: { first: salt } } } } });
      const ext = cred.getClientExtensionResults ? cred.getClientExtensionResults() : {};
      if (!ext.prf || ext.prf.enabled === false) throw new Error('noprf');
      const secret = (ext.prf.results && ext.prf.results.first) || await prfGet(cred.rawId, salt);
      key = await prfKey(secret); extra = { cred: b64(cred.rawId), salt: b64(salt) };
      try { await idb('del'); } catch (e) {}
    } else {
      key = await crypto.subtle.generateKey({ name: 'AES-GCM', length: 256 }, false, ['encrypt', 'decrypt']);
      await idb('put', key);
    }
    const iv = crypto.getRandomValues(new Uint8Array(12));
    const ct = await crypto.subtle.encrypt({ name: 'AES-GCM', iv }, key, new TextEncoder().encode(JSON.stringify({ u, p })));
    store.set('keepBlob', Object.assign({ mode, iv: b64(iv), ct: b64(ct) }, extra));
    store.set('keepMode', mode); S.keepMode = mode;
  }
  async function keepLoad() {
    const b = store.get('keepBlob', null); if (!b) return null;
    const key = b.mode === 'bio' ? await prfKey(await prfGet(unb64(b.cred), unb64(b.salt))) : await idb('get');
    if (!key) return null;
    return JSON.parse(new TextDecoder().decode(await crypto.subtle.decrypt({ name: 'AES-GCM', iv: unb64(b.iv) }, key, unb64(b.ct))));
  }
  async function keepErase() { store.set('keepBlob', null); store.set('keepMode', 'off'); S.keepMode = 'off'; try { await idb('del'); } catch (e) {} }
  async function autoSignIn() {
    if (DEMO || S.keepMode === 'off' || (S.reauthAt && Date.now() - S.reauthAt < 5 * 60 * 1000)) return false;
    S.reauthAt = Date.now();
    let c = null; try { c = await keepLoad(); } catch (e) { return false; }
    if (!c || !c.u || !c.p) return false;
    let st = 0;
    try { const r = await fetch(LITE + '/api/v1/login', { method: 'POST', credentials: 'include', headers: { Accept: 'application/json', 'Content-Type': 'application/json' }, body: JSON.stringify({ login_name: c.u, login_pwd: c.p }) }); st = r.status; } catch (e) {}
    c = null;
    if (st === 401 || st === 403) S.keepNote = 'Lightning Bolt didn’t accept the saved login — has your password changed? Turn Keep me signed in off and on again in Settings.';
    return st === 200;
  }
  function keepCard() {
    const m = S.keepMode, f = S.keepForm;
    let h = `<section class="xc"><h3>Keep me signed in</h3><p class="xp">Lightning Bolt signs you out about once a week, and whenever your password changes. This saves your Lightning Bolt login in this browser only (encrypted, never sent anywhere but Lightning Bolt’s own sign-in) and signs you straight back in. With Touch ID / Face ID it asks for your fingerprint or face first; without, anyone using this browser could open Working-Bolt signed in. Pick one — turning one on turns the other off. Turn it off to erase the saved login.</p>
      <div class="xr"><div class="l">With Touch ID / Face ID<small>Uses a passkey on this device to lock the saved login.</small></div>${tog(m === 'bio' || f === 'bio', 'keepbio', 'Keep me signed in with Touch ID or Face ID')}</div>
      <div class="xr"><div class="l">Without</div>${tog(m === 'plain' || f === 'plain', 'keepplain', 'Keep me signed in without Touch ID or Face ID')}</div>`;
    if (f) h += `<form class="keepf" autocomplete="on" onsubmit="return false"><input class="xin" data-keepu autocomplete="username" placeholder="Lightning Bolt username" aria-label="Lightning Bolt username"><input class="xin" data-keepp type="password" autocomplete="current-password" placeholder="Password" aria-label="Lightning Bolt password">
      <div class="xbtns" style="justify-content:flex-end"><button type="button" class="chipbtn" data-x="keepx">Cancel</button><button type="button" class="chipbtn primary" data-x="keepsave">${f === 'bio' ? 'Save with Touch ID / Face ID' : 'Save'}</button></div>
      <div class="fine">Saved only in this browser. It’s checked the next time Lightning Bolt signs you out — if it’s wrong, you’ll see a note here.</div></form>`;
    if (S.keepNote) h += `<div class="warnline">${esc(S.keepNote)}</div>`;
    if (DEMO) h += '<div class="fine">Sample mode: nothing is saved or sent.</div>';
    return h + '</section>';
  }
  async function keepSubmit() {
    const u = (root.querySelector('[data-keepu]') || {}).value || '', pEl = root.querySelector('[data-keepp]'), p = pEl ? pEl.value : '';
    if (!u.trim() || !p) return flash('Type your Lightning Bolt username and password first.');
    const mode = S.keepForm;
    if (pEl) pEl.value = '';
    if (DEMO) { S.keepMode = mode; S.keepForm = null; rerender(true); return flash('Sample: turned on — nothing was saved.'); }
    try { await keepSave(mode, u.trim(), p); S.keepForm = null; S.keepNote = ''; flash(mode === 'bio' ? 'Saved — locked with Touch ID / Face ID.' : 'Saved in this browser.'); }
    catch (e) { S.keepNote = e && e.message === 'noprf' ? 'This browser can’t lock a saved login with Touch ID / Face ID. Use “Without”, or try Safari or Chrome on a device with a fingerprint reader or Face ID.' : 'Not saved — the Touch ID / Face ID step was cancelled or failed.'; }
    rerender(true);
  }

  // ── Who's On unit order
  function setWhoOrder(o) { WHO_ORDER.splice(0, WHO_ORDER.length, ...o); store.set('whoOrder', o); }

  // ── Hennie holiday: the next run of 4+ days off between worked days (post-call counts as worked)
  function nextHennie() {
    const worked = new Set(); let last = '';
    for (const s of S.mine) { worked.add(s.date); if (s.ov) worked.add(addDays(s.date, 1)); if (s.date > last) last = s.date; }
    if (!last) return null;
    let run = null;
    for (let d = today; d <= last; d = addDays(d, 1)) {
      if (!worked.has(d)) { if (!run) run = { start: d, n: 0 }; run.n++; }
      else { if (run && run.n >= 4) return { start: run.start, end: addDays(d, -1), days: run.n }; run = null; }
    }
    return null;
  }
  function hennieWidget() {
    const h = nextHennie();
    if (!h) return '<div class="off">No Hennie holiday on the horizon. Chin up — go pick one up. ☕️</div>';
    const inN = ord(h.start) - ord(today);
    return `<div class="meta" style="font-weight:700;color:var(--accent)">🌴 Next Hennie holiday</div>
      <div class="big">${h.days} <span style="font-size:16px;font-weight:650;color:var(--muted)">days off</span></div>
      <div class="meta">${dLong(h.start)} – ${dLong(h.end)}</div>
      <div class="meta">${inN <= 0 ? 'Starts today — enjoy it.' : inN === 1 ? 'Starts tomorrow' : `Starts in ${inN} days`}</div>`;
  }

  // ── pick one of my shifts to swap or give away (Crew → "Swap or give away")
  let pkEl = null;
  function pkOpen() {
    pkClose();
    const list = swappableMine();
    pkEl = document.createElement('div'); pkEl.className = 'sheetbg';
    let last = '', rows = '';
    for (const s of list) {
      if (ymOf(s.date) !== last) { last = ymOf(s.date); rows += `<h3>${monthTitle(last)}</h3>`; }
      const pq = s.unit === 'PRR' && S.mine.some(y => y.date === s.date && y.unit === 'MSU' && y.slot && !y.pending);
      rows += `<div class="xr"><span class="pill" style="--u:${UNITS[s.unit].color}">${pq ? 'Pasqua 24 h' : uName(s.unit)}</span><div class="l">${dLong(s.date)}<small>${pq ? 'Rapid + MSU' : hrsLabel(s)}</small></div>
        <div class="xbtns" style="margin:0"><button class="chipbtn" data-pk="swap" data-slot="${esc(s.slot)}">Swap</button><button class="chipbtn" data-pk="give" data-slot="${esc(s.slot)}">Give away</button></div></div>`;
    }
    pkEl.innerHTML = `<div class="sheet pk" role="dialog" aria-modal="true" aria-label="Swap or give away">
      <header><div><h2>Swap or give away</h2><div class="meta">Pick one of your shifts. Nothing is sent until you confirm.</div></div><button class="x" data-pkx aria-label="Close">${I.close}</button></header>
      <div class="sb">${rows || '<div class="off" style="padding:20px 0">No upcoming shifts you can swap or give away (ones already posted are under Pool → My posts).</div>'}</div></div>`;
    pkEl.addEventListener('click', e => {
      if (e.target === pkEl || e.target.closest('[data-pkx]')) return pkClose();
      const b = e.target.closest('[data-pk]'); if (!b) return;
      const slot = b.dataset.slot, k = b.dataset.pk; pkClose();
      if (k === 'swap') openSwap(slot); else openGive(slot);
    });
    root.appendChild(pkEl);
    const x = pkEl.querySelector('[data-pkx]'); if (x) x.focus();
  }
  function pkClose() { if (pkEl) { pkEl.remove(); pkEl = null; } }

  // ── Cafeteria tab (sidebar → Cafeteria; Today's widget → Full menu). Same Supabase menus as the app.
  const SUN = '<svg viewBox="0 0 24 24" width="14" height="14" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" aria-hidden="true"><circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M4.6 4.6 6 6M18 18l1.4 1.4M2.5 12h2M19.5 12h2M4.6 19.4 6 18M18 6l1.4-1.4"/></svg>';
  function viewCafe() {
    const iso = S.cafeDay || (S.cafeDay = today), has = (x, w) => (x.label || '').toLowerCase().includes(w);
    const seg = `<div class="seg sm" role="group" aria-label="Site" style="margin:0">${[['RGH', 'RGH'], ['PH', 'Pasqua']].map(([k, l]) => `<button data-cafe="${k}" aria-pressed="${S.cafeSite === k}">${l}</button>`).join('')}</div>`;
    let body = banners() + `<div class="cobar"><span class="sp"></span>${seg}
      <button class="chipbtn" data-x="cafed" data-v="-1" title="Previous day (←)" aria-label="Previous day">${I.back}</button><button class="chipbtn" data-x="cafed" data-v="0" ${iso === today ? 'disabled' : ''} title="Back to today (T)">Today</button><button class="chipbtn" data-x="cafed" data-v="1" title="Next day (→)" aria-label="Next day">${I.fwd}</button></div>`;
    body += `<div class="cfday"><b class="${iso === today ? 'now' : ''}">${DAYL[dow(iso)]}</b><span>${MONTH[+iso.slice(5, 7) - 1]} ${+iso.slice(8)}${iso === today ? ' · today' : ''}</span></div>`;
    if (S.cafe == null) body += '<div class="off">Checking the specials…</div>';
    else {
      const m = cafeMenu(iso, S.cafeSite);
      if (!m) body += `<div class="empty"><b>${S.cafeFailed ? 'Couldn’t reach the menu just now' : S.cafe.some(p => p.site === S.cafeSite) ? 'Nothing listed for this day' : 'No menu yet'}</b>${S.cafeFailed ? 'Check your connection, then come back to this page.' : 'Menus are captured from the hospital intranet. Check back soon.'}</div>`;
      else {
        const secs = (m.day.sections || []).map(x => ({ label: x.label || '', items: (x.items || []).filter(it => it && it.name) })).filter(x => x.items.length);
        // Lunch with its sides, then pizza, then soup, (anything else,) then supper with its sides. A side belongs to the
        // meal its label names ("Supper side"), else to the meal just before it, else to lunch.
        const isSup = x => has(x, 'supper') || has(x, 'dinner'), isLun = x => has(x, 'lunch');
        const meal = { lunch: { main: [], sides: [] }, supper: { main: [], sides: [] } }, pizza = [], soup = [], other = [];
        let last = null;
        for (const x of secs) {
          if (has(x, 'side')) { const k = isSup(x) ? 'supper' : isLun(x) ? 'lunch' : last || 'lunch'; meal[k].sides.push(x); continue; }
          if (isLun(x)) { meal.lunch.main.push(x); last = 'lunch'; }
          else if (isSup(x)) { meal.supper.main.push(x); last = 'supper'; }
          else if (has(x, 'pizza')) pizza.push(x);
          else if (has(x, 'soup')) soup.push(x);
          else other.push(x);
        }
        const rows = (xs, cls) => xs.flatMap(x => x.items).map(it => `<div class="cfr ${cls || ''}"><span>${esc(it.name)}</span>${it.price ? `<em>${esc(it.price)}</em>` : ''}</div>`).join('');
        const mealCard = (k, title, ic) => {
          const ml = meal[k]; if (!ml.main.length && !ml.sides.length) return '';
          const sides = ml.sides.length ? `<div class="cfside"><i>${ml.sides.flatMap(x => x.items).length > 1 ? 'Sides' : 'Side'}</i>${rows(ml.sides)}</div>` : '';
          return `<section class="xc feat cfmeal"><h3>${ic}${title}</h3>${rows(ml.main, 'cfmain')}${sides}</section>`;
        };
        const plain = x => `<section class="xc"><h3>${esc(x.label)}</h3>${rows([x])}</section>`;
        body += `<div class="cfp">${mealCard('lunch', 'Lunch', SUN)}${pizza.map(plain).join('')}${soup.map(plain).join('')}${other.map(plain).join('')}${mealCard('supper', 'Supper', MOON)}</div>`;
        body += `<p class="fine" style="margin-top:14px">Menu week ${m.week} of ${m.of} · prices as printed. It’s a rotating menu, so if today looks off, blame the kitchen.</p>`;
      }
    }
    return header('Cafeteria', S.cafeSite === 'PH' ? 'Pasqua' : 'RGH', '') + `<div class="view">${body}</div>`;
  }

  // ── Guide (Settings → More → How to use Working-Bolt). Web version of the app's guide. Crew-facing only: never list
  // owner/admin features here. Keep it current: anything crew can see or do on the web gets a line in the same change.
  const kb = x => `<kbd>${x}</kbd>`;
  const GUIDE = [
    ['Getting around', [
      ['Open it', `Sign in to Lightning Bolt as usual, then click the Working-Bolt bookmark. Click it again any time to bring Working-Bolt back; ${kb('Esc')} (or the LB button) takes you back to Lightning Bolt.`],
      ['Keyboard', `${kb('1')}–${kb('8')} switch tabs · ${kb('←')} ${kb('→')} previous / next month, week or day · ${kb('T')} back to today · ${kb('/')} find a colleague · ${kb('R')} refresh · ${kb('E')} edit layout · ${kb('?')} shows them all.`],
      ['Refreshing', 'It reads Lightning Bolt when you open it and again when you come back to the tab after a while. Press R to refresh by hand, wherever you are.'],
      ['Edit layout', 'Edit layout (sidebar) or E: click a block to pick it, drag it to move, pull an edge to resize, and set its text size or the whole page’s. Saved in this browser. Lock freezes it. Wide screens only.'],
    ]],
    ['Today', [
      ['Widgets', 'Your next shift, who’s on now, the doctors on call, your agenda, open shifts, the weather, this month, time off, your next Hennie holiday and the cafeteria. Customize to add, hide or drag them around; × hides one.'],
      ['Hennie holiday', 'Your next run of 4 or more days off in a row.'],
      ['Cafeteria', 'Today’s specials at RGH or Pasqua: lunch first, supper first after 2 pm. Full menu opens the Cafeteria tab.'],
    ]],
    ['Shift Pool', [
      ['All · For me · My posts', 'All = every shift posted on Lightning Bolt, including ones sent to a set list that leaves you out (marked “Not offered to you”: you can see them but not take them). For me = only the ones that don’t clash with your roster or a busy day. My posts = shifts you’ve offered, with Withdraw.'],
      ['Picking one up', 'Take it opens Lightning Bolt’s own accept page in a window here. Nothing is taken until you accept there. It shows in My Shifts as soon as Lightning Bolt has it.'],
      ['Clash labels', '“You’re on …”, “Post-call” or “Pre-call” means it overlaps or sits next to one of your shifts. “You’re busy” = a day you marked busy.'],
      ['Mini-calendars', 'Your shifts in colour, open shifts as orange squares. Click a square to jump to that shift.'],
      ['Swaps box', 'Swaps sent to you (Accept / Decline), the return half of a swap you sent (Take it), and swaps that didn’t go through (OK). Accept, Decline and Take it open Lightning Bolt’s own page: click the request there → Accept or Deny → Submit.'],
      ['Recently taken', 'Shifts picked up in the last 2 days and who took them, so a shift that vanished was taken, not lost. Turn it off in Settings.'],
    ]],
    ['My Shifts', [
      ['Your calendar', 'Months side by side; scroll for more. Colour = unit. 24-hour calls run into a faded post-call day. Orange square = an open shift you could take.'],
      ['Click a day', 'Opens the day panel: your shift with Give away… and Ask to swap…, who’s working that day (with an On-call doctors switch), and a busy note. ← → step through the days; drag the panel’s header to move it.'],
      ['Several days at once', 'Drag across days, or Shift / ⌘-click, to pick a run. Then mark them all busy, ask for them off in one request, or cancel pending requests together.'],
      ['Busy days', 'Click a day → type what’s on (optional) → Mark busy. The Pool then warns you before you take a shift that day. Kept in this browser only.'],
      ['Day off · Night off', 'On days past the published roster that you don’t work: Ask for the day off or Night off, with a confirm before anything is sent.'],
      ['Your own calendars', 'Add your calendar: paste a live link from Google, Apple or Outlook and its events show on your days. It re-reads itself every 30 minutes.'],
    ]],
    ['Swaps & give-aways', [
      ['Ask to swap', 'Every month the roster is out for, as mini calendars. Your shifts show their number of possible swaps (⇄ N); coloured squares mark the units you could swap into. Click a day to see who’s working it, then Ask to swap, Ask to pick up or Text. Change picks a different shift of yours.'],
      ['Give it away', 'To everyone eligible (it goes to the Pool) or to the people you pick. You can give away part of a shift. Note: only a scheduler can merge pieces back.'],
      ['From anywhere', 'Click your shift in My Shifts, hold (or right-click) it in Who’s On, or use Crew → Swap or give away.'],
      ['Text colleagues', 'Text one person, Text all on a day, or Text everyone free. Opens Messages on a Mac or iPhone; elsewhere the message is copied for you. Numbers are read when needed and never saved.'],
      ['Cancel an offer', 'Pool → My posts → Withdraw, or the day panel → Withdraw.'],
    ]],
    ['Who’s On', [
      ['The board', 'Units down the side, days running sideways. Swipe sideways on the trackpad, turn the mouse wheel, or grab and drag to move through the days (up/down trackpad swipes are ignored here; Scroll flips the wheel’s direction). Today and the arrows jump by week; the date box goes to any day.'],
      ['Find a colleague', 'Type a name (or press /) to highlight their shifts; click a name on the board to do the same.'],
      ['On call', 'On call (or D) adds each ICU’s intensivist with their number, who’s in CCU, and a row for tonight: the ICU intensivist on call (with 2nd call) and cardiology on call · STEMI. Unit desk and CCA call-room numbers sit in the unit labels.'],
      ['Hold your own shift', 'Press and hold (or right-click) one of your upcoming shifts → Find a swap or Give it away, for that exact shift.'],
      ['Buddy shifts', 'A new CCA learning the units shows under the unit they’re shadowing, with a dashed “buddy” tag. Buddy shifts aren’t worked shifts and can’t be swapped.'],
      ['Unit order', 'Settings → Who’s On order.'],
    ]],
    ['Crew', [
      ['Side by side', 'Add colleagues (tick several at once) to see only their shifts together. Days you’re all off are shaded.'],
      ['Board', 'Scroll, swipe or drag sideways through the next months; the arrows and Today jump by week.'],
      ['Swap or give away', 'Pick one of your shifts and go straight to Swap or Give away.'],
    ]],
    ['My Stats', [
      ['Your numbers', 'Month by month, monthly average, coming up, year to date, by year and a custom range. Drag a card by its title (or use Reorder) to arrange them; Export saves them.'],
    ]],
    ['Cafeteria', [
      ['The menu', 'The day’s specials at RGH or Pasqua with prices, in order: lunch with its sides, pizza, soup, then supper with its sides. ← → or the arrows step through the days, T comes back to today.'],
    ]],
    ['Settings', [
      ['Arrange the cards', 'Drag a card by its title to move it; Reset order puts them back.'],
      ['General', 'Open on (a tab, or where you left off), week starts on Sunday or Monday, and Appearance: system, light or dark.'],
      ['Shift Pool', 'Open the Pool on All or For me, show Recently taken, and when the My posts tab appears.'],
      ['Time off', 'New request: Time Off or Night Off, pick any mix of dates, add a reason, confirm. Your requests with their status; pending or approved ones can be cancelled.'],
      ['Notifications', 'Turn on to get the app’s alerts in this browser, even when Lightning Bolt isn’t open: Open: … (a new open shift), Swap offer · Offered to you · Swap back (aimed at you only) and Picked up: … (someone took a shift you gave away).'],
      ['Calendar sync', 'A private subscribe link for Google or Apple Calendar that keeps updating itself with new shifts, swaps and pickups.'],
      ['Export', 'This year, all time or a custom period: your shifts as a spreadsheet (CSV) or Print / PDF, your stats summary, or a one-off calendar file (.ics).'],
      ['Keep me signed in', 'Lightning Bolt signs you out about once a week. This saves your login in this browser only, encrypted, with or without Touch ID / Face ID, and signs you straight back in.'],
      ['Sign out', 'Erases the saved login from this browser and closes Working-Bolt.'],
    ]],
    ['Good to know', [
      ['Lightning Bolt stays in charge', 'Working-Bolt reads your roster with the session you’re already signed in with. Taking a shift always happens on Lightning Bolt’s own page, with your own click, and every send asks you first.'],
      ['What stays in this browser', 'Your settings, layout, busy days, picked colleagues and (if you turn it on) your saved login. Nothing else is kept.'],
      ['On your phone', 'Use the Working-Bolt app: it does all of this, plus notifications on your phone.'],
    ]],
  ];
  const gText = x => x.replace(/<[^>]+>/g, '').toLowerCase();
  function viewGuide() {
    const q = (S.guideQ || '').trim().toLowerCase();
    let shown = 0;
    const secs = GUIDE.map(([t, items]) => {
      const li = items.map(([a, b]) => { const on = !q || gText(`${t} ${a} ${b}`).includes(q); if (on) shown++; return `<li data-gt="${esc(gText(`${t} ${a} ${b}`))}" ${on ? '' : 'hidden'}><b>${esc(a)}</b><p>${b}</p></li>`; }).join('');
      const any = !q || items.some(([a, b]) => gText(`${t} ${a} ${b}`).includes(q));
      return `<section class="xc" ${any ? '' : 'hidden'}><h3>${esc(t)}</h3><ul>${li}</ul></section>`;
    }).join('');
    const body = banners() + `<div class="cobar"><button class="chipbtn ghost" data-x="page" data-v="">${I.back}Settings</button>
      <label class="search gdq">${I.search}<input type="search" placeholder="Search the guide" value="${esc(S.guideQ || '')}" data-gq aria-label="Search the guide"></label></div>
      <p class="xp">Everything Working-Bolt can do on the web, by tab. Most of it is a click away: a day, a shift, or a name.</p>
      <div class="xgrid gd">${secs}</div><div class="off gdnone" ${shown ? 'hidden' : ''} style="padding:18px 0">Nothing matches “<span data-gqe>${esc(S.guideQ || '')}</span>”.</div>`;
    return header('How to use Working-Bolt', 'Working-Bolt for the web', '') + `<div class="view">${body}</div>`;
  }
  function guideFilter(v) {
    S.guideQ = v; const q = v.trim().toLowerCase(); let shown = 0;
    root.querySelectorAll('.gd section').forEach(sec => {
      let n = 0; sec.querySelectorAll('li').forEach(li => { const on = !q || li.dataset.gt.includes(q); li.hidden = !on; if (on) n++; });
      sec.hidden = !n; shown += n;
    });
    const none = root.querySelector('.gdnone'); if (none) { none.hidden = !!shown; const e = none.querySelector('[data-gqe]'); if (e) e.textContent = v; }
  }
  app.addEventListener('input', e => { if (e.target.dataset && e.target.dataset.gq != null) guideFilter(e.target.value); });

  // ── Notifications. A browser can only get push messages through a service worker on the site that asks, and this runs on
  // Lightning Bolt's site, so turning them on opens a small Working-Bolt page (GitHub Pages) that asks the browser. Only your
  // Lightning Bolt id goes along (in the #hash, so it never reaches a server log) — to send you the alerts meant for you.
  const PUSH_PAGE = 'https://nvdberg.github.io/hacking-bolt/';
  function notifCard() {
    const on = store.get('pushOn', false);
    return `<section class="xc" id="x-notif"><h3>Notifications</h3>
      <p class="xp">The app’s alerts, in this browser: a new open shift, a swap or shift offered to you, a swap coming back, and someone picking up a shift you gave away. They arrive even when Lightning Bolt isn’t open.</p>
      <div class="xr"><div class="l">${on ? 'Turned on in this browser' : 'Turn on in this browser'}<small>Opens a small Working-Bolt page where your browser asks to allow notifications. Chrome, Edge, Firefox and Safari on a computer. On a phone, the app sends them.</small></div>
        <button class="chipbtn ${on ? '' : 'primary'}" data-x="push" data-v="${on ? 'off' : 'on'}">${on ? 'Turn off' : 'Turn on'}</button></div></section>`;
  }
  function pushToggle(v) {
    if (DEMO) return xAsk({ title: 'Notifications', okOnly: true, text: 'Sample data: nothing is turned on here. On the live version this opens a small Working-Bolt page where your browser asks to allow notifications.' });
    if (v === 'on' && !S.emp) return xAsk({ title: 'Notifications', okOnly: true, text: 'Working-Bolt hasn’t read your Lightning Bolt profile yet. Refresh (R), then try again.' });
    const w = window.open(PUSH_PAGE + '#push=' + (v === 'on' ? encodeURIComponent(S.emp) : 'off'), '_blank');
    if (!w) return flash('Your browser blocked the new tab. Allow pop-ups for this site, then try again.');
    store.set('pushOn', v === 'on'); rerender(true);
  }

  // ── Who's On: press and hold (or right-click) one of your own upcoming shifts → Find a swap / Give it away, as in the app.
  let wmEl = null, wmHold = null, wmSwallow = false;
  function wmClose() { if (wmEl) { wmEl.remove(); wmEl = null; } }
  function wmOpen(slot, x, y) {
    wmClose();
    const s = S.mine.find(m => String(m.slot) === String(slot)); if (!s) return;
    const pq = s.unit === 'MSU' ? S.mine.find(m => m.date === s.date && m.unit === 'PRR' && m.slot && !m.pending) : null;   // Pasqua Rapid + MSU go as one
    const use = (pq || s).slot;
    wmEl = document.createElement('div'); wmEl.className = 'wmenu'; wmEl.setAttribute('role', 'menu');
    wmEl.innerHTML = `<div class="wmh">Your ${esc(pq ? 'Pasqua 24 h' : UNITS[s.unit].short)} · ${fmtDay(s.date)}</div>
      <button role="menuitem" data-wm="swap">${I.refresh}Find a swap…</button><button role="menuitem" data-wm="give">${I.fwd}Give it away…</button>`;
    wmEl.addEventListener('click', e => { const b = e.target.closest('[data-wm]'); if (!b) return; wmClose(); if (b.dataset.wm === 'swap') openSwap(use); else openGive(use); });
    wmEl.addEventListener('keydown', e => {
      const bs = [...wmEl.querySelectorAll('button')], i = bs.indexOf(root.activeElement);
      if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); bs[(i + (e.key === 'ArrowDown' ? 1 : bs.length - 1)) % bs.length].focus(); }
    });
    root.appendChild(wmEl);
    const r = wmEl.getBoundingClientRect();
    wmEl.style.left = Math.max(8, Math.min(x, window.innerWidth - r.width - 8)) + 'px';
    wmEl.style.top = Math.max(8, Math.min(y, window.innerHeight - r.height - 8)) + 'px';
    wmEl.querySelector('button').focus();
  }
  app.addEventListener('pointerdown', e => {
    wmSwallow = false;
    if (dzOn || e.button !== 0) return;
    const b = e.target.closest('[data-wmine]'); if (!b) return;
    const x = e.clientX, y = e.clientY;
    b.classList.add('pressing');
    wmHold = { b, x, y, t: setTimeout(() => { b.classList.remove('pressing'); wmHold = null; wmSwallow = true; wmOpen(b.dataset.wmine, x, y); }, 520) };
  });
  const wmCancel = () => { if (wmHold) { clearTimeout(wmHold.t); wmHold.b.classList.remove('pressing'); wmHold = null; } };
  window.addEventListener('pointermove', e => { if (wmHold && Math.hypot(e.clientX - wmHold.x, e.clientY - wmHold.y) > 6) wmCancel(); });
  window.addEventListener('pointerup', wmCancel); window.addEventListener('pointercancel', wmCancel);
  window.addEventListener('pointerdown', e => { if (wmEl && !e.composedPath().includes(wmEl)) wmClose(); }, true);
  app.addEventListener('click', e => { if (wmSwallow && e.target.closest('[data-wmine]')) { e.preventDefault(); e.stopPropagation(); } wmSwallow = false; }, true);
  app.addEventListener('contextmenu', e => {
    if (dzOn) return;
    const b = e.target.closest('[data-wmine]'); if (!b) return;
    e.preventDefault(); wmCancel();
    let { clientX: x, clientY: y } = e;
    if (!x && !y) { const r = b.getBoundingClientRect(); x = r.left + 8; y = r.bottom + 4; }   // keyboard menu key
    wmOpen(b.dataset.wmine, x, y);
  });

  // ── Settings
  const SET_CARDS = ['general', 'pool', 'order', 'timeoff', 'calsync', 'export', 'notif', 'keep', 'help', 'about'];
  function setOrder() { const o = (S.setOrder || []).filter(k => SET_CARDS.includes(k)); for (const k of SET_CARDS) if (!o.includes(k)) o.push(k); return o; }
  function viewSettings() {
    if (S.setPage === 'timeoff') return viewTimeOff();
    if (S.setPage === 'guide') return viewGuide();
    if (S.calSubState === 'idle') setTimeout(() => calSubLoad(false));
    const tabsOpt = [['last', 'Where I left off']].concat(TABS.filter(t => t.id !== 'settings').map(t => [t.id, t.label]));
    const upTO = reqGroups().filter(g => g.end >= today && (g.status === 'pending' || g.status === 'approved'));
    const general = `<section class="xc"><h3>General</h3>
      <div class="xr"><div class="l">Open on</div><select data-xin="openTab" aria-label="Open on">${tabsOpt.map(([v, l]) => `<option value="${v}" ${S.openTab === v ? 'selected' : ''}>${esc(l)}</option>`).join('')}</select></div>
      <div class="xr"><div class="l">Week starts on</div>${segX('weekStart', S.weekStart, [[0, 'Sunday'], [1, 'Monday']])}</div>
      <div class="xr"><div class="l">Appearance</div><div class="seg sm" role="group">${['system', 'light', 'dark'].map(t => `<button data-themeset="${t}" aria-pressed="${S.theme === t}">${t[0].toUpperCase() + t.slice(1)}</button>`).join('')}</div></div></section>`;
    const pool = `<section class="xc"><h3>Shift Pool</h3>
      <div class="xr"><div class="l">Open the Pool on</div>${segX('poolDefault', S.poolDefault, [['all', 'All'], ['me', 'For me']])}</div>
      <div class="xr"><div class="l">Recently taken<small>Shifts picked up in the last 2 days, under the lists.</small></div>${tog(S.showTaken, 'showTaken', 'Recently taken')}</div>
      <div class="xr"><div class="l">My posts tab<small>Auto shows it when you’ve posted or given away a shift.</small></div>${segX('postsMode', S.postsMode, [['auto', 'Auto'], ['always', 'Always'], ['awaiting', 'Only when waiting']])}</div></section>`;
    const timeoff = `<section class="xc"><h3>Time off<button class="go" data-x="page" data-v="timeoff">Open →</button></h3>
      <p class="xp">${upTO.length ? `${plural(upTO.length, 'request')} coming up: ${upTO.slice(0, 3).map(g => `${esc(g.kind)} ${dateRuns(g.ids.map((_, i) => addDays(g.start, i)))}`).join(' · ')}` : 'No time off coming up.'}</p>
      <div class="xbtns"><button class="chipbtn primary" data-x="tonew2">${I.plus}New request</button><button class="chipbtn" data-x="page" data-v="timeoff">See all requests</button></div></section>`;
    const order = `<section class="xc"><h3>Who’s On order<button class="go" data-x="woreset">Reset</button></h3>${WHO_ORDER.map((u, i) => `<div class="xr wo"><span class="pill" style="--u:${UNITS[u].color}">${uName(u)}</span><div class="l">${UNITS[u].full}</div>
      <span class="ctl"><button data-x="wo" data-k="${u}" data-v="-1" ${i ? '' : 'disabled'} aria-label="Move ${uName(u)} up">↑</button><button data-x="wo" data-k="${u}" data-v="1" ${i < WHO_ORDER.length - 1 ? '' : 'disabled'} aria-label="Move ${uName(u)} down">↓</button></span></div>`).join('')}</section>`;
    const help = `<section class="xc"><h3>Help</h3>
      <div class="xr"><div class="l">How to use Working-Bolt<small>Every feature on the web, by tab. Searchable.</small></div><button class="chipbtn" data-x="page" data-v="guide">Open ›</button></div>
      <div class="xr"><div class="l">Keyboard shortcuts<small>Press ? anywhere to see them.</small></div><button class="chipbtn" data-act="keys">Show</button></div></section>`;
    const about = `<section class="xc"><h3>About</h3><p class="xp"><b style="color:var(--ink)">Working-Bolt for the web.</b> It reads your Lightning Bolt schedule in this tab and shows it the way the app does. Nothing changes in Lightning Bolt unless you confirm it — and taking a shift always happens on Lightning Bolt’s own page, with your own click.</p>
      <p class="xp">Your settings, layout and colleagues’ picks live in this browser only. Phone numbers are read when needed and never saved.</p>
      <div class="xr"><div class="l">Sign out<small>Erases this browser’s saved login and closes Working-Bolt.</small></div><button class="chipbtn danger" data-x="signout">Sign out</button></div></section>`;
    const cards = { general, pool, order, timeoff, calsync: calSyncCard(), export: exportCard(), notif: notifCard(), keep: keepCard(), help, about };
    const custom = (S.setOrder || []).length > 0;
    let body = banners() + (window.innerWidth > 760 ? `<div class="cobar"><span class="fine" style="margin:0">Drag a card by its title to move it.</span><span class="sp"></span>${custom ? '<button class="chipbtn ghost" data-x="setorder">Reset order</button>' : ''}</div>` : '');
    body += `<div class="xgrid mgrid" data-mgrid="settings">${setOrder().map(k => cards[k].replace(/<section\b/, `<section data-card="${k}"`)).join('')}</div>`;
    return header('Settings', DEMO ? 'Sample data' : esc(S.me || ''), '') + `<div class="view">${body}</div>`;
  }

  // ── events for everything above (own listeners, so the main one stays as it was)
  app.addEventListener('click', e => {
    const el = e.target.closest('[data-x]'); if (!el || el.disabled) return;
    const d = el.dataset, v = d.v;
    switch (d.x) {
      case 'page': S.setPage = v || null; if (v === 'cafe') S.cafeDay = today; if (v === 'guide') S.guideQ = ''; rerender(false); if (v === 'guide') { const i = root.querySelector('[data-gq]'); if (i && window.innerWidth > 760) i.focus(); } return;
      case 'cafepage': return setTab('cafe');
      case 'cafed': S.cafeDay = +v ? addDays(S.cafeDay || today, +v) : today; return rerender(true);
      case 'push': return pushToggle(v);
      case 'page2': S.tab = 'settings'; store.set('tab', 'settings'); S.setPage = null; rerender(false); setTimeout(() => { const x = root.querySelector('#x-export'); if (x) x.scrollIntoView({ block: 'start' }); }); return;
      case 'tonew2': S.setPage = 'timeoff'; S.toNew = { kind: 'Time Off', dates: [], note: '', ym: null }; return rerender(false);
      case 'set': {
        const k = d.k;
        if (k === 'weekStart') { S.weekStart = +v; store.set('weekStart', S.weekStart); S.crewLeft = null; }
        else if (k === 'tokind') { S.toNew.kind = v; }
        else if (k === 'exPeriod') { S.exPeriod = v; if (v === 'all') loadHist(); }
        else { S[k] = v; store.set(k, v); if (k === 'poolDefault') S.poolSeg = v; }
        return rerender(true);
      }
      case 'tog': {
        if (d.k === 'showTaken') { S.showTaken = !S.showTaken; store.set('showTaken', S.showTaken); return rerender(true); }
        if (d.k === 'keepbio' || d.k === 'keepplain') {
          const mode = d.k === 'keepbio' ? 'bio' : 'plain', on = S.keepMode === mode || S.keepForm === mode;
          if (on) { S.keepForm = null; if (S.keepMode === mode) { if (DEMO) S.keepMode = 'off'; else keepErase(); flash('Turned off — the saved login is erased.'); } }
          else { if (S.keepMode !== 'off') { if (DEMO) S.keepMode = 'off'; else keepErase(); } S.keepForm = mode; S.keepNote = ''; }
          rerender(true); if (S.keepForm) { const u = root.querySelector('[data-keepu]'); if (u) u.focus(); }
          return;
        }
        return;
      }
      case 'keepx': S.keepForm = null; return rerender(true);
      case 'keepsave': return keepSubmit();
      case 'wo': { const o = WHO_ORDER.slice(), i = o.indexOf(d.k), j = i + (+v); if (i < 0 || j < 0 || j >= o.length) return; [o[i], o[j]] = [o[j], o[i]]; setWhoOrder(o); rerender(true); const b = root.querySelector(`[data-x="wo"][data-k="${d.k}"][data-v="${v}"]:not(:disabled)`); if (b) b.focus(); return; }
      case 'woreset': setWhoOrder(['RR', 'SICU', 'MICU', 'CCU', 'PHICU', 'PRR', 'MSU']); return rerender(true);
      case 'calsub': return calSubLoad(v === '1');
      case 'calcopy': { const url = S.calSub && FEED(S.calSub.token); if (!url) return; (navigator.clipboard ? navigator.clipboard.writeText(url) : Promise.reject()).then(() => flash('Link copied.'), () => flash('Select the link and copy it.')); return; }
      case 'export': return exportAs(v);
      case 'signout': return xAsk({ title: 'Sign out?', yes: 'Sign out', danger: true,
        text: 'Erases the login saved in this browser (Keep me signed in) and closes Working-Bolt. To sign out of Lightning Bolt itself, use its own menu.',
        onYes: async () => { AUTH = ''; if (!DEMO) await keepErase(); else S.keepMode = 'off'; setTimeout(hide, 50); return { text: 'Signed out of Working-Bolt.' }; } });
      case 'crewseg': S.crewSeg = v; store.set('crewSeg', v); if (v === 'stats') loadHist(); return rerender(false);
      case 'pick': return pkOpen();
      case 'withdraw': return withdrawPost(d.slot);
      case 'noto': return xAsk({ title: 'Unable to accept', okOnly: true, text: 'Not offered to you — Lightning Bolt sent this one to a set list of people. It’s here so you can see what’s out there.' });
      case 'swacc': case 'swdec': case 'swback': case 'swret': case 'swok': return swapAct(d.x, d.slot);
      case 'tonew': S.toNew = { kind: 'Time Off', dates: [], note: '', ym: null }; return rerender(true);
      case 'tonewx': S.toNew = null; return rerender(true);
      case 'tonav': S.toNew.ym = addMonths(S.toNew.ym, +v); return rerender(true);
      case 'todate': { const N = S.toNew, i = N.dates.indexOf(d.d); if (i >= 0) N.dates.splice(i, 1); else N.dates.push(d.d); return rerender(true); }
      case 'toreview': return toReview();
      case 'tocancel': return toCancel(d.i);
      case 'stm': if (S.statsOpen.has(v)) S.statsOpen.delete(v); else S.statsOpen.add(v); return rerender(true);
      case 'setorder': S.setOrder = []; store.set('setOrder', []); return rerender(true);
      case 'streorder': S.statsReorder = !S.statsReorder; return rerender(true);
      case 'stmove': { const o = statOrder(), i = o.indexOf(d.k), j = i + (+v); if (j < 0 || j >= o.length) return; [o[i], o[j]] = [o[j], o[i]]; S.statsOrder = o; store.set('statsOrder', o); return rerender(true); }
      case 'styear': S.statsYear = v; return rerender(true);
    }
  });
  app.addEventListener('change', e => {
    const k = e.target.dataset && e.target.dataset.xin; if (!k) return;
    const val = e.target.value;
    if (k === 'openTab') { S.openTab = val; store.set('openTab', val); return flash(val === 'last' ? 'Working-Bolt opens where you left off.' : `Working-Bolt opens on ${(TABS.find(t => t.id === val) || {}).label}.`); }
    if (k === 'stFrom') S.statsFrom = val; else if (k === 'stTo') S.statsTo = val;
    else if (k === 'exFrom') S.exFrom = val; else if (k === 'exTo') { S.exTo = val; }
    else return;
    if ((k === 'exFrom' || k === 'exTo') && S.exFrom < today.slice(0, 4)) loadHist();
    rerender(true);
  });
  app.addEventListener('input', e => { const k = e.target.dataset && e.target.dataset.xin; if (k === 'tonote' && S.toNew) S.toNew.note = e.target.value; });

  // ───────────────────────────── layout editor ─────────────────────────────
  // "Edit layout" (E): click any block to pick it, drag it anywhere, pull its edges to resize, change its text size,
  // or the whole page's. Saved in this browser as you go; Export gives a file to keep / hand back so the layout can be
  // baked into Working-Bolt for everyone. Lock keeps the layout and stops edits. Wide screens only (phones keep the stock layout).
  let DZ = Object.assign({ v: 1, scale: 1, locked: false, b: {} }, store.get('design', {}));
  let dzOn = false, dzSel = null, dzHov = null, dzMap = new Map(), dzUndo = [], dzEl = null, dzPanelTop = false;
  const DZ_KEYS = ['ym', 'w', 'day', 'tab', 'scroll', 'seg', 'act', 'open', 'pday'];
  const dzWide = () => window.innerWidth > 760;
  function dzSave() { store.set('design', DZ); }
  function dzPush() { dzUndo.push(JSON.stringify(DZ)); if (dzUndo.length > 80) dzUndo.shift(); }
  function dzWalk() {                       // a stable name for every element: tab / tag.class[data-id or :nth] / …
    const map = new Map();
    const walk = (el, pre) => {
      const seen = {};
      for (const c of el.children) {
        let sig = c.tagName.toLowerCase() + (c.classList[0] ? '.' + c.classList[0] : '');
        const id = DZ_KEYS.find(k => c.dataset && c.dataset[k] != null);
        if (id) sig += `[${id}=${c.dataset[id]}]`;
        else { const n = seen[sig] = (seen[sig] || 0) + 1; if (n > 1) sig += ':' + n; }
        const k = (pre == null ? (c.classList.contains('side') ? '*' : S.tab) : pre) + '/' + sig;
        map.set(k, c); c.__dzk = k;
        if (c.tagName !== 'svg') walk(c, k);
      }
    };
    walk(app, null);
    return map;
  }
  const dzName = k => { const p = (k || '').split('/'); const last = p[p.length - 1] || ''; return (p[0] === '*' ? 'sidebar · ' : '') + last.replace(/^(\w+)\.?/, (m, t) => m.length > t.length ? '' : t).replace(/\[(\w+)=([^\]]+)\]/, ' $2').replace(/:(\d+)$/, ' #$1').replace(/-/g, ' '); };
  function applyDesign() {
    app.style.zoom = dzWide() && DZ.scale !== 1 ? DZ.scale : '';
    app.classList.toggle('dzon', dzOn);
    const keys = Object.keys(DZ.b);
    dzMap = keys.length || dzOn ? dzWalk() : new Map();
    if (dzWide()) {
      const fs = [];
      for (const k of keys) {
        const el = dzMap.get(k), o = DZ.b[k]; if (!el) continue;
        if (o.x || o.y) { el.style.translate = `${o.x || 0}px ${o.y || 0}px`; if (getComputedStyle(el).position === 'static') el.style.position = 'relative'; el.style.zIndex = 3; }
        if ((o.w || o.h) && !(o.x || o.y)) { if (getComputedStyle(el).position === 'static') el.style.position = 'relative'; el.style.zIndex = 2; }
        if (o.w) { el.style.width = o.w + 'px'; el.style.maxWidth = 'none'; el.style.minWidth = '0'; el.style.flex = 'none'; el.style.boxSizing = 'border-box'; }
        if (o.h) { el.style.height = o.h + 'px'; el.style.minHeight = '0'; el.style.maxHeight = 'none'; el.style.overflow = 'auto'; el.style.boxSizing = 'border-box'; }
        if (o.fs && o.fs !== 1) fs.push([el, o.fs]);
      }
      // text size: read every element's own size first, then scale (so nested picks don't compound)
      const sub = el => [el, ...el.querySelectorAll('*')];
      for (const [el] of fs) for (const x of sub(el)) x.style.fontSize = '';
      const base = new Map();
      for (const [el] of fs) for (const x of sub(el)) if (!base.has(x)) base.set(x, parseFloat(getComputedStyle(x).fontSize) || 14);
      for (const [el, f] of fs) for (const x of sub(el)) x.style.fontSize = (base.get(x) * f).toFixed(2) + 'px';
    }
    dzDraw();
  }
  function dzBlock(t) {
    let el = t && t.nodeType === 1 ? t : t && t.parentElement;
    while (el && el !== app && (el.closest('svg') && el.tagName !== 'svg' || !el.__dzk || getComputedStyle(el).display === 'inline' || el.offsetWidth < 14 || el.offsetHeight < 10)) el = el.parentElement;
    return el && el !== app ? el : null;
  }
  const dzEls = () => ({ sel: dzSel && dzMap.get(dzSel), hov: dzHov && dzMap.get(dzHov) });
  function dzToggle(on) {
    dzOn = on == null ? !dzOn : on;
    if (dzOn && DZ.locked) { DZ.locked = false; dzSave(); }
    if (!dzOn) { dzSel = dzHov = null; if (root.activeElement) root.activeElement.blur && root.activeElement.blur(); }
    if (dzOn && !dzWide()) { dzOn = false; flash('Layout editing needs a wider window.'); }
    rerender(true);
  }
  function dzDraw() {
    if (!dzOn) { if (dzEl) { dzEl.remove(); dzEl = null; } return; }
    if (!dzEl) {
      dzEl = document.createElement('div'); dzEl.className = 'dz';
      dzEl.addEventListener('pointerdown', dzHandleDown);
      dzEl.addEventListener('click', dzPanelClick);
      dzEl.addEventListener('change', e => { if (e.target.dataset.dzfile != null && e.target.files[0]) dzImport(e.target.files[0]); });
      root.appendChild(dzEl);
    }
    const { sel, hov } = dzEls(), o = (dzSel && DZ.b[dzSel]) || {};
    const box = (el, cls, inner) => { if (!el || !el.isConnected) return ''; const r = el.getBoundingClientRect(); return `<div class="${cls}" style="left:${r.left}px;top:${r.top}px;width:${r.width}px;height:${r.height}px">${inner || ''}</div>`; };
    let h = hov && hov !== sel ? box(hov, 'dzhov') : '';
    if (sel) {
      const r = sel.getBoundingClientRect();
      h += box(sel, 'dzbox', `<span class="dztag ${r.top < 30 ? 'in' : ''}">${esc(dzName(dzSel))} · ${Math.round(r.width / (DZ.scale || 1))}×${Math.round(r.height / (DZ.scale || 1))}</span>` + ['n', 's', 'e', 'w', 'ne', 'nw', 'se', 'sw'].map(d => `<i class="dzh" data-dzh="${d}"></i>`).join(''));
    }
    const pct = f => Math.round((f || 1) * 100) + '%';
    const changed = Object.keys(DZ.b).length, onTab = Object.keys(DZ.b).filter(k => k.startsWith(S.tab + '/')).length;
    h += `<div class="dzpanel ${dzPanelTop ? 'top' : ''}" role="toolbar" aria-label="Layout editor">
      <span class="dzt">Edit layout</span>
      ${sel ? `<span class="grp"><b>${esc(dzName(dzSel))}</b>
        <button data-dz="parent" title="Pick the block around it ( [ or ⌥-click )">Bigger block</button>
        <span class="lbl">Text</span><button data-dz="fs-" title="Smaller text (−)">A−</button><span class="v">${pct(o.fs)}</span><button data-dz="fs+" title="Bigger text (+)">A+</button>
        ${o.w || o.h ? '<button data-dz="fit" title="Back to its natural size">Natural size</button>' : ''}
        <button data-dz="reset" title="Undo everything on this block (Delete)">Reset block</button></span>`
      : '<span class="hint">Click any block to pick it · drag to move · pull an edge to resize · arrows nudge</span>'}
      <span class="grp"><span class="lbl">Page text</span><button data-dz="pz-">−</button><span class="v">${pct(DZ.scale)}</span><button data-dz="pz+">+</button></span>
      <span class="grp"><button data-dz="undo" ${dzUndo.length ? '' : 'disabled'} title="Undo (⌘Z)">Undo</button>
        <button data-dz="resettab" ${onTab ? '' : 'disabled'} title="Reset every change on this page">Reset page</button>
        <button data-dz="export" ${changed || DZ.scale !== 1 ? '' : 'disabled'} title="Download the layout as a file (and copy it)">Export</button>
        <button data-dz="import" title="Load a layout file">Import</button><input type="file" accept=".json,application/json" data-dzfile hidden>
        <button data-dz="flip" title="Move this bar ${dzPanelTop ? 'down' : 'up'}">${dzPanelTop ? '↓' : '↑'}</button>
        <button data-dz="lock" class="pri" title="Keep this layout and stop editing">Lock layout</button>
        <button data-dz="done" title="Stop editing (Esc) — changes stay">Done</button></span>
    </div>`;
    dzEl.innerHTML = h;
  }
  let dzRaf = 0; const dzRedraw = () => { if (dzOn && !dzRaf) dzRaf = requestAnimationFrame(() => { dzRaf = 0; dzDraw(); }); };
  root.addEventListener('scroll', dzRedraw, true);
  window.addEventListener('resize', dzRedraw);
  function dzSet(k, patch) {
    const o = Object.assign({}, DZ.b[k] || {}, patch);
    for (const f of Object.keys(o)) if (!o[f] || (f === 'fs' && Math.abs(o.fs - 1) < 0.001)) delete o[f];
    if (Object.keys(o).length) DZ.b[k] = o; else delete DZ.b[k];
    dzSave();
  }
  // picking / moving: capture everything inside the app while editing, so nothing in the app reacts
  for (const ev of ['click', 'dblclick', 'mousedown', 'mouseup', 'dragstart', 'submit', 'contextmenu'])
    app.addEventListener(ev, e => { if (dzOn) { e.preventDefault(); e.stopPropagation(); } }, true);
  app.addEventListener('pointermove', e => {
    if (!dzOn || dzDrag) return;
    const b = dzBlock(e.target), k = b && b.__dzk;
    if (k !== dzHov) { dzHov = k; dzDraw(); }
  }, true);
  app.addEventListener('pointerleave', () => { if (dzOn && dzHov) { dzHov = null; dzDraw(); } });
  let dzDrag = null;
  app.addEventListener('pointerdown', e => {
    if (!dzOn || e.button !== 0) return;
    e.preventDefault(); e.stopPropagation();
    const { sel } = dzEls();
    let el = sel && sel.contains(e.target) ? sel : dzBlock(e.target);
    if (e.altKey && el) el = dzBlock(el.parentElement) || el;
    if (!el) return;
    const o = DZ.b[el.__dzk] || {};
    dzDrag = { mode: 'move', el, k: el.__dzk, sx: e.clientX, sy: e.clientY, x0: o.x || 0, y0: o.y || 0, moved: false, pick: e.altKey ? el.__dzk : (dzBlock(e.target) || el).__dzk };
    if (getComputedStyle(el).position === 'static') el.style.position = 'relative';
  }, true);
  function dzHandleDown(e) {
    const hd = e.target.closest('[data-dzh]'); if (!hd) return;
    const { sel } = dzEls(); if (!sel) return;
    e.preventDefault(); e.stopPropagation();
    const r = sel.getBoundingClientRect(), o = DZ.b[dzSel] || {}, z = DZ.scale || 1;
    dzDrag = { mode: 'size', dir: hd.dataset.dzh, el: sel, k: dzSel, sx: e.clientX, sy: e.clientY, x0: o.x || 0, y0: o.y || 0, w0: r.width / z, h0: r.height / z, moved: false };
    dzPush();
  }
  window.addEventListener('pointermove', e => {
    if (!dzDrag) return;
    const z = DZ.scale || 1, dx = (e.clientX - dzDrag.sx) / z, dy = (e.clientY - dzDrag.sy) / z;
    if (!dzDrag.moved && Math.hypot(dx, dy) < 4) return;
    if (!dzDrag.moved) { dzDrag.moved = true; if (dzDrag.mode === 'move') { dzPush(); dzSel = dzDrag.k; } }
    const d = dzDrag, el = d.el;
    const snap = v => e.shiftKey ? v : Math.round(v / 4) * 4;   // 4-px grid; hold Shift for free movement
    if (d.mode === 'move') { d.x = snap(d.x0 + dx); d.y = snap(d.y0 + dy); el.style.translate = `${d.x}px ${d.y}px`; el.style.zIndex = 3; }
    else {
      const dir = d.dir; d.patch = {};
      if (dir.includes('e')) d.patch.w = Math.max(24, snap(d.w0 + dx));
      if (dir.includes('w')) { d.patch.w = Math.max(24, snap(d.w0 - dx)); d.patch.x = d.x0 + (d.w0 - d.patch.w); }
      if (dir.includes('s')) d.patch.h = Math.max(16, snap(d.h0 + dy));
      if (dir.includes('n')) { d.patch.h = Math.max(16, snap(d.h0 - dy)); d.patch.y = d.y0 + (d.h0 - d.patch.h); }
      if (d.patch.w) { el.style.width = d.patch.w + 'px'; el.style.maxWidth = 'none'; el.style.minWidth = '0'; el.style.flex = 'none'; el.style.boxSizing = 'border-box'; }
      if (d.patch.h) { el.style.height = d.patch.h + 'px'; el.style.minHeight = '0'; el.style.maxHeight = 'none'; el.style.overflow = 'auto'; el.style.boxSizing = 'border-box'; }
      if (d.patch.x != null || d.patch.y != null) el.style.translate = `${d.patch.x != null ? d.patch.x : d.x0}px ${d.patch.y != null ? d.patch.y : d.y0}px`;
    }
    dzRedraw();
  });
  window.addEventListener('pointerup', () => {
    const d = dzDrag; if (!d) return; dzDrag = null;
    if (!d.moved) { if (d.mode === 'move') { dzSel = d.pick; dzDraw(); } return; }
    if (d.mode === 'move') dzSet(d.k, { x: d.x, y: d.y }); else dzSet(d.k, d.patch);
    dzSel = d.k; applyDesign();
  });
  function dzAct(a) {
    const k = dzSel, o = (k && DZ.b[k]) || {};
    if (a === 'parent') { const { sel } = dzEls(); const p = sel && dzBlock(sel.parentElement); if (p) dzSel = p.__dzk; return dzDraw(); }
    if (a === 'child') { const { sel } = dzEls(); const c = sel && [...sel.children].find(x => x.__dzk && x.offsetWidth >= 14 && x.offsetHeight >= 10); if (c) dzSel = c.__dzk; return dzDraw(); }
    if (a === 'fs+' || a === 'fs-') { if (!k) return; dzPush(); dzSet(k, { fs: Math.max(0.5, Math.min(3, Math.round(((o.fs || 1) + (a === 'fs+' ? 0.05 : -0.05)) * 100) / 100)) }); return rerender(true); }
    if (a === 'pz+' || a === 'pz-') { dzPush(); DZ.scale = Math.max(0.7, Math.min(1.6, Math.round(((DZ.scale || 1) + (a === 'pz+' ? 0.05 : -0.05)) * 100) / 100)); dzSave(); return rerender(true); }
    if (a === 'fit') { if (!k) return; dzPush(); dzSet(k, { w: 0, h: 0 }); return rerender(true); }
    if (a === 'reset') { if (!k) return; dzPush(); delete DZ.b[k]; dzSave(); return rerender(true); }
    if (a === 'resettab') { dzPush(); for (const x of Object.keys(DZ.b)) if (x.startsWith(S.tab + '/')) delete DZ.b[x]; dzSave(); return rerender(true); }
    if (a === 'undo') { const u = dzUndo.pop(); if (!u) return; DZ = JSON.parse(u); dzSave(); return rerender(true); }
    if (a === 'export') return dzExport();
    if (a === 'import') { const f = dzEl && dzEl.querySelector('[data-dzfile]'); if (f) f.click(); return; }
    if (a === 'flip') { dzPanelTop = !dzPanelTop; return dzDraw(); }
    if (a === 'lock') { DZ.locked = true; dzSave(); dzOn = false; dzSel = dzHov = null; rerender(true); return flash('Layout locked. “Edit layout” in the sidebar unlocks it.'); }
    if (a === 'done') return dzToggle(false);
  }
  function dzPanelClick(e) { const b = e.target.closest('[data-dz]'); if (b && !b.disabled) dzAct(b.dataset.dz); }
  function dzKey(e) {                        // true = handled
    const mod = e.metaKey || e.ctrlKey;
    if (e.key === 'Escape') { e.preventDefault(); if (dzSel) { dzSel = null; dzDraw(); } else dzToggle(false); return true; }
    if (mod && (e.key === 'z' || e.key === 'Z')) { e.preventDefault(); dzAct('undo'); return true; }
    if (mod) return false;
    if (e.key === '[') { dzAct('parent'); return true; }
    if (e.key === ']') { dzAct('child'); return true; }
    if (e.key === '+' || e.key === '=') { dzAct('fs+'); return true; }
    if (e.key === '-' || e.key === '_') { dzAct('fs-'); return true; }
    if ((e.key === 'Delete' || e.key === 'Backspace') && dzSel) { e.preventDefault(); dzAct('reset'); return true; }
    const arr = { ArrowLeft: [-1, 0], ArrowRight: [1, 0], ArrowUp: [0, -1], ArrowDown: [0, 1] }[e.key];
    if (arr && dzSel) {
      e.preventDefault(); const st = e.shiftKey ? 10 : 1, o = DZ.b[dzSel] || {};
      if (!e.repeat) dzPush();
      dzSet(dzSel, { x: (o.x || 0) + arr[0] * st, y: (o.y || 0) + arr[1] * st }); applyDesign(); return true;
    }
    if (e.key === 'e' || e.key === 'E') { dzToggle(false); return true; }
    return !!arr;
  }
  function dzExport() {
    const out = { app: 'Working-Bolt web', kind: 'layout', v: 1, saved: new Date().toISOString(), screen: `${window.innerWidth}×${window.innerHeight}`, scale: DZ.scale, blocks: DZ.b };
    const txt = JSON.stringify(out, null, 2);
    try { navigator.clipboard && navigator.clipboard.writeText(txt); } catch (e) {}
    const a = document.createElement('a');
    a.href = URL.createObjectURL(new Blob([txt], { type: 'application/json' }));
    a.download = `working-bolt-layout-${today}.json`; root.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 5000);
    flash('Layout saved to Downloads (and copied).');
  }
  function dzImport(file) {
    const r = new FileReader();
    r.onload = () => {
      try {
        const j = JSON.parse(r.result); if (!j || typeof j.blocks !== 'object') throw 0;
        dzPush(); DZ = { v: 1, scale: +j.scale || 1, locked: false, b: j.blocks }; dzSave(); rerender(true); flash('Layout loaded.');
      } catch (e) { flash('That file isn’t a Working-Bolt layout.'); }
    };
    r.readAsText(file);
  }

  // ───────────────────────────── events ─────────────────────────────
  function rerender(keepScroll) {
    const v = root.querySelector('.view'), y = v ? v.scrollTop : 0;
    const f = root.activeElement && root.activeElement.dataset && root.activeElement.dataset.input;
    const pos = f ? root.activeElement.selectionStart : null;
    render();
    if (keepScroll) { const v2 = root.querySelector('.view'); if (v2) v2.scrollTop = y; }
    if (f) { const el = root.querySelector(`[data-input="${f}"]`); if (el) { el.focus(); try { el.setSelectionRange(pos, pos); } catch (e) {} } }
  }
  function setTab(t) { wmClose(); if (t !== 'mine') closeDay(); S.tab = t; store.set('tab', t); if (t === 'settings') S.setPage = ''; if (t === 'who') S.whoGo = addDays(today, -2); if (t === 'crew') S.crewGo = weekStartOf(today); if (t === 'cafe') S.cafeDay = today; if (t === 'mine') { S.msGo = ymOf(today); S.msTop = null; } rerender(false); }
  function shift(dir) {
    if (S.tab === 'mine') { const [a, b] = msRange(), ym = addMonths(S.msMonth, dir); if (ym >= a && ym <= b) msScrollTo(ym, true); return; }
    else if (S.tab === 'who') { const w = root.querySelector('.wweek'), c = w && w.querySelector('.wh'); if (w && c) w.scrollBy({ left: dir * 7 * c.getBoundingClientRect().width, behavior: 'smooth' }); return; }
    else if (S.tab === 'crew') { const w = root.querySelector('.crewtab'), c = w && w.querySelector('thead th[data-day]'); if (w && c) w.scrollBy({ left: dir * 7 * c.getBoundingClientRect().width, behavior: 'smooth' }); return; }
    rerender(S.tab !== 'mine');
  }
  function toToday() {
    if (S.tab === 'mine') return msScrollTo(ymOf(today), true);
    else if (S.tab === 'who') { S.whoDate = null; return whoScrollTo(addDays(today, -2), true); }
    else if (S.tab === 'crew') return crewScrollTo(weekStartOf(today), true);
    rerender(false);
  }
  app.addEventListener('click', e => {
    if (mSwallow) { mSwallow = false; return; }   // the click that ends a drag-pick
    if (S.crewOpen && !e.target.closest('.cpick')) { S.crewOpen = false; S.crewQuery = ''; rerender(true); }
    // a click on empty page space (not a day, not a control) closes the day panel, like its × button
    if (dayEl && !dzOn && e.target.closest('.main') && !e.target.closest('.cell[data-day],button,a,input,select,textarea,label,summary,[data-day],[role="button"],[tabindex]') && !String(window.getSelection && window.getSelection() || '')) closeDay();
    const el = e.target.closest('[data-crewtog],[data-crewact],[data-tab],[data-act],[data-seg],[data-unit],[data-open],[data-jump],[data-themeset],[data-doc],[data-addcrew],[data-uncrew],[data-cal],[data-calrm],[data-wadd],[data-wmove],[data-whide],[data-cafe],[data-take],[data-day],[data-pday],[data-taken]');
    if (!el) { root.querySelector('.keys') && root.querySelector('.keys').classList.remove('on'); return; }
    const d = el.dataset;
    if (d.tab) return setTab(d.tab);
    if (d.cal) { const c = S.cals.find(x => x.id === d.cal); if (c) { c.on = !c.on; saveCals(); } return rerender(true); }
    if (d.calrm) { S.cals = S.cals.filter(x => x.id !== d.calrm); saveCals(); return rerender(true); }
    if (d.wadd) { placeWidget(d.wadd, DEFAULT_LAYOUT.main.includes(d.wadd) ? 'main' : 'side', null); return rerender(true); }
    if (d.whide) { hideWidget(d.whide); return rerender(true); }
    if (d.wmove) { nudgeWidget(d.wmove, d.dir); rerender(true); const b = root.querySelector(`[data-wmove="${d.wmove}"][data-dir="${d.dir}"]:not(:disabled)`); if (b) b.focus(); return; }
    if (d.cafe) { S.cafeSite = d.cafe; store.set('cafeSite', d.cafe); return rerender(true); }
    if (d.seg) { S.poolSeg = d.seg; return rerender(false); }
    if (d.taken === 'fold') { S.takenOpen = !S.takenOpen; return rerender(true); }
    if (d.taken) { S.showTaken = d.taken === 'show'; store.set('showTaken', S.showTaken); if (S.showTaken) S.takenOpen = true; return rerender(true); }
    if (d.unit) { S.unitsOff.has(d.unit) ? S.unitsOff.delete(d.unit) : S.unitsOff.add(d.unit); store.set('unitsOff', [...S.unitsOff]); return rerender(true); }
    if (d.take) return openTake(d.take);
    if (d.pday) { S.poolDay = S.poolDay === d.pday ? null : d.pday; const o = S.poolDay && S.open.find(x => x.date === S.poolDay && (S.poolSeg !== 'me' || pickable(x))); if (o) S.selPool = o.id; return rerender(true); }
    if (d.day && el.classList.contains('cell')) {
      if (e.shiftKey || e.metaKey || e.ctrlKey) { e.preventDefault(); return pickDay(d.day, e); }
      mAnchor = d.day; S.dayMsg = null; return openDay(d.day);
    }
    if (d.open) {
      if (window.innerWidth < 1280) return openTake(d.open);
      S.selPool = d.open; return rerender(true);
    }
    if (d.jump) {
      if (S.tab !== 'pool') { S.tab = 'pool'; store.set('tab', 'pool'); }
      S.poolSeg = 'all'; const o = S.open.find(x => x.date === d.jump); if (o) S.selPool = o.id; render();
      const c = o && root.querySelector(`[data-open="${o.id}"]`); if (c) c.scrollIntoView({ block: 'center', behavior: 'smooth' });
      return;
    }
    if (d.themeset) { S.theme = d.themeset; store.set('theme', S.theme); applyTheme(); return rerender(true); }
    if (d.doc) { S.highlight = S.highlight === d.doc ? '' : d.doc; return rerender(true); }
    if (d.crewtog != null) { const n = d.crewtog; S.crew = S.crew.includes(n) ? S.crew.filter(c => c !== n) : S.crew.concat(n); store.set('crew', S.crew); rerender(true); return crewFocus(); }
    if (d.crewact === 'clear') { S.crew = []; store.set('crew', S.crew); rerender(true); return crewFocus(); }
    if (d.crewact === 'done') { S.crewOpen = false; S.crewQuery = ''; return rerender(true); }
    if (d.addcrew) { S.crew = [...new Set(S.crew.concat(d.addcrew))]; S.crewQuery = ''; store.set('crew', S.crew); return rerender(true); }
    if (d.uncrew) { S.crew = S.crew.filter(c => c !== d.uncrew); store.set('crew', S.crew); return rerender(true); }
    const a = d.act;
    if (a === 'whoflip') { S.whoFlip = !S.whoFlip; store.set('whoFlip', S.whoFlip); flash(S.whoFlip ? 'Scrolling now pulls the days like dragging a page.' : 'Scrolling now moves forward through the days.'); return rerender(true); }
    if (a === 'whodocs') { S.whoDocs = !S.whoDocs; store.set('whoDocs', S.whoDocs); return rerender(true); }
    if (a === 'refresh') return refresh();
    if (a === 'design') return dzToggle();
    if (a === 'close') return hide();
    if (a === 'keys') { e.stopPropagation(); return root.querySelector('.keys').classList.toggle('on'); }
    if (a === 'mprev' || a === 'wprev' || a === 'cprev') return shift(-1);
    if (a === 'mnext' || a === 'wnext' || a === 'cnext') return shift(1);
    if (a === 'mtoday' || a === 'wtoday' || a === 'ctoday') return toToday();
    if (a === 'ics') return downloadICS();
    if (a === 'custom') { S.customizing = !S.customizing; return rerender(true); }
    if (a === 'wreset') { S.layout = freshLayout(); saveLayout(); return rerender(true); }
    if (a === 'wundo') { const u = S.undoHide; S.undoHide = null; hideFlash(); if (u) { placeWidget(u.w, u.col, u.before); rerender(true); } return; }
    if (a === 'addcal') return openAddCal();
  });
  // drag across My Shifts days to pick a run (mouse / pen; touch keeps scrolling)
  app.addEventListener('pointerdown', e => {
    if (e.button !== 0 || dzOn || e.shiftKey || e.metaKey || e.ctrlKey || e.pointerType === 'touch' || S.tab !== 'mine') return;
    const c = e.target.closest('.cell[data-day]'); if (c) mDrag = { from: c.dataset.day, to: c.dataset.day, moved: false };
  });
  window.addEventListener('pointermove', e => {
    if (!mDrag) return;
    if (!(e.buttons & 1)) { mDrag = null; return; }
    const t = root.elementFromPoint(e.clientX, e.clientY), c = t && t.closest && t.closest('.cell[data-day]');
    if (!c || c.dataset.day === mDrag.to) return;
    mDrag.to = c.dataset.day; mDrag.moved = true;
    S.multi = rangeDays(mDrag.from, mDrag.to); paintMulti();
  });
  window.addEventListener('pointerup', () => {
    if (!mDrag) return; const g = mDrag; mDrag = null;
    if (!g.moved) return;
    mSwallow = true; setTimeout(() => { mSwallow = false; }, 60);
    mAnchor = g.from; setMulti(rangeDays(g.from, g.to));
  });
  app.addEventListener('change', e => {
    if (e.target.dataset && e.target.dataset.file === 'cal' && e.target.files) addCalendarFiles(e.target.files);
  });
  // drag Today's cards: by the grip (or anywhere on the card while customizing), within and across columns, or onto
  // the hide zone. Hidden chips in the Customize tray drag in too.
  let wDrag = null, wDrop = null;
  const clearMark = () => { root.querySelectorAll('.wmark').forEach(m => m.remove()); root.querySelectorAll('.over').forEach(m => m.classList.remove('over')); };
  function endWDrag(changed) {
    wDrag = null; wDrop = null; clearMark();
    const v = root.querySelector('.view'); if (v) v.classList.remove('wdragging');
    root.querySelectorAll('.w.ghost').forEach(x => x.classList.remove('ghost'));
    if (changed) rerender(true);
  }
  app.addEventListener('dragstart', e => {
    const src = e.target.closest && e.target.closest('[data-wdrag],[data-w]');
    if (!src || S.tab !== 'today') return;
    wDrag = src.dataset.wdrag || src.dataset.w;
    e.dataTransfer.effectAllowed = 'move';
    try { e.dataTransfer.setData('text/plain', WIDGETS[wDrag]); } catch (x) {}
    const sec = src.closest('.w');
    if (sec) { const r = sec.getBoundingClientRect(); try { e.dataTransfer.setDragImage(sec, Math.min(40, r.width / 2), 22); } catch (x) {} }
    requestAnimationFrame(() => { if (sec) sec.classList.add('ghost'); const v = root.querySelector('.view'); if (v) v.classList.add('wdragging'); });
  });
  app.addEventListener('dragover', e => {
    if (!wDrag) return;
    const hz = e.target.closest('[data-wdrop="hide"]'), col = e.target.closest('[data-wcol]');
    if (!hz && !col) { clearMark(); wDrop = null; return; }
    e.preventDefault(); e.dataTransfer.dropEffect = 'move';
    if (hz) { if (!hz.classList.contains('over')) { clearMark(); hz.classList.add('over'); } wDrop = { hide: true }; return; }
    const cards = [...col.querySelectorAll(':scope > .w')].filter(c => c.dataset.w !== wDrag);
    let i = cards.findIndex(c => { const r = c.getBoundingClientRect(); return e.clientY < r.top + r.height / 2; });
    if (i < 0) i = cards.length;
    const before = cards[i] ? cards[i].dataset.w : null;
    if (wDrop && wDrop.col === col.dataset.wcol && wDrop.before === before) return;
    wDrop = { col: col.dataset.wcol, before };
    clearMark();
    const m = document.createElement('div'); m.className = 'wmark';
    if (cards[i]) col.insertBefore(m, cards[i]); else { const em = col.querySelector('.wempty'); if (em) em.classList.add('over'); else col.appendChild(m); }
  });
  app.addEventListener('drop', e => {
    if (!wDrag) return;
    e.preventDefault();
    const w = wDrag, to = wDrop;
    if (to && to.hide) { if (S.layout.main.includes(w) || S.layout.side.includes(w)) hideWidget(w); }
    else if (to && to.col) placeWidget(w, to.col, to.before);
    endWDrag(true);
  });
  app.addEventListener('dragend', () => { if (wDrag) endWDrag(false); });

  // drop an .ics anywhere on Working-Bolt to add it (and never let the drop navigate the page away)
  const hasFiles = e => e.dataTransfer && [...(e.dataTransfer.types || [])].includes('Files');
  app.addEventListener('dragover', e => { if (!hasFiles(e)) return; e.preventDefault(); app.classList.add('drop'); });
  app.addEventListener('dragleave', e => { if (e.target === app || !app.contains(e.relatedTarget)) app.classList.remove('drop'); });
  app.addEventListener('drop', e => {
    if (!hasFiles(e)) return; e.preventDefault(); app.classList.remove('drop');
    addCalendarFiles(e.dataTransfer.files);
    if (S.tab !== 'mine' && S.tab !== 'today') setTab('mine');
  });
  // Crew: clicking (or double-clicking) the colleague field opens a tick-list of everyone; pick several at once
  function crewFocus() { const i = root.querySelector('[data-input="crew"]'); if (i) i.focus({ preventScroll: true }); }
  function crewOpen() { if (!S.crewOpen) { S.crewOpen = true; rerender(true); } }
  app.addEventListener('focusin', e => { if (e.target.dataset && e.target.dataset.input === 'crew') crewOpen(); });
  app.addEventListener('dblclick', e => { if (e.target.closest('.cpick .search')) crewOpen(); });
  app.addEventListener('mousedown', e => { if (e.target.closest('.cdrop')) e.preventDefault(); });   // keep typing focus in the field
  root.addEventListener('click', e => {
    const a = e.target.closest && e.target.closest('a[data-txtcopy]'); if (!a) return;
    try { navigator.clipboard.writeText(a.dataset.txtcopy).then(() => flash('Message copied too — paste it if Messages doesn’t open')); } catch (err) {}
  });
  app.addEventListener('input', e => {
    const f = e.target.dataset && e.target.dataset.input;
    if (f === 'hl') { S.highlight = e.target.value; rerender(true); }
    if (f === 'crew') { S.crewQuery = e.target.value; S.crewOpen = true; rerender(true); }
    if (f === 'wdate' && e.target.value) { S.whoDate = e.target.value; whoScrollTo(addDays(e.target.value, -1), true); }
  });
  app.addEventListener('keydown', e => {
    if (e.target.dataset && e.target.dataset.input === 'crew') {
      if (e.key === 'Enter') { e.preventDefault(); const b = root.querySelector('[data-crewtog]'); if (b) { b.click(); S.crewQuery = ''; rerender(true); crewFocus(); } }
      if (e.key === 'Escape' && S.crewOpen) { e.stopPropagation(); S.crewOpen = false; S.crewQuery = ''; rerender(true); }
      if (e.key === 'ArrowDown' && !S.crewOpen) { S.crewOpen = true; rerender(true); }
    }
    if ((e.key === 'Enter' || e.key === ' ') && e.target.classList && e.target.classList.contains('cell') && e.target.dataset.day) { e.preventDefault(); S.dayMsg = null; openDay(e.target.dataset.day); }
  });
  function onKey(e) {
    if (!host.isConnected || host.style.display === 'none') return;
    const typing = root.activeElement && /INPUT|TEXTAREA|SELECT/.test(root.activeElement.tagName);
    if (dzOn && !typing) { if (dzKey(e)) return; }
    if (!typing && !e.metaKey && !e.ctrlKey && (e.key === 'e' || e.key === 'E') && !giveEl && !swapEl && !takeEl) { e.preventDefault(); return dzToggle(true); }
    if (wmEl) { if (e.key === 'Escape') { e.preventDefault(); wmClose(); } return; }
    if (xEl || lbEl || pkEl) { if (e.key === 'Escape') { e.preventDefault(); if (xEl) xClose(); else if (lbEl) lbClose(); else pkClose(); } return; }
    if (calEl) { if (e.key === 'Escape') { e.preventDefault(); closeAddCal(); } return; }
    if (giveEl) { if (e.key === 'Escape' && S.G && S.G.phase !== 'sending') { e.preventDefault(); closeGive(); } return; }
    if (swapEl) { if (e.key === 'Escape' && S.W && S.W.phase !== 'sending') { e.preventDefault(); closeSwap(); } return; }
    if (takeEl) { if (e.key === 'Escape') { e.preventDefault(); closeTake(); } return; }
    if (dayEl) {
      if (e.key === 'Escape') { e.preventDefault(); if (typing) root.activeElement.blur(); else closeDay(); return; }
      if (!typing && S.multi.length && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) { e.preventDefault(); return; }
      if (!typing && (e.key === 'ArrowLeft' || e.key === 'ArrowRight')) { e.preventDefault(); S.dayMsg = null; openDay(addDays(S.daySel, e.key === 'ArrowLeft' ? -1 : 1)); return; }
      if (typing) return;
    }
    if (e.key === 'Escape') { if (typing) { root.activeElement.blur(); return; } const k = root.querySelector('.keys.on'); if (k) { k.classList.remove('on'); return; } hide(); return; }
    if (typing || e.metaKey || e.ctrlKey || e.altKey) return;
    const t = TABS.find(x => x.key === e.key); if (t) { e.preventDefault(); return setTab(t.id); }
    if (S.tab === 'cafe' && /^(ArrowLeft|ArrowRight|t|T)$/.test(e.key)) { e.preventDefault(); S.cafeDay = e.key.length === 1 ? today : addDays(S.cafeDay || today, e.key === 'ArrowLeft' ? -1 : 1); return rerender(true); }
    if (e.key === 'ArrowLeft') { e.preventDefault(); return shift(-1); }
    if (e.key === 'ArrowRight') { e.preventDefault(); return shift(1); }
    if ((e.key === 'd' || e.key === 'D') && S.tab === 'who') { S.whoDocs = !S.whoDocs; store.set('whoDocs', S.whoDocs); return rerender(true); }
    if (e.key === 't' || e.key === 'T') return toToday();
    if ((e.key === 'r' || e.key === 'R') && !DEMO) return refresh();
    if (e.key === '/') { const i = root.querySelector('[data-input]'); if (i) { e.preventDefault(); i.focus(); } return; }
    if (e.key === '?') { const k = root.querySelector('.keys'); if (k) k.classList.toggle('on'); }
  }
  window.addEventListener('keydown', onKey, true);
  let rt = 0; window.addEventListener('resize', () => { clearTimeout(rt); rt = setTimeout(() => rerender(true), 120); });

  function hide() { host.style.display = 'none'; document.documentElement.style.overflow = prevOverflow; }
  function show() { host.style.display = ''; document.documentElement.style.overflow = 'hidden'; syncCals(); if (!DEMO && S.loaded && Date.now() - (S.loadedAt || 0) > 10 * 60 * 1000) refresh(); }
  window.__WB = { show, hide };

  // ───────────────────────────── load ─────────────────────────────
  function stampNow() { return new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit' }).format(new Date()); }
  async function refresh() {
    if (S.status === 'loading') return;
    S.status = 'loading'; S.note = ''; rerender(true);
    try {
      if (!AUTH) await captureToken();
      if (!AUTH || !S.emp) throw Object.assign(new Error('session'), { session: true });
      const d = await loadLive();
      S.mine = d.mine; S.open = d.open; if (d.group) S.group = d.group; S.requests = d.requests;
      if (!S.me) S.me = (S.group.find(g => g.emp === S.emp) || {}).doc || '';
      derive();
      S.loaded = true; S.loadedAt = Date.now(); S.status = 'ok'; S.updated = stampNow();
      loadTaken(); loadSwapNotes(); loadNotOffered(); loadMyPickups();
      if (!d.group) S.note = 'Who’s On didn’t load this time — refresh to try again.';
    } catch (err) {
      if (err && err.session && await autoSignIn()) { AUTH = ''; S.status = 'idle'; S.note = ''; setTimeout(refresh, 400); return; }
      AUTH = err && err.session ? '' : AUTH;
      S.status = 'error';
      S.note = err && err.session
        ? 'Lightning Bolt’s session in this tab has ended. Sign in to Lightning Bolt again (Esc to go back), then click the Working-Bolt bookmark.'
        : (navigator.onLine === false ? 'No connection — showing what was read last. Refresh when you’re back online.' : 'Lightning Bolt didn’t answer. Refresh to try again.');
    }
    rerender(true);
  }

  loadWeather(); loadOncall(); loadCafe(); syncCals(); loadTaken();
  setInterval(() => { if (host.style.display !== 'none' && document.visibilityState === 'visible') { loadWeather(); loadOncall(); syncCals(); loadTaken(); } }, 30 * 60 * 1000);
  if (DEMO) {
    const d = demoData();
    Object.assign(S, { me: d.me, emp: d.emp, mine: d.mine, open: d.open, group: d.group, requests: d.requests, loaded: true, status: 'ok', updated: stampNow() });
    if (!S.cals.length) S.cals = [demoCal()];
    if (!S.crew.length) S.crew = ['Sarah Chen', 'David Kim', 'Maria Santos'];
    derive(); render(); loadSwapNotes(); loadNotOffered(); loadMyPickups();
  } else if (looksSignedOut()) {
    S.status = 'error';
    S.note = 'Sign in to Lightning Bolt in this tab first, then click the Working-Bolt bookmark again.';
    render();
  } else {
    render(); refresh();
    // every 3 minutes while open: a light re-read (the pool moves fast)
    setInterval(() => { if (host.style.display !== 'none' && document.visibilityState === 'visible') refresh(); }, 3 * 60 * 1000);
  }
})();
