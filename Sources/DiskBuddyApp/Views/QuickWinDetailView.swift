import SwiftUI
import ScannerCore

/// The filtered list behind a Quick Wins row.
public struct QuickWinDetailView: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cleanup: CleanupQueue
    let detector: QuickWinDetectorType

    public init(detector: QuickWinDetectorType) {
        self.detector = detector
    }

    public var body: some View {
        if let result = app.quickWins[detector] {
            let items = filtered(result.items)
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: detector.icon)
                        .font(.system(size: 17))
                        .foregroundStyle(Theme.inkSecond)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(result.title)
                            .font(.system(size: 18, weight: .bold))
                            .foregroundStyle(Theme.ink)
                        Text(result.description)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.inkFaint)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 2) {
                        Text(Fmt.bytes(result.totalBytes))
                            .font(.system(size: 19, weight: .bold).monospacedDigit())
                            .foregroundStyle(Theme.ink)
                        Text("\(Fmt.count(result.itemCount)) items")
                            .font(.system(size: 11).monospacedDigit())
                            .foregroundStyle(Theme.inkFaint)
                    }
                    Button {
                        var added = 0
                        for item in items {
                            if cleanup.add(path: item.path, name: item.name, size: item.size,
                                           isDir: item.isDir, origin: result.title) { added += 1 }
                        }
                        _ = added
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "trash").font(.system(size: 11))
                            Text("Stage all \(items.count)").font(.system(size: 12, weight: .semibold))
                        }
                        .foregroundStyle(Theme.pillText)
                        .padding(.horizontal, 13).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.pill))
                    }
                    .buttonStyle(.plain)
                    .help("Adds these to the review queue. Nothing is deleted until you confirm.")
                }

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(items) { item in
                            QuickWinItemRow(item: item, maxSize: items.first?.size ?? 1)
                        }
                    }
                }
                .scrollIndicators(.automatic)
            }
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        } else {
            Text("No results").foregroundStyle(Theme.inkFaint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func filtered(_ items: [QuickWinItem]) -> [QuickWinItem] {
        guard !app.filterText.isEmpty else { return items }
        let q = app.filterText.lowercased()
        return items.filter { $0.name.lowercased().contains(q) }
    }
}

private struct QuickWinItemRow: View {
    @EnvironmentObject var app: AppState
    @EnvironmentObject var cleanup: CleanupQueue
    let item: QuickWinItem
    let maxSize: Int64
    @State private var hovering = false

    var body: some View {
        Button { app.selectNode(item.nodeIndex) } label: {
            HStack(spacing: 10) {
                Image(systemName: cleanup.contains(item.path)
                      ? "checkmark.circle.fill" : (item.isDir ? "folder" : "doc"))
                    .font(.system(size: 11))
                    .foregroundStyle(cleanup.contains(item.path) ? Theme.good : Theme.inkSecond)
                    .frame(width: 14)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 5).fill(Theme.track.opacity(0.5))
                        RoundedRectangle(cornerRadius: 5)
                            .fill(Theme.cardColor(item.name))
                            .frame(width: max(6, geo.size.width * CGFloat(item.size) / CGFloat(max(1, maxSize))))
                        VStack(alignment: .leading, spacing: 0) {
                            Text(item.name)
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(Theme.ink)
                                .lineLimit(1)
                            Text(item.path)
                                .font(.system(size: 9))
                                .foregroundStyle(Theme.inkFaint)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        .padding(.horizontal, 9)
                    }
                }
                .frame(height: 32)

                Text(Fmt.ago(item.mtime))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.inkFaint)
                    .frame(width: 96, alignment: .trailing)
                Text(Fmt.bytes(item.size))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .frame(width: 78, alignment: .trailing)
            }
            .padding(.vertical, 3).padding(.horizontal, 6)
            .background(RoundedRectangle(cornerRadius: 7)
                .fill(hovering ? Theme.pillSoft.opacity(0.4) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
