import SwiftUI

/// Bird's-eye mini month grid (like the web pool sidebar): my shifts in unit colour,
/// post-call days lighter, open-shift days ringed in amber, today outlined.
struct MiniMonth: View {
    let year: Int
    let month: Int                 // 1...12
    let fill: [Int: Color]         // day-of-month -> shift colour
    let post: [Int: Color]         // day-of-month -> post-call (lighter)
    let open: Set<Int>             // day-of-month with an open shift
    let todayDay: Int?             // day-of-month if today falls in this month
    var fuseStart: Set<Int> = []   // on-call days that fuse into the next (post-call) day
    var fuseEnd: Set<Int> = []     // post-call days that continue from the previous day

    private let cols = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
    private let dow = ["S", "M", "T", "W", "T", "F", "S"]
    private let cal = Calendar(identifier: .gregorian)

    var body: some View {
        var comp = DateComponents(); comp.year = year; comp.month = month; comp.day = 1
        let first = cal.date(from: comp) ?? Date()
        let firstWeekday = cal.component(.weekday, from: first) - 1     // 0 = Sunday
        let days = cal.range(of: .day, in: .month, for: first)?.count ?? 30

        return VStack(alignment: .leading, spacing: 5) {
            Text(monthName(first)).font(.caption2.weight(.bold)).foregroundStyle(Theme.ink)
            LazyVGrid(columns: cols, spacing: 3) {
                ForEach(1000..<1007, id: \.self) { i in       // header id-space (avoid collision with day ids)
                    Text(dow[i - 1000]).font(.system(size: 8)).foregroundStyle(Theme.muted)
                }
                ForEach(2000..<(2000 + firstWeekday), id: \.self) { _ in Color.clear.frame(height: 17) }   // pad id-space
                ForEach(1...days, id: \.self) { d in cell(d) }   // day cells (ids 1…31)
            }
        }
        .padding(9)
        .frame(width: 176)
        .background(Theme.panel)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.05), radius: 6, y: 2)
    }

    @ViewBuilder private func cell(_ d: Int) -> some View {
        let filled = fill[d]
        let fStart = fuseStart.contains(d), fEnd = fuseEnd.contains(d)
        ZStack {
            if let c = filled {
                corners(fuseRight: fStart).fill(c).padding(.trailing, fStart ? -4 : 0)      // on-call bleeds right to meet post-call
            } else if let c = post[d] {
                corners(fuseLeft: fEnd).fill(c.opacity(0.30))                                // post-call: square left edge, no bleed (avoids overlap)
            }
            if open.contains(d) {
                RoundedRectangle(cornerRadius: 4).stroke(Theme.available, lineWidth: 1.6)
            }
            Text("\(d)")
                .font(.system(size: 9, weight: filled != nil ? .bold : .regular))
                .foregroundStyle(filled != nil ? .white : Theme.muted)
        }
        .frame(height: 17)
        .overlay {
            if todayDay == d { RoundedRectangle(cornerRadius: 4).stroke(Theme.accent, lineWidth: 1.6) }
        }
        .zIndex(filled != nil ? 1 : 0)   // on-call cells sit above post-call so the fused edge reads cleanly
    }

    private func corners(fuseLeft: Bool = false, fuseRight: Bool = false) -> UnevenRoundedRectangle {
        UnevenRoundedRectangle(cornerRadii: .init(
            topLeading:     fuseLeft  ? 0 : 4,
            bottomLeading:  fuseLeft  ? 0 : 4,
            bottomTrailing: fuseRight ? 0 : 4,
            topTrailing:    fuseRight ? 0 : 4))
    }

    private func monthName(_ date: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "MMM yyyy"
        return f.string(from: date)
    }
}
