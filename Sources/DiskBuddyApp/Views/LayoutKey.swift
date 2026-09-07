import Foundation

/// Composite key describing every input a layout depends on.
struct LayoutKey: Equatable {
    var nodes: Int = 0
    var root: Int = 0
    var rings: Int = 0
    var w: Int = 0
    var h: Int = 0
}

/// Memoises one layout result.
///
/// Layouts are DERIVED from the tree, not independent state. Storing them in
/// `@State` and refreshing from `onAppear`/`onChange`/`task` meant the Canvas
/// could capture an empty array and never redraw — the sunburst rendered its
/// hub and nothing else, intermittently. Computing inside `body` through this
/// cache makes the drawn value always match the current inputs, while the
/// cache keeps us from recomputing on every unrelated re-render.
final class LayoutCache<T> {
    private var key: LayoutKey?
    private var value: T?

    func get(_ k: LayoutKey, _ make: () -> T) -> T {
        if let v = value, key == k { return v }
        let v = make()
        key = k
        value = v
        return v
    }
}
