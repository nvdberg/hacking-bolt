import SwiftUI

/// The branded opening screen: the ECG-bolt mark draws itself in, then the wordmark, tagline and a
/// witty line fade up. Commits to the teal/amber identity in both light & dark (a deliberate branded
/// moment). Auto-dismisses after ~2.2s; tap to skip.
struct LaunchScreen: View {
    var onDone: () -> Void

    @State private var trace = false     // ECG line draws in
    @State private var spark = false     // bolt flashes in
    @State private var lift  = false     // wordmark + copy rise
    @State private var beat  = false     // ambient heartbeat pulse while it holds
    @State private var strike = false            // red pen strikes through "Hacking"
    @State private var workingReveal: CGFloat = 0 // "Working" scrawls in above it
    @State private var qi    = 0         // current quip index — cycles while the screen holds

    // Editable pool (Settings → Witty lines), falling back to the built-in defaults if emptied.
    @State private var pool: [String] = {
        let q = QuipStore.shared.quips; return q.isEmpty ? QuipStore.defaults : q
    }()
    private let splashSecs: Double = 8.0        // dialed-in hold; tap to skip
    private var current: String { pool[qi % max(pool.count, 1)] }   // one random line per launch

    private let amber = Color(red: 0xF0/255, green: 0xB2/255, blue: 0x4A/255)

    var body: some View {
        ZStack {
            // Subtle black / graphite ground (matches the app icon) with a soft amber glow behind the mark.
            LinearGradient(colors: [Color(red: 0x2a/255, green: 0x2c/255, blue: 0x31/255),
                                    Color(red: 0x0a/255, green: 0x0b/255, blue: 0x0e/255)],
                           startPoint: .top, endPoint: .bottom)
                .overlay(RadialGradient(colors: [amber.opacity(0.16), .clear],
                                        center: .center, startRadius: 4, endRadius: 320))
                .ignoresSafeArea()

            VStack(spacing: 0) {
                Spacer()

                // ECG-bolt mark: white heartbeat trace with the amber bolt struck through it.
                ZStack {
                    ECGTrace()
                        .trim(from: 0, to: trace ? 1 : 0)
                        .stroke(.white.opacity(0.92), style: .init(lineWidth: 3, lineCap: .round, lineJoin: .round))
                        .frame(width: 220, height: 92)
                        .shadow(color: .white.opacity(0.35), radius: 6)

                    Image(systemName: "bolt.fill")
                        .font(.system(size: 76, weight: .black))
                        .foregroundStyle(amber)
                        .shadow(color: amber.opacity(beat ? 0.7 : 0.5), radius: beat ? 24 : 16)
                        .scaleEffect(spark ? 1 : 0.4)
                        .opacity(spark ? 1 : 0)
                        .rotationEffect(.degrees(spark ? 0 : -12))
                        .scaleEffect(beat ? 1.06 : 1.0)          // gentle heartbeat while the screen holds
                }
                .frame(height: 120)

                // Wordmark — the gag: strike out "Hacking" in red pen, scrawl "Working" above it.
                ZStack(alignment: .top) {
                    HStack(spacing: 0) {
                        Text("Hacking")
                            .foregroundStyle(.white.opacity(strike ? 0.5 : 1))
                            .overlay {
                                Capsule()
                                    .fill(Color(red: 0.93, green: 0.33, blue: 0.28))
                                    .frame(height: 3.5)
                                    .rotationEffect(.degrees(-1.5))
                                    .scaleEffect(x: strike ? 1 : 0, anchor: .leading)
                                    .shadow(color: .black.opacity(0.5), radius: 1, y: 1)
                            }
                        Text("-Bolt").foregroundStyle(amber)
                    }
                    .font(.system(size: 34, weight: .heavy, design: .monospaced))
                    .tracking(1)

                    // Handwritten correction floating above "Hacking". MarkerFelt-Wide ships on iOS (unlike
                    // "Bradley Hand", which silently fell back). Bright amber + an amber glow so it pops in the
                    // dark gap; a light fade-and-pop reveal (the mask approach rendered muddy/clipped).
                    Text("Working")
                        .font(.custom("MarkerFelt-Wide", size: 36))
                        .fontWeight(.heavy)
                        .foregroundStyle(amber)
                        .rotationEffect(.degrees(-8))
                        .shadow(color: amber.opacity(0.7), radius: 12)
                        .shadow(color: .black.opacity(0.45), radius: 2, y: 1)
                        .offset(x: -8, y: -48)
                        .scaleEffect(workingReveal < 1 ? 0.55 : 1, anchor: .bottomLeading)
                        .opacity(workingReveal)
                }
                .padding(.top, 52)
                .opacity(lift ? 1 : 0)
                .offset(y: lift ? 0 : 10)

                // Tagline the user liked, carried over from the web version.
                Text("Your shift board & roster, minus the clutter.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white.opacity(0.82))
                    .multilineTextAlignment(.center)
                    .padding(.top, 8)
                    .opacity(lift ? 1 : 0)
                    .offset(y: lift ? 0 : 10)

                Spacer()

                // Fixed disclaimer, sitting just above the rotating witty line.
                Text("Disclaimer: this is only a prototype — but a damn good one.")
                    .font(.system(size: 12.5, weight: .medium)).italic()
                    .foregroundStyle(.white.opacity(0.6))
                    .multilineTextAlignment(.center).padding(.horizontal, 34)
                    .opacity(lift ? 1 : 0)

                // The witty line — cycles through the rotation; the "sleepless nights" line pops larger.
                ZStack {
                    QuipLine(text: current).id(qi).transition(.opacity)
                }
                .frame(height: 62)
                .opacity(lift ? 1 : 0)

                Text("Unofficial · a personal shift companion")
                    .font(.system(size: 10.5, weight: .regular, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.34))
                    .padding(.top, 10).padding(.bottom, 26)
                    .opacity(lift ? 1 : 0)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onDone() }                       // tap to skip
        .onAppear {
            qi = Int.random(in: 0..<max(pool.count, 1))    // start on a random line
            withAnimation(.easeInOut(duration: 1.5)) { trace = true }
            withAnimation(.spring(response: 0.55, dampingFraction: 0.5).delay(0.6)) { spark = true }
            withAnimation(.easeOut(duration: 0.7).delay(0.95)) { lift = true }
            withAnimation(.easeInOut(duration: 0.5).delay(1.7)) { strike = true }        // cross out "Hacking"
            withAnimation(.spring(response: 0.5, dampingFraction: 0.55).delay(2.2)) { workingReveal = 1 }  // scrawl "Working" pops in above
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true).delay(1.6)) { beat = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + max(splashSecs, 2)) { onDone() }  // your Settings duration; tap to skip
        }
    }
}

/// One witty line. Animates its own entrance; the "sleepless nights" line springs up larger for effect.
private struct QuipLine: View {
    let text: String
    @State private var show = false
    private var isPunch: Bool { text.contains("sleepless") }
    private let amber = Color(red: 0xF0/255, green: 0xB2/255, blue: 0x4A/255)

    var body: some View {
        Text(text)
            .font(.system(size: isPunch ? 18 : 13.5, weight: isPunch ? .bold : .regular))
            .italic()
            .foregroundStyle(.white.opacity(isPunch ? 0.95 : 0.62))
            .multilineTextAlignment(.center)
            .padding(.horizontal, 40)
            .scaleEffect(show ? (isPunch ? 1.3 : 1.0) : (isPunch ? 0.8 : 0.96))
            .shadow(color: amber.opacity(isPunch && show ? 0.5 : 0), radius: 14)
            .onAppear {
                withAnimation(isPunch ? .spring(response: 0.55, dampingFraction: 0.48)
                                      : .easeOut(duration: 0.4)) { show = true }
            }
    }
}

/// A single heartbeat: flat baseline → small P → QRS spike → T → flat. Drawn as a fraction of the frame.
private struct ECGTrace: Shape {
    func path(in r: CGRect) -> Path {
        let w = r.width, h = r.height, mid = r.midY
        func pt(_ fx: CGFloat, _ fy: CGFloat) -> CGPoint { CGPoint(x: r.minX + fx * w, y: mid - fy * h) }
        var p = Path()
        p.move(to: pt(0.00, 0))
        p.addLine(to: pt(0.28, 0))          // baseline
        p.addLine(to: pt(0.34, 0.12))       // P wave
        p.addLine(to: pt(0.40, 0))
        p.addLine(to: pt(0.44, -0.18))      // Q
        p.addLine(to: pt(0.50, 0.5))        // R spike
        p.addLine(to: pt(0.56, -0.30))      // S
        p.addLine(to: pt(0.62, 0))
        p.addLine(to: pt(0.70, 0.16))       // T wave
        p.addLine(to: pt(0.76, 0))
        p.addLine(to: pt(1.00, 0))          // baseline
        return p
    }
}
