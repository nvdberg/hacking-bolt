import SwiftUI
import WebKit
import os

let hbLog = Logger(subsystem: "com.nvdberg.hackingbolt", category: "harvest")

/// Owns a single WKWebView. The user logs in on Lightning Bolt's real page (we never see the password);
/// afterwards we drive the same web view (its session cookies persist) to read window.LbsAppData —
/// exactly the object the scraper reads. No token handling, no server.
@MainActor
final class LBWebSource: NSObject, ObservableObject {

    static let sharedPool = WKProcessPool()           // share the live session with the accept web view
    let webView: WKWebView = {
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()            // persist the session between launches
        cfg.processPool = LBWebSource.sharedPool
        // Capture the session Bearer the SPA sends to lbapi (into window.__lbAuth, never leaves the web
        // view) so we can call schedule/range?only_pending — the complete cross-department open-offer list.
        let hook = WKUserScript(source: LBWebSource.tokenCaptureJS, injectionTime: .atDocumentStart, forMainFrameOnly: true)
        cfg.userContentController.addUserScript(hook)
        return WKWebView(frame: .zero, configuration: cfg)
    }()

    static let loginURL = URL(string: "https://lblite.lightning-bolt.com/dashboard/")!
    static func viewerURL(_ dt: String) -> URL { URL(string: "https://lblite.lightning-bolt.com/viewer/?dt=\(dt)")! }

    override init() { super.init(); webView.navigationDelegate = self }

    func loadLogin() { webView.load(URLRequest(url: Self.loginURL)) }

    /// Owner opt-in Face ID auto-login: fill LB's own login form with the (biometrically-unlocked) credentials
    /// and submit. Generic selectors so it survives minor markup changes: the first password input + the nearest
    /// username/email/text input. Returns true if it submitted the form. The password is embedded as a safely
    /// escaped JS string literal — it lives only in the web view, same as a manual login.
    func autoSignIn(username: String, password: String) async -> Bool {
        let js = Self.autoLoginJS
            .replacingOccurrences(of: "__USER__", with: Self.jsLit(username))
            .replacingOccurrences(of: "__PASS__", with: Self.jsLit(password))
        let r = (try? await evalAsync(js)) as? String
        hbLog.log("autoSignIn: \(r ?? "nil", privacy: .public)")
        return r == "submitted"
    }

    private static func jsLit(_ s: String) -> String {
        var o = "'"
        for c in s.unicodeScalars {
            switch c {
            case "\\": o += "\\\\"
            case "'":  o += "\\'"
            case "\n": o += "\\n"
            case "\r": o += "\\r"
            default:   o += c.value < 0x20 ? String(format: "\\u%04x", c.value) : String(c)
            }
        }
        return o + "'"
    }

    private static let autoLoginJS = """
    (function(){
      try {
        var pw = document.querySelector('input[type=password]');
        if(!pw) return 'no-form';
        var inputs = Array.prototype.slice.call(document.querySelectorAll('input'));
        var user = null;
        for (var i=0;i<inputs.length;i++){ var el=inputs[i]; if(el===pw) continue; var t=(el.type||'').toLowerCase();
          if(t==='text'||t==='email'|| /user|email|login|name/i.test((el.name||'')+' '+(el.id||''))){ user=el; break; } }
        var setVal = function(el, v){ var d=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value').set;
          d.call(el, v); el.dispatchEvent(new Event('input',{bubbles:true})); el.dispatchEvent(new Event('change',{bubbles:true})); };
        if(user) setVal(user, __USER__);
        setVal(pw, __PASS__);
        var btn = document.querySelector('button[type=submit], input[type=submit]');
        if(!btn && pw.form) btn = pw.form.querySelector('button');
        if(btn){ btn.click(); } else if(pw.form){ pw.form.submit(); } else { return 'no-submit'; }
        return 'submitted';
      } catch(e){ return 'err:'+e; }
    })()
    """

    /// Clear the Lightning Bolt session (cookies + storage + captured token) so the login screen returns
    /// for a fresh user — used by Sign out (e.g. to let a colleague log in and load their own data).
    func signOut() {
        let store = webView.configuration.websiteDataStore
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        store.fetchDataRecords(ofTypes: types) { records in
            store.removeData(ofTypes: types, for: records) {}
        }
        webView.evaluateJavaScript("try{window.__lbAuth='';}catch(e){}", completionHandler: nil)
    }

    /// True once the dashboard/app shows a logged-in state (not the sign-in screen).
    func isLoggedIn() async -> Bool {
        let js = "/SWAPORTUNITY|Sign out/i.test(document.body.innerText) && !/Sign in to access/i.test(document.body.innerText)"
        return (try? await eval(js)) as? Bool ?? false
    }

    // MARK: - Harvest

    /// Load the viewer ONCE (which fires the SPA's authed lbapi call, captured into window.__lbAuth), then
    /// read the live window entirely from the fast per-year API paths: my roster via `fetchMyShifts`, the
    /// complete cross-department open-offer pool via `fetchOpenOffers`. Identity (emp_id + name) comes straight
    /// from LbsAppData. No week-by-week SPA paging, no 56 navigations, no per-week timeouts — one navigation
    /// plus two API reads. The whole-group backfill (Who's On + colleague roster) is handled separately by
    /// `loadGroupHistory`, so harvest stays light and fast.
    func harvest() async throws -> HarvestResult {
        await load(Self.viewerURL(Self.currentMonthDt()))       // start at the 1st of the current month
        _ = await waitForSlots()                                // the viewer's data load fires the authed lbapi fetch…
        _ = await waitForToken()                                // …which the documentStart hook captures into __lbAuth
        // identity straight from LbsAppData (no paging, no network)
        var me = "", emp: String? = nil
        if let j = (try? await evalAsync(Self.identityJS)) as? String, let d = j.data(using: .utf8),
           let id = try? JSONDecoder().decode(Identity.self, from: d) {
            me = id.me; if !id.emp.isEmpty { emp = id.emp }
        }
        // the live window: my shifts (this year + next) + the complete open-offer pool, both via the fast API
        // requireAll: a partial read (e.g. next year's request failed) must not replace the whole window
        let mine = await fetchMyShifts(since: Self.currentYearDt(), requireAll: true) ?? []
        let offers = await fetchOpenOffers()
        let pending = offers ?? []
        if emp == nil { emp = mine.first?.emp }                 // fallbacks if LbsAppData.User was sparse
        if me.isEmpty { me = mine.first?.offerer ?? "" }
        hbLog.log("harvest DONE (api): pending=\(pending.count, privacy: .public) mine=\(mine.count, privacy: .public) me='\(me, privacy: .public)'")
        return HarvestResult(pending: pending, mine: mine, me: me, emp: emp, offersOK: offers != nil)
    }

    static func currentMonthDt() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMM'01'"; f.timeZone = TimeZone(identifier: "America/Regina")
        return f.string(from: Date())
    }
    /// Jan 1 of the current year (America/Regina) — the start of harvest's live my-shifts window
    /// (fetchMyShifts serves whole years, start-year → next year, so this covers this year + next).
    static func currentYearDt() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy'0101'"; f.timeZone = TimeZone(identifier: "America/Regina")
        return f.string(from: Date())
    }

    private struct Identity: Decodable { let emp: String; let me: String }
    // Reads my emp_id + display name directly from LbsAppData (no paging). Run via evalAsync (allows `return`).
    private static let identityJS = """
    const D = window.LbsAppData;
    function emp(){ try {
      if (D.User && D.User.emp_id) return D.User.emp_id;
      if (D.User && D.User.attributes && D.User.attributes.emp_id) return D.User.attributes.emp_id;
      if (D.MyPersonnel && D.MyPersonnel.models && D.MyPersonnel.models[0]) return D.MyPersonnel.models[0].attributes.emp_id;
    } catch(e){} return null; }
    function nm(){ try {
      if (D.MyPersonnel && D.MyPersonnel.models && D.MyPersonnel.models[0]){ var a=D.MyPersonnel.models[0].attributes; return a.display_name || ((a.first_name||'')+' '+(a.last_name||'')).trim(); }
      if (D.User && D.User.attributes && D.User.attributes.display_name) return D.User.attributes.display_name;
    } catch(e){} return ''; }
    var e = emp();
    return JSON.stringify({ emp: (e!=null?(''+e):''), me: nm() });
    """

    // MARK: - Complete open-offer list (lbapi schedule/range?only_pending — cross-department, all slot_ids)

    // Injected at documentStart: wrap XHR/fetch so the Bearer the SPA sends to lbapi is captured into
    // window.__lbAuth. That lets us call the same only_pending endpoint the "posted shifts" widget uses,
    // which lists EVERY open swaportunity — Rapid Response included — each with its slot_id. Never leaves
    // the web view; used only to read the user's own authorised data.
    static let tokenCaptureJS = """
    (function(){
      if (window.__lbAuthHook) return; window.__lbAuthHook = 1; window.__lbAuth = '';
      try {
        var os = XMLHttpRequest.prototype.setRequestHeader;
        XMLHttpRequest.prototype.setRequestHeader = function(k, v){
          try { if (/^authorization$/i.test(k) && /bearer/i.test(v)) window.__lbAuth = v; } catch(e){}
          return os.apply(this, arguments);
        };
        if (window.fetch) { var of = window.fetch; window.fetch = function(input, init){
          try { var h = init && init.headers; if (h){ var a=(h.get&&h.get('authorization'))||h['Authorization']||h['authorization']; if(a && /bearer/i.test(a)) window.__lbAuth=a; } } catch(e){}
          return of.apply(this, arguments);
        }; }
      } catch(e){}
    })();
    """

    private struct OpenOffersResult: Decodable { let ok: Bool; let pending: [RawSlot] }

    /// The complete open-offer list from lbapi schedule/range?only_pending — every live swaportunity
    /// (all units, whole roster) already carrying its slot_id. Needs the captured Bearer + logged-in emp_id.
    /// Returns nil if either isn't ready yet, so the caller keeps the LbsAppData scan as a fallback.
    /// `trace` (owner-only): slot ids whose full LB record is returned too, to study how a swap moves through LB.
    func fetchOpenOffers(trace: [Int]? = nil) async -> [RawSlot]? {
        let js = Self.openOffersJS.replacingOccurrences(of: "__TRACE__", with: trace.map { "[\($0.map(String.init).joined(separator: ","))]" } ?? "null")
        guard let json = (try? await evalAsync(js)) as? String,
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(OpenOffersResult.self, from: data), r.ok else {
            hbLog.log("openOffers: unavailable (token/emp not ready) — keeping LbsAppData scan")
            return nil
        }
        hbLog.log("openOffers: \(r.pending.count, privacy: .public) live pending (cross-department)")
        return r.pending
    }

    // One fetch per month across the roster; dedup by slot_id. Same query the human-icon widget makes.
    private static let openOffersJS = """
    const D = window.LbsAppData;
    let emp = '';
    try { emp = (D && D.User && (D.User.emp_id || (D.User.attributes && D.User.attributes.emp_id))) || ''; } catch(e){}
    const auth = window.__lbAuth || '';
    if (!emp || !auth) return JSON.stringify({ ok:false, pending:[] });
    const W = __TRACE__;   // null = no trace; else my own pending slots + these ids carry their full record
    function endOf(y,m){ return new Date(Date.UTC(y, m, 0)).getUTCDate(); }
    const out = [], seen = {};
    let anyOk = false;   // did ANY request succeed? if not (e.g. expired token → all 401), report failure so the pool isn't wiped
    let now = new Date(), y = now.getUTCFullYear(), m = now.getUTCMonth()+1;
    for (let i=0;i<14;i++){
      const mm = ('0'+m).slice(-2), dd = ('0'+endOf(y,m)).slice(-2);
      const url = 'https://lbapi.lightning-bolt.com/schedule/range/?start_date='+y+mm+'01&end_date='+y+mm+dd+'&listed=true&emp_id='+emp+'&only_pending=true';
      try {
        const r = await fetch(url, { headers: { Authorization: auth } });
        if (r.ok) {
          anyOk = true;
          const j = await r.json();
          const arr = Array.isArray(j) ? j : (j.data || j.slots || []);
          for (let k=0;k<arr.length;k++){ const a = arr[k];
            if (a && a.is_pending && a.slot_id && !seen[a.slot_id]) { seen[a.slot_id]=1;
              out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                         unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                         emp:(a.emp_id!=null?(''+a.emp_id):''),
                         pending_emp:(a.pending_emp_id!=null?(''+a.pending_emp_id):null), pending_name:(a.pending_display_name||null),
                         raw:(W && ((''+a.emp_id)===(''+emp) || W.indexOf(a.slot_id)>=0)) ? JSON.stringify(a).slice(0,2500) : null }); } }
        }
      } catch(e){}
      m++; if (m>12){ m=1; y++; }
    }
    return JSON.stringify({ ok: anyOk, pending: out });
    """

    // MARK: - Directory (lbapi /personnel) — emp_id → cell/email, for the Swap Finder "text them" action.

    private struct DirectoryResult: Decodable { let ok: Bool; let people: [RawPerson] }

    /// The group directory (name, cell, email per emp_id) from lbapi /personnel, via the captured Bearer.
    /// Returns nil if the token isn't ready. Used only to let the user text a colleague to propose a swap.
    func fetchDirectory() async -> [RawPerson]? {
        guard let json = (try? await evalAsync(Self.directoryJS)) as? String,
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(DirectoryResult.self, from: data), r.ok else {
            hbLog.log("directory: unavailable (token not ready)"); return nil
        }
        hbLog.log("directory: \(r.people.count, privacy: .public) people")
        return r.people
    }

    // One authed call to /personnel; map each person → emp_id + name + cell + email (robust field fallbacks).
    private static let directoryJS = """
    const auth = window.__lbAuth || '';
    if (!auth) return JSON.stringify({ ok:false, people:[] });
    const out = [];
    try {
      const r = await fetch('https://lbapi.lightning-bolt.com/personnel/', { headers: { Authorization: auth } });
      if (!r.ok) return JSON.stringify({ ok:false, people:[] });
      const j = await r.json();
      const arr = Array.isArray(j) ? j : (j.data || j.personnel || j.people || []);
      for (let i=0;i<arr.length;i++){ const a = arr[i]; if (!a || a.emp_id==null) continue;
        const nm = a.display_name || ((a.first_name||'')+' '+(a.last_name||'')).trim() || '';
        const cell = a.phone_cell || a.cell || a.phone_mobile || a.mobile || a.phone || '';
        out.push({ emp:(''+a.emp_id), name:nm, cell:(''+cell), email:(a.email||'') }); }
      return JSON.stringify({ ok:true, people: out });
    } catch(e){ return JSON.stringify({ ok:false, people:[] }); }
    """

    // MARK: - My shift history (for stats) — schedule/range WITHOUT only_pending = my own roster

    private struct MyShiftsResult: Decodable { let ok: Bool; let all: Bool?; let shifts: [RawSlot] }

    /// My own worked/scheduled shifts from `sinceYYYYMM01` through the current month, via the same
    /// schedule/range endpoint (no only_pending → my roster), filtered to my emp_id. One call per month.
    /// Cached by the caller; the future half comes from the live harvest, so the log stays dynamic.
    func fetchMyShifts(since sinceYYYYMM01: String, requireAll: Bool = false) async -> [RawSlot]? {
        let js = Self.myShiftsJS.replacingOccurrences(of: "__SINCE__", with: sinceYYYYMM01)
        guard let json = (try? await evalAsync(js)) as? String,
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(MyShiftsResult.self, from: data), r.ok else {
            hbLog.log("myShifts history: unavailable (token/emp not ready)"); return nil
        }
        if requireAll && r.all == false { hbLog.log("myShifts: a year failed — partial read discarded"); return nil }
        hbLog.log("myShifts history: \(r.shifts.count, privacy: .public) slots since \(sinceYYYYMM01, privacy: .public)")
        return r.shifts
    }

    // ONE call per year (the endpoint serves a whole year at once), start-year → next year (to catch the
    // future roster). Fast even over several years.
    private static let myShiftsJS = """
    const D = window.LbsAppData;
    let emp = '';
    try { emp = (D && D.User && (D.User.emp_id || (D.User.attributes && D.User.attributes.emp_id))) || ''; } catch(e){}
    const auth = window.__lbAuth || '';
    if (!emp || !auth) return JSON.stringify({ ok:false, shifts:[] });
    const startY = parseInt('__SINCE__'.slice(0,4), 10);
    const endY = new Date().getUTCFullYear() + 1;
    const out = [], seen = {};
    let anyOk = false, allOk = true;
    for (let y = startY; y <= endY; y++){
      const url = 'https://lbapi.lightning-bolt.com/schedule/range/?start_date='+y+'0101&end_date='+y+'1231&listed=true&emp_id='+emp;
      try {
        const r = await fetch(url, { headers: { Authorization: auth } });
        if (!r.ok) allOk = false;
        if (r.ok) {
          anyOk = true;
          const j = await r.json();
          const arr = Array.isArray(j) ? j : (j.data || j.slots || []);
          for (let k=0;k<arr.length;k++){ const a = arr[k];
            if (a && a.slot_id && (''+a.emp_id) === (''+emp) && !seen[a.slot_id]) { seen[a.slot_id]=1;
              out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                         unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                         emp:(''+a.emp_id) }); } }
        }
      } catch(e){ allOk = false; }
    }
    return JSON.stringify({ ok: anyOk, all: allOk, shifts: out });
    """

    // MARK: - Group history (admin) — the WHOLE group's shifts via schedule/range with NO emp filter.
    // (Confirmed: dropping emp_id returns every doctor, all units, cross-department, back to Jan 2025.)
    // One fast API call per month — replaces the slow, unreliable viewer paging.

    private struct GroupShiftsResult: Decodable { let ok: Bool; let shifts: [RawSlot]; let swaps: [RawSwap] }

    /// The whole group's roster + every changed-hands slot (Shift-pickups). Fetched ONE YEAR AT A TIME and merged
    /// in Swift — the whole-group year payload is ~9 MB, so pulling all years in a single JS call (~30 MB held in
    /// the web view + one giant bridge return) overflowed on device and silently failed, leaving Who's On / Crew /
    /// Stats on stale cache. Per-year keeps each call small and lets a partial result still land.
    func fetchGroupShifts(years: [Int]) async -> (shifts: [RawSlot], swaps: [RawSwap], failedYears: Set<Int>)? {
        var shifts: [RawSlot] = [], swaps: [RawSwap] = []
        var seen = Set<Int>(), swapSeen = Set<Int>()
        var anyOK = false, failed = Set<Int>()
        for y in years {
            guard let r = await fetchGroupYear(y), r.ok else { failed.insert(y); continue }
            anyOK = true
            for s in r.shifts { if let id = s.slot_id, seen.insert(id).inserted { shifts.append(s) } }
            for sw in r.swaps { if let id = sw.slot_id, swapSeen.insert(id).inserted { swaps.append(sw) } }
        }
        guard anyOK else { hbLog.log("group shifts: every year failed (token not ready?)"); return nil }
        hbLog.log("group shifts (chunked): \(shifts.count, privacy: .public) slots, \(swaps.count, privacy: .public) swaps")
        return (shifts, swaps, failed)
    }

    private func fetchGroupYear(_ y: Int) async -> GroupShiftsResult? {
        let js = Self.groupYearJS.replacingOccurrences(of: "__YEAR__", with: "\(y)")
        guard let json = (try? await evalAsync(js)) as? String else {
            hbLog.log("group year \(y, privacy: .public): fetch failed"); return nil
        }
        // A year is ~9 MB of JSON — decode it off the main thread so the UI doesn't hitch while it lands.
        let r = await Task.detached(priority: .userInitiated) { () -> GroupShiftsResult? in
            guard let data = json.data(using: .utf8) else { return nil }
            return try? JSONDecoder().decode(GroupShiftsResult.self, from: data)
        }.value
        if r == nil { hbLog.log("group year \(y, privacy: .public): decode failed") }
        return r
    }

    // ONE year of the whole group (no emp filter): slots + changed-hands swaps, giver resolved within the year.
    private static let groupYearJS = """
    const auth = window.__lbAuth || '';
    if (!auth) return JSON.stringify({ ok:false, shifts:[], swaps:[] });
    const y = __YEAR__;
    const out = [], seen = {}, empName = {}, swapSeen = {}, swaps = [];
    let ok = false;
    const url = 'https://lbapi.lightning-bolt.com/schedule/range/?start_date='+y+'0101&end_date='+y+'1231&listed=true';
    try {
      const r = await fetch(url, { headers: { Authorization: auth } });
      if (r.ok) { ok = true;
        const j = await r.json();
        const arr = Array.isArray(j) ? j : (j.data || j.slots || []);
        for (let k=0;k<arr.length;k++){ const a = arr[k];
          if (!a || !a.slot_id) continue;
          if (a.emp_id!=null && a.display_name) empName[''+a.emp_id] = a.display_name;
          if (!seen[a.slot_id]) { seen[a.slot_id]=1;
            out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                       unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                       emp:(a.emp_id!=null?(''+a.emp_id):'') }); }
          if (a.original_emp_id!=null && a.emp_id!=null && (''+a.original_emp_id)!==(''+a.emp_id) && !swapSeen[a.slot_id]) {
            swapSeen[a.slot_id]=1;
            const h = (a.slot_history && a.slot_history[0] && a.slot_history[0].text) || '';
            swaps.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                         unit:a.assign_display_name||a.assign_compact_name||'', toName:a.display_name||'',
                         toEmp:(''+a.emp_id), fromEmp:(''+a.original_emp_id), when:a.modified_date||'', hist:h }); }
        }
      }
    } catch(e){}
    for (let i=0;i<swaps.length;i++){ swaps[i].fromName = empName[swaps[i].fromEmp] || ''; }
    return JSON.stringify({ ok: ok, shifts: out, swaps: swaps });
    """

    // MARK: - Give-away writes (REAL schedule mutations — payloads captured 2026-07-30, see LB-giveaway-investigation.md)
    // These POST to Lightning Bolt using the app's own logged-in web-view token (window.__lbAuth) — no stored creds.
    // NOT wired to any UI yet; the give-away wizard will call these ONLY behind an explicit in-app confirm, and
    // owner-only until reviewed. Every offer is reversible via cancelOffer(). Nothing here runs unless called.

    private struct WriteResult: Decodable { let ok: Bool; let status: Int; let body: String? }
    /// Result of a give-away write. `ok` is TRUE only when LB actually applied it — a 200 can carry a `warnings`
    /// array (e.g. "Matt Butz - Assignment 'MICU' is incompatible with 'Rapid Response RGH'") meaning the offer
    /// was declined. `message` is LB's own explanation, shown to the user.
    struct WriteOutcome { let ok: Bool; let message: String?; var partial = false }   // partial: something DID change
    /// Diagnostic: LB's raw status + response body from the last write. Surfaced owner-only in the give-away result.
    @MainActor var lastWriteInfo = ""

    /// Pull the first human message out of LB's `errors`/`warnings` (object or array-of-objects response).
    private static func lbMessage(from body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) else { return nil }
        let dict = (obj as? [String: Any]) ?? (obj as? [[String: Any]])?.first
        func firstMsg(_ any: Any?) -> String? {
            (any as? [[String: Any]])?.compactMap { $0["message"] as? String }.first { !$0.isEmpty }
        }
        return firstMsg(dict?["errors"]) ?? firstMsg(dict?["warnings"])
    }

    /// POST `payload` to an lbapi endpoint with the captured Bearer, and interpret LB's response.
    private func lbPost(_ url: String, _ payload: Any) async -> WriteOutcome {
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let body = String(data: data, encoding: .utf8) else { return WriteOutcome(ok: false, message: "Couldn't build the request.") }
        let js = """
        const auth = window.__lbAuth || '';
        if (!auth) return JSON.stringify({ ok:false, status:0, body:'no-auth' });
        try {
          const r = await fetch(url, { method:'POST', headers:{ 'Authorization': auth, 'Content-Type':'application/json' }, body: body });
          const t = await r.text();
          return JSON.stringify({ ok: r.ok, status: r.status, body: t.slice(0,400) });
        } catch(e) { return JSON.stringify({ ok:false, status:-1, body: String(e) }); }
        """
        guard let json = (try? await webView.callAsyncJavaScript(js, arguments: ["url": url, "body": body], in: nil, contentWorld: .page)) as? String,
              let d = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(WriteResult.self, from: d) else {
            hbLog.log("LB write \(url, privacy: .public): failed (token/eval)")
            await MainActor.run { lastWriteInfo = "eval failed (no token?)" }
            return WriteOutcome(ok: false, message: "Couldn't reach Lightning Bolt. Try again in the app.")
        }
        hbLog.log("LB write \(url, privacy: .public): ok=\(r.ok, privacy: .public) status=\(r.status, privacy: .public)")
        let info = "status \(r.status) · \(r.body ?? "")"
        await MainActor.run { lastWriteInfo = info }
        // A 200 can still carry a warning/error meaning LB declined it → real success is HTTP-ok AND no message.
        let msg = Self.lbMessage(from: r.body)
        return WriteOutcome(ok: r.ok && msg == nil, message: r.ok ? msg : (msg ?? "Lightning Bolt rejected it (status \(r.status))."))
    }

    /// Split a shift into parts (each `emp_ids` = who keeps that part). `POST /schedule/split`.
    func splitShift(slotID: Int, parts: [(start: String, end: String, empID: Int)], note: String) async -> WriteOutcome {
        let splits = parts.map { ["start_time": $0.start, "end_time": $0.end, "emp_ids": [$0.empID]] as [String: Any] }
        return await lbPost("https://lbapi.lightning-bolt.com/schedule/split",
                            ["slot_id": slotID, "splits": splits, "note": note] as [String: Any])
    }

    /// Offer a shift to ONE person (a pending replace; carries a note; reversible until accepted). `POST /schedule/update`.
    /// `templateID` = the slot's own LB schedule/template (RR is template 6, same as ICU — confirmed working).
    func offerToPerson(slotID: Int, empID: Int, note: String, templateID: Int) async -> WriteOutcome {
        await lbPost("https://lbapi.lightning-bolt.com/schedule/update",
                     [["slot_id": slotID, "emp_id": empID, "note": note, "template_id": templateID, "type": "replace personnel"]])
    }

    /// Offer a shift to everyone eligible (classic swaportunity broadcast; LB carries NO note here). `POST /schedule/preswap`.
    func offerToGroup(slotID: Int, empIDs: [Int]) async -> WriteOutcome {
        await lbPost("https://lbapi.lightning-bolt.com/schedule/preswap",
                     [["slot_id": slotID, "emp_ids": empIDs, "type": "preswap_create"]])
    }

    /// Withdraw/cancel a pending offer. `POST /schedule/update` with "delete swap".
    func cancelOffer(slotID: Int, empID: Int) async -> WriteOutcome {
        await lbPost("https://lbapi.lightning-bolt.com/schedule/update",
                     [["type": "delete swap", "slot_id": slotID, "emp_id": empID, "decision_note": NSNull()]])
    }

    // MARK: - Time-off requests (Matt's ask) — the signed-in user's OWN requests only; never approve/deny.
    // Shapes captured 2026-09-29 by a send-blocked dry-run (see LB-timeoff-requests.md).

    /// One day of a request as LB lists it (`GET /request/range/`). Times are Regina local, no zone.
    struct RawRequest: Decodable {
        let id: Int
        let date: String            // "YYYY-MM-DD"
        let status: String?         // "pending" / approved / denied …
        let kind: String?           // assign_display_name ("Time Off" / "Night Off")
        let note: String?           // message
        let submitted: String?      // timestamp
        let decision: String?       // decision_msg or denial_reason_name
    }
    private struct RequestsResult: Decodable { let ok: Bool; let requests: [RawRequest] }

    /// My requests between two YYYYMMDD dates. nil = the read failed (no token / every call errored) → the
    /// caller keeps its cached list. Tries the whole span in one call, falls back to month-by-month (the LB UI pages by month).
    func fetchMyRequests(startYYYYMMDD: String, endYYYYMMDD: String) async -> [RawRequest]? {
        guard let json = (try? await webView.callAsyncJavaScript(Self.requestsJS, arguments: ["s": startYYYYMMDD, "e": endYYYYMMDD],
                                                                 in: nil, contentWorld: .page)) as? String,
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(RequestsResult.self, from: data), r.ok else {
            hbLog.log("requests: unavailable (token/emp not ready or all calls failed)")
            return nil
        }
        hbLog.log("requests: \(r.requests.count, privacy: .public) of mine")
        return r.requests
    }

    private static let requestsJS = """
    const D = window.LbsAppData;
    let emp = '';
    try { emp = (D && D.User && (D.User.emp_id || (D.User.attributes && D.User.attributes.emp_id))) || ''; } catch(e){}
    const auth = window.__lbAuth || '';
    if (!emp || !auth) return JSON.stringify({ ok:false, requests:[] });
    const out = [], seen = {};
    function take(j){
      const arr = Array.isArray(j) ? j : (j.data || []);
      for (let k=0;k<arr.length;k++){ const a = arr[k];
        if (!a || a.request_id == null || seen[a.request_id]) continue;
        if (a.emp_id != null && (''+a.emp_id) !== (''+emp)) continue;          // mine only
        seen[a.request_id] = 1;
        out.push({ id:a.request_id, date:(a.request_date||'').slice(0,10), status:a.status||null,
                   kind:a.assign_display_name||null, note:a.message||null, submitted:a.timestamp||null,
                   decision:a.decision_msg||a.denial_reason_name||null });
      }
    }
    async function get(a,b){
      const url = 'https://lbapi.lightning-bolt.com/request/range/?start_date='+a+'&end_date='+b+'&listed=true&emp_id='+emp;
      try { const r = await fetch(url, { headers:{ Authorization: auth } }); if (!r.ok) return false; take(await r.json()); return true; }
      catch(e){ return false; }
    }
    if (await get(s, e)) return JSON.stringify({ ok:true, requests: out });
    // fallback: month by month (the LB UI's own paging)
    let y = +s.slice(0,4), m = +s.slice(4,6); const ey = +e.slice(0,4), em = +e.slice(4,6);
    let anyOk = false, g = 0;
    while ((y < ey || (y === ey && m <= em)) && g < 36) {
      const mm = ('0'+m).slice(-2), last = ('0'+new Date(Date.UTC(y, m, 0)).getUTCDate()).slice(-2);
      if (await get(''+y+mm+'01', ''+y+mm+last)) anyOk = true;
      m++; if (m>12){ m=1; y++; } g++;
    }
    return JSON.stringify({ ok:anyOk, requests: out });
    """

    /// LB's request type ids (template 6 = Critical Care). "Default" time only — custom times weren't captured.
    enum RequestKind: String, CaseIterable, Codable {
        case timeOff = "Time Off", nightOff = "Night Off"
        var assignID: Int { self == .timeOff ? 20248 : 20251 }
        var structureID: Int { self == .timeOff ? 343 : 346 }
    }

    /// Submit a time-off / night-off request — one element per day, exactly as LB's own UI sends. `POST /request`.
    /// `dates` are "YYYY-MM-DD". Reversible with deleteRequests while pending.
    func submitRequests(kind: RequestKind, dates: [String], note: String, empID: Int) async -> WriteOutcome {
        guard !dates.isEmpty else { return WriteOutcome(ok: false, message: "No dates chosen.") }
        let items: [[String: Any]] = dates.map { d in
            ["type": "new", "emp_id": empID, "date": d + "T00:00:00",
             "assign_id": kind.assignID, "assign_structure_id": kind.structureID, "assign_name": kind.rawValue,
             "template_id": 6, "command_type": 0, "note": note, "start_date": NSNull(), "end_date": NSNull()]
        }
        return await lbPost("https://lbapi.lightning-bolt.com/request", items)
    }

    /// Cancel my own request days (one request_id per day). `POST /request` with type "delete".
    func deleteRequests(ids: [Int]) async -> WriteOutcome {
        guard !ids.isEmpty else { return WriteOutcome(ok: false, message: "Nothing to cancel.") }
        return await lbPost("https://lbapi.lightning-bolt.com/request",
                            ids.map { ["type": "delete", "request_id": $0, "decision_note": NSNull()] as [String: Any] })
    }

    // MARK: - WKWebView helpers

    private func load(_ url: URL) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            navDone = { c.resume() }
            webView.load(URLRequest(url: url))
        }
    }

    /// Poll until LbsAppData.Slots is populated (the viewer's data load is async), up to ~15s.
    /// Waits for the week's data. Returns as soon as the Slots collection has models (has data) OR is a
    /// stable empty array (the week loaded but nobody's scheduled — e.g. past the roster end). An empty
    /// week resolves in ~2s instead of timing out, so the look-ahead can detect the roster's end quickly.
    private func waitForSlots() async -> Bool {
        let js = "(window.LbsAppData && window.LbsAppData.Slots && Array.isArray(window.LbsAppData.Slots.models)) ? window.LbsAppData.Slots.models.length : -1"
        var emptyStable = 0
        for i in 0..<14 {                                   // up to ~7s (real weeks load in <2s)
            let n = (try? await eval(js)) as? Int ?? -1
            if n > 0 { return true }                        // has shifts
            if n == 0 { emptyStable += 1; if emptyStable >= 2 && i >= 2 { return false } }   // loaded, empty → resolve fast
            else { emptyStable = 0 }                        // -1: not loaded yet, keep waiting
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        return false
    }

    /// Poll until the SPA's Bearer has been captured into window.__lbAuth (up to ~3s), so the API reads
    /// (fetchMyShifts / fetchOpenOffers) have a token to use. The viewer's own data load triggers the
    /// capture; this just waits for it to land before we call lbapi.
    private func waitForToken() async -> Bool {
        for _ in 0..<12 {                                   // up to ~3s
            if let t = (try? await eval("window.__lbAuth || ''")) as? String, !t.isEmpty { return true }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        return false
    }

    private func eval(_ js: String) async throws -> Any? {
        try await withCheckedThrowingContinuation { c in
            webView.evaluateJavaScript(js) { result, error in
                if let error { c.resume(throwing: error) } else { c.resume(returning: result) }
            }
        }
    }

    /// Runs `js` as an async function body and awaits its returned promise (needed for the paging loop).
    private func evalAsync(_ js: String) async throws -> Any? {
        try await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    }

    // navigation gate
    fileprivate var navDone: (() -> Void)?
}

extension LBWebSource: WKNavigationDelegate {
    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in let cb = self.navDone; self.navDone = nil; cb?() }
    }
    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in let cb = self.navDone; self.navDone = nil; cb?() }
    }
}

/// SwiftUI wrapper to show the login web view.
struct LoginWebView: UIViewRepresentable {
    let source: LBWebSource
    func makeUIView(context: Context) -> WKWebView { source.webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
