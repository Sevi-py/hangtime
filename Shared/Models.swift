import Foundation

// MARK: - Providers

public enum ProviderID: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case claude, codex, grok, antigravity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claude: "Claude Code"
        case .codex: "Codex"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        }
    }

    public var shortName: String {
        switch self {
        case .claude: "Claude"
        case .codex: "Codex"
        case .grok: "Grok"
        case .antigravity: "Antigravity"
        }
    }

    /// Default terminal command used to locate the CLI.
    public var defaultCommand: String {
        switch self {
        case .claude: "claude"
        case .codex: "codex"
        case .grok: "grok"
        case .antigravity: "agy"
        }
    }

    /// Brand mark in Brand.xcassets (template image).
    public var logo: String { "logo-\(rawValue)" }

    /// SF Symbol used when no brand glyph is available.
    public var symbol: String {
        switch self {
        case .claude: "asterisk"
        case .codex: "chevron.left.forwardslash.chevron.right"
        case .grok: "bolt.horizontal"
        case .antigravity: "arrow.up.circle"
        }
    }
}

// MARK: - Limit windows

public enum WindowKind: String, Codable, Hashable, Sendable, CaseIterable {
    /// Short rolling window (e.g. Claude/Codex 5 hour session).
    case session
    /// Weekly window covering all models.
    case weekly
    /// Weekly (or other) window scoped to one model / model family (e.g. Fable, Opus).
    case model
    /// Anything we could not classify (new limit types added by a CLI update).
    case other

    public var sortOrder: Int {
        switch self {
        case .session: 0
        case .weekly: 1
        case .model: 2
        case .other: 3
        }
    }
}

public struct UsageWindow: Codable, Hashable, Identifiable, Sendable {
    /// Stable identifier as reported by the backend (e.g. `five_hour`, `seven_day_fable`, `codex.primary`).
    public var id: String
    public var kind: WindowKind
    public var title: String
    /// Optional scope (model name) the limit applies to.
    public var scope: String?
    /// 0...1 – fraction of the window that has been used.
    public var usedFraction: Double
    public var resetsAt: Date?
    /// Length of the window, when known. Needed for the "even pace" marker.
    public var duration: TimeInterval?
    /// Last known value only (the provider couldn't be reached recently). Optional for Codable compatibility.
    public var isStale: Bool?
    /// Extra context, e.g. "Up to 50% of weekly · 22% of weekly used".
    public var note: String?

    public init(id: String, kind: WindowKind, title: String, scope: String? = nil,
                usedFraction: Double, resetsAt: Date?, duration: TimeInterval?) {
        self.id = id
        self.kind = kind
        self.title = title
        self.scope = scope
        self.usedFraction = min(max(usedFraction, 0), 1)
        self.resetsAt = resetsAt
        self.duration = duration
    }

    public var remainingFraction: Double { 1 - usedFraction }
    public var isExhausted: Bool { usedFraction >= 0.999 }

    /// Fraction of the limit that would still be left right now if usage had been
    /// spread perfectly evenly across the window. When the window is half over, this is 0.5.
    public func evenPaceRemaining(at now: Date = .now) -> Double? {
        guard let resetsAt, let duration, duration > 0 else { return nil }
        let left = resetsAt.timeIntervalSince(now)
        return min(max(left / duration, 0), 1)
    }

    /// Positive = ahead of pace (more left than an even pace), negative = burning faster.
    public func paceDelta(at now: Date = .now) -> Double? {
        guard let even = evenPaceRemaining(at: now) else { return nil }
        return remainingFraction - even
    }

    /// Estimated date the limit will run out at the current average burn rate.
    public func projectedExhaustion(at now: Date = .now) -> Date? {
        guard let resetsAt, let duration, usedFraction > 0.01 else { return nil }
        let start = resetsAt.addingTimeInterval(-duration)
        let elapsed = now.timeIntervalSince(start)
        guard elapsed > 60 else { return nil }
        let rate = usedFraction / elapsed
        let eta = now.addingTimeInterval(remainingFraction / rate)
        return eta < resetsAt ? eta : nil
    }
}

// MARK: - Banked resets

public struct BankedReset: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String?
    public var grantedAt: Date?
    public var expiresAt: Date?
    /// Whether the app knows how to redeem this reset.
    public var redeemable: Bool

    public init(id: String, title: String, detail: String? = nil, grantedAt: Date? = nil,
                expiresAt: Date? = nil, redeemable: Bool) {
        self.id = id
        self.title = title
        self.detail = detail
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.redeemable = redeemable
    }
}

// MARK: - Provider snapshot

public enum ProviderStatus: Codable, Hashable, Sendable {
    case ok
    case loggedOut
    case notInstalled
    case error(String)

    public var isProblem: Bool {
        switch self {
        case .ok, .notInstalled: false
        default: true
        }
    }
}

public struct ProviderSnapshot: Codable, Hashable, Identifiable, Sendable {
    public var provider: ProviderID
    public var status: ProviderStatus
    public var plan: String?
    public var account: String?
    public var windows: [UsageWindow]
    public var bankedResets: [BankedReset]
    /// Number of banked resets when the backend only provides a count.
    public var bankedResetCount: Int?
    /// Extra free-form facts (e.g. "Credits: $4.20").
    public var notes: [String]
    public var fetchedAt: Date
    public var cliVersion: String?
    /// When the limit numbers were actually read from the provider (may be older than `fetchedAt`).
    public var dataAsOf: Date?
    /// Why the numbers are old (shown on the card).
    public var staleReason: String?

    public var id: ProviderID { provider }

    public init(provider: ProviderID, status: ProviderStatus, plan: String? = nil, account: String? = nil,
                windows: [UsageWindow] = [], bankedResets: [BankedReset] = [], bankedResetCount: Int? = nil,
                notes: [String] = [], fetchedAt: Date = .now, cliVersion: String? = nil) {
        self.provider = provider
        self.status = status
        self.plan = plan
        self.account = account
        self.windows = windows
        self.bankedResets = bankedResets
        self.bankedResetCount = bankedResetCount
        self.notes = notes
        self.fetchedAt = fetchedAt
        self.cliVersion = cliVersion
    }

    public var sortedWindows: [UsageWindow] {
        windows.sorted { ($0.kind.sortOrder, $0.title) < ($1.kind.sortOrder, $1.title) }
    }

    public var session: UsageWindow? { windows.first { $0.kind == .session } }
    public var weekly: UsageWindow? { windows.first { $0.kind == .weekly } }

    /// The window that is most constraining right now (least remaining).
    public var tightest: UsageWindow? { windows.min { $0.remainingFraction < $1.remainingFraction } }

    public var availableResetCount: Int { max(bankedResets.count, bankedResetCount ?? 0) }

    public func window(id: String) -> UsageWindow? { windows.first { $0.id == id } }
}

// MARK: - History

public struct DailyUsage: Codable, Hashable, Identifiable, Sendable {
    /// Day in `yyyy-MM-dd` (local time).
    public var day: String
    public var provider: ProviderID
    public var model: String?
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    /// Estimated API-equivalent cost in USD (may be nil when unknown).
    public var costUSD: Double?
    /// When only a total is known (e.g. Codex account usage buckets).
    public var totalOverride: Int?

    public var id: String { "\(day)|\(provider.rawValue)|\(model ?? "-")" }

    public init(day: String, provider: ProviderID, model: String? = nil, inputTokens: Int = 0, outputTokens: Int = 0,
                cacheReadTokens: Int = 0, cacheWriteTokens: Int = 0, costUSD: Double? = nil, totalOverride: Int? = nil) {
        self.day = day
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.costUSD = costUSD
        self.totalOverride = totalOverride
    }

    public var totalTokens: Int {
        totalOverride ?? (inputTokens + outputTokens + cacheReadTokens + cacheWriteTokens)
    }

    public var date: Date { DayFormatter.date(from: day) ?? .distantPast }
}

public enum HistorySource: String, Codable, Sendable {
    case t3code = "T3 Code"
    case cliLogs = "CLI logs"
    case none = "None"
}

public struct UsageHistory: Codable, Hashable, Sendable {
    public var days: [DailyUsage]
    public var source: HistorySource
    public var updatedAt: Date

    public init(days: [DailyUsage] = [], source: HistorySource = .none, updatedAt: Date = .now) {
        self.days = days
        self.source = source
        self.updatedAt = updatedAt
    }

    public enum Metric: String, Codable, CaseIterable, Identifiable, Sendable {
        case cost, tokens
        public var id: String { rawValue }
        public var title: String { self == .cost ? "Cost" : "Tokens" }
    }

    /// Aggregated values per day and provider for the last `days` days (including today), zero-filled.
    public func series(lastDays count: Int, metric: Metric, providers: Set<ProviderID>, now: Date = .now) -> [DayPoint] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        var buckets: [String: [ProviderID: Double]] = [:]
        for d in days where providers.contains(d.provider) {
            let v: Double = metric == .cost ? (d.costUSD ?? 0) : Double(d.totalTokens)
            buckets[d.day, default: [:]][d.provider, default: 0] += v
        }
        var out: [DayPoint] = []
        for offset in stride(from: count - 1, through: 0, by: -1) {
            guard let date = cal.date(byAdding: .day, value: -offset, to: today) else { continue }
            let key = DayFormatter.string(from: date)
            for p in ProviderID.allCases where providers.contains(p) {
                out.append(DayPoint(date: date, provider: p, value: buckets[key]?[p] ?? 0))
            }
        }
        return out
    }

    /// Totals per day (summed across the selected providers), used by the heatmap.
    public func dailyTotals(metric: Metric, providers: Set<ProviderID>) -> [String: Double] {
        var out: [String: Double] = [:]
        for d in days where providers.contains(d.provider) {
            out[d.day, default: 0] += metric == .cost ? (d.costUSD ?? 0) : Double(d.totalTokens)
        }
        return out
    }

    public func total(metric: Metric, providers: Set<ProviderID>, since: Date) -> Double {
        let key = DayFormatter.string(from: since)
        return days.filter { providers.contains($0.provider) && $0.day >= key }
            .reduce(0) { $0 + (metric == .cost ? ($1.costUSD ?? 0) : Double($1.totalTokens)) }
    }

    public var hasCost: Bool { days.contains { ($0.costUSD ?? 0) > 0 } }
}

public struct DayPoint: Hashable, Identifiable, Sendable {
    public var date: Date
    public var provider: ProviderID
    public var value: Double
    public var id: String { "\(date.timeIntervalSince1970)-\(provider.rawValue)" }
}

public enum DayFormatter {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    private static let lock = NSLock()

    public static func string(from date: Date) -> String {
        lock.lock(); defer { lock.unlock() }
        return formatter.string(from: date)
    }

    public static func date(from string: String) -> Date? {
        lock.lock(); defer { lock.unlock() }
        return formatter.date(from: String(string.prefix(10)))
    }
}

// MARK: - Shared snapshot written by the app, read by widgets

public struct SharedState: Codable, Sendable {
    public var providers: [ProviderSnapshot]
    public var history: UsageHistory
    public var updatedAt: Date
    /// Providers the user enabled and whose CLI is installed – in display order.
    public var visibleProviders: [ProviderID]

    public init(providers: [ProviderSnapshot] = [], history: UsageHistory = .init(),
                updatedAt: Date = .now, visibleProviders: [ProviderID] = []) {
        self.providers = providers
        self.history = history
        self.updatedAt = updatedAt
        self.visibleProviders = visibleProviders
    }

    public func snapshot(for id: ProviderID) -> ProviderSnapshot? { providers.first { $0.provider == id } }

    public var visibleSnapshots: [ProviderSnapshot] {
        visibleProviders.compactMap { snapshot(for: $0) }
    }
}
