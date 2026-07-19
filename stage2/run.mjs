// Hacking-Bolt — scrape the Lightning Bolt swaportunity board, write shifts.json,
// and push a phone notification (ntfy) when a *pickable* shift appears.
// Runs headless in GitHub Actions every ~10 min. First run: test locally (see README).
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';

const LB_USER    = process.env.LB_USER;
const LB_PASS    = process.env.LB_PASS;
const NTFY_TOPIC = process.env.NTFY_TOPIC;                       // e.g. "hackingbolt-nvdb-7q3x"
const NTFY_SERVER= process.env.NTFY_SERVER || 'https://ntfy.sh';
const STATE_FILE = process.env.STATE_FILE || 'state.json';      // persisted session (cookies) — cached between runs
const OUT_DIR    = process.env.OUT_DIR    || 'site';
const SHIFTS_FILE= path.join(OUT_DIR, 'shifts.json');
const NOW_ISO    = new Date().toISOString();

const LOGIN_URL = 'https://lblite.lightning-bolt.com/login';
const DASH_URL  = 'https://lblite.lightning-bolt.com/dashboard/';
const VIEWER_ME = (dt) => `https://lblite.lightning-bolt.com/viewer/me?dt=${dt}`;

if (!LB_USER || !LB_PASS) { console.error('Missing LB_USER / LB_PASS env vars'); process.exit(1); }

// ---------- unit taxonomy (friendly names, hours, colour key) ----------
const UNITS = {
  MICU: {short:'MICU',      full:'Medical ICU',          hrs:'08:00–08:00 · 24h'},
  SICU: {short:'SICU',      full:'Surgical ICU',         hrs:'08:00–08:00 · 24h'},
  CCU:  {short:'CCU',       full:'Coronary Care',        hrs:'08:00–08:00 · 24h'},
  PHICU:{short:'PHICU',     full:'Pasqua ICU',           hrs:'08:00–08:00 · 24h'},
  RR:   {short:'RR',        full:'Rapid Response · RGH', hrs:'08:00–17:00 · day'},
  PRR:  {short:'Pasqua RR', full:'Pasqua Rapid Response',hrs:'08:00–17:00 · day'},
  MSU:  {short:'Pasqua-MSU',full:'Pasqua Medical Surveillance Unit', hrs:'17:00–08:00 · night'}
};
function unitKey(raw){
  const r=(raw||'').toUpperCase();
  if(r.includes('PASQUA RAPID')) return 'PRR';
  if(r.includes('RAPID RESPONSE')) return 'RR';
  if(r.startsWith('MSU')) return 'MSU';
  if(r.startsWith('PHICU')||r.startsWith('PICU')) return 'PHICU';
  if(r.startsWith('MICU')) return 'MICU';
  if(r.startsWith('SICU')) return 'SICU';
  if(r.startsWith('CCU')) return 'CCU';
  return null; // unknown / non-clinical (e.g. RQHR) — skip
}

// ---------- time + date helpers (conflict logic, ported from the pool page) ----------
const MONTHS=['january','february','march','april','may','june','july','august','september','october','november','december'];
function toMin(hhmm){const [h,m]=hhmm.split(':').map(Number);return h*60+m;}
function ordinal(iso){const [y,m,d]=iso.split('-').map(Number);return Date.UTC(y,m-1,d)/86400000;}
function interval(iso,start,end,ov){const base=ordinal(iso)*1440,s=toMin(start),e=toMin(end);let E=base+e;if(ov||e<=s)E+=1440;return {S:base+s,E};}
function openInterval(iso,k){
  if(k==='RR'||k==='PRR') return interval(iso,'08:00','17:00',false);
  if(k==='MSU')           return interval(iso,'17:00','08:00',true);   // Pasqua MSU: 17:00 → 08:00 (follows Pasqua RR 08:00–17:00, same doc)
  return interval(iso,'08:00','08:00',true); // 24h units
}
function addDay(iso){const [y,m,d]=iso.split('-').map(Number);return new Date(Date.UTC(y,m-1,d+1)).toISOString().slice(0,10);}

// ================= Playwright =================
const browser = await chromium.launch({ args:['--no-sandbox','--disable-dev-shm-usage'] });
const context = await browser.newContext(fs.existsSync(STATE_FILE) ? { storageState: STATE_FILE } : {});
context.setDefaultTimeout(45000);
const page = await context.newPage();

// Capture the session Bearer + emp_id (the Bearer is NEVER logged) — needed to call the schedule/range
// only_pending endpoint that lists every open swaportunity, cross-department, with its slot_id.
let BEARER = '';
page.on('request', (req)=>{ try {
  const a = req.headers()['authorization'];
  if (a && /^bearer /i.test(a) && /lightning-bolt/.test(req.url())) BEARER = a;
} catch {} });
let EMP_ID = '20147';   // overwritten from the live employee_feed URL so it personalises to whoever logs in
page.on('response', (resp)=>{ try { const m=resp.url().match(/employee_feed\/\d+\/(\d+)/); if(m) EMP_ID=m[1]; } catch {} });

const isLoggedIn = () => page.evaluate(()=>/SWAPORTUNITY|Sign out/i.test(document.body.innerText) && !/Sign in to access/i.test(document.body.innerText));

async function login(){
  // /login redirects to the s2 sign-in form; wait for it, then type as real keystrokes
  // (this React form ignores programmatic value-setting — learned from live testing).
  await page.goto(LOGIN_URL,{waitUntil:'domcontentloaded'});
  const user = page.locator('input[placeholder="Username"]');
  await user.waitFor({state:'visible', timeout:35000});
  await user.click(); await user.pressSequentially(LB_USER, {delay:20});
  const pass = page.locator('input[placeholder="Password"]');
  await pass.click(); await pass.pressSequentially(LB_PASS, {delay:20});
  // submit: click the button if present, and press Enter as a fallback
  const btn = page.locator('button:has-text("Sign in"), button[type="submit"], input[type="submit"]');
  if(await btn.count().catch(()=>0)) await btn.first().click().catch(()=>{});
  await pass.press('Enter').catch(()=>{});
  await page.waitForTimeout(7000);
  await page.goto(DASH_URL,{waitUntil:'domcontentloaded'}).catch(()=>{});
  await page.waitForTimeout(4000);
  if(!await isLoggedIn()) throw new Error('Login failed — check LB_USER/LB_PASS (or MFA/SSO now required)');
  await context.storageState({ path: STATE_FILE }); // persist for next run
  console.log('Logged in fresh; session saved');
}

// 1) open dashboard, re-login if the saved session is dead
await page.goto(DASH_URL,{waitUntil:'domcontentloaded'}).catch(()=>{});
await page.waitForTimeout(4000);
if(!await isLoggedIn()){ console.log('No/expired session — logging in'); await login(); await page.goto(DASH_URL,{waitUntil:'domcontentloaded'}); await page.waitForTimeout(4000); }
else { console.log('Reused existing session'); }

// the logged-in user's own name (dashboard header line 2) — so the app personalises to whoever logs in
const me = await page.evaluate(()=>{
  const lines=document.body.innerText.split('\n').map(s=>s.trim()).filter(Boolean);
  const nm=lines[1]||'';
  if(!nm || nm.length>40 || /SWAPORTUNITY|SIGN|NEXT\s*3|DASHBOARD/i.test(nm)) return '';
  return nm.toLowerCase().replace(/(^|[\s'-])\S/g,c=>c.toUpperCase());
}).catch(()=>'');
console.log('user:', me||'(name not captured)');

// DIAGNOSTIC (temp): how far back does schedule/range go? Probe 2024 / 2023.
try {
  for (const m of ['20240101','20240601','20241201','20230601','20220601']) {
    const end = m.slice(0,6)+'28';
    const url = `https://lbapi.lightning-bolt.com/schedule/range/?start_date=${m}&end_date=${end}&listed=true`;
    const r = await page.request.get(url,{headers: BEARER?{authorization:BEARER}:{}}).catch(()=>null);
    if (r) { let j=null; try{ j=await r.json(); }catch{}
      const arr = Array.isArray(j)?j:(j?.data||j?.slots||[]);
      const emps = new Set(arr.map(s=>String(s.emp_id)));
      console.log('[back-diag]', m, 'status', r.status(), 'total', arr.length, 'doctors', emps.size);
    } else console.log('[back-diag]', m, 'request-failed');
  }
} catch(e){ console.log('[back-diag] err', e.message); }

// Direct accept link. Confirmed from Lightning Bolt's own swaportunity emails: a logged-in user is
// routed to origin_hash = swop/<slot_id>/<action>. The id is the offered shift's slot_id (verified:
// the id in a real decline email == the slot_id in the app's own data for that shift).
// origin = /login (EXACT format of LB's own swaportunity email links, verified against a real email
// 2026-07-18: swop/1826146/accept). Do NOT change origin to /dashboard — that breaks the redirect.
const ACCEPT=(id)=>`https://lblite.lightning-bolt.com/login/?origin=${encodeURIComponent('https://lblite.lightning-bolt.com/login')}&origin_hash=${encodeURIComponent('swop/'+id+'/accept')}`;

// Build an absolute-minute interval + tidy hours label from a slot's EXACT ISO start/stop
// (overnight when the stop lands on a later calendar day — e.g. MSU 17:00 → 08:00 next day).
function slotInterval(s){
  const sd=s.start.slice(0,10), sh=s.start.slice(11,16), eh=s.stop.slice(11,16);
  const ov = s.stop.slice(0,10) > s.start.slice(0,10);
  return { iv: interval(sd, sh, eh, ov), sh, eh };
}
function slotHoursLabel(s){ const {iv,sh,eh}=slotInterval(s); return `${sh}–${eh} · ${Math.round((iv.E-iv.S)/60)}h`; }

// 3) scrape MY roster from /viewer/me, month by month, until an empty stretch (auto-follows new rosters)
async function scrapeMonth(dt){
  await page.goto(VIEWER_ME(dt),{waitUntil:'domcontentloaded'});
  await page.waitForTimeout(1800);
  return page.evaluate(()=>{
    const MON={JANUARY:1,FEBRUARY:2,MARCH:3,APRIL:4,MAY:5,JUNE:6,JULY:7,AUGUST:8,SEPTEMBER:9,OCTOBER:10,NOVEMBER:11,DECEMBER:12};
    const t=document.body.innerText;
    const hm=t.match(/\b(JANUARY|FEBRUARY|MARCH|APRIL|MAY|JUNE|JULY|AUGUST|SEPTEMBER|OCTOBER|NOVEMBER|DECEMBER)\s+(\d{4})\b/i);
    if(!hm) return {shifts:[]};
    const hMon=MON[hm[1].toUpperCase()], hYear=+hm[2];
    const lines=t.split(/\n/).map(s=>s.trim()).filter(Boolean);
    const dre=/^(Sun|Mon|Tue|Wed|Thu|Fri|Sat)\s+(\d{1,2})\/(\d{1,2})$/;
    const tre=/^(\d{1,2}:\d{2}\s*(?:am|pm))\s*-\s*(\d{1,2}:\d{2}\s*(?:am|pm))(?:\s*\((\d{2}\/\d{2})\))?$/i;
    const to24=(x)=>{const mm=x.match(/(\d{1,2}):(\d{2})\s*(am|pm)/i);let h=+mm[1]%12;if(/pm/i.test(mm[3]))h+=12;return String(h).padStart(2,'0')+':'+mm[2];};
    let cur=null,out={};
    for(let i=0;i<lines.length;i++){const L=lines[i];const dm=L.match(dre);
      if(dm){let mo=+dm[2],da=+dm[3],yr=hYear;if(hMon===12&&mo===1)yr++;else if(hMon===1&&mo===12)yr--;
        cur=`${yr}-${String(mo).padStart(2,'0')}-${String(da).padStart(2,'0')}`;out[cur]=out[cur]||[];continue;}
      const tm=L.match(tre);
      if(tm&&cur){const name=lines[i-1]||''; if(!dre.test(name)&&!tre.test(name)) out[cur].push({name,start:to24(tm[1]),end:to24(tm[2]),overnight:!!tm[3]});}
    }
    const shifts=[];Object.entries(out).forEach(([d,arr])=>arr.forEach(s=>shifts.push({date:d,...s})));
    return {shifts};
  });
}
// Roster changes rarely, so cache it and only re-scrape every ROSTER_MAX_AGE_H hours.
// This keeps most 30-min runs feed-only (~1 min) so we stay inside GitHub's free minutes.
const ROSTER_FILE = process.env.ROSTER_FILE || 'roster.json';
const ROSTER_MAX_AGE_H = 12;
let mine=[], rosterCached=false;
try{ const r=JSON.parse(fs.readFileSync(ROSTER_FILE,'utf8'));
  if(r.updatedAt && (Date.now()-Date.parse(r.updatedAt))/36e5 < ROSTER_MAX_AGE_H && Array.isArray(r.mine) && r.mine.length){ mine=r.mine; rosterCached=true; } }catch{}
if(!rosterCached){
  const now=new Date(); let y=now.getUTCFullYear(), m=now.getUTCMonth()+1, dry=0, guard=0;
  while(dry<3 && guard++<20){                                   // 3 empty months in a row = truly past the roster
    const dt=`${y}${String(m).padStart(2,'0')}01`;
    let {shifts}=await scrapeMonth(dt);
    let clinical=shifts.filter(s=>unitKey(s.name));
    if(clinical.length===0){                                    // Lightning Bolt sometimes returns an empty month transiently — retry once
      await page.waitForTimeout(1600);
      ({shifts}=await scrapeMonth(dt)); clinical=shifts.filter(s=>unitKey(s.name));
    }
    if(clinical.length===0) dry++;
    else { dry=0; for(const s of clinical) if(!mine.some(x=>x.date===s.date&&x.name===s.name&&x.start===s.start)) mine.push(s); }
    m++; if(m>12){m=1;y++;}
  }
  fs.writeFileSync(ROSTER_FILE, JSON.stringify({updatedAt:NOW_ISO, mine}, null, 2));
}
console.log(rosterCached?`roster: cached (${mine.length} shifts)`:`roster: scraped (${mine.length} shifts)`);

// 4) my intervals + post-call map, then conflict flags (time-based; post-call = full rest day)
const myIvs=[], myPost={};
for(const s of mine){ const k=unitKey(s.name); const iv=interval(s.date,s.start,s.end,s.overnight);
  myIvs.push({S:iv.S,E:iv.E,short:UNITS[k].short}); if(s.overnight) myPost[addDay(s.date)]=UNITS[k].short; }
function flagFor(iso,k,ivOverride){
  if(myPost[iso]) return `Post-call · off ${myPost[iso]}`;
  const {S:oS,E:oE}= ivOverride || openInterval(iso,k); let best=null;  // exact offered window when known, else unit assumption
  for(const mIv of myIvs){ if(mIv.S<=oE&&mIv.E>=oS){ const type=(mIv.S<oE&&mIv.E>oS)?'overlap':(mIv.E===oS?'postcall':'after');
    const sev={overlap:3,postcall:2,after:1}[type]; if(!best||sev>best.sev)best={type,sev,short:mIv.short}; } }
  if(!best) return null;
  if(best.type==='overlap')  return `You're on ${best.short}`;
  if(best.type==='postcall') return `Post-call · off ${best.short}`;
  return `Pre-call · before ${best.short}`;
}

// 4.5) OPEN OFFERS — authoritative source: schedule/range?only_pending=true (the human-icon widget's
// endpoint). Every LIVE open swaportunity, cross-department (Rapid Response included), each already
// carrying its slot_id, across the whole roster. This replaces the stale SWAPORTUNITY FEED text and the
// per-week viewer harvest. One HTTP call per month; the session Bearer (captured above) authorises it.
const todayIso=NOW_ISO.slice(0,10);
async function fetchPendingMonth(monthDt){
  const y=+monthDt.slice(0,4), mo=+monthDt.slice(4,6);
  const end=`${monthDt.slice(0,6)}${String(new Date(Date.UTC(y,mo,0)).getUTCDate()).padStart(2,'0')}`;
  const url=`https://lbapi.lightning-bolt.com/schedule/range/?start_date=${monthDt}&end_date=${end}&listed=true&emp_id=${EMP_ID}&only_pending=true`;
  const r=await page.request.get(url,{headers: BEARER?{authorization:BEARER}:{}}).catch(()=>null);
  if(!r || r.status()!==200) return [];
  let j=null; try{ j=await r.json(); }catch{ return []; }
  const arr=Array.isArray(j)?j:(Array.isArray(j?.data)?j.data:(Array.isArray(j?.slots)?j.slots:[]));
  return arr.filter(s=>s&&s.is_pending&&s.slot_id&&s.slot_date&&s.start_time&&s.stop_time);
}
const pending=[];
{ const now=new Date(); let y=now.getUTCFullYear(), m=now.getUTCMonth()+1;
  for(let i=0;i<14;i++){ pending.push(...await fetchPendingMonth(`${y}${String(m).padStart(2,'0')}01`)); m++; if(m>12){m=1;y++;} } }
const seenSlot=new Set();
const pendingUniq=pending.filter(s=>{ const id=String(s.slot_id); if(seenSlot.has(id))return false; seenSlot.add(id); return true; });
console.log(`open-offers: ${pendingUniq.length} live pending slot(s) from schedule/range (whole roster, all units)`);

// 5) assemble sorted open list — every offer has a slot_id → real one-tap accept link
const open=[];
for(const s of pendingUniq){
  const iso=String(s.slot_date).slice(0,10); if(iso<todayIso) continue;
  const k=unitKey(s.assign_display_name||s.assign_compact_name||''); if(!k) continue;   // skip non-clinical
  const slot={start:s.start_time, stop:s.stop_time};
  const {iv}=slotInterval(slot); const flag=flagFor(iso,k,iv);
  open.push({ id:String(s.slot_id), iso, unitKey:k, unit:UNITS[k].full, short:UNITS[k].short,
    hrs:slotHoursLabel(slot), offerer:(s.display_name||s.compact_name||'').trim(),
    conflict:!!flag, flag: flag||'Available', acceptUrl:ACCEPT(s.slot_id), hasDirect:true });
}
// sort by date, then by start time within a day (hrs begins "HH:MM–", so lexical order = chronological)
open.sort((a,b)=> a.iso!==b.iso ? (a.iso<b.iso?-1:1) : (String(a.hrs)<String(b.hrs)?-1:1));

// 6) diff vs previous run → notify on newly-appeared PICKABLE shifts only
let prev={open:[]}; try{ prev=JSON.parse(fs.readFileSync(SHIFTS_FILE,'utf8')); }catch{}
const keyOf=o=> o.id ? ('s'+o.id) : `${o.iso}|${o.unitKey}|${o.offerer}`;   // per-segment for splits, else per shift
const prevKeys=new Set((prev.open||[]).map(keyOf));
const fresh=open.filter(o=>!o.conflict && !prevKeys.has(keyOf(o)));

// 7) write shifts.json (consumed by index.html)
fs.mkdirSync(OUT_DIR,{recursive:true});
fs.writeFileSync(SHIFTS_FILE, JSON.stringify({ updatedAt:NOW_ISO, me, open,
  mine: mine.map(s=>({date:s.date,unitKey:unitKey(s.name),start:s.start,end:s.end,overnight:s.overnight})) }, null, 2));
console.log(`open=${open.length} pickable=${open.filter(o=>!o.conflict).length} new=${fresh.length} directIds=${open.filter(o=>o.hasDirect).length}/${open.length}`);
// directIds counts open shifts we matched to a slot_id (→ real one-tap accept link); the rest fall back to the dashboard.

// 8) push notifications
if(NTFY_TOPIC){
  for(const o of fresh){
    const nice=new Date(o.iso+'T00:00:00Z').toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric',timeZone:'UTC'});
    await fetch(`${NTFY_SERVER}/${NTFY_TOPIC}`,{ method:'POST',
      headers:{ Title:`Open: ${o.short} · ${nice}`, Tags:'zap', Click:o.acceptUrl },
      body:`${o.unit} (${o.hrs}) offered by ${o.offerer}. Tap to accept in Lightning Bolt.` }).catch(e=>console.log('ntfy error',e.message));
    console.log('pushed', o.short, o.iso);
  }
} else console.log('NTFY_TOPIC not set — skipping push');

await context.storageState({ path: STATE_FILE }).catch(()=>{});
await browser.close();
