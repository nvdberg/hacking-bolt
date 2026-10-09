import Foundation

/// Minimal Supabase (PostgREST) client over URLSession — no SDK dependency. Uses the project's PUBLIC
/// publishable key (safe to ship). Backend holds only shift logistics (no patient data). Not wired to any
/// UI yet — foundation for Option 2 (shared open-shift set + device push tokens) and Option 3 (offer notes).
///
/// Project: NMVDB / "Working bolt" (ca-central-1). Schema: open_shifts, offer_notes, devices (RLS on).
enum Supabase {
    static let baseURL = "https://qbtnxkzpddexczhcvxre.supabase.co/rest/v1"
    static let key = "sb_publishable_uqqWXuhGAPqd85yXC4rLsA_q7RX1zAQ"   // publishable/anon key — public by design

    // MARK: Models (mirror the tables)
    struct SupaOpenShift: Codable { let slot_id: Int; let date: String?; let unit: String?
        let start_time: String?; let stop_time: String?; let offerer: String?; let offerer_emp: Int? }
    struct SupaOfferNote: Codable { let slot_id: Int; let note: String?; let reason: String?; let by_emp: Int? }
    struct SupaDevice: Codable { let emp_id: Int?; let apns_token: String }
    struct SupaPickup: Codable { let slot_id: Int; let date: String?; let unit: String?
        let giver_emp: Int?; let giver: String?; let taker_emp: Int?; let taker: String?
        let kind: String?; let picked_up_at: String? }
    struct SupaCalSub: Codable { let emp_id: Int; let token: String; let enabled: Bool? }

    // MARK: Requests
    private static func request(_ path: String, method: String = "GET", body: Data? = nil, prefer: String? = nil) -> URLRequest {
        var req = URLRequest(url: URL(string: baseURL + path)!)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let prefer { req.setValue(prefer, forHTTPHeaderField: "Prefer") }
        req.httpBody = body
        req.timeoutInterval = 12
        return req
    }

    private static func send(_ req: URLRequest) async -> (ok: Bool, data: Data?) {
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              let code = (resp as? HTTPURLResponse)?.statusCode else { return (false, nil) }
        return ((200...299).contains(code), data)
    }

    // MARK: API
    /// The shared open-shift set (kept current by the poller) — a fallback/complement to the per-user LB fetch.
    static func openShifts() async -> [SupaOpenShift]? {
        let (ok, data) = await send(request("/open_shifts?select=*"))
        guard ok, let data else { return nil }
        return try? JSONDecoder().decode([SupaOpenShift].self, from: data)
    }

    /// Attach/replace the note on a give-away (upsert on slot_id) — powers group-offer notes LB can't store.
    static func putOfferNote(slotID: Int, note: String, reason: String?, byEmp: Int?) async -> Bool {
        let row = SupaOfferNote(slot_id: slotID, note: note, reason: reason, by_emp: byEmp)
        guard let body = try? JSONEncoder().encode([row]) else { return false }
        return await send(request("/offer_notes?on_conflict=slot_id", method: "POST", body: body,
                                  prefer: "resolution=merge-duplicates,return=minimal")).ok
    }

    /// All notes I've attached to my offers (slot_id → note) — labels my pending posts as swaps vs give-aways.
    static func myOfferNotes(byEmp: Int) async -> [Int: String]? {
        let (ok, data) = await send(request("/offer_notes?by_emp=eq.\(byEmp)&select=slot_id,note"))
        guard ok, let data, let rows = try? JSONDecoder().decode([SupaOfferNote].self, from: data) else { return nil }
        return Dictionary(rows.compactMap { r in r.note.map { (r.slot_id, $0) } }, uniquingKeysWith: { a, _ in a })
    }

    /// Every swap-tagged offer (reason "swap:…" / "swapback:…") — pairs the two halves of a two-way swap.
    static func swapNotes() async -> [SupaOfferNote]? {
        let (ok, data) = await send(request("/offer_notes?reason=like.swap*&select=slot_id,note,reason,by_emp"))
        guard ok, let data else { return nil }
        return try? JSONDecoder().decode([SupaOfferNote].self, from: data)
    }

    /// Read the note for a slot (shown in the Pool next to the offer).
    static func offerNote(slotID: Int) async -> SupaOfferNote? {
        let (ok, data) = await send(request("/offer_notes?slot_id=eq.\(slotID)&select=*"))
        guard ok, let data else { return nil }
        return (try? JSONDecoder().decode([SupaOfferNote].self, from: data))?.first
    }

    /// Shifts I posted that got picked up (kept current by the poller — current + prior years it scans) —
    /// powers "My Posts → Picked up". Returns all the poller has recorded for me, newest first.
    static func pickups(giverEmp: Int) async -> [SupaPickup]? {
        let path = "/pickups?giver_emp=eq.\(giverEmp)&select=*&order=picked_up_at.desc"
        let (ok, data) = await send(request(path))
        guard ok, let data else { return nil }
        return try? JSONDecoder().decode([SupaPickup].self, from: data)
    }

    /// Every shift that changed hands since `sinceLocal` ("YYYY-MM-DDTHH:MM:SS", Regina — the poller stores LB's
    /// local modified time) — powers the Pool's "Recently taken" list. Only date/unit/kind/time (+ emp numbers, to drop my own) are read, never names.
    static func recentPickups(sinceLocal: String) async -> [SupaPickup]? {
        let path = "/pickups?picked_up_at=gte.\(sinceLocal)&select=slot_id,date,unit,kind,giver_emp,taker_emp,picked_up_at&order=picked_up_at.desc&limit=40"
        let (ok, data) = await send(request(path))
        guard ok, let data else { return nil }
        return try? JSONDecoder().decode([SupaPickup].self, from: data)
    }

    // MARK: Hospital rosters + menus (captured on the Unit Board from the hospital network; read-only here)
    struct SupaRosterRow: Codable, Equatable, Sendable { let date: String; let unit: String; let role: String; let name: String? }
    struct SupaMenuItem: Codable { let name: String?; let price: String? }
    struct SupaMenuSection: Codable { let label: String?; let items: [SupaMenuItem]? }
    struct SupaMenuDay: Codable { let date: String?; let weekday: String?; let sections: [SupaMenuSection]? }
    struct SupaMenuPage: Codable { let site: String; let page: Int; let first_date: String?; let days: [SupaMenuDay]? }

    /// Intensivists (Petal) + cardiology (PDF) for a date range, inclusive — powers Who's On → double-tap.
    static func oncallRoster(from: String, to: String) async -> [SupaRosterRow]? {
        let path = "/oncall_roster?date=gte.\(from)&date=lte.\(to)&select=date,unit,role,name&limit=5000"
        let (ok, data) = await send(request(path))
        guard ok, let data else { return nil }
        return try? JSONDecoder().decode([SupaRosterRow].self, from: data)
    }

    /// Every captured cafeteria menu page (RGH / PH rotation) — powers More → Cafeteria menu.
    static func cafeteriaMenus() async -> [SupaMenuPage]? {
        let (ok, data) = await send(request("/cafeteria_menu?select=site,page,first_date,days&order=site,page"))
        guard ok, let data else { return nil }
        return try? JSONDecoder().decode([SupaMenuPage].self, from: data)
    }

    // MARK: Calendar sync (live subscribable feed)
    /// Public URL of a subscriber's live .ics — the poller regenerates the file at this path every few minutes.
    static func calendarURL(token: String) -> String {
        "https://qbtnxkzpddexczhcvxre.supabase.co/storage/v1/object/public/calendars/\(token).ics"
    }

    /// My existing calendar-feed row (stable token + on/off), if I've enrolled before — keyed on emp_id.
    /// `ok == false` means the lookup FAILED (offline / server hiccup) — distinct from "no row yet", so a caller
    /// never mints a fresh token (and breaks an existing subscription) just because the read didn't go through.
    static func calSub(emp: Int) async -> (ok: Bool, sub: SupaCalSub?) {
        let (ok, data) = await send(request("/cal_subs?emp_id=eq.\(emp)&select=emp_id,token,enabled"))
        guard ok, let data, let rows = try? JSONDecoder().decode([SupaCalSub].self, from: data) else { return (false, nil) }
        return (true, rows.first)
    }

    /// Turn my live calendar feed on/off (upsert on emp_id). The token stays stable so the subscribe URL
    /// never changes. `enabled=false` tells the poller to stop refreshing my file.
    static func enrollCalendar(emp: Int, token: String, enabled: Bool) async -> Bool {
        let row = SupaCalSub(emp_id: emp, token: token, enabled: enabled)
        guard let body = try? JSONEncoder().encode([row]) else { return false }
        return await send(request("/cal_subs?on_conflict=emp_id", method: "POST", body: body,
                                  prefer: "resolution=merge-duplicates,return=minimal")).ok
    }

    /// Register this device's APNs token for new-shift push alerts (upsert on apns_token).
    static func registerDevice(empID: Int?, token: String) async -> Bool {
        let row = SupaDevice(emp_id: empID, apns_token: token)
        guard let body = try? JSONEncoder().encode([row]) else { return false }
        return await send(request("/devices?on_conflict=apns_token", method: "POST", body: body,
                                  prefer: "resolution=merge-duplicates,return=minimal")).ok
    }
}
