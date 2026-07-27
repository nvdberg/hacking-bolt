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

    /// Load each week and read offered slots + my roster + my name from LbsAppData.
    /// Scans forward through `weeks`, stopping `stopAfterEmpty` empty weeks after the roster ends — so it
    /// covers every published month and auto-extends when a new roster is posted (those weeks fill in).
    /// Load the viewer ONCE, then page forward week-by-week using the SPA's own AJAX (DateManager.incrementWeek
    /// — no full page navigation, so no navigation-throttle), accumulating every slot in a single async JS call.
    /// Stops 3 empty weeks past the roster. Reliable + fast (one navigation, ~30 AJAX refetches).
    func harvest() async throws -> HarvestResult {
        await load(Self.viewerURL(Self.currentMonthDt()))       // start at the 1st of the current month
        _ = await waitForSlots()
        hbLog.log("harvest: paging the roster…")
        guard let json = (try? await evalAsync(Self.pagingJS)) as? String,
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(HarvestResult.self, from: data) else {
            hbLog.log("harvest: paging failed"); return HarvestResult(pending: [], mine: [], me: "")
        }
        var result = r
        if let full = await fetchOpenOffers() { result.pending = full }   // complete cross-department list (RR/PRR incl.)
        hbLog.log("harvest DONE: pending=\(result.pending.count, privacy: .public) mine=\(result.mine.count, privacy: .public) me='\(result.me, privacy: .public)'")
        return result
    }

    static func currentMonthDt() -> String {
        let f = DateFormatter(); f.dateFormat = "yyyyMM'01'"; f.timeZone = TimeZone(identifier: "America/Regina")
        return f.string(from: Date())
    }

    // Pages the whole roster in one async JS call, accumulating is_pending slots + my slots (emp_id == me).
    private static let pagingJS = """
    const D = window.LbsAppData;
    if (!D || !D.Slots || !D.DateManager) return JSON.stringify({ pending: [], mine: [], me: '' });
    function myEmp(){ try {
      if (D.User && D.User.emp_id) return D.User.emp_id;
      if (D.User && D.User.attributes && D.User.attributes.emp_id) return D.User.attributes.emp_id;
      if (D.MyPersonnel && D.MyPersonnel.models && D.MyPersonnel.models[0]) return D.MyPersonnel.models[0].attributes.emp_id;
    } catch(e){} return null; }
    var MY = myEmp();
    var acc = { pending: [], mine: [], me: '', emp: (MY != null ? (''+MY) : ''), all: [] }, seen = {};
    function slot(a){ return { slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                               unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                               emp:(a.emp_id!=null?(''+a.emp_id):'') }; }
    function readWeek(){ var n=0, S=(D.Slots.models||[]);
      for (var i=0;i<S.length;i++){ var a=S[i].attributes;
        if (a.is_pending && !seen['p'+a.slot_id]){ seen['p'+a.slot_id]=1; acc.pending.push(slot(a)); n++; }
        if (MY && a.emp_id===MY && !seen['m'+a.slot_id]){ seen['m'+a.slot_id]=1; acc.mine.push(slot(a)); n++; if(!acc.me) acc.me=a.display_name||''; }
        if (!seen['a'+a.slot_id]){ seen['a'+a.slot_id]=1; acc.all.push(slot(a)); }   // everyone's assignments (Who's Working)
      } return n; }
    function maxDate(){ var mx='', S=(D.Slots.models||[]); for (var i=0;i<S.length;i++){ var d=S[i].attributes.slot_date; if(d>mx) mx=d; } return mx; }
    var emptyStreak = 0, seenData = false;
    for (var w=0; w<56; w++){
      var n = readWeek();
      if (n>0){ seenData = true; emptyStreak = 0; } else if (seenData){ emptyStreak++; if (emptyStreak>=3) break; }
      var before = maxDate();
      D.DateManager.incrementWeek();
      for (var j=0;j<40;j++){ await new Promise(function(r){ setTimeout(r,150); }); if (maxDate()!==before) break; }
    }
    readWeek();
    return JSON.stringify(acc);
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
    func fetchOpenOffers() async -> [RawSlot]? {
        guard let json = (try? await evalAsync(Self.openOffersJS)) as? String,
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
    function endOf(y,m){ return new Date(Date.UTC(y, m, 0)).getUTCDate(); }
    const out = [], seen = {};
    let now = new Date(), y = now.getUTCFullYear(), m = now.getUTCMonth()+1;
    for (let i=0;i<14;i++){
      const mm = ('0'+m).slice(-2), dd = ('0'+endOf(y,m)).slice(-2);
      const url = 'https://lbapi.lightning-bolt.com/schedule/range/?start_date='+y+mm+'01&end_date='+y+mm+dd+'&listed=true&emp_id='+emp+'&only_pending=true';
      try {
        const r = await fetch(url, { headers: { Authorization: auth } });
        if (r.ok) {
          const j = await r.json();
          const arr = Array.isArray(j) ? j : (j.data || j.slots || []);
          for (let k=0;k<arr.length;k++){ const a = arr[k];
            if (a && a.is_pending && a.slot_id && !seen[a.slot_id]) { seen[a.slot_id]=1;
              out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                         unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                         emp:(a.emp_id!=null?(''+a.emp_id):'') }); } }
        }
      } catch(e){}
      m++; if (m>12){ m=1; y++; }
    }
    return JSON.stringify({ ok:true, pending: out });
    """

    // MARK: - My shift history (for stats) — schedule/range WITHOUT only_pending = my own roster

    private struct MyShiftsResult: Decodable { let ok: Bool; let shifts: [RawSlot] }

    /// My own worked/scheduled shifts from `sinceYYYYMM01` through the current month, via the same
    /// schedule/range endpoint (no only_pending → my roster), filtered to my emp_id. One call per month.
    /// Cached by the caller; the future half comes from the live harvest, so the log stays dynamic.
    func fetchMyShifts(since sinceYYYYMM01: String) async -> [RawSlot]? {
        let js = Self.myShiftsJS.replacingOccurrences(of: "__SINCE__", with: sinceYYYYMM01)
        guard let json = (try? await evalAsync(js)) as? String,
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(MyShiftsResult.self, from: data), r.ok else {
            hbLog.log("myShifts history: unavailable (token/emp not ready)"); return nil
        }
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
    for (let y = startY; y <= endY; y++){
      const url = 'https://lbapi.lightning-bolt.com/schedule/range/?start_date='+y+'0101&end_date='+y+'1231&listed=true&emp_id='+emp;
      try {
        const r = await fetch(url, { headers: { Authorization: auth } });
        if (r.ok) {
          const j = await r.json();
          const arr = Array.isArray(j) ? j : (j.data || j.slots || []);
          for (let k=0;k<arr.length;k++){ const a = arr[k];
            if (a && a.slot_id && (''+a.emp_id) === (''+emp) && !seen[a.slot_id]) { seen[a.slot_id]=1;
              out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                         unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                         emp:(''+a.emp_id) }); } }
        }
      } catch(e){}
    }
    return JSON.stringify({ ok:true, shifts: out });
    """

    // MARK: - Group history (admin) — the WHOLE group's shifts via schedule/range with NO emp filter.
    // (Confirmed: dropping emp_id returns every doctor, all units, cross-department, back to Jan 2025.)
    // One fast API call per month — replaces the slow, unreliable viewer paging.

    private struct GroupShiftsResult: Decodable { let ok: Bool; let shifts: [RawSlot] }

    func fetchGroupShifts(since sinceYYYYMM01: String) async -> [RawSlot]? {
        let js = Self.groupShiftsJS.replacingOccurrences(of: "__SINCE__", with: sinceYYYYMM01)
        guard let json = (try? await evalAsync(js)) as? String,
              let data = json.data(using: .utf8),
              let r = try? JSONDecoder().decode(GroupShiftsResult.self, from: data), r.ok else {
            hbLog.log("group shifts: unavailable (token not ready)"); return nil
        }
        hbLog.log("group shifts: \(r.shifts.count, privacy: .public) slots (all doctors) since \(sinceYYYYMM01, privacy: .public)")
        return r.shifts
    }

    private static let groupShiftsJS = """
    const auth = window.__lbAuth || '';
    if (!auth) return JSON.stringify({ ok:false, shifts:[] });
    const startY = parseInt('__SINCE__'.slice(0,4), 10);
    const endY = new Date().getUTCFullYear() + 1;
    const out = [], seen = {};
    for (let y = startY; y <= endY; y++){
      const url = 'https://lbapi.lightning-bolt.com/schedule/range/?start_date='+y+'0101&end_date='+y+'1231&listed=true';
      try {
        const r = await fetch(url, { headers: { Authorization: auth } });
        if (r.ok) {
          const j = await r.json();
          const arr = Array.isArray(j) ? j : (j.data || j.slots || []);
          for (let k=0;k<arr.length;k++){ const a = arr[k];
            if (a && a.slot_id && !seen[a.slot_id]) { seen[a.slot_id]=1;
              out.push({ slot_id:a.slot_id, date:a.slot_date, start:a.start_time, stop:a.stop_time,
                         unit:a.assign_display_name||a.assign_compact_name||'', offerer:a.display_name||'',
                         emp:(a.emp_id!=null?(''+a.emp_id):'') }); } }
        }
      } catch(e){}
    }
    return JSON.stringify({ ok:true, shifts: out });
    """

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
