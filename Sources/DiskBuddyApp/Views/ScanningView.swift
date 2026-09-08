import SwiftUI
import ScannerCore

/// The full-pane scanning screen.
///
/// Two rules shaped this:
///
///  1. Nothing from the previous scan is on screen while a new one runs. A
///     half-built tree has meaningless folder sizes (subtree sums only exist
///     after the reverse pass), and showing the *old* tree during a rescan is
///     worse still — it looks live and isn't.
///
///  2. Every number here is measured, not decorative. The throughput graph is
///     real samples, the counters are the scanner's own, and each stage is
///     named as it happens so a slow pass never looks like a hang.
struct ScanningView: View {
    @EnvironmentObject var app: AppState

    /// Throughput history, sampled once a second. Small on purpose — this is a
    /// pulse, not a chart, and it must not become the expensive thing on
    /// screen while the scanner is trying to saturate every core.
    @State private var history: [Double] = []
    @State private var lastFiles: Int = 0
    @State private var lastSample: Date = .now
    @State private var spin: Double = 0
    @State private var pulse: Bool = false

    private var stage: ScanStage { app.scanStage }
    private var p: ScanProgress { app.liveProgress }

    private var filesPerSecond: Double {
        guard p.elapsed > 0.4 else { return 0 }
        return Double(p.files) / p.elapsed
    }

    private var rateLabel: String {
        let r = filesPerSecond
        if r >= 1000 { return "\(Int(r / 1000))k" }
        return "\(Int(r))"
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)

            emblem
                .frame(width: 190, height: 190)
                .padding(.bottom, 26)

            Text(stage.title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Theme.ink)
                .contentTransition(.opacity)
                .animation(.easeInOut(duration: 0.25), value: stage)

            Text(stage.detail)
                .font(.system(size: 12))
                .foregroundStyle(Theme.inkSecond)
                .padding(.top, 5)
                .multilineTextAlignment(.center)
                .animation(.easeInOut(duration: 0.25), value: stage)

            counters
                .padding(.top, 26)

            throughput
                .padding(.top, 22)

            stageTrack
                .padding(.top, 24)

            currentPath
                .padding(.top, 20)

            Button("Cancel") { app.cancelScan() }
                .buttonStyle(.plain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.inkSecond)
                .padding(.top, 18)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
        .onAppear {
            // One continuous rotation rather than a per-frame animation, so the
            // emblem costs the compositor a transform and nothing else.
            withAnimation(.linear(duration: 3.2).repeatForever(autoreverses: false)) {
                spin = 360
            }
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                pulse = true
            }
        }
        .onChange(of: p.files) { _, files in
            let now = Date()
            let dt = now.timeIntervalSince(lastSample)
            guard dt >= 0.9 else { return }
            history.append(Double(files - lastFiles) / dt)
            if history.count > 48 { history.removeFirst(history.count - 48) }
            lastFiles = files
            lastSample = now
        }
    }

    // MARK: - Emblem

    /// The app icon, alive: the ring builds itself while the sweep arm goes
    /// round. The ring is genuinely indeterminate — a filesystem does not tell
    /// you how big it is before you have walked it, so a percentage here would
    /// be invented.
    private var emblem: some View {
        ZStack {
            Circle()
                .stroke(Theme.track, lineWidth: 10)

            // Pastel arcs in the folder palette, each a different length and
            // speed, so the ring never repeats the same shape twice.
            ForEach(0..<5, id: \.self) { i in
                arc(i)
            }

            // The sweep arm — the thing that makes it read as "working".
            Circle()
                .trim(from: 0, to: 0.055)
                .stroke(Theme.gauge, style: StrokeStyle(lineWidth: 10, lineCap: .round))
                .rotationEffect(.degrees(spin * 2.1))

            Circle()
                .fill(Theme.ground)
                .padding(26)

            VStack(spacing: 2) {
                Text(Fmt.bytes(p.allocated))
                    .font(.system(size: 26, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .contentTransition(.numericText())
                    .animation(.easeOut(duration: 0.3), value: p.allocated)
                Text("measured")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(Theme.inkFaint)
                    .textCase(.uppercase)
            }
            .scaleEffect(pulse ? 1.02 : 1.0)
        }
    }

    /// One pastel ring segment. Split out of `emblem` because the type
    /// checker times out on the arithmetic when it's inline in a ZStack.
    private func arc(_ i: Int) -> some View {
        let length: Double = 0.10 + Double(i) * 0.045
        let speed: Double = 1.0 + Double(i) * 0.34
        let offset: Double = Double(i) * 61
        let colour: Color = Theme.strokeColors[(i * 3) % Theme.strokeColors.count]
        return Circle()
            .trim(from: 0, to: length)
            .stroke(colour, style: StrokeStyle(lineWidth: 10, lineCap: .round))
            .rotationEffect(.degrees(spin * speed + offset))
    }

    // MARK: - Counters

    private var counters: some View {
        HStack(spacing: 0) {
            counter(Fmt.count(p.files), "files")
            divider
            counter(Fmt.count(p.dirs), "folders")
            divider
            counter(rateLabel, "per second")
            divider
            counter(String(format: "%.1fs", p.elapsed), "elapsed")
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.rail)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
        )
    }

    private func counter(_ value: String, _ label: String) -> some View {
        VStack(spacing: 3) {
            Text(value)
                .font(.system(size: 19, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
                // "3,507,363" is nine glyphs and wrapped mid-number at 92pt.
                .lineLimit(1)
                .minimumScaleFactor(0.65)
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(Theme.inkFaint)
                .textCase(.uppercase)
        }
        .frame(width: 112)
    }

    private var divider: some View {
        Rectangle().fill(Theme.hairline).frame(width: 1, height: 26)
    }

    // MARK: - Throughput

    /// Real samples, one a second. Flat while rolling up — which is the point:
    /// you can see the walk stop and the arithmetic start.
    private var throughput: some View {
        VStack(spacing: 6) {
            Canvas { ctx, size in
                guard history.count > 1 else { return }
                let peak = max(history.max() ?? 1, 1)
                let step = size.width / CGFloat(max(history.count - 1, 1))

                var line = Path()
                for (i, v) in history.enumerated() {
                    let x = CGFloat(i) * step
                    let y = size.height - CGFloat(v / peak) * size.height
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else { line.addLine(to: CGPoint(x: x, y: y)) }
                }

                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()

                ctx.fill(fill, with: .linearGradient(
                    Gradient(colors: [Theme.gauge.opacity(0.28), Theme.gauge.opacity(0.02)]),
                    startPoint: .zero, endPoint: CGPoint(x: 0, y: size.height)))
                ctx.stroke(line, with: .color(Theme.gauge),
                           style: StrokeStyle(lineWidth: 1.6, lineJoin: .round))
            }
            .frame(width: 380, height: 42)

            Text(history.isEmpty ? "sampling…" : "files per second, last \(history.count)s")
                .font(.system(size: 10))
                .foregroundStyle(Theme.inkFaint)
        }
    }

    // MARK: - Stage track

    private var stageTrack: some View {
        HStack(spacing: 10) {
            ForEach(ScanStage.allCases, id: \.self) { s in
                let done = s.rawValue < stage.rawValue
                let now = s == stage
                HStack(spacing: 6) {
                    Circle()
                        .fill(done ? Theme.good : (now ? Theme.gauge : Theme.track))
                        .frame(width: 7, height: 7)
                        .scaleEffect(now && pulse ? 1.35 : 1.0)
                    Text(s.title)
                        .font(.system(size: 11, weight: now ? .semibold : .regular))
                        .foregroundStyle(now ? Theme.ink : Theme.inkFaint)
                }
                if s != ScanStage.allCases.last {
                    Rectangle()
                        .fill(done ? Theme.good.opacity(0.5) : Theme.track)
                        .frame(width: 18, height: 1)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: stage)
    }

    // MARK: - Current path

    private var currentPath: some View {
        Text(p.currentPath.isEmpty ? app.scanRootPath : p.currentPath)
            .font(.system(size: 11).monospacedDigit())
            .foregroundStyle(Theme.inkFaint)
            .lineLimit(1)
            .truncationMode(.middle)
            .frame(maxWidth: 460)
            .animation(nil, value: p.currentPath)   // never animate 200k/s of text
    }
}
