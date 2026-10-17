import SwiftUI
import Security

// MARK: - Colleague notes (OWNER ONLY — never in the Guide or Android)
//
// The owner's own knowledge the roster can't show — locum (only if already in town), retired, not started yet,
// ED is their main gig, prefers no nights… Feeds "Who could cover?" and drops retired people (and no-longer-SICU people for
// SICU shifts) from the give-away / swap pickers. Lives in a PRIVATE Supabase table (stage2/cover_notes.sql): the public key can't read it, only
// RPCs that check the owner's app secret. Cached on the phone so it works offline.

enum CoverTag: String, CaseIterable, Identifiable {
    case locum, retired, notstarted, nosicu, ed, rarecca, nonights, hospitalist
    var id: String { rawValue }
    var label: String {
        switch self {
        case .locum:       return "Locum — only if already in town"
        case .retired:     return "Retired / moved — hide everywhere"
        case .notstarted:  return "Hasn't started yet"
        case .nosicu:      return "No longer does SICU"
        case .ed:          return "ED is their main gig"
        case .rarecca:     return "Rarely does CCA"
        case .nonights:    return "Prefers no nights"
        case .hospitalist: return "Mostly hospitalist"
        }
    }
}

/// The owner's random app secret — made once, kept in iCloud Keychain (synced, so a new phone has it too).
/// Nobody types it; it just unlocks the private notes table.
enum OwnerSecret {
    private static let service = "wb.owner.secret", account = "owner"
    private static var base: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: account, kSecAttrSynchronizable as String: kCFBooleanTrue!]
    }
    static func get() -> String {
        var q = base; q[kSecReturnData as String] = true
        var out: AnyObject?
        if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
           let d = out as? Data, let s = String(data: d, encoding: .utf8), !s.isEmpty { return s }
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let s = bytes.map { String(format: "%02x", $0) }.joined()
        var add = base; add[kSecValueData as String] = Data(s.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(add as CFDictionary, nil)
        return s
    }
}

extension AppModel {
    static let coverNotesKey = "hb_cover_notes"

    /// Pull the notes (owner only). First run claims the private table with this phone's secret. A failed read
    /// keeps the cached notes.
    func loadCoverNotes() async {
        guard isOwner, !demo else { return }
        let secret = OwnerSecret.get()
        var rows = await Supabase.coverNotes(secret: secret)
        if rows == nil, await Supabase.claimOwner(secret: secret) { rows = await Supabase.coverNotes(secret: secret) }
        guard let rows else { coverNotesStatus = "Couldn't reach the notes — showing the saved copy."; return }
        coverNotesStatus = nil
        if rows != coverNotes { coverNotes = rows }
    }

    /// Save one person's note (empty tags + note = remove). Applied on the phone at once, then sent.
    @discardableResult
    func setCoverNote(name: String, tags: [CoverTag], note: String) async -> Bool {
        let t = tags.map(\.rawValue), n = note.trimmingCharacters(in: .whitespacesAndNewlines)
        var list = coverNotes.filter { $0.name != name }
        if !t.isEmpty || !n.isEmpty { list.append(.init(name: name, tags: t, note: n.isEmpty ? nil : n)) }
        coverNotes = list.sorted { $0.name < $1.name }
        let ok = await Supabase.putCoverNote(secret: OwnerSecret.get(), name: name, tags: t, note: n.isEmpty ? nil : n)
        coverNotesStatus = ok ? nil : "Saved on this phone — couldn't reach the server, try again later."
        return ok
    }

    /// Notes keyed by roster display name. A note saved under part of a name ("Sam") applies when exactly one
    /// person in the roster has all those words in their name.
    var coverNotesByName: [String: Supabase.SupaCoverNote] {
        let key = "\(rosterVersion)|\(coverNotesVersion)"
        if let m = coverNotesMemo, m.key == key { return m.map }
        let names = Set(roster.values)
        var map = [String: Supabase.SupaCoverNote]()
        for n in coverNotes {
            if names.contains(n.name) { map[n.name] = n; continue }
            let words = n.name.lowercased().split(separator: " ")
            let hits = names.filter { full in
                let fw = Set(full.lowercased().split(separator: " ")); return words.allSatisfy { fw.contains($0) }
            }
            if hits.count == 1, let h = hits.first, map[h] == nil { map[h] = n }
        }
        coverNotesMemo = (key, map)
        return map
    }
    func coverTags(_ name: String) -> Set<CoverTag> {
        Set((coverNotesByName[name]?.tags ?? []).compactMap(CoverTag.init(rawValue:)))
    }
    /// Retired / moved — dropped from the owner's give-away, swap and cover lists.
    func isRetired(_ name: String) -> Bool { isOwner && coverTags(name).contains(.retired) }
}

// MARK: - Editing

/// Every colleague (retired included, so they can be brought back), with their notes. Owner only.
struct ColleagueNotesView: View {
    @EnvironmentObject var model: AppModel
    @State private var editing: EditName?
    @State private var search = ""
    struct EditName: Identifiable { let id: String }

    private var people: [String] {
        let all = Set(model.roster.values.filter { !$0.isEmpty }).union(model.coverNotesByName.keys)
        let list = all.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        return search.isEmpty ? list : list.filter { $0.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List {
            if let s = model.coverNotesStatus { Text(s).font(.caption).foregroundStyle(.orange) }
            Section {
                ForEach(people, id: \.self) { name in
                    Button { editing = EditName(id: name) } label: { NoteRow(name: name) }.tint(.primary)
                }
            } footer: {
                Text("Only you see these. They shape “Who could cover?”; retired people are hidden from your give-away and swap lists.")
            }
        }
        .navigationTitle("Colleague notes").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Search colleagues")
        .sheet(item: $editing) { CoverNoteEditor(name: $0.id) }
        .task { await model.loadCoverNotes() }
    }
}

struct NoteRow: View {
    @EnvironmentObject var model: AppModel
    let name: String
    var body: some View {
        let n = model.coverNotesByName[name]
        VStack(alignment: .leading, spacing: 3) {
            Text(name).foregroundStyle(model.coverTags(name).contains(.retired) ? .secondary : .primary)
            let tags = CoverTag.allCases.filter { model.coverTags(name).contains($0) }
            if !tags.isEmpty || n?.note != nil {
                Text((tags.map { $0.label.components(separatedBy: " — ").first ?? $0.label } + [n?.note].compactMap { $0 })
                        .joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }
}

struct CoverNoteEditor: View {
    let name: String
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var tags: Set<CoverTag> = []
    @State private var note = ""
    @State private var saving = false

    var body: some View {
        NavigationStack {
            Form {
                Section("About \(name)") {
                    ForEach(CoverTag.allCases) { t in
                        Toggle(t.label, isOn: Binding(get: { tags.contains(t) },
                                                      set: { on in if on { tags.insert(t) } else { tags.remove(t) } }))
                    }
                }
                Section("Note") { TextField("Anything else worth remembering", text: $note, axis: .vertical) }
            }
            .navigationTitle(name).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        saving = true
                        Task {
                            // The note may be stored under a short name ("Sam") — save under the full name, drop the old.
                            if let old = model.coverNotesByName[name]?.name, old != name {
                                await model.setCoverNote(name: old, tags: [], note: "")
                            }
                            await model.setCoverNote(name: name, tags: CoverTag.allCases.filter { tags.contains($0) }, note: note)
                            dismiss()
                        }
                    }.disabled(saving)
                }
            }
            .onAppear {
                tags = model.coverTags(name)
                note = model.coverNotesByName[name]?.note ?? ""
            }
        }
    }
}
