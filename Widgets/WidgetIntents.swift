import AppIntents
import WidgetKit
import Foundation

enum ProviderOption: String, AppEnum {
    case automatic, claude, codex, grok, antigravity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [ProviderOption: DisplayRepresentation] = [
        .automatic: "Automatic",
        .claude: "Claude Code",
        .codex: "Codex",
        .grok: "Grok",
        .antigravity: "Antigravity",
    ]

    func resolve(in state: SharedState) -> ProviderID? {
        switch self {
        case .automatic: state.visibleProviders.first ?? state.providers.first?.provider
        case .claude: .claude
        case .codex: .codex
        case .grok: .grok
        case .antigravity: .antigravity
        }
    }
}

/// Provider choice for the history widgets, where "All" combines every provider.
/// `all` keeps the old "automatic" raw value so widgets that were already placed keep showing everything.
enum HistoryProviderOption: String, AppEnum {
    case all = "automatic", claude, codex, grok, antigravity

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Provider"
    static let caseDisplayRepresentations: [HistoryProviderOption: DisplayRepresentation] = [
        .all: "All",
        .claude: "Claude Code",
        .codex: "Codex",
        .grok: "Grok",
        .antigravity: "Antigravity",
    ]

    var single: ProviderID? { ProviderID(rawValue: rawValue) }

    func providers(in state: SharedState) -> Set<ProviderID> {
        if let single { return [single] }
        return Set(state.visibleProviders.isEmpty ? ProviderID.allCases : state.visibleProviders)
    }
}

enum LimitOption: String, AppEnum {
    case session, weekly, tightest

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Limit"
    static let caseDisplayRepresentations: [LimitOption: DisplayRepresentation] = [
        .session: "Session",
        .weekly: "Weekly",
        .tightest: "Most constrained",
    ]

    func pick(_ snap: ProviderSnapshot) -> UsageWindow? {
        switch self {
        case .session: snap.session ?? snap.weekly ?? snap.tightest
        case .weekly: snap.weekly ?? snap.session ?? snap.tightest
        case .tightest: snap.tightest
        }
    }

    /// For widgets showing just this one limit of one provider: honours "0% when a limit is used up".
    func pickSingle(_ snap: ProviderSnapshot) -> UsageWindow? {
        guard let w = pick(snap) else { return nil }
        let zero = SharedStore.defaults.object(forKey: SharedStore.Key.zeroWhenBlocked) as? Bool ?? true
        return zero ? snap.blocked(w) : w
    }
}

enum MetricOption: String, AppEnum {
    case automatic, cost, tokens
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Metric"
    static let caseDisplayRepresentations: [MetricOption: DisplayRepresentation] = [
        .automatic: "Same as app", .cost: "Cost", .tokens: "Tokens",
    ]

    func resolve(_ history: UsageHistory) -> UsageHistory.Metric {
        let m: UsageHistory.Metric = switch self {
        case .automatic: UsageHistory.Metric(rawValue: SharedStore.defaults.string(forKey: SharedStore.Key.historyMetric) ?? "") ?? .cost
        case .cost: .cost
        case .tokens: .tokens
        }
        return m == .cost && !history.hasCost ? .tokens : m
    }
}

enum StyleOption: String, AppEnum {
    case rings, bars
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Style"
    static let caseDisplayRepresentations: [StyleOption: DisplayRepresentation] = [
        .rings: "Rings", .bars: "Bars",
    ]
}

struct ProviderLimitsIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Provider Limits"
    static let description = IntentDescription("Session and weekly limits for one CLI.")

    @Parameter(title: "Provider", default: .automatic) var provider: ProviderOption
    @Parameter(title: "Style", default: .rings) var style: StyleOption
    @Parameter(title: "Show model limits", default: true) var showModelLimits: Bool
    @Parameter(title: "Even-pace marker on bars", default: true) var showPace: Bool
    @Parameter(title: "Even-pace marker on rings", default: false) var showPaceOnRings: Bool
}

struct SingleGaugeIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Single Limit"
    static let description = IntentDescription("One big gauge for one limit.")

    @Parameter(title: "Provider", default: .automatic) var provider: ProviderOption
    @Parameter(title: "Limit", default: .session) var limit: LimitOption
    @Parameter(title: "Show even-pace marker", default: false) var showPace: Bool
}

struct OverviewIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "All Providers"
    static let description = IntentDescription("Remaining limits for every installed CLI.")

    @Parameter(title: "Limit", default: .tightest) var limit: LimitOption
    @Parameter(title: "Show all limits (large size)", default: true) var showAll: Bool
    @Parameter(title: "Show even-pace marker", default: true) var showPace: Bool
}

struct ChartIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Usage Chart"
    static let description = IntentDescription("Daily cost or tokens across providers.")

    @Parameter(title: "Provider", default: .all) var provider: HistoryProviderOption
    @Parameter(title: "Metric", default: .automatic) var metric: MetricOption
    @Parameter(title: "Days", default: 30, inclusiveRange: (7, 90)) var days: Int
    @Parameter(title: "Bars", default: false) var bars: Bool
}

struct HeatmapIntent: WidgetConfigurationIntent {
    static let title: LocalizedStringResource = "Activity"
    static let description = IntentDescription("Your coding activity, GitHub-style.")

    @Parameter(title: "Provider", default: .all) var provider: HistoryProviderOption
    @Parameter(title: "Metric", default: .automatic) var metric: MetricOption
    @Parameter(title: "Use provider color", default: false) var providerColor: Bool
}

/// Asks the menu bar app (which owns the CLI logins) to refresh. Widgets are sandboxed and
/// can't run the CLIs themselves, so we ping the app over a Darwin notification.
struct RefreshUsageIntent: AppIntent {
    static let title: LocalizedStringResource = "Refresh Usage"
    static let description = IntentDescription("Fetches the latest usage limits.")

    func perform() async throws -> some IntentResult {
        DarwinNotify.post(DarwinNotify.refresh)
        try? await Task.sleep(for: .seconds(4))
        WidgetCenter.shared.reloadAllTimelines()
        return .result()
    }
}
