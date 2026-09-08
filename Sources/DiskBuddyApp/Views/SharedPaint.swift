import SwiftUI
import ScannerCore

/// One colouring rule for every visualization, so a folder keeps its identity
/// as you move between Folders, Treemap, Sunburst, Flame, Bubbles and Mind Map.
enum SharedPaint {

    static func color(_ store: NodeStore, _ index: Int, depth: Int,
                      mode: AppState.SizeMode, rootIndex: Int) -> Color {
        // Deeper nodes fade so nesting reads without extra borders. The floor
        // used to be 0.6, which on a saturated palette turned a depth-10 cell
        // into mud; with the richer colours it can go lighter and still be
        // distinguishable from its neighbours.
        let fade = max(0.42, 1.0 - Double(depth) * 0.055)

        switch mode {
        case .byFolder:
            // The saturated palette, not the card pastels. A treemap cell can
            // be four pixels wide with no room for a label, so its colour is
            // the only thing telling you which branch it belongs to.
            let branch = topAncestor(store, index, rootIndex)
            let family = Theme.vizColor(store.name(branch))
            return Theme.shade(family, node: store.name(index)).opacity(fade)

        case .byType:
            if store.isDir(index) { return Theme.track.opacity(max(0.35, fade * 0.7)) }
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
