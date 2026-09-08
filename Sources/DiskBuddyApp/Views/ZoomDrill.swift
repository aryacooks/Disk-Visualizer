import SwiftUI

/// The drill-in zoom, applied once around the centre pane so that every
/// visualiser gets the same motion for free — folders, sunburst, flame,
/// bubbles, mind map, treemap, top sizes and the age map.
///
/// The illusion is cheap and holds up: the outgoing level grows *past* the
/// viewer, anchored on the shape that was clicked, while the incoming level
/// arrives slightly small and settles. Going back plays it in reverse, which
/// is what stops Back from feeling like another step forward.
///
/// It is a crossfade, not a true morph — the clicked arc does not physically
/// unfold into the new ring. A real morph would need each layout to
/// interpolate its own geometry between two roots, and at 11,000 cells the
/// honest version of that is a lot of per-frame work for a 400 ms effect.
struct ZoomDrill: ViewModifier {
    let key: Int
    let anchor: UnitPoint
    let zoomingIn: Bool

    func body(content: Content) -> some View {
        content
            .id(key)
            .transition(.asymmetric(
                insertion: .scale(scale: zoomingIn ? 0.70 : 1.35, anchor: anchor)
                    .combined(with: .opacity),
                removal: .scale(scale: zoomingIn ? 1.45 : 0.72, anchor: anchor)
                    .combined(with: .opacity)
            ))
    }
}

extension View {
    /// `key` is whatever identifies "which level am I looking at" — the
    /// current folder index. Changing it is what plays the transition.
    func zoomDrill(key: Int, anchor: UnitPoint, zoomingIn: Bool) -> some View {
        modifier(ZoomDrill(key: key, anchor: anchor, zoomingIn: zoomingIn))
    }
}

extension CGPoint {
    /// Convert a tap in a canvas into the unit point the zoom anchors on.
    /// Clamped, because a tap can land a hair outside the reported size and a
    /// negative anchor sends the zoom off in the wrong direction entirely.
    func unitAnchor(in size: CGSize) -> UnitPoint {
        guard size.width > 0, size.height > 0 else { return .center }
        return UnitPoint(x: min(max(x / size.width, 0), 1),
                         y: min(max(y / size.height, 0), 1))
    }
}
