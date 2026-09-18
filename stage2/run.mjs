// Hacking-Bolt — scrape the Lightning Bolt swaportunity board, write shifts.json,
// and push a phone notification (ntfy) when a *pickable* shift appears.
// Runs headless in GitHub Actions every ~10 min. First run: test locally (see README).
import { chromium } from 'playwright';
import fs from 'node:fs';
import path from 'node:path';
import { syncOpenShifts, deviceTokens, pruneTokens, supabaseConfigured,
         syncPickups, unnotifiedPickups, markPickupsNotified, deviceTokensByEmp,
         readCalSubs, uploadCalendar } from './supabase.mjs';
import { pushAll, apnsConfigured } from './apns.mjs';

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
// Re-navigate the dashboard to keep the session alive + re-capture a fresh Bearer (the token expires ~1h,
// so a long self-looping run must refresh it periodically).
async function refreshSession(){
  await page.goto(DASH_URL,{waitUntil:'domcontentloaded'}).catch(()=>{});
  await page.waitForTimeout(3000);
  if(!await isLoggedIn()){ try{ await login(); }catch(e){ console.log('re-login failed:', e.message); }
    await page.goto(DASH_URL,{waitUntil:'domcontentloaded'}).catch(()=>{}); await page.waitForTimeout(3000); }
}
async function fetchPendingMonth(monthDt){
  const y=+monthDt.slice(0,4), mo=+monthDt.slice(4,6);
  const end=`${monthDt.slice(0,6)}${String(new Date(Date.UTC(y,mo,0)).getUTCDate()).padStart(2,'0')}`;
  const url=`https://lbapi.lightning-bolt.com/schedule/range/?start_date=${monthDt}&end_date=${end}&listed=true&emp_id=${EMP_ID}&only_pending=true`;
  const r=await page.request.get(url,{headers: BEARER?{authorization:BEARER}:{}}).catch(()=>null);
  if(!r || r.status()!==200) return {slots:[], ok:false};
  let j=null; try{ j=await r.json(); }catch{ return {slots:[], ok:false}; }
  const arr=Array.isArray(j)?j:(Array.isArray(j?.data)?j.data:(Array.isArray(j?.slots)?j.slots:[]));
  return {slots: arr.filter(s=>s&&s.is_pending&&s.slot_id&&s.slot_date&&s.start_time&&s.stop_time), ok:true};
}

// ── Pickups (Working-Bolt "My Posts") ────────────────────────────────────────────────────────────────
// Fetch the whole calendar year's group schedule (no only_pending), find shifts that changed hands through
// the pool, sync them to Supabase, and push the GIVER a "your shift was picked up by X" note (once each).
async function fetchGroupRange(start, end){   // start/end = "YYYYMMDD"
  const url=`https://lbapi.lightning-bolt.com/schedule/range/?start_date=${start}&end_date=${end}&listed=true`;
  const r=await page.request.get(url,{headers: BEARER?{authorization:BEARER}:{}}).catch(()=>null);
  if(!r || r.status()!==200) return {slots:[], ok:false};
  let j=null; try{ j=await r.json(); }catch{ return {slots:[], ok:false}; }
  const arr=Array.isArray(j)?j:(Array.isArray(j?.data)?j.data:(Array.isArray(j?.slots)?j.slots:[]));
  return {slots:arr, ok:true};
}
const fetchGroupYear=(year)=>fetchGroupRange(`${year}0101`, `${year}1231`);   // still used by the calendar feed
const ymd=(d)=>d.toISOString().slice(0,10).replace(/-/g,'');
function detectPickups(slots){
  const nameOf={};
  for(const s of slots){ const n=(s.display_name||s.compact_name||'').trim(); if(s.emp_id!=null && n) nameOf[s.emp_id]=n; }
  const out=[], seen=new Set();
  for(const s of slots){
    const id=Number(s.slot_id); if(!id || seen.has(id)) continue; seen.add(id);
    if(s.original_emp_id==null || s.emp_id==null || s.original_emp_id===s.emp_id) continue;   // never changed hands
    const hist=(s.slot_history?.[0]?.text||'').toLowerCase();
    const isPickup = hist.includes('request to swap') && hist.includes('approved by');         // pool give-away
    const isSwap   = hist.includes('swapped');                                                 // "Swapped A with B by C"
    if(!isPickup && !isSwap) continue;                                                         // skip time-edits/other
    const k=unitKey(s.assign_display_name||s.assign_compact_name||''); if(!k) continue;        // clinical only
    const giver=(nameOf[s.original_emp_id]||'').trim(), taker=(s.display_name||nameOf[s.emp_id]||'').trim();
    if(!giver || !taker || giver.toUpperCase()==='EMPTY' || taker.toUpperCase()==='EMPTY') continue;
    out.push({ slot_id:id, date:String(s.slot_date||s.date||'').slice(0,10), unit:k,   // store the KEY (app maps it)
      giver_emp:Number(s.original_emp_id), giver, taker_emp:Number(s.emp_id), taker,
      kind:isSwap ? 'swap' : 'giveaway', picked_up_at:s.modified_date||null, updated_at:new Date().toISOString() });
  }
  return out;
}
async function syncAndNotifyPickups(){
  // Rolling FORWARD window: pickups only ever happen to today-or-future shifts (a swap is approved before the
  // shift), so scan from ~2 weeks back (buffer for day/timezone edges) to ~14 months ahead. Skips the dead past
  // AND reaches into next year — the old fixed calendar-year scan wasted the past months and missed next-year
  // pickups entirely. One HTTP call.
  const now=new Date();
  const from=ymd(new Date(now.getTime()-14*86400*1000));
  const to  =ymd(new Date(now.getTime()+430*86400*1000));
  const g=await fetchGroupRange(from, to);
  if(!g.ok){ console.log('pickups: group fetch failed — skipping'); return; }
  const picks=detectPickups(g.slots);
  console.log(`pickups: ${picks.length} changed-hands (${from}..${to})`);
  if(picks.length && supabaseConfigured()){
    const ok=await syncPickups(picks); console.log(`pickups: supabase sync ${ok?'ok':'FAILED'} (${picks.length} rows)`);
  }
  if(!(apnsConfigured() && supabaseConfigured())) return;
  // Push only pickups that are BOTH un-notified AND recent — so first deploy silently catches up the whole
  // year's history (marks it notified, no push) and only genuinely new pickups alert the giver.
  const pend=await unnotifiedPickups(); if(!pend.length) return;
  // 72h window (was 6h): the first-deploy backfill is long done, so any un-notified pickup is genuinely new;
  // the wide window just tolerates poller gaps so a real pickup still alerts even if detection lagged a day+.
  const cutoff=Date.now()-72*3600*1000;
  const fresh=pend.filter(p=>p.picked_up_at && Date.parse(p.picked_up_at)>=cutoff);
  const stale=pend.filter(p=>!fresh.includes(p));
  const byEmp=await deviceTokensByEmp(); const deadSet=new Set();
  for(const p of fresh){
    const tokens=byEmp[p.giver_emp]; if(!tokens?.length) continue;                             // giver has no device — leave; still marked below
    const short=UNITS[p.unit]?.short || p.unit;                                                // p.unit is the key
    const nice=new Date(p.date+'T00:00:00Z').toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric',timeZone:'UTC'});
    const res=await pushAll(tokens,{ title:`Picked up: ${short} · ${nice}`,
      body:`Your ${short} shift on ${nice} was picked up by ${p.taker}.`,
      data:{ slot_id:Number(p.slot_id), unit:short, iso:p.date, kind:'pickup' } });
    res.dead.forEach(t=>deadSet.add(t));
    console.log(`pickups: notified giver ${p.giver_emp} — ${p.unit} ${p.date} → sent=${res.sent}`);
  }
  const done=[...fresh, ...stale].map(p=>p.slot_id);
  if(done.length) await markPickupsNotified(done);
  if(deadSet.size){ await pruneTokens([...deadSet]); }
}

// ── Calendar sync (live subscribable .ics feeds) ─────────────────────────────────────────────────────
// For each enrolled subscriber (cal_subs), regenerate their own roster as an .ics and upload it to the
// public `calendars` Storage bucket at <token>.ics. A Google/Apple subscription to that URL then keeps
// itself current. Mirrors the on-device ICSExporter (CalendarExport.swift): coloured-square emoji titles,
// no time in the title, 24h calls fold 08:00→08:00, Pasqua Rapid+MSU merge, times in UTC (Regina UTC-6).
const CAL_EMOJI={MICU:'🟩',SICU:'🟦',CCU:'🟥',PHICU:'🟢',RR:'🟧',PRR:'🟪',MSU:'🟪'};
function pad2(n){return String(n).padStart(2,'0');}
function icsUTC(dateIso,hhmm){ const [y,mo,d]=dateIso.split('-').map(Number); const [h,mi]=hhmm.split(':').map(Number);
  const dt=new Date(Date.UTC(y,mo-1,d,h+6,mi,0));   // Regina is UTC-6 year-round (no DST) → +6h to UTC
  return `${dt.getUTCFullYear()}${pad2(dt.getUTCMonth()+1)}${pad2(dt.getUTCDate())}T${pad2(dt.getUTCHours())}${pad2(dt.getUTCMinutes())}00Z`; }
function icsStamp(){ const dt=new Date(); return `${dt.getUTCFullYear()}${pad2(dt.getUTCMonth()+1)}${pad2(dt.getUTCDate())}T${pad2(dt.getUTCHours())}${pad2(dt.getUTCMinutes())}${pad2(dt.getUTCSeconds())}Z`; }
function icsEsc(s){ return String(s).replace(/\\/g,'\\\\').replace(/;/g,'\\;').replace(/,/g,'\\,').replace(/\n/g,'\\n'); }
function buildICS(shifts){
  const lines=['BEGIN:VCALENDAR','VERSION:2.0','PRODID:-//Working-Bolt//Shifts//EN','CALSCALE:GREGORIAN','METHOD:PUBLISH','X-WR-CALNAME:Working-Bolt shifts'];
  const byDate={}; for(const s of shifts){ (byDate[s.date]||=[]).push(s); }
  const stamp=icsStamp(), pasquaDone=new Set();
  const sorted=[...shifts].sort((a,b)=> a.date===b.date ? (a.start<b.start?-1:1) : (a.date<b.date?-1:1));
  for(const s of sorted){
    if(s.key==='PRR'||s.key==='MSU'){                                          // Pasqua Rapid + MSU same day → one 24h block
      const day=byDate[s.date]||[];
      if(day.some(x=>x.key==='PRR')&&day.some(x=>x.key==='MSU')){
        if(pasquaDone.has(s.date))continue; pasquaDone.add(s.date);
        lines.push('BEGIN:VEVENT',`UID:wb-pasqua-${s.date}@working-bolt`,`DTSTAMP:${stamp}`,
          `DTSTART:${icsUTC(s.date,'08:00')}`,`DTEND:${icsUTC(addDay(s.date),'08:00')}`,
          `SUMMARY:${icsEsc('🟪 Pasqua-Rapid/MSU')}`,'END:VEVENT'); continue;
      }
    }
    const e=CAL_EMOJI[s.key]||'⚪️', name=UNITS[s.key]?.short||s.key, endDate=s.overnight?addDay(s.date):s.date;
    lines.push('BEGIN:VEVENT',`UID:wb-${s.slot_id||0}-${s.date}-${s.key}@working-bolt`,`DTSTAMP:${stamp}`,
      `DTSTART:${icsUTC(s.date,s.start)}`,`DTEND:${icsUTC(endDate,s.end)}`,
      `SUMMARY:${icsEsc(`${e} ${name}`)}`,'END:VEVENT');
  }
  lines.push('END:VCALENDAR');
  return lines.join('\r\n');
}
async function syncCalendarFeeds(){
  if(!supabaseConfigured())return;
  const subs=await readCalSubs();
  if(!subs.length)return;                                                       // nobody subscribed → zero cost
  const cur=new Date().getUTCFullYear();
  let slots=[], anyOk=false;
  for(const y of [cur, cur+1]){ const g=await fetchGroupYear(y); if(g.ok){ anyOk=true; slots.push(...g.slots); } }
  if(!anyOk){ console.log('calfeed: group fetch failed — skipping'); return; }
  const cut=new Date(Date.now()-14*86400*1000).toISOString().slice(0,10);       // keep from ~2 weeks back onward
  const byEmp={}, seen=new Set();
  for(const s of slots){
    const emp=Number(s.emp_id); if(!emp)continue;                               // unassigned/open slot
    const date=String(s.slot_date||s.date||'').slice(0,10); if(!date||date<cut)continue;
    const k=unitKey(s.assign_display_name||s.assign_compact_name||''); if(!k)continue;   // clinical only
    const start=String(s.start_time||'').slice(11,16), end=String(s.stop_time||'').slice(11,16); if(!start||!end)continue;
    const ov=String(s.stop_time||'').slice(0,10) > String(s.start_time||'').slice(0,10);
    const id=Number(s.slot_id), key=`${emp}|${id}|${date}|${k}`; if(seen.has(key))continue; seen.add(key);
    (byEmp[emp]||=[]).push({date,key:k,start,end,overnight:ov,slot_id:id});
  }
  let up=0;
  for(const sub of subs){ if(await uploadCalendar(sub.token, buildICS(byEmp[Number(sub.emp_id)]||[]))) up++; }
  console.log(`calfeed: ${subs.length} subscriber(s), uploaded ${up}`);
}
let calCycle=0;   // throttle to ~every 8th tick (Google refreshes subscriptions only every 8–24h anyway)

// One poll cycle: fetch the whole-roster open set, diff, publish (shifts.json + Supabase), push new shifts.
// Called once normally, or repeatedly by the self-loop (LOOP_MINUTES).
async function tick(){
const todayIso=new Date().toISOString().slice(0,10);
const pending=[]; let authOk=true;
{ const now=new Date(); let y=now.getUTCFullYear(), m=now.getUTCMonth()+1;
  for(let i=0;i<14;i++){ const r=await fetchPendingMonth(`${y}${String(m).padStart(2,'0')}01`); if(!r.ok) authOk=false; pending.push(...r.slots); m++; if(m>12){m=1;y++;} } }
// Session died mid-loop (auth failing, nothing back) → refresh + skip this cycle so we never wipe the shared set on a transient 401.
if(!authOk && pending.length===0){ console.log('tick: fetch auth failure — refreshing session, skipping this cycle'); await refreshSession(); return; }
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
    hrs:slotHoursLabel(slot), start:s.start_time, stop:s.stop_time,
    offerer:(s.display_name||s.compact_name||'').trim(), offererEmp:(s.emp_id ?? s.employee_id ?? null),
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
fs.writeFileSync(SHIFTS_FILE, JSON.stringify({ updatedAt:new Date().toISOString(), me, open,
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

// 9) Backend (Working-Bolt): sync the shared open-shift set to Supabase + native APNs push for new shifts.
//    Both are gated on their secrets — absent = skipped, so this stays a no-op until wired in CI.
if (supabaseConfigured()) {
  const ok = await syncOpenShifts(open, new Date().toISOString());
  console.log(`supabase: open_shifts sync ${ok ? 'ok' : 'FAILED'} (${open.length} rows)`);
} else console.log('supabase: not configured — skipping shared sync');

if (apnsConfigured()) {
  const tokens = await deviceTokens();
  console.log(`apns: ${tokens.length} device(s) registered, ${fresh.length} new pickable shift(s)`);
  const deadSet = new Set();
  for (const o of fresh) {
    const nice = new Date(o.iso+'T00:00:00Z').toLocaleDateString('en-US',{weekday:'short',month:'short',day:'numeric',timeZone:'UTC'});
    const res = await pushAll(tokens, {
      title: `Open: ${o.short} · ${nice}`,
      body:  `${o.unit} (${o.hrs}) offered by ${o.offerer}. Tap to open in Working-Bolt.`,
      data:  { slot_id: Number(o.id), unit: o.short, iso: o.iso },
    });
    res.dead.forEach(t => deadSet.add(t));
    console.log(`apns: pushed ${o.short} ${o.iso} → sent=${res.sent} failed=${res.failed}`);
  }
  if (deadSet.size) { await pruneTokens([...deadSet]); console.log(`apns: pruned ${deadSet.size} dead token(s)`); }
} else console.log('apns: not configured — skipping native push');

// 10) Pickups (My Posts): detect shifts that changed hands this year + notify each giver once.
//     Throttled to ~every 3rd cycle (the year-scan is one big call; a pickup still alerts within minutes).
// Every cycle now (was every 3rd) so a pickup alerts as promptly as a new-shift post — the year scan is one
// HTTP call, negligible next to the 14 the open-shift pass already does.
try { await syncAndNotifyPickups(); } catch(e){ console.log('pickups error:', e.message); }

// 11) Calendar sync: regenerate each enrolled subscriber's live .ics (throttled — Google refreshes slowly).
calCycle++;
if (calCycle % 8 === 1) { try { await syncCalendarFeeds(); } catch(e){ console.log('calfeed error:', e.message); } }
}  // end tick()

// ---- run: once, or a self-looping poll for tight cadence (free on the public repo) ----
const LOOP_MINUTES=+(process.env.LOOP_MINUTES||0);
const LOOP_EVERY_S=+(process.env.LOOP_EVERY_S||90);
if(LOOP_MINUTES>0){
  const endAt=Date.now()+LOOP_MINUTES*60000; let n=0;
  console.log(`loop: polling every ${LOOP_EVERY_S}s for ~${LOOP_MINUTES}m`);
  while(Date.now()<endAt){
    n++;
    try{ await tick(); }catch(e){ console.log('tick error:', e.message); }
    await context.storageState({ path: STATE_FILE }).catch(()=>{});
    if(n%12===0) await refreshSession();   // proactively refresh the ~1h Bearer (~every 18m at 90s)
    if(Date.now()>=endAt) break;
    await page.waitForTimeout(LOOP_EVERY_S*1000);
  }
  console.log(`loop done: ${n} cycle(s)`);
} else {
  await tick();
}
await context.storageState({ path: STATE_FILE }).catch(()=>{});
await browser.close();
