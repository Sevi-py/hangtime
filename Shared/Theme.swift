import SwiftUI

public extension ProviderID {
    var tint: Color {
        switch self {
        case .claude: Color(red: 0.85, green: 0.47, blue: 0.34)
        case .codex: Color(red: 0.20, green: 0.62, blue: 0.52)
        case .grok: Color(red: 0.42, green: 0.48, blue: 0.95)
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
        let r = window.remainingFraction
        if r < 0.10 { return .red }
        if byProvider { return r < 0.25 ? .orange : provider.tint }
        return statusColor(remaining: r)
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
        return "Resets \(date.formatted(.dateTime.weekday(.abbreviated).hour().minute()))"
    }

    public static func expires(_ date: Date?, now: Date = .now) -> String {
        guard let date else { return "No expiry" }
        let left = date.timeIntervalSince(now)
        if left <= 0 { return "Expired" }
        if left < 7 * 86_400 { return "Expires in \(duration(left))" }
        return "Expires \(date.formatted(.dateTime.month(.abbreviated).day()))"
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
