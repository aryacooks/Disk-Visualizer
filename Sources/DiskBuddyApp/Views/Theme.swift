import SwiftUI
import ScannerCore

/// The "Paper" theme. Warm cream ground, muted pastel cards, near-black pills.
/// Every colour here was matched against the reference screenshots.
public enum Theme {

    // MARK: - Grounds

    /// Window chrome behind everything (the title-bar strip).
    public static let chrome      = Color(red: 0.957, green: 0.961, blue: 0.969)
    /// Main content ground — warm paper, never pure white.
    public static let ground      = Color(red: 0.996, green: 0.984, blue: 0.965) // #FEFBF6
    /// Left rail + right inspector, a half-shade warmer than the centre.
    public static let rail        = Color(red: 0.992, green: 0.976, blue: 0.949) // #FDF9F2
    /// Inset boxes inside the inspector (DETAILS, LARGEST INSIDE).
    public static let inset       = Color(red: 0.988, green: 0.973, blue: 0.945)
    /// Hairline separators and box borders.
    public static let hairline    = Color(red: 0.898, green: 0.878, blue: 0.843)
    /// Track behind progress bars and the disk ring.
    public static let track       = Color(red: 0.925, green: 0.910, blue: 0.882)

    // MARK: - Ink

    public static let ink         = Color(red: 0.086, green: 0.082, blue: 0.078) // near-black
    public static let inkSecond   = Color(red: 0.435, green: 0.416, blue: 0.388)
    public static let inkFaint    = Color(red: 0.612, green: 0.592, blue: 0.561)

    /// Filled pill for the active tab / segment.
    public static let pill        = Color(red: 0.086, green: 0.082, blue: 0.078)
    public static let pillText    = Color(red: 0.980, green: 0.973, blue: 0.961)
    /// Soft grey fill for a selected-but-secondary segment.
    public static let pillSoft    = Color(red: 0.906, green: 0.890, blue: 0.863)

    // MARK: - Accents

    public static let gauge       = Color(red: 0.722, green: 0.549, blue: 0.196) // amber ring
    public static let danger      = Color(red: 0.788, green: 0.310, blue: 0.271)
    public static let good        = Color(red: 0.310, green: 0.569, blue: 0.376)

    // MARK: - Folder card pastels
    // Muted, desaturated, high-lightness. Hue is a stable hash of the folder
    // name, so a folder keeps its colour across every view and every session.

    private static let cardTops: [Color] = [
        Color(red: 0.976, green: 0.898, blue: 0.749),  // butter
        Color(red: 0.976, green: 0.851, blue: 0.859),  // blush
        Color(red: 0.855, green: 0.898, blue: 0.831),  // sage
        Color(red: 0.827, green: 0.886, blue: 0.937),  // sky
        Color(red: 0.878, green: 0.867, blue: 0.933),  // lilac
        Color(red: 0.973, green: 0.882, blue: 0.831),  // clay
        Color(red: 0.859, green: 0.925, blue: 0.906),  // mint
        Color(red: 0.937, green: 0.867, blue: 0.914),  // orchid
        Color(red: 0.933, green: 0.914, blue: 0.827),  // wheat
        Color(red: 0.898, green: 0.878, blue: 0.847),  // stone
    ]

    /// FNV-1a over the name — stable across launches, unlike `hashValue`.
    public static func hashIndex(_ name: String, _ modulo: Int) -> Int {
        var h: UInt64 = 0xcbf29ce484222325
        for b in name.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return Int(h % UInt64(modulo))
    }

    public static func cardColor(_ name: String) -> Color {
        cardTops[hashIndex(name, cardTops.count)]
    }

    /// Cards fade toward the paper ground at the bottom, as in the reference.
    public static func cardGradient(_ name: String) -> LinearGradient {
        let top = cardColor(name)
        return LinearGradient(
            colors: [top.opacity(0.95), top.opacity(0.42)],
            startPoint: .top, endPoint: .bottom
        )
    }

    /// Saturated enough to read as a 3px dot or a treemap rect.
    public static func markColor(_ name: String) -> Color {
        let base = cardColor(name)
        return base.opacity(1.0)
    }

    // MARK: - File type legend colours

    public static func categoryColor(_ c: FileTypeCategory) -> Color {
        switch c {
        case .video:     return Color(red: 0.910, green: 0.545, blue: 0.596)
        case .audio:     return Color(red: 0.678, green: 0.612, blue: 0.859)
        case .image:     return Color(red: 0.529, green: 0.729, blue: 0.882)
        case .document:  return Color(red: 0.831, green: 0.784, blue: 0.706)
        case .developer: return Color(red: 0.588, green: 0.749, blue: 0.549)
        case .archive:   return Color(red: 0.902, green: 0.678, blue: 0.400)
        case .other:     return Color(red: 0.792, green: 0.776, blue: 0.749)
        }
    }
}

// MARK: - Formatting

public enum Fmt {
    /// Decimal units, matching Finder — "68.4 GB", never a raw byte count.
    public static func bytes(_ b: Int64) -> String {
        if b < 1000 { return "\(b) B" }
        let units = ["KB", "MB", "GB", "TB", "PB"]
        var v = Double(b) / 1000, i = 0
        while v >= 1000 && i < units.count - 1 { v /= 1000; i += 1 }
        return String(format: v >= 100 ? "%.0f %@" : "%.2f %@", v, units[i])
    }

    public static func count(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    public static func pct(_ v: Double) -> String {
        if v > 0 && v < 0.1 { return "<0.1%" }
        return String(format: "%.1f%%", v)
    }

    /// "4 hours ago", "1 year ago" — the reference never shows a raw date.
    public static func ago(_ date: Date) -> String {
        let s = Int(Date().timeIntervalSince(date))
        if s < 60 { return "just now" }
        let mins = s / 60
        if mins < 60 { return "\(mins) minute\(mins == 1 ? "" : "s") ago" }
        let hrs = mins / 60
        if hrs < 24 { return "\(hrs) hour\(hrs == 1 ? "" : "s") ago" }
        let days = hrs / 24
        if days < 31 { return "\(days) day\(days == 1 ? "" : "s") ago" }
        let months = days / 30
        if months < 12 { return "\(months) month\(months == 1 ? "" : "s") ago" }
        let years = days / 365
        return "\(years) year\(years == 1 ? "" : "s") ago"
    }
}

// MARK: - Shared building blocks

/// Small, uppercase, wide-tracked section label — used down both rails.
public struct RailLabel: View {
    let text: String
    var trailing: String? = nil
    public init(_ text: String, trailing: String? = nil) {
        self.text = text; self.trailing = trailing
    }
    public var body: some View {
        HStack {
            Text(text.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(Theme.inkFaint)
            Spacer()
            if let t = trailing {
                Text(t)
                    .font(.system(size: 10, weight: .medium).monospacedDigit())
                    .foregroundStyle(Theme.inkFaint)
            }
        }
    }
}

/// The folder-shaped card silhouette: a rounded rect with a tab on the top-left.
public struct FolderShape: Shape {
    public init() {}
    public func path(in r: CGRect) -> Path {
        let radius: CGFloat = 12
        let tabW = min(r.width * 0.30, 96)
        let tabH: CGFloat = 13
        let tr: CGFloat = 6

        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY + tabH + tr))
        // tab, left edge up
        p.addQuadCurve(to: CGPoint(x: r.minX + tr, y: r.minY + tabH),
                       control: CGPoint(x: r.minX, y: r.minY + tabH))
        p.addLine(to: CGPoint(x: r.minX + tabW - tr, y: r.minY + tabH))
        // the little diagonal shoulder into the tab top
        p.addQuadCurve(to: CGPoint(x: r.minX + tabW + 6, y: r.minY + tr),
                       control: CGPoint(x: r.minX + tabW + 1, y: r.minY + tabH - 2))
        p.addQuadCurve(to: CGPoint(x: r.minX + tabW + 6 + tr, y: r.minY),
                       control: CGPoint(x: r.minX + tabW + 6, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY + radius),
                       control: CGPoint(x: r.maxX, y: r.minY))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY - radius))
        p.addQuadCurve(to: CGPoint(x: r.maxX - radius, y: r.maxY),
                       control: CGPoint(x: r.maxX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX + radius, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.minX, y: r.maxY - radius),
                       control: CGPoint(x: r.minX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}
