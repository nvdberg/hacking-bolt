import SwiftUI

/// Pick which of my upcoming shifts to give away → hands the chosen shift to the wizard.
struct GiveAwayPicker: View {
    @Environment(\.dismiss) private var dismiss
    let shifts: [MyShift]
    let onPick: (MyShift) -> Void

    private func nice(_ iso: String) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: iso) else { return iso }
        f.dateFormat = "EEE, MMM d"; return f.string(from: d)
    }
    var body: some View {
        NavigationStack {
            List(shifts) { s in
                Button { onPick(s) } label: {
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 5).fill(Units.info[s.unit]!.color).frame(width: 5, height: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Units.info[s.unit]!.full).font(.subheadline.weight(.semibold))
                            Text("\(nice(s.date)) · \(s.start)–\(s.end)").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Which shift?")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
        }
    }
}

/// Give away one of my shifts — to the whole pool or one colleague — with a note/reason (Matt's ask; LB's own
/// note UX is poor, and LB can't note group offers at all). REAL schedule mutation, behind an explicit confirm;
/// individual offers are reversible via cancel until accepted.
struct GiveAwayWizard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let shift: MyShift
    /// When the tapped day is a Pasqua Rapid+MSU pair, both halves are passed so we can offer 24h / Rapid / MSU.
    var pasqua: (rapid: MyShift, msu: MyShift)? = nil

    @State private var everyone = false
    @State private var selectedEmps: Set<Int> = []   // one or several specific colleagues to offer/text
    @State private var freeText = ""
    @State private var phase: Phase = .form
    @State private var confirming = false
    @State private var failMessage: String?
    @State private var failPartial = false          // half a Pasqua 24h went through → don't claim "nothing changed" / don't re-offer
    @State private var giveWhole = true          // whole shift vs a part (split)
    @State private var giveStartISO = ""         // full "yyyy-MM-ddTHH:mm:00" of the portion to hand off
    @State private var giveEndISO = ""
    @State private var pasquaPart: PasquaPart = .both

    enum Phase: Equatable { case form, sending, doneOne, doneGroup, failed }
    enum PasquaPart: String, CaseIterable { case both = "24h", rapid = "Rapid", msu = "MSU" }

    /// The shift actually being given away — for a Pasqua day this reflects the 24h / Rapid / MSU choice
    /// (24h carries both LB slots via slotID + slotID2, so the give-away moves both halves).
    private var activeShift: MyShift {
        guard let p = pasqua else { return shift }
        switch pasquaPart {
        case .both:  return MyShift(date: p.rapid.date, unit: .PRR, start: "08:00", end: "08:00", overnight: true,
                                    slotID: p.rapid.slotID, slotID2: p.msu.slotID, templateID: p.rapid.templateID ?? p.msu.templateID)
        case .rapid: return p.rapid
        case .msu:   return p.msu
        }
    }
    private var isPasqua24h: Bool { pasqua != nil && pasquaPart == .both }

    private var unit: UnitInfo { Units.info[activeShift.unit]! }
    private var whatShort: String { isPasqua24h ? "Pasqua 24h" : unit.short }
    private var niceDate: String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: activeShift.date) else { return activeShift.date }
        f.dateFormat = "EEE, MMM d"; return f.string(from: d)
    }
    private var note: String { freeText.trimmingCharacters(in: .whitespacesAndNewlines) }
    // Eligibility scans the whole group history — compute it once per shift/data change, not on every note keystroke.
    @State private var eligible: [(emp: Int, name: String)] = []
    private var eligibleSig: String { "\(activeShift.date)|\(activeShift.unit.rawValue)|\(activeShift.overnight)|\(model.whoVersion)|\(model.roster.count)" }
    private var oneEmp: Int? { selectedEmps.count == 1 ? selectedEmps.first : nil }
    private func nameOf(_ emp: Int) -> String { model.roster[emp] ?? "" }
    private func firstOf(_ emp: Int) -> String { nameOf(emp).split(separator: " ").first.map(String.init) ?? nameOf(emp) }
    private var oneName: String { oneEmp.map(nameOf) ?? "" }
    private var oneFirst: String { oneEmp.map(firstOf) ?? "" }
    private func cellFor(_ emp: Int) -> String? { let c = model.directory[emp]?.cell; return (c?.isEmpty ?? true) ? nil : c }
    private var chosen: Bool { everyone || !selectedEmps.isEmpty }
    private var isGroup: Bool { everyone || selectedEmps.count >= 2 }   // a group offer (pool or several picked)
    private var recipientLabel: String {
        if everyone { return "Everyone who can work it" }
        switch selectedEmps.count { case 0: return "Choose…"; case 1: return oneName; default: return "\(selectedEmps.count) colleagues" }
    }
    // Messages (no "first to reply" — reads as a race; keep it neutral).
    private func askOne(_ emp: Int) -> String {
        "Hi \(firstOf(emp)), are you able to take my \(whatShort) on \(niceDate)? I'm offering it to you — let me know. Thanks!"
    }
    private func askGroup() -> String {
        "Hi — are any of you able to take my \(whatShort) on \(niceDate)? Let me know if you can, thanks!"
    }
    // Day-aware 30-min timeline across the whole shift (handles 24h + overnight): each step carries a full ISO
    // timestamp (correct day) + a label ("08:00", "00:00 (+1)", …).
    private var timeline: [(iso: String, label: String)] {
        func mins(_ s: String) -> Int { let p = s.split(separator: ":").compactMap { Int($0) }; return p.count == 2 ? p[0]*60 + p[1] : 0 }
        let startM = mins(activeShift.start), endM = mins(activeShift.end)
        let span = activeShift.overnight ? (1440 - startM + endM) : (endM - startM)
        guard span > 0 else { return [] }
        var out: [(String, String)] = []; var t = 0
        while t <= span {
            let abs = startM + t, dayOff = abs / 1440, clk = abs % 1440
            let date = dayOff == 0 ? activeShift.date : AppModel.addDays(activeShift.date, dayOff)
            let iso = String(format: "%@T%02d:%02d:00", date, clk / 60, clk % 60)
            let label = String(format: "%02d:%02d", clk / 60, clk % 60) + (dayOff > 0 ? " (+\(dayOff))" : "")
            out.append((iso, label)); t += 30
        }
        return out
    }
    private func label(forISO iso: String) -> String { timeline.first { $0.iso == iso }?.label ?? String(iso.dropFirst(11).prefix(5)) }
    private var partValid: Bool { !giveStartISO.isEmpty && !giveEndISO.isEmpty && giveStartISO < giveEndISO }
    // A time-split can only go to ONE person or the whole pool — offering a part to several picked people isn't a
    // thing, so selecting 2+ specific colleagues always hands over the whole shift.
    private var effectiveWhole: Bool { giveWhole || (selectedEmps.count >= 2 && !everyone) }
    private var sendable: Bool { chosen && (effectiveWhole || partValid) }
    private var giveHours: String { effectiveWhole ? "\(activeShift.start)–\(activeShift.end)" : "\(label(forISO: giveStartISO))–\(label(forISO: giveEndISO))" }
    private var recipientPhrase: String {
        if everyone { return "the pool" }
        return selectedEmps.count >= 2 ? "\(selectedEmps.count) colleagues" : oneName
    }
    private var sendLabel: String {
        if everyone { return "Post to the pool" }
        return selectedEmps.count >= 2 ? "Offer to \(selectedEmps.count) colleagues" : "Give away to \(oneName)"
    }
    private var confirmTitle: String {
        let what = effectiveWhole ? "your \(whatShort) shift" : "the \(giveHours) part of your \(whatShort) shift"
        return everyone ? "Post \(what) on \(niceDate) to the pool?" : "Offer \(what) on \(niceDate) to \(recipientPhrase)?"
    }
    private var confirmMessage: String {
        let split = effectiveWhole ? "" : "This splits your shift in Lightning Bolt (you keep the rest). "
        return split + (isGroup ? "Anyone eligible you offered it to can pick it up. You can withdraw it in Lightning Bolt."
                                : "They'll get it as a pending offer. You can cancel until they accept.")
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .form:      form
                case .sending:   sending
                case .doneOne, .doneGroup: done
                case .failed:    failed
                }
            }
            .navigationTitle("Give away shift")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { if phase == .form { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } } }
        }
        .onAppear { eligible = model.eligibleColleagues(for: activeShift) }
        .onChange(of: eligibleSig) { _, _ in eligible = model.eligibleColleagues(for: activeShift) }
        .task {
            if giveStartISO.isEmpty, timeline.count >= 2 { giveStartISO = timeline[timeline.count / 2].iso; giveEndISO = timeline.last!.iso }
            if model.colleagues.isEmpty { await model.loadGroupHistory() }
        }
    }

    // MARK: Form (clean, sectioned — no overlap)
    private var form: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    RoundedRectangle(cornerRadius: 6).fill(unit.color).frame(width: 6, height: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(isPasqua24h ? "Pasqua (Rapid + MSU)" : unit.full).font(.headline)
                        Text("\(niceDate) · \(activeShift.start)–\(activeShift.end)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            }
            if pasqua != nil {
                // Pasqua Rapid+MSU is one 24h shift — hand over both, or just one half (each is a separate LB slot).
                Section("Which part?") {
                    Picker("", selection: $pasquaPart) {
                        ForEach(PasquaPart.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                    Text(pasquaPart == .both ? "Gives away the whole 24h (Rapid + MSU)."
                         : "Gives away just the \(pasquaPart == .rapid ? "Rapid (08:00–17:00)" : "MSU (17:00–08:00)") half; you keep the other.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            } else {
                Section("How much?") {
                    Picker("", selection: $giveWhole) { Text("Whole shift").tag(true); Text("Just a part").tag(false) }
                        .pickerStyle(.segmented)
                    if !giveWhole {
                        Picker("Give away from", selection: $giveStartISO) {
                            ForEach(timeline.dropLast(), id: \.iso) { Text($0.label).tag($0.iso) }
                        }
                        Picker("until", selection: $giveEndISO) {
                            ForEach(timeline.filter { $0.iso > giveStartISO }, id: \.iso) { Text($0.label).tag($0.iso) }
                        }
                        Text("You keep the rest. Heads-up: Lightning Bolt only lets a scheduler merge pieces back — so split when you mean it.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Give it to") {
                NavigationLink {
                    RecipientList(colleagues: eligible, everyone: $everyone, selected: $selectedEmps,
                                  cellFor: cellFor, textOne: { openSwapText(askOne($0), cell: cellFor($0) ?? "") },
                                  textMany: { emps in openGroupText(askGroup(), cells: emps.compactMap(cellFor)) })
                } label: {
                    HStack {
                        Image(systemName: (everyone || selectedEmps.count > 1) ? "person.3.fill" : "person.fill").foregroundStyle(Theme.accent)
                        Text(recipientLabel).foregroundStyle(chosen ? .primary : .secondary)
                    }
                }
            }
            Section("Note (optional)") {
                TextField("Add a note", text: $freeText, axis: .vertical).lineLimit(1...4)
            }
            if everyone {
                Section { Text("Posted to the pool, whoever's eligible can grab it. LB can't attach a note here — Working-Bolt keeps yours and shows it in the Pool.")
                    .font(.caption).foregroundStyle(.secondary) }
            }
        }
        .safeAreaInset(edge: .bottom) {
            Button { confirming = true } label: {
                Text(!chosen ? "Choose who gets it" : (!sendable ? "Set the times" : sendLabel))
                    .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Capsule().fill(!sendable ? Color.gray.opacity(0.4) : Theme.accent))
                    .foregroundStyle(.white)
            }
            .disabled(!sendable)
            .padding(.horizontal, 16).padding(.bottom, 8)
            .confirmationDialog(confirmTitle, isPresented: $confirming, titleVisibility: .visible) {
                Button(sendLabel, role: effectiveWhole ? nil : .destructive) { send() }
                Button("Cancel", role: .cancel) {}
            } message: { Text(confirmMessage) }
        }
    }

    // MARK: Other phases
    private var sending: some View {
        VStack(spacing: 14) { ProgressView().scaleEffect(1.3)
            Text(isGroup ? "Offering…" : "Offering to \(oneName)…").foregroundStyle(.secondary) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var doneTitle: String {
        if phase == .doneOne { return "Offered to \(oneName)" }
        return everyone ? "Posted to the pool" : "Offered to \(selectedEmps.count) colleagues"
    }

    private var done: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill").font(.system(size: 54)).foregroundStyle(.green)
            Text(doneTitle).font(.title3.weight(.semibold))
            Text("\(whatShort) · \(niceDate)." + (phase == .doneGroup
                 ? " Whoever's eligible can pick it up." : " Pending until they accept — you can cancel below."))
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            if !note.isEmpty {
                Text("“\(note)”").font(.subheadline).italic()
                    .padding(12).background(RoundedRectangle(cornerRadius: 10).fill(Color.gray.opacity(0.12)))
            }
            VStack(spacing: 10) {
                if phase == .doneOne, let e = oneEmp, let cell = cellFor(e) {
                    Button { openSwapText(askOne(e), cell: cell) } label: {
                        Label("Text \(oneFirst)", systemImage: "message.fill").frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().fill(Theme.accent.opacity(0.15))).foregroundStyle(Theme.accent)
                    }
                }
                if phase == .doneOne {
                    Button(role: .destructive) { cancelOffer() } label: {
                        Text("Cancel this offer").frame(maxWidth: .infinity).padding(.vertical, 12)
                            .background(Capsule().stroke(Color.red, lineWidth: 1)).foregroundStyle(.red)
                    }
                }
                Button { dismiss() } label: {
                    Text("Done").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                        .background(Capsule().fill(Theme.accent)).foregroundStyle(.white)
                }
            }.padding(.horizontal, 30).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    private var failed: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 48)).foregroundStyle(.orange)
            Text("Couldn't give it away").font(.title3.weight(.semibold))
            Text(failMessage ?? "Nothing was changed. Check your connection and try again.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 24)
            if !failPartial { Text("Nothing was changed on your schedule.").font(.caption).foregroundStyle(.secondary) }
            Button { if failPartial { dismiss() } else { failMessage = nil; phase = .form } } label: {
                Text(failPartial ? "Done" : "Back").font(.headline).frame(maxWidth: .infinity).padding(.vertical, 12)
                    .background(Capsule().fill(Theme.accent)).foregroundStyle(.white)
            }.padding(.horizontal, 40).padding(.top, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity).padding()
    }

    // MARK: Actions
    private func send() {
        phase = .sending
        Task {
            let out: LBWebSource.WriteOutcome
            let groupEmps = everyone ? eligible.map { $0.emp } : Array(selectedEmps)
            if !effectiveWhole, everyone {                                   // time-split → the pool
                out = await model.giveAwayPart(shift: activeShift, giveStartISO: giveStartISO, giveEndISO: giveEndISO, toEmp: nil, everyone: true, note: note)
            } else if !effectiveWhole, let e = oneEmp {                      // time-split → one colleague
                out = await model.giveAwayPart(shift: activeShift, giveStartISO: giveStartISO, giveEndISO: giveEndISO, toEmp: e, everyone: false, note: note)
            } else if isGroup {                                             // whole shift → pool or the picked group
                out = await model.giveAwayToGroup(shift: activeShift, toEmps: groupEmps, note: note, reason: nil)
            } else if let e = oneEmp {                                       // whole shift → one colleague
                out = await model.giveAway(shift: activeShift, toEmp: e, note: note, reason: nil)
            } else { phase = .failed; return }
            if out.ok { phase = isGroup ? .doneGroup : .doneOne } else { failMessage = out.message; failPartial = out.partial; phase = .failed }
        }
    }
    private func cancelOffer() {
        guard let slot = activeShift.slotID, let emp = oneEmp else { return }
        phase = .sending
        Task { _ = await model.cancelGiveAway(slotID: slot, toEmp: emp); dismiss() }
    }
}

/// Searchable multi-select recipient picker: "Everyone" (pool) at the top, then tick one or several colleagues.
/// Three separate text actions (kept distinct): 💬 per person, "Text selected", and "Text everyone who can work it".
struct RecipientList: View {
    let colleagues: [(emp: Int, name: String)]
    @Binding var everyone: Bool
    @Binding var selected: Set<Int>
    let cellFor: (Int) -> String?              // nil → no number on file, hide that person's 💬
    let textOne: (Int) -> Void                 // text just this colleague
    let textMany: ([Int]) -> Void              // group text to the given colleagues
    @Environment(\.dismiss) private var dismiss
    @State private var search = ""

    private var filtered: [(emp: Int, name: String)] {
        search.isEmpty ? colleagues : colleagues.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }
    private var allEmps: [Int] { colleagues.map { $0.emp } }
    private var textableAll: [Int] { allEmps.filter { cellFor($0) != nil } }
    private var textableSelected: [Int] { Array(selected).filter { cellFor($0) != nil } }

    var body: some View {
        List {
            Section {
                Button { everyone = true; selected = []; } label: {
                    HStack {
                        Image(systemName: "person.3.fill").foregroundStyle(Theme.accent)
                        Text("Everyone who can work it")
                        Spacer()
                        if everyone { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                    }
                }
            } footer: { Text("Offer it to everyone eligible — anyone free that day can pick it up.") }

            Section("Or pick one or more (who can take it)") {
                ForEach(filtered, id: \.emp) { c in
                    HStack {
                        Image(systemName: selected.contains(c.emp) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selected.contains(c.emp) ? Theme.accent : Theme.muted)
                        Text(c.name).foregroundStyle(.primary)
                        Spacer()
                        if cellFor(c.emp) != nil {
                            Button { textOne(c.emp) } label: { Image(systemName: "message.fill").foregroundStyle(Theme.accent) }
                                .buttonStyle(.borderless)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture { everyone = false; if selected.contains(c.emp) { selected.remove(c.emp) } else { selected.insert(c.emp) } }
                }
            }

            // The two group-text actions (distinct from the per-person 💬 above).
            Section("Text to ask") {
                if !textableSelected.isEmpty {
                    Button { textMany(textableSelected) } label: {
                        Label("Text selected (\(textableSelected.count))", systemImage: "text.bubble.fill")
                    }
                }
                if !textableAll.isEmpty {
                    Button { textMany(textableAll) } label: {
                        Label("Text everyone who can work it (\(textableAll.count))", systemImage: "bubble.left.and.bubble.right.fill")
                    }
                }
            }
        }
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search colleagues")
        .navigationTitle("Give it to").navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
    }
}
