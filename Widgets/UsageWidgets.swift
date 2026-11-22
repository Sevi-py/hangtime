import WidgetKit
import SwiftUI
import AppIntents

// MARK: - Timeline

struct UsageEntry: TimelineEntry {
    var date: Date
    var state: SharedState
    var intent: (any WidgetConfigurationIntent)?
}

private func makeTimeline(state: SharedState?, intent: (any WidgetConfigurationIntent)?) -> Timeline<UsageEntry> {
    let s = state ?? .placeholder
    // Several entries so pace markers & countdowns advance between app refreshes.
    let entries = (0..<8).map { i in UsageEntry(date: Date.now.addingTimeInterval(Double(i) * 15 * 60), state: s, intent: intent) }
    return Timeline(entries: entries, policy: .after(Date.now.addingTimeInterval(2 * 3600)))
}

struct IntentProvider<Intent: WidgetConfigurationIntent>: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> UsageEntry { UsageEntry(date: .now, state: .placeholder, intent: nil) }
    func snapshot(for configuration: Intent, in context: Context) async -> UsageEntry {
        UsageEntry(date: .now, state: context.isPreview ? .placeholder : (SharedStore.load() ?? .placeholder), intent: configuration)
    }
    func timeline(for configuration: Intent, in context: Context) async -> Timeline<UsageEntry> {
        makeTimeline(state: SharedStore.load(), intent: configuration)
    }
}

private var globalShowPace: Bool { SharedStore.defaults.object(forKey: SharedStore.Key.showPaceMarker) as? Bool ?? true }
private var globalByProvider: Bool { SharedStore.defaults.object(forKey: SharedStore.Key.colorByProvider) as? Bool ?? true }

// MARK: - Shared bits

struct WidgetHeader: View {
    var provider: ProviderID
    var snapshot: ProviderSnapshot?
    var compact = false

    var body: some View {
        HStack(spacing: 6) {
            ProviderGlyph(provider, size: compact ? 14 : 16)
            Text(compact ? provider.shortName : provider.displayName)
                .font(.system(size: compact ? 12 : 13, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 0)
            if let plan = Fmt.planName(snapshot?.plan), !compact {
                Text(plan).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
            }
        }
    }
}

struct StatusPlaceholder: View {
    var snapshot: ProviderSnapshot?
    var body: some View {
        VStack(spacing: 4) {
            switch snapshot?.status {
            case .loggedOut?:
                Image(systemName: "person.crop.circle.badge.exclamationmark").font(.title2).foregroundStyle(.orange)
                Text("Signed out").font(.caption.weight(.semibold))
                Text("Open Headroom to sign in").font(.caption2).foregroundStyle(.secondary)
            case nil:
                Image(systemName: "terminal").font(.title2).foregroundStyle(.secondary)
                Text("Not set up").font(.caption.weight(.semibold))
            default:
                Image(systemName: "exclamationmark.triangle").font(.title2).foregroundStyle(.orange)
                Text("No data").font(.caption.weight(.semibold))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .multilineTextAlignment(.center)
    }
}

private func usable(_ snap: ProviderSnapshot?) -> Bool {
    guard let snap else { return false }
    return snap.status != .loggedOut && !snap.windows.isEmpty
}

// MARK: - Provider Limits widget

struct ProviderLimitsView: View {
    var entry: UsageEntry
    var config: ProviderLimitsIntent
    @Environment(\.widgetFamily) private var envFamily
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        let pid = config.provider.resolve(in: entry.state) ?? .claude
        let snap = entry.state.snapshot(for: pid)
        let showPace = config.showPace && globalShowPace
        let windows = (snap?.sortedWindows ?? []).filter { config.showModelLimits || $0.kind == .session || $0.kind == .weekly }
        VStack(alignment: .leading, spacing: 8) {
            WidgetHeader(provider: pid, snapshot: snap, compact: family == .systemSmall)
            if !usable(snap) {
                StatusPlaceholder(snapshot: snap)
            } else if config.style == .rings {
                let shown = Array(windows.prefix(family == .systemSmall ? 2 : family == .systemMedium ? 4 : 6))
                Spacer(minLength: 0)
                HStack(spacing: family == .systemSmall ? 8 : 14) {
                    ForEach(shown) { w in
                        VStack(spacing: 4) {
                            RingGauge(remaining: w.remainingFraction,
                                      pace: config.showPaceOnRings && globalShowPace ? w.evenPaceRemaining(at: entry.date) : nil,
                                      color: Theme.color(for: w, provider: pid, byProvider: globalByProvider),
                                      lineWidth: family == .systemSmall ? 6 : 7)
                            Text(shortTitle(w)).font(.system(size: 10, weight: .medium)).lineLimit(1)
                            if family != .systemSmall {
                                Group {
                                    if let r = w.resetsAt {
                                        if DateFmt.resetPref == .absolute { Text(DateFmt.dayTime(r, now: entry.date)) } else { Text(r, style: .relative) }
                                    } else { Text("Not started") }
                                }
                                .font(.system(size: 9)).foregroundStyle(.secondary).lineLimit(1)
                                .multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                Spacer(minLength: 0)
                if family != .systemSmall, let snap, snap.availableResetCount > 0 { resetsFooter(snap) }
            } else {
                VStack(spacing: family == .systemSmall ? 6 : 9) {
                    ForEach(windows.prefix(family == .systemSmall ? 3 : family == .systemMedium ? 3 : 7)) { w in
                        WindowRow(window: w, provider: pid, showPace: showPace, colorByProvider: globalByProvider,
                                  compact: family != .systemLarge, now: entry.date)
                    }
                }
                Spacer(minLength: 0)
                if family != .systemSmall, let snap, snap.availableResetCount > 0 { resetsFooter(snap) }
            }
        }
        .widgetURL(URL(string: "headroom://refresh"))
    }

    private func shortTitle(_ w: UsageWindow) -> String {
        if let scope = w.scope { return scope }
        switch w.kind {
        case .session: return "Session"
        case .weekly: return "Weekly"
        default: return w.title
        }
    }

    private func resetsFooter(_ snap: ProviderSnapshot) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(snap.provider.tint)
            Text("\(snap.availableResetCount) banked reset\(snap.availableResetCount == 1 ? "" : "s")")
            if let exp = snap.bankedResets.compactMap(\.expiresAt).min() {
                Text("· \(Fmt.expires(exp, now: entry.date).lowercasingFirst)").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10, weight: .medium))
        .lineLimit(1)
    }
}

struct ProviderLimitsWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "ProviderLimits", intent: ProviderLimitsIntent.self, provider: IntentProvider<ProviderLimitsIntent>()) { entry in
            ProviderLimitsView(entry: entry, config: entry.configurationIntent(ProviderLimitsIntent.self))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Provider Limits")
        .description("Session, weekly and model limits for one CLI.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

// MARK: - Single gauge

struct SingleGaugeView: View {
    var entry: UsageEntry
    var config: SingleGaugeIntent

    var body: some View {
        let pid = config.provider.resolve(in: entry.state) ?? .claude
        let snap = entry.state.snapshot(for: pid)
        if let snap, usable(snap), let w = config.limit.pick(snap) {
            VStack(spacing: 6) {
                HStack(spacing: 5) {
                    ProviderGlyph(pid, size: 14)
                    Text(pid.shortName).font(.system(size: 12, weight: .semibold))
                    Spacer()
                }
                RingGauge(remaining: w.remainingFraction,
                          pace: config.showPace && globalShowPace ? w.evenPaceRemaining(at: entry.date) : nil,
                          color: Theme.color(for: w, provider: pid, byProvider: globalByProvider),
                          lineWidth: 10, label: w.scope ?? (w.kind == .session ? "Session" : w.kind == .weekly ? "Weekly" : w.title))
                if let r = w.resetsAt {
                    ResetText(date: r, now: entry.date).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        } else {
            StatusPlaceholder(snapshot: snap)
        }
    }
}

struct SingleGaugeWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "SingleGauge", intent: SingleGaugeIntent.self, provider: IntentProvider<SingleGaugeIntent>()) { entry in
            SingleGaugeView(entry: entry, config: entry.configurationIntent(SingleGaugeIntent.self))
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "headroom://refresh"))
        }
        .configurationDisplayName("Single Limit")
        .description("One big gauge for the limit you care about.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Overview (all providers)

struct OverviewView: View {
    var entry: UsageEntry
    var config: OverviewIntent
    @Environment(\.widgetFamily) private var envFamily
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        let snaps = entry.state.visibleSnapshots
        let showPace = config.showPace && globalShowPace
        if snaps.isEmpty {
            StatusPlaceholder(snapshot: nil)
        } else if family == .systemSmall {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(snaps.prefix(4)) { s in
                    HStack(spacing: 6) {
                        ProviderGlyph(s.provider, size: 14)
                        if let w = config.limit.pick(s), usable(s) {
                            LimitBar(remaining: w.remainingFraction, pace: showPace ? w.evenPaceRemaining(at: entry.date) : nil,
                                     color: Theme.color(for: w, provider: s.provider, byProvider: globalByProvider), height: 5)
                            Text(Fmt.percent(w.remainingFraction)).font(.system(size: 11, weight: .semibold)).monospacedDigit()
                                .frame(width: 34, alignment: .trailing)
                        } else {
                            Text(s.status == .loggedOut ? "Signed out" : "—").font(.caption2).foregroundStyle(.secondary)
                            Spacer()
                        }
                    }
                }
            }
            .frame(maxHeight: .infinity)
        } else if family == .systemLarge {
            // Use the richest layout that fits; with many providers/limits fall back to denser ones.
            ViewThatFits(in: .vertical) {
                if config.showAll {
                    headered(snaps, spacing: 10) { s in
                        ForEach(s.sortedWindows) { w in row(w, s, showPace) }
                    }
                    headered(snaps, spacing: 8) { s in
                        grid(s.sortedWindows, s, showPace)
                    }
                }
                headered(snaps, spacing: 10) { s in grid(pair(s), s, showPace) }
                compactRows(snaps, spacing: 8, showPace)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        } else {
            ViewThatFits(in: .vertical) {
                headered(snaps, spacing: 8) { s in grid(pair(s), s, showPace) }
                compactRows(snaps, spacing: 8, showPace)
                compactRows(Array(snaps.prefix(4)), spacing: 6, showPace)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
    }

    /// Session + weekly, or the first two limits for CLIs that have neither (e.g. per-model quotas).
    private func pair(_ s: ProviderSnapshot) -> [UsageWindow] {
        var p = [s.session, s.weekly].compactMap { $0 }
        for w in s.sortedWindows where p.count < 2 && !p.contains(where: { $0.id == w.id }) { p.append(w) }
        return p
    }

    private func row(_ w: UsageWindow, _ s: ProviderSnapshot, _ showPace: Bool) -> some View {
        WindowRow(window: w, provider: s.provider, showPace: showPace,
                  colorByProvider: globalByProvider, compact: true, now: entry.date)
    }

    /// Half-width rows: "Weekly · Gemini 3.8 Flash" → "Gemini 3.8 Flash" so it isn't truncated.
    private func short(_ w: UsageWindow) -> UsageWindow {
        var w = w
        if let scope = w.scope { w.title = scope }
        return w
    }

    /// Limits two per line.
    private func grid(_ windows: [UsageWindow], _ s: ProviderSnapshot, _ showPace: Bool) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(stride(from: 0, to: windows.count, by: 2)), id: \.self) { i in
                HStack(spacing: 10) {
                    row(short(windows[i]), s, showPace)
                    if i + 1 < windows.count { row(short(windows[i + 1]), s, showPace) } else { Color.clear.frame(maxWidth: .infinity, maxHeight: 1) }
                }
            }
        }
    }

    private func unavailable(_ s: ProviderSnapshot) -> some View {
        Text(s.status == .loggedOut ? "Signed out – open Headroom to sign in" : "No data")
            .font(.caption2).foregroundStyle(.orange).lineLimit(1)
    }

    /// One block per provider: header line, then its limits.
    private func headered<C: View>(_ snaps: [ProviderSnapshot], spacing: CGFloat,
                                   @ViewBuilder content: @escaping (ProviderSnapshot) -> C) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(snaps) { s in
                VStack(alignment: .leading, spacing: 5) {
                    WidgetHeader(provider: s.provider, snapshot: s, compact: family == .systemMedium)
                    if usable(s) { content(s) } else { unavailable(s) }
                }
            }
        }
    }

    /// Densest layout: the provider's icon followed by its two main limits on one line.
    private func compactRows(_ snaps: [ProviderSnapshot], spacing: CGFloat, _ showPace: Bool) -> some View {
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(snaps) { s in
                HStack(spacing: 8) {
                    ProviderGlyph(s.provider, size: 14).frame(width: 16)
                    if usable(s) { grid(pair(s), s, showPace) } else { unavailable(s); Spacer(minLength: 0) }
                }
            }
        }
    }
}

struct OverviewWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Overview", intent: OverviewIntent.self, provider: IntentProvider<OverviewIntent>()) { entry in
            OverviewView(entry: entry, config: entry.configurationIntent(OverviewIntent.self))
                .containerBackground(.fill.tertiary, for: .widget)
                .widgetURL(URL(string: "headroom://refresh"))
        }
        .configurationDisplayName("All Providers")
        .description("What's left on every installed CLI.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Chart

struct ChartWidgetView: View {
    var entry: UsageEntry
    var config: ChartIntent
    @Environment(\.widgetFamily) private var envFamily
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        let h = entry.state.history
        let metric = config.metric.resolve(h)
        let providers: Set<ProviderID> = config.allProviders
            ? Set(entry.state.visibleProviders.isEmpty ? ProviderID.allCases : entry.state.visibleProviders)
            : Set([config.provider.resolve(in: entry.state) ?? .claude])
        let days = family == .systemSmall ? min(config.days, 14) : config.days
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Daily \(metric == .cost ? "cost" : "tokens")").font(.system(size: 13, weight: .semibold))
                Spacer()
                let week = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: entry.date))!
                Text("\(Fmt.metric(h.total(metric: metric, providers: providers, since: week), metric)) / 7d")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).monospacedDigit()
            }
            if h.days.isEmpty {
                Text("No history yet").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                DailyUsageChart(points: h.series(lastDays: days, metric: metric, providers: providers, now: entry.date),
                                metric: metric, showAxes: family != .systemSmall, stacked: config.bars)
            }
        }
    }
}

struct ChartWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "UsageChart", intent: ChartIntent.self, provider: IntentProvider<ChartIntent>()) { entry in
            ChartWidgetView(entry: entry, config: entry.configurationIntent(ChartIntent.self))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Usage Chart")
        .description("Daily cost or tokens over time.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge, .systemExtraLarge])
    }
}

// MARK: - Heatmap

struct HeatmapWidgetView: View {
    var entry: UsageEntry
    var config: HeatmapIntent
    @Environment(\.widgetFamily) private var envFamily
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? envFamily }

    var body: some View {
        let h = entry.state.history
        let metric = config.metric.resolve(h)
        let single = config.provider.resolve(in: entry.state) ?? .claude
        let providers: Set<ProviderID> = config.allProviders
            ? Set(entry.state.visibleProviders.isEmpty ? ProviderID.allCases : entry.state.visibleProviders)
            : [single]
        let weeks = switch family {
        case .systemSmall: 9
        case .systemMedium: 22
        case .systemLarge: 22
        default: 48
        }
        let tint: Color = config.providerColor && !config.allProviders ? single.tint : HeatmapPalette.current.color
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Activity").font(.system(size: 13, weight: .semibold))
                Spacer()
                let total = h.total(metric: metric, providers: providers,
                                    since: Calendar.current.date(byAdding: .day, value: -weeks * 7, to: entry.date)!)
                Text(Fmt.metric(total, metric)).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
            }
            ActivityHeatmap(totals: h.dailyTotals(metric: metric, providers: providers), weeks: weeks, tint: tint,
                            spacing: family == .systemSmall ? 2 : 3, showLabels: family != .systemSmall,
                            metric: metric, now: entry.date)
                .aspectRatio(family == .systemLarge ? ActivityHeatmap.aspectRatio(weeks: weeks, spacing: 3, showLabels: true) : nil,
                             contentMode: .fit)
            if family == .systemLarge {
                Divider().padding(.vertical, 2)
                DailyUsageChart(points: h.series(lastDays: 30, metric: metric, providers: providers, now: entry.date),
                                metric: metric, showAxes: true)
            }
        }
    }
}

struct HeatmapWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "Heatmap", intent: HeatmapIntent.self, provider: IntentProvider<HeatmapIntent>()) { entry in
            HeatmapWidgetView(entry: entry, config: entry.configurationIntent(HeatmapIntent.self))
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Activity")
        .description("A contribution-style heatmap of your usage.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

// MARK: - Entry → configuration helper

extension UsageEntry {
    /// Timeline entries don't carry the intent in our shared provider, so we read the current one from the context.
    func configurationIntent<I: WidgetConfigurationIntent>(_ type: I.Type) -> I {
        (intent as? I) ?? I()
    }
}

// MARK: - Placeholder data

extension SharedState {
    static var placeholder: SharedState {
        let now = Date.now
        func w(_ id: String, _ kind: WindowKind, _ title: String, _ used: Double, _ left: TimeInterval, _ dur: TimeInterval, scope: String? = nil) -> UsageWindow {
            UsageWindow(id: id, kind: kind, title: title, scope: scope, usedFraction: used,
                        resetsAt: now.addingTimeInterval(left), duration: dur)
        }
        let claude = ProviderSnapshot(provider: .claude, status: .ok, plan: "max_5x", windows: [
            w("s", .session, "Session (5h)", 0.35, 3 * 3600, 5 * 3600),
            w("w", .weekly, "Weekly", 0.44, 2 * 86400, 7 * 86400),
            w("f", .model, "Weekly · Fable", 0.30, 2 * 86400, 7 * 86400, scope: "Fable"),
        ], bankedResets: [BankedReset(id: "x", title: "Session reset", expiresAt: now.addingTimeInterval(9 * 86400), redeemable: true)])
        let codex = ProviderSnapshot(provider: .codex, status: .ok, plan: "plus", windows: [
            w("p", .session, "Session (5h)", 0.12, 4 * 3600, 5 * 3600),
            w("s", .weekly, "Weekly", 0.40, 3 * 86400, 7 * 86400),
        ])
        var days: [DailyUsage] = []
        let cal = Calendar.current
        for i in 0..<120 {
            let d = DayFormatter.string(from: cal.date(byAdding: .day, value: -i, to: now)!)
            let wave = (sin(Double(i) / 3) + 1.2) * 40
            if i % 7 != 3 {
                days.append(DailyUsage(day: d, provider: .claude, model: "claude", inputTokens: Int(wave * 1e5), costUSD: wave * 2))
                days.append(DailyUsage(day: d, provider: .codex, model: "gpt", inputTokens: Int(wave * 3e4), costUSD: wave * 0.4))
            }
        }
        return SharedState(providers: [claude, codex], history: UsageHistory(days: days, source: .cliLogs),
                           visibleProviders: [.claude, .codex])
    }
}
