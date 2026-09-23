import SwiftUI

/// The "My Posts" segment in the Pool — shifts I've put up for pickup or swap. Pending ones I'm still waiting
/// on are pinned at the top; the ones that were taken are grouped by month below (newest expanded, older
/// folded away), and the whole "picked up" block hides behind the eye toggle.
struct MyPostsList: View {
    let posts: [MyPost]
    @EnvironmentObject var model: AppModel
    @State private var showCompleted = true                 // eye toggle — shown by default
    @State private var collapsed: Set<String> = []          // completed-month keys the user has folded away
    @State private var appliedDefaultCollapse = false
    @State private var cancelTarget: MyPost?                // pending post awaiting a cancel-confirm
    @State private var cancelError: String?                 // LB rejected the cancel → show a hint
    @State private var cancelling = false

    private var pending: [MyPost] {
        let p = posts.filter { $0.status == .pending }
        return p.sorted { $0.iso < $1.iso }
    }
    private var completed: [MyPost] { posts.filter { $0.status == .completed } }

    private func monthKey(_ p: MyPost) -> String { String((p.when ?? p.iso).prefix(7)) }   // "YYYY-MM"
    private var completedMonths: [String] { Array(Set(completed.map(monthKey))).sorted(by: >) }
    /// Collapse all but the two most recent months — once, the first time there ARE months (posts load async).
    private func applyDefaultCollapse() {
        guard !appliedDefaultCollapse, !completedMonths.isEmpty else { return }
        appliedDefaultCollapse = true
        collapsed = Set(completedMonths.dropFirst(2))
    }
    private func monthTitle(_ k: String) -> String {
        let names = ["", "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let parts = k.split(separator: "-")
        guard parts.count == 2, let y = Int(parts[0]), let m = Int(parts[1]), (1...12).contains(m) else { return k }
        return "\(names[m]) \(y)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if pending.isEmpty && completed.isEmpty {
                Text("You haven't posted any shifts.\nGive one away or offer a swap and it'll show up here.")
                    .multilineTextAlignment(.center).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity).padding(.top, 40)
            }

            if !pending.isEmpty {
                sectionHeader("Waiting for pickup", count: pending.count, icon: "clock")
                ForEach(pending) { p in
                    PostCard(post: p, onCancel: p.slotID != nil ? { cancelTarget = p } : nil)
                }
            }

            if !completed.isEmpty {
                HStack {
                    sectionHeader("Picked up", count: completed.count, icon: "checkmark.circle")
                    Spacer()
                    Button { withAnimation { showCompleted.toggle() } } label: {
                        Image(systemName: showCompleted ? "eye" : "eye.slash").foregroundStyle(Theme.muted)
                    }
                    .accessibilityLabel(showCompleted ? "Hide picked-up posts" : "Show picked-up posts")
                }
                .padding(.top, 8)

                if showCompleted {
                    ForEach(completedMonths, id: \.self) { mk in
                        let rows = completed.filter { monthKey($0) == mk }
                            .sorted { ($0.when ?? $0.iso) > ($1.when ?? $1.iso) }
                        DisclosureGroup(isExpanded: expansion(mk)) {
                            ForEach(rows) { PostCard(post: $0) }
                        } label: {
                            Text("\(monthTitle(mk))  ·  \(rows.count)")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                        }
                        .tint(Theme.muted)
                    }
                }
            }

            if !posts.isEmpty {                                  // quiet easter egg — the feature was Hein's idea
                Text("Hein's idea 🤝").font(.caption2).italic()
                    .foregroundStyle(Theme.muted).frame(maxWidth: .infinity).padding(.top, 10)
            }
        }
        .onAppear { applyDefaultCollapse() }
        .onChange(of: completedMonths) { _, _ in applyDefaultCollapse() }   // posts can arrive after the list appears
        .confirmationDialog("Cancel this offer?",
                            isPresented: Binding(get: { cancelTarget != nil }, set: { if !$0 { cancelTarget = nil } }),
                            titleVisibility: .visible) {
            Button("Withdraw offer", role: .destructive) {
                guard let p = cancelTarget else { return }
                cancelTarget = nil; cancelling = true
                Task { let ok = await model.cancelPost(p); cancelling = false
                       if !ok { cancelError = "Lightning Bolt didn't cancel it — try withdrawing it in LB." } }
            }
            Button("Keep it", role: .cancel) { cancelTarget = nil }
        } message: {
            if let p = cancelTarget { Text("\(p.kind.rawValue) · \(fmt(p.iso, "EEE, MMM d")). This withdraws it from the pool.") }
        }
        .alert("Couldn't cancel", isPresented: Binding(get: { cancelError != nil }, set: { if !$0 { cancelError = nil } })) {
            Button("OK", role: .cancel) { cancelError = nil }
        } message: { Text(cancelError ?? "") }
    }

    private func expansion(_ k: String) -> Binding<Bool> {
        Binding(get: { !collapsed.contains(k) },
                set: { open in if open { collapsed.remove(k) } else { collapsed.insert(k) } })
    }

    private func sectionHeader(_ title: String, count: Int, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(Theme.muted)
            Text("\(title) (\(count))").font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
        }
    }
}

/// One row in My Posts — the shift's date, unit, whether it was a give-away or a swap, and who's on the
/// other end (waiting, or who took it).
struct PostCard: View {
    let post: MyPost
    var onCancel: (() -> Void)? = nil        // pending rows only → withdraw the offer
    private var info: UnitInfo { Units.info[post.unit] ?? UnitInfo(short: post.unit.rawValue, full: "", color: .gray) }
    private var pending: Bool { post.status == .pending }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(info.color).frame(width: 5)
            VStack(spacing: 0) {
                Text(fmt(post.iso, "EEE")).font(.caption2).foregroundStyle(Theme.muted)
                Text(fmt(post.iso, "d")).font(.title3.weight(.heavy)).foregroundStyle(info.color)
                Text(fmt(post.iso, "MMM").uppercased()).font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .frame(width: 46).padding(.leading, 8)
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 8) {
                    Text(info.short).font(.caption2).bold()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(info.color.opacity(0.16)).foregroundStyle(info.color).clipShape(Capsule())
                    Text(post.kind.rawValue).font(.system(size: 9.5, weight: .heavy))
                        .foregroundStyle(Theme.posted).padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Theme.posted.opacity(0.14)).clipShape(Capsule())
                }
                if !post.hoursLabel.isEmpty {
                    Text(post.hoursLabel).font(.caption).foregroundStyle(Theme.muted)
                }
                Text(subtitle).font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(.vertical, 12).padding(.leading, 12)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                statusBadge
                if pending, let onCancel {
                    Button(role: .destructive) { onCancel() } label: {
                        Text("Cancel").font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.borderless).tint(Theme.available)
                }
            }
            .padding(.trailing, 12)
        }
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.05), radius: 8, y: 3)
    }

    private var subtitle: String {
        if pending {
            if post.kind == .swap { return post.note ?? "Swap — waiting for a reply" }
            return "Waiting for a pickup"
        }
        let who = post.counterparty ?? "a colleague"
        var s = (post.kind == .swap ? "Swapped with " : "Picked up by ") + who
        if let w = post.when { s += " · " + fmt(String(w.prefix(10)), "MMM d") }
        return s
    }

    private var statusBadge: some View {
        Group {
            if pending {
                HStack(spacing: 3) { Text("Pending"); Image(systemName: "clock") }
                    .font(.caption.bold()).foregroundStyle(Theme.posted)
            } else {
                HStack(spacing: 3) { Text("Taken"); Image(systemName: "checkmark") }
                    .font(.caption.bold()).foregroundStyle(Theme.available)
            }
        }
        .frame(maxWidth: 96, alignment: .trailing)
    }
}
