import SwiftUI
import ScannerCore

@MainActor
final class MonitorModel: ObservableObject {
    @Published var sample = SystemSample()
    @Published var cpuHistory: [Double] = []
    @Published var netHistory: [Double] = []
    @Published var volumeFree: Int64 = 0
    @Published var volumeTotal: Int64 = 0
    @Published var sortByWrites = false
    @Published var thermal = ThermalReport()
    @Published var tempHistory: [Double] = []

    private let sampler = SystemSampler()
    private let sensors = SensorReader()
    private var timer: Timer?

    func start() {
        guard timer == nil else { return }
        tick()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        let s = sampler.sample()
        sample = s
        cpuHistory.append(s.cpuBusy)
        netHistory.append(Double(s.netInPerSec + s.netOutPerSec))
        if cpuHistory.count > 90 { cpuHistory.removeFirst() }
        if netHistory.count > 90 { netHistory.removeFirst() }

        let t = sensors.read()
        thermal = t
        if let avg = t.cpuAverage {
            tempHistory.append(avg)
            if tempHistory.count > 90 { tempHistory.removeFirst() }
        }

        let url = URL(fileURLWithPath: "/")
        if let v = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey,
                                                    .volumeAvailableCapacityForImportantUsageKey]) {
            volumeTotal = Int64(v.volumeTotalCapacity ?? 0)
            volumeFree = v.volumeAvailableCapacityForImportantUsage ?? 0
        }
    }
}

/// "Watch the machine while you clean it."
public struct MonitorView: View {
    @StateObject private var model = MonitorModel()

    public init() {}

    private func pct(_ v: Double) -> String { String(format: "%.1f%%", v) }

    public var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                HStack(spacing: 12) {
                    cpuCard
                    memoryCard
                }
                HStack(spacing: 12) {
                    networkCard
                    storageCard
                }
                HStack(spacing: 12) {
                    thermalCard
                    batteryCard
                }
                sensorsPanel
                processCard
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .scrollIndicators(.never)
        .background(Theme.ground)
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    // MARK: Cards

    private var cpuCard: some View {
        MonitorCard(icon: "cpu", title: "CPU",
                    headline: pct(model.sample.cpuBusy)) {
            Sparkline(values: model.cpuHistory, maxValue: 100, tint: Theme.gauge)
                .frame(height: 42)
            HStack(spacing: 0) {
                MiniStat("USER", pct(model.sample.cpuUser))
                MiniStat("SYSTEM", pct(model.sample.cpuSystem))
                MiniStat("LOAD", String(format: "%.2f", model.sample.loadAverage))
            }
        }
    }

    private var memoryCard: some View {
        let s = model.sample
        let frac = s.memTotal > 0 ? Double(s.memUsed) / Double(s.memTotal) : 0
        return MonitorCard(icon: "memorychip", title: "Memory",
                           headline: Fmt.bytes(s.memUsed)) {
            SegmentBar(segments: [
                (Double(s.memWired), Theme.danger),
                (Double(s.memCompressed), Theme.gauge),
                (Double(max(0, s.memUsed - s.memWired - s.memCompressed)), Theme.inkFaint)
            ], total: Double(max(1, s.memTotal)))
            .frame(height: 9)
            HStack(spacing: 0) {
                MiniStat("WIRED", Fmt.bytes(s.memWired), dot: Theme.danger)
                MiniStat("COMPRESSED", Fmt.bytes(s.memCompressed), dot: Theme.gauge)
                MiniStat("TOTAL", Fmt.bytes(s.memTotal))
            }
            .help("\(Int(frac * 100))% of physical memory in use")
        }
    }

    private var networkCard: some View {
        let s = model.sample
        return MonitorCard(icon: "network", title: "Network",
                           headline: "\(Fmt.bytes(s.netInPerSec + s.netOutPerSec))/s") {
            Sparkline(values: model.netHistory, maxValue: max(1, model.netHistory.max() ?? 1),
                      tint: Theme.gauge)
                .frame(height: 42)
            HStack(spacing: 0) {
                MiniStat("DOWN", "\(Fmt.bytes(s.netInPerSec))/s")
                MiniStat("UP", "\(Fmt.bytes(s.netOutPerSec))/s")
                MiniStat("SESSION IN", Fmt.bytes(s.netInTotal))
            }
        }
    }

    private var storageCard: some View {
        let used = max(0, model.volumeTotal - model.volumeFree)
        return MonitorCard(icon: "internaldrive", title: "Storage",
                           headline: "\(Fmt.bytes(model.volumeFree)) free") {
            SegmentBar(segments: [(Double(used), Theme.gauge)],
                       total: Double(max(1, model.volumeTotal)))
                .frame(height: 9)
            HStack(spacing: 0) {
                MiniStat("USED", Fmt.bytes(used))
                MiniStat("FREE", Fmt.bytes(model.volumeFree), dot: Theme.good)
                MiniStat("TOTAL", Fmt.bytes(model.volumeTotal))
            }
            Text("Updates live, so you can watch the drive recover during a cleanup.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.inkFaint)
        }
    }

    // MARK: Thermals

    private var thermalCard: some View {
        let t = model.thermal
        return MonitorCard(icon: "thermometer.medium", title: "Temperature",
                           headline: t.cpuAverage.map { String(format: "%.1f °C", $0) } ?? "—") {
            if t.sensorsUnavailable {
                Text("On-die sensors aren't readable on this Mac. macOS still reports overall thermal pressure below.")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Sparkline(values: model.tempHistory, maxValue: 100, tint: tempTint(t.cpuAverage ?? 0))
                    .frame(height: 42)
            }
            HStack(spacing: 0) {
                MiniStat("SoC AVG", t.cpuAverage.map { String(format: "%.1f °C", $0) } ?? "—")
                MiniStat("HOTTEST", t.hottest.map { String(format: "%.1f °C", $0.celsius) } ?? "—",
                         dot: tempTint(t.hottest?.celsius ?? 0))
                MiniStat("PRESSURE", t.thermalState,
                         dot: t.thermalState == "Nominal" ? Theme.good : Theme.danger)
            }
            if let h = t.hottest {
                Text("Hottest sensor: \(h.name)")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            }
        }
    }

    private var batteryCard: some View {
        let b = model.thermal.battery
        return MonitorCard(icon: "battery.100", title: "Battery",
                           headline: b.present ? "\(b.percent)%" : "No battery") {
            if b.present {
                SegmentBar(segments: [(Double(b.percent), b.percent < 20 ? Theme.danger : Theme.good)],
                           total: 100)
                    .frame(height: 9)
                HStack(spacing: 0) {
                    MiniStat("STATE", b.charging ? "Charging" : "On battery")
                    MiniStat("CYCLES", "\(b.cycleCount)")
                    MiniStat("HEALTH", b.health.isEmpty ? "—" : b.health)
                }
                if !b.charging && b.timeToEmptyMinutes > 0 {
                    Text("About \(b.timeToEmptyMinutes / 60)h \(b.timeToEmptyMinutes % 60)m remaining")
                        .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                }
            } else {
                Text("This Mac runs on wall power.")
                    .font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
            }
        }
    }

    @ViewBuilder
    private var sensorsPanel: some View {
        let t = model.thermal
        if !t.sensors.isEmpty {
            Panel(title: "All sensors", trailing: "\(t.sensors.count) reading") {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(t.groups, id: \.self) { g in
                        let inGroup = t.sensors.filter { $0.group == g }
                        VStack(alignment: .leading, spacing: 5) {
                            HStack(spacing: 6) {
                                Text(g.uppercased())
                                    .font(.system(size: 9, weight: .semibold)).tracking(0.6)
                                    .foregroundStyle(Theme.inkFaint)
                                Text("\(inGroup.count)")
                                    .font(.system(size: 9).monospacedDigit())
                                    .foregroundStyle(Theme.inkFaint)
                                if g == "Reference" {
                                    Text("calibration, not a real temperature")
                                        .font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                                }
                            }
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 168, maximum: 300), spacing: 8)],
                                      spacing: 6) {
                                ForEach(inGroup) { s in
                                    HStack(spacing: 7) {
                                        Circle().fill(tempTint(s.celsius)).frame(width: 6, height: 6)
                                        Text(s.name).font(.system(size: 11))
                                            .foregroundStyle(Theme.ink).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(String(format: "%.1f °C", s.celsius))
                                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                                            .foregroundStyle(Theme.inkSecond)
                                    }
                                    .padding(.horizontal, 8).padding(.vertical, 4)
                                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.ground))
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    /// Cool green → warm amber → hot red, on a scale that suits Apple silicon.
    private func tempTint(_ c: Double) -> Color {
        let t = min(1.0, max(0.0, (c - 30) / 55))
        return Color(red: 0.30 + 0.52 * t, green: 0.62 - 0.30 * t, blue: 0.42 - 0.24 * t)
    }

    private var processCard: some View {
        let procs = model.sortByWrites
            ? model.sample.processes.sorted { $0.diskWrittenBytes > $1.diskWrittenBytes }
            : model.sample.processes
        return Panel(title: model.sortByWrites ? "Top processes by disk writes" : "Top processes by CPU",
                     trailing: "\(model.sample.processes.count) running") {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("PROCESS").frame(maxWidth: .infinity, alignment: .leading)
                    Text("PID").frame(width: 62, alignment: .trailing)
                    Button { model.sortByWrites = false } label: {
                        Text("CPU").foregroundStyle(model.sortByWrites ? Theme.inkFaint : Theme.ink)
                    }
                    .buttonStyle(.plain).frame(width: 58, alignment: .trailing)
                    Text("MEMORY").frame(width: 78, alignment: .trailing)
                    Button { model.sortByWrites = true } label: {
                        Text("DISK WRITTEN")
                            .foregroundStyle(model.sortByWrites ? Theme.ink : Theme.inkFaint)
                    }
                    .buttonStyle(.plain).frame(width: 100, alignment: .trailing)
                }
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.inkFaint)
                .padding(.bottom, 7)

                ForEach(procs.prefix(28)) { p in
                    HStack(spacing: 8) {
                        Text(p.name)
                            .lineLimit(1).truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("\(p.pid)")
                            .foregroundStyle(Theme.inkFaint)
                            .frame(width: 62, alignment: .trailing)
                        Text(pct(p.cpuPercent))
                            .foregroundStyle(p.cpuPercent > 15 ? Theme.danger : Theme.inkSecond)
                            .frame(width: 58, alignment: .trailing)
                        Text(Fmt.bytes(p.residentBytes))
                            .foregroundStyle(Theme.inkSecond)
                            .frame(width: 78, alignment: .trailing)
                        Text(p.diskWrittenBytes > 0 ? Fmt.bytes(p.diskWrittenBytes) : "—")
                            .foregroundStyle(Theme.inkSecond)
                            .frame(width: 100, alignment: .trailing)
                    }
                    .font(.system(size: 11).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .padding(.vertical, 3)
                }

                Text("Disk figures are lifetime totals for each process, not a rate.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.inkFaint)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 8)
            }
        }
    }
}

// MARK: - Pieces

private struct MonitorCard<Content: View>: View {
    let icon: String, title: String, headline: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: icon).font(.system(size: 10)).foregroundStyle(Theme.inkFaint)
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold)).tracking(0.8)
                    .foregroundStyle(Theme.inkFaint)
                Spacer()
                Text(headline)
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
            }
            content
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.rail)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
        )
    }
}

private struct MiniStat: View {
    let label: String, value: String
    var dot: Color? = nil
    init(_ label: String, _ value: String, dot: Color? = nil) {
        self.label = label; self.value = value; self.dot = dot
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                if let d = dot { Circle().fill(d).frame(width: 5, height: 5) }
                Text(label)
                    .font(.system(size: 8, weight: .semibold)).tracking(0.5)
                    .foregroundStyle(Theme.inkFaint)
            }
            Text(value)
                .font(.system(size: 11, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.ink)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct Sparkline: View {
    let values: [Double]
    let maxValue: Double
    let tint: Color

    var body: some View {
        GeometryReader { geo in
            Canvas { ctx, size in
                guard values.count > 1, maxValue > 0 else { return }
                let step = size.width / CGFloat(max(1, values.count - 1))
                var line = Path()
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = size.height - CGFloat(min(1, v / maxValue)) * size.height
                    if i == 0 { line.move(to: CGPoint(x: x, y: y)) }
                    else { line.addLine(to: CGPoint(x: x, y: y)) }
                }
                var fill = line
                fill.addLine(to: CGPoint(x: size.width, y: size.height))
                fill.addLine(to: CGPoint(x: 0, y: size.height))
                fill.closeSubpath()
                ctx.fill(fill, with: .color(tint.opacity(0.16)))
                ctx.stroke(line, with: .color(tint), lineWidth: 1.4)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .background(
            RoundedRectangle(cornerRadius: 6).fill(Theme.ground.opacity(0.6))
        )
    }
}

private struct SegmentBar: View {
    let segments: [(Double, Color)]
    let total: Double

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 1) {
                ForEach(Array(segments.enumerated()), id: \.offset) { _, seg in
                    seg.1.frame(width: max(0, geo.size.width * CGFloat(seg.0 / total)))
                }
                Spacer(minLength: 0)
            }
            .background(Theme.track)
            .clipShape(Capsule())
        }
    }
}
