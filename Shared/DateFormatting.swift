import Foundation

/// User-selectable date/time formatting. "System" follows macOS (Language & Region, incl. the
/// 24-hour time switch) via `Locale.autoupdatingCurrent`. Stored in the app group so widgets match.
public enum TimeFormatPref: String, CaseIterable, Identifiable, Sendable {
    case system, h12, h24
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "System"
        case .h12: "12-hour"
        case .h24: "24-hour"
        }
    }
    /// Hour/minute part of a DateFormatter template.
    var template: String {
        switch self {
        case .system: "jmm"
        case .h12: "hmma"
        case .h24: "HHmm"
        }
    }
}

public enum DateFormatPref: String, CaseIterable, Identifiable, Sendable {
    case system, numeric, long, iso
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .system: "System"
        case .numeric: "Numeric"
        case .long: "Long"
        case .iso: "ISO 8601"
        }
    }
    var template: String {
        switch self {
        case .system: "MMMd"
        case .numeric: "Md"
        case .long: "MMMMd"
        case .iso: "yyyyMMdd"
        }
    }
}

public enum ResetDisplayPref: String, CaseIterable, Identifiable, Sendable {
    case relative, absolute, both
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .relative: "Countdown"
        case .absolute: "Date & time"
        case .both: "Both"
        }
    }
}

public enum DateFmt {
    public enum Key {
        public static let time = "fmt.time"
        public static let date = "fmt.date"
        public static let reset = "fmt.reset"
    }

    public static var timePref: TimeFormatPref {
        TimeFormatPref(rawValue: SharedStore.defaults.string(forKey: Key.time) ?? "") ?? .system
    }
    public static var datePref: DateFormatPref {
        DateFormatPref(rawValue: SharedStore.defaults.string(forKey: Key.date) ?? "") ?? .system
    }
    public static var resetPref: ResetDisplayPref {
        ResetDisplayPref(rawValue: SharedStore.defaults.string(forKey: Key.reset) ?? "") ?? .relative
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]

    private static func formatter(_ template: String, fixed: Bool = false) -> DateFormatter {
        lock.lock(); defer { lock.unlock() }
        let key = "\(fixed)|\(template)|\(Locale.autoupdatingCurrent.identifier)"
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        if fixed { f.dateFormat = template } else { f.setLocalizedDateFormatFromTemplate(template) }
        cache[key] = f
        return f
    }

    public static func time(_ d: Date, _ pref: TimeFormatPref = timePref) -> String {
        formatter(pref.template).string(from: d)
    }

    public static func date(_ d: Date, _ pref: DateFormatPref = datePref) -> String {
        pref == .iso ? formatter("yyyy-MM-dd", fixed: true).string(from: d) : formatter(pref.template).string(from: d)
    }

    public static func dateTime(_ d: Date) -> String {
        if datePref == .iso { return "\(date(d)) \(time(d))" }
        return formatter(datePref.template + timePref.template).string(from: d)
    }

    /// "Today 14:59", "Tomorrow 09:40", "Mon 14:59", or a full date + time further out.
    public static func dayTime(_ d: Date, now: Date = .now) -> String {
        let cal = Calendar.autoupdatingCurrent
        if cal.isDate(d, inSameDayAs: now) { return "\(relativeDayName(0)) \(time(d))" }
        if let tomorrow = cal.date(byAdding: .day, value: 1, to: now), cal.isDate(d, inSameDayAs: tomorrow) {
            return "\(relativeDayName(1)) \(time(d))"
        }
        if d.timeIntervalSince(now) < 6 * 86_400, d > now {
            return formatter("EEE" + timePref.template).string(from: d)
        }
        return dateTime(d)
    }

    /// Localized "Today" / "Tomorrow".
    private static func relativeDayName(_ offset: Int) -> String {
        let r = DateFormatter()
        r.locale = .autoupdatingCurrent
        r.dateStyle = .medium
        r.timeStyle = .none
        r.doesRelativeDateFormatting = true
        return r.string(from: Calendar.autoupdatingCurrent.date(byAdding: .day, value: offset, to: .now) ?? .now)
    }
}
