import SwiftUI
import ScannerCore

/// One colouring rule for every visualization, so a folder keeps its identity
/// as you move between Folders, Treemap, Sunburst, Flame, Bubbles and Mind Map.
enum SharedPaint {

    static func color(_ store: NodeStore, _ index: Int, depth: Int,
                      mode: AppState.SizeMode, rootIndex: Int) -> Color {
        // Deeper nodes fade slightly so nesting reads without extra borders.
        let fade = max(0.6, 1.0 - Double(depth) * 0.035)

        switch mode {
        case .byFolder:
            return cardColor(store, topAncestor(store, index, rootIndex)).opacity(fade)

        case .byType:
            if store.isDir(index) { return Theme.track.opacity(max(0.45, fade * 0.7)) }
            let ext = (store.name(index) as NSString).pathExtension
            return Theme.categoryColor(FileTypeCategory.classify(extension: ext)).opacity(fade)

        case .byAge:
            let days = max(0, Date().timeIntervalSince(store.modifiedDate(index)) / 86400)
            let t = min(1.0, days / 730.0)   // fresh green → two-year-old clay
            return Color(red: 0.42 + 0.38 * t,
                         green: 0.62 - 0.13 * t,
                         blue: 0.46 - 0.10 * t).opacity(fade)
        }
    }

    private static func cardColor(_ store: NodeStore, _ index: Int) -> Color {
        Theme.cardColor(store.name(index))
    }

    /// Walk up to the child of the current view root, so a whole branch shares
    /// one hue instead of every level picking a new one.
    static func topAncestor(_ store: NodeStore, _ index: Int, _ rootIndex: Int) -> Int {
        var cur = index
        var hops = 0
        while store.parent[cur] > Int32(rootIndex), hops < 64 {
            cur = Int(store.parent[cur]); hops += 1
        }
        return cur
    }
}
