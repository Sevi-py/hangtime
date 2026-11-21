import SwiftUI
import Charts

/// Larger view of the usage history: chart, year heatmap and a per-model breakdown.
struct DashboardView: View {
    @Environment(AppModel.self) private var model
    @State private var days = 30
    @State private var metric: UsageHistory.Metric = .cost
    @State private var stacked = false
    @State private var hidden: Set<ProviderID> = []

    private var providers: Set<ProviderID> {
        Set((model.visibleProviders.isEmpty ? ProviderID.allCases : model.visibleProviders).filter { !hidden.contains($0) })
    }

    private var effectiveMetric: UsageHistory.Metric { model.history.hasCost ? metric : .tokens }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                limits
                summary
                chartCard
                heatmapCard
                modelsCard
                Text("Source: \(model.history.source.rawValue). Costs are API-equivalent estimates, not what your subscription charges.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
        .frame(minWidth: 720, minHeight: 560)
        .environment(\.headroomAnimates, true)
        .background(.background)
        .toolbar {
            ToolbarItemGroup {
                Picker("Metric", selection: $metric) {
                    ForEach(UsageHistory.Metric.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .disabled(!model.history.hasCost)
                Picker("Range", selection: $days) {
                    Text("7 days").tag(7)
                    Text("30 days").tag(30)
                    Text("90 days").tag(90)
                    Text("1 year").tag(365)
                }
                .pickerStyle(.menu)
                Button {
                    Task { await model.refreshAll(includeHistory: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing || model.isLoadingHistory)
            }
        }
        .onAppear { metric = model.settings.historyMetric }
    }

    // MARK: Sections

    private var limits: some View {
        HStack(alignment: .top, spacing: 12) {
            ForEach(model.visibleSnapshots) { snap in
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 6) {
                        ProviderGlyph(snap.provider, size: 16)
                        Text(snap.provider.displayName).font(.headline)
                        Spacer()
                        if let plan = Fmt.planName(snap.plan) {
                            Text(plan).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if snap.status == .loggedOut {
                        Text("Signed out").foregroundStyle(.orange).font(.callout)
                    }
                    HStack(spacing: 14) {
                        ForEach(snap.sortedWindows.prefix(3)) { w in
                            VStack(spacing: 4) {
                                RingGauge(remaining: w.remainingFraction,
                                          pace: model.settings.showPaceMarker ? w.evenPaceRemaining() : nil,
                                          color: Theme.color(for: w, provider: snap.provider, byProvider: model.settings.colorByProvider),
                                          lineWidth: 6)
                                    .frame(width: 58, height: 58)
                                Text(w.scope ?? (w.kind == .session ? "Session" : w.kind == .weekly ? "Weekly" : w.title))
                                    .font(.caption).lineLimit(1)
                            }
                        }
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var summary: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: .now)
        let m = effectiveMetric
        return HStack(spacing: 12) {
            stat("Today", model.history.total(metric: m, providers: providers, since: today), m)
            stat("7 days", model.history.total(metric: m, providers: providers, since: cal.date(byAdding: .day, value: -6, to: today)!), m)
            stat("30 days", model.history.total(metric: m, providers: providers, since: cal.date(byAdding: .day, value: -29, to: today)!), m)
            stat("This year", model.history.total(metric: m, providers: providers, since: cal.date(from: cal.dateComponents([.year], from: today))!), m)
        }
    }

    private func stat(_ title: String, _ value: Double, _ m: UsageHistory.Metric) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(Fmt.metric(value, m)).font(.system(.title2, design: .rounded).weight(.semibold)).monospacedDigit()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var chartCard: some View {
        card {
            HStack {
                Text("Daily \(effectiveMetric == .cost ? "cost" : "tokens")").font(.headline)
                Spacer()
                ForEach(model.visibleProviders) { p in
                    Toggle(isOn: Binding(get: { !hidden.contains(p) }, set: { on in
                        if on { hidden.remove(p) } else { hidden.insert(p) }
                    })) {
                        HStack(spacing: 4) { ProviderGlyph(p, size: 12); Text(p.shortName) }
                    }
                    .toggleStyle(.button)
                    .controlSize(.small)
                }
                Toggle("Bars", isOn: $stacked).toggleStyle(.button).controlSize(.small)
            }
            DailyUsageChart(points: model.history.series(lastDays: days, metric: effectiveMetric, providers: providers),
                            metric: effectiveMetric, stacked: stacked)
                .frame(height: 240)
        }
    }

    private var heatmapCard: some View {
        card {
            Text("Activity").font(.headline)
            ActivityHeatmap(totals: model.history.dailyTotals(metric: effectiveMetric, providers: providers),
                            weeks: 53, spacing: 3, metric: effectiveMetric)
                .frame(height: 112)
        }
    }

    private struct ModelRow: Identifiable {
        var id: String { "\(provider.rawValue)|\(model)" }
        var provider: ProviderID
        var model: String
        var tokens: Int
        var cost: Double
    }

    private var modelRows: [ModelRow] {
        let since = DayFormatter.string(from: Calendar.current.date(byAdding: .day, value: -(days - 1), to: Calendar.current.startOfDay(for: .now))!)
        var rows: [String: ModelRow] = [:]
        for d in model.history.days where d.day >= since && providers.contains(d.provider) {
            let name = d.model ?? "Unknown"
            let key = "\(d.provider.rawValue)|\(name)"
            var r = rows[key] ?? ModelRow(provider: d.provider, model: name, tokens: 0, cost: 0)
            r.tokens += d.totalTokens
            r.cost += d.costUSD ?? 0
            rows[key] = r
        }
        return rows.values.sorted { $0.cost == $1.cost ? $0.tokens > $1.tokens : $0.cost > $1.cost }
    }

    private var modelsCard: some View {
        let rows = modelRows
        return card {
            Text("By model · last \(days == 365 ? "year" : "\(days) days")").font(.headline)
            if rows.isEmpty {
                Text("No usage in this range.").foregroundStyle(.secondary)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
                GridRow {
                    Text("Model"); Text("Tokens").gridColumnAlignment(.trailing); Text("Cost").gridColumnAlignment(.trailing)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(rows) { r in
                    GridRow {
                        HStack(spacing: 6) { ProviderGlyph(r.provider, size: 13); Text(r.model).lineLimit(1) }
                        Text(Fmt.tokens(Double(r.tokens))).monospacedDigit()
                        Text(r.cost > 0 ? Fmt.cost(r.cost) : "—").monospacedDigit()
                    }
                    Divider().gridCellUnsizedAxes(.horizontal)
                }
            }
        }
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}
