import SwiftUI
import ScannerCore

/// "Where your bytes sit on a timeline" — age histogram, month heatmap,
/// and the Big & Untouched list. All three come free from the scan.
public struct AgeMapView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cleanup: CleanupQueue

    public init() {}

    private let bucketLabels = ["Last 7 days", "8–30 days", "1–3 months",
                                "3–12 months", "1–2 years", "Over 2 years"]

    public var body: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 14) {
                histogramPanel
                heatmapPanel
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)

            untouchedPanel
                .frame(width: 340)
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
    }

    // MARK: Histogram

    @ViewBuilder
    private var histogramPanel: some View {
        if let stats = app.stats {
            let maxB = max(Int64(1), stats.ageBytes.max() ?? 1)
            let total = max(Int64(1), stats.allocated)

            Panel(title: "How old are these bytes?", trailing: Fmt.bytes(stats.allocated)) {
                VStack(spacing: 9) {
                    ForEach(0..<6, id: \.self) { i in
                        HStack(spacing: 10) {
                            Text(bucketLabels[i])
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.inkSecond)
                                .frame(width: 88, alignment: .leading)

                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule().fill(Theme.track)
                                    Capsule().fill(ageColor(i))
                                        .frame(width: max(3, geo.size.width * CGFloat(stats.ageBytes[i]) / CGFloat(maxB)))
                                }
                            }
                            .frame(height: 9)

                            Text(Fmt.bytes(stats.ageBytes[i]))
                                .font(.system(size: 11, weight: .medium).monospacedDigit())
                                .foregroundStyle(Theme.ink)
                                .frame(width: 68, alignment: .trailing)
                            Text(Fmt.pct(Double(stats.ageBytes[i]) / Double(total) * 100))
                                .font(.system(size: 11).monospacedDigit())
                                .foregroundStyle(Theme.inkFaint)
                                .frame(width: 46, alignment: .trailing)
                        }
                    }
                }
            }
        }
    }

    /// Fresh bytes are green, stale bytes drift toward clay.
    private func ageColor(_ i: Int) -> Color {
        switch i {
        case 0:  return Color(red: 0.365, green: 0.588, blue: 0.427)  // green
        case 1:  return Color(red: 0.541, green: 0.573, blue: 0.427)
        case 2:  return Color(red: 0.639, green: 0.573, blue: 0.404)
        case 3:  return Color(red: 0.722, green: 0.549, blue: 0.376)
        case 4:  return Color(red: 0.769, green: 0.510, blue: 0.376)
        default: return Color(red: 0.788, green: 0.435, blue: 0.373)  // clay
        }
    }

    // MARK: Heatmap

    @ViewBuilder
    private var heatmapPanel: some View {
        if let age = app.ageMapResult, !age.years.isEmpty {
            Panel(title: "Bytes by last-modified month",
                  trailing: age.busiestMonth.map { "Busiest: \(Fmt.bytes($0.bytes))" }) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 4) {
                        Text("").frame(width: 34)
                        ForEach(1...12, id: \.self) { m in
                            Text(monthInitial(m))
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.inkFaint)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    ForEach(age.years.sorted(by: >), id: \.self) { year in
                        HStack(spacing: 4) {
                            Text(String(year))
                                .font(.system(size: 10).monospacedDigit())
                                .foregroundStyle(Theme.inkSecond)
                                .frame(width: 34, alignment: .leading)
                            ForEach(1...12, id: \.self) { m in
                                let b = age.bytesFor(year: year, month: m)
                                let t = age.maxMonthBytes > 0 ? Double(b) / Double(age.maxMonthBytes) : 0
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(heatColor(t))
                                    .frame(height: 26)
                                    .frame(maxWidth: .infinity)
                                    .overlay(
                                        t > 0.35 ? Text(Fmt.bytes(b))
                                            .font(.system(size: 8, weight: .medium))
                                            .foregroundStyle(Theme.ink.opacity(0.75)) : nil
                                    )
                                    .help(b > 0 ? "\(monthInitial(m)) \(year): \(Fmt.bytes(b))" : "")
                            }
                        }
                    }

                    HStack(spacing: 5) {
                        Text("less").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                        ForEach(0..<5, id: \.self) { s in
                            RoundedRectangle(cornerRadius: 2)
                                .fill(heatColor(Double(s) / 4))
                                .frame(width: 15, height: 9)
                        }
                        Text("more").font(.system(size: 9)).foregroundStyle(Theme.inkFaint)
                        Spacer()
                    }
                    .padding(.top, 4)
                }
            }
        }
    }

    private func monthInitial(_ m: Int) -> String {
        ["J","F","M","A","M","J","J","A","S","O","N","D"][m - 1]
    }

    private func heatColor(_ t: Double) -> Color {
        if t <= 0 { return Theme.track.opacity(0.45) }
        // Empty → warm stone → deep clay
        return Color(red: 0.85 - 0.30 * t, green: 0.82 - 0.36 * t, blue: 0.78 - 0.42 * t)
    }

    // MARK: Big & untouched

    @ViewBuilder
    private var untouchedPanel: some View {
        if let age = app.ageMapResult {
            let items = age.bigAndUntouched
            let total = items.reduce(Int64(0)) { $0 + $1.size }
            Panel(title: "Big & Untouched", trailing: "over a year old") {
                VStack(alignment: .leading, spacing: 9) {
                    HStack(spacing: 8) {
                        Text("\(Fmt.bytes(total)) across \(items.count) items")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Theme.gauge)
                        Spacer()
                        if !items.isEmpty {
                            Button {
                                for i in items {
                                    _ = cleanup.add(path: i.path, name: i.name, size: i.size,
                                                    isDir: false, origin: "Big & Untouched")
                                }
                            } label: {
                                Text("Stage all").font(.system(size: 10, weight: .semibold))
                                    .foregroundStyle(Theme.pillText)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Capsule().fill(Theme.pill))
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    if items.isEmpty {
                        Text("Nothing large has gone untouched for a year.")
                            .font(.system(size: 11)).foregroundStyle(Theme.inkFaint)
                    }

                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(items.prefix(40)) { item in
                                Button { app.selectNode(item.nodeIndex) } label: {
                                    HStack(spacing: 8) {
                                        Image(systemName: "doc")
                                            .font(.system(size: 11))
                                            .foregroundStyle(Theme.inkFaint)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(item.name)
                                                .font(.system(size: 11))
                                                .foregroundStyle(Theme.ink)
                                                .lineLimit(1).truncationMode(.middle)
                                            Text(Fmt.ago(item.mtime))
                                                .font(.system(size: 9))
                                                .foregroundStyle(Theme.inkFaint)
                                        }
                                        Spacer(minLength: 4)
                                        Text(Fmt.bytes(item.size))
                                            .font(.system(size: 11, weight: .medium).monospacedDigit())
                                            .foregroundStyle(Theme.inkSecond)
                                    }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .frame(maxHeight: 460)
                }
            }
        }
    }
}

// MARK: - Panel

struct Panel<Content: View>: View {
    let title: String
    var trailing: String? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            RailLabel(title, trailing: trailing)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Theme.rail)
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Theme.hairline, lineWidth: 1))
        )
    }
}
