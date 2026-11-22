import SwiftUI
import AppKit

public extension ProviderID {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.30, green: 0.38, blue: 1.0)
        // Grok's brand is monochrome: near-black in light mode, near-white in dark mode.
        case .grok: Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                ? NSColor(white: 0.88, alpha: 1) : NSColor(white: 0.18, alpha: 1)
        })
        case .antigravity: Color(red: 0.16, green: 0.60, blue: 0.86)
        }
    }
}

public enum Theme {
    /// Color for a remaining fraction: calm when plenty is left, warm when it gets tight.
    public static func statusColor(remaining: Double) -> Color {
        switch remaining {
        case ..<0.10: .red
        case ..<0.25: .orange
        case ..<0.50: .yellow
        default: .green
        }
    }

    public static func color(for window: UsageWindow, provider: ProviderID, byProvider: Bool) -> Color {
        byProvider ? provider.tint : statusColor(remaining: window.remainingFraction)
    }
}

public enum Fmt {
    public static func percent(_ fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    /// "2h 14m", "3d 4h", "12m", "now"
    public static func duration(_ interval: TimeInterval, compact: Bool = false) -> String {
        let s = max(0, Int(interval))
        let d = s / 86_400, h = (s % 86_400) / 3600, m = (s % 3600) / 60
        if d > 0 { return compact ? "\(d)d" : (h > 0 ? "\(d)d \(h)h" : "\(d)d") }
        if h > 0 { return compact ? "\(h)h" : (m > 0 ? "\(h)h \(m)m" : "\(h)h") }
        if m > 0 { return "\(m)m" }
        return s > 0 ? "<1m" : "now"
    }

    public static func resets(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "" }
        let left = date.timeIntervalSince(now)
        if left <= 0 { return "Resetting…" }
        if left < 86_400 { return "Resets in \(duration(left))" }
        return "Resets \(DateFmt.dayTime(date, now: now))"
    }

    public static func expires(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "No expiry" }
        let left = date.timeIntervalSince(now)
        if left <= 0 { return "Expired" }
        if left < 7 * 86_400 { return "Expires in \(duration(left))" }
        return "Expires \(DateFmt.date(date))"
    }

    public static func tokens(_ value: Double) -> String {
        switch value {
        case 1_000_000_000...: String(format: "%.1fB", value / 1_000_000_000)
        case 1_000_000...: String(format: "%.1fM", value / 1_000_000)
        case 1_000...: String(format: "%.0fK", value / 1_000)
        default: String(Int(value))
        }
    }

    public static func cost(_ value: Double) -> String {
        value >= 1000 ? String(format: "$%.1fK", value / 1000) : String(format: "$%.2f", value)
    }

    public static func metric(_ value: Double, _ metric: UsageHistory.Metric) -> String {
        metric == .cost ? cost(value) : tokens(value)
    }

    public static func planName(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let known: [String: String] = [
            "max_5x": "Max 5×", "max_20x": "Max 20×", "max": "Max", "pro": "Pro", "plus": "Plus",
            "free": "Free", "team": "Team", "enterprise": "Enterprise", "business": "Business",
            "edu": "Edu", "go": "Go", "prolite": "Pro Lite", "promax": "Pro Max",
            "supergrok": "SuperGrok", "supergrok_heavy": "SuperGrok Heavy",
        ]
        if let k = known[raw.lowercased()] { return k }
        return raw.replacingOccurrences(of: "_", with: " ").capitalized
    }
}

/// Heatmap colors (deliberately not GitHub green by default).
public enum HeatmapPalette: String, CaseIterable, Identifiable, Sendable {
    case violet, blue, orange, pink, teal, graphite
    public var id: String { rawValue }
    public var title: String { rawValue.capitalized }
    public var color: Color {
        switch self {
        case .violet: Color(red: 0.49, green: 0.36, blue: 0.96)
        case .blue: Color(red: 0.20, green: 0.48, blue: 1.0)
        case .orange: Color(red: 0.95, green: 0.50, blue: 0.20)
        case .pink: Color(red: 0.93, green: 0.30, blue: 0.55)
        case .teal: Color(red: 0.10, green: 0.66, blue: 0.70)
        case .graphite: Color.primary
        }
    }
    public static var current: HeatmapPalette {
        HeatmapPalette(rawValue: SharedStore.defaults.string(forKey: SharedStore.Key.heatmapPalette) ?? "") ?? .violet
    }
}

public extension String {
    /// "Expires 12 Dec" → "expires 12 Dec" (only the first letter, so month names keep their case).
    var lowercasingFirst: String { prefix(1).lowercased() + dropFirst() }
}
