import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        let s = model.settings
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 10) {
                    if model.visibleProviders.isEmpty {
                        emptyState
                    }
                    ForEach(model.visibleProviders) { p in
                        ProviderCard(provider: p, snapshot: model.snapshots[p])
                    }
                    if !model.visibleProviders.isEmpty && (s.popoverShowsChart || s.popoverShowsHeatmap) {
                        HistoryCard()
                    }
                }
                .padding(12)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: 640)
            if let toast = model.toast {
                ToastBar(text: toast) { model.toast = nil }
            }
            Divider().opacity(0.5)
            footer
        }
        .frame(width: 360)
        .onAppear {
            SettingsOpener.action = openSettings
            if (model.lastRefresh.map { Date.now.timeIntervalSince($0) > 60 } ?? true) {
                Task { await model.refreshAll() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Usage")
                .font(.headline)
            Spacer()
            Button {
                Task { await model.refreshAll(includeHistory: true) }
            } label: {
                if model.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .keyboardShortcut("r")
            .frame(width: 20)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var footer: some View {
        HStack {
            if let last = model.lastRefresh {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Text("Updated \(last.formatted(.relative(presentation: .named)))")
                }
            } else {
                Text("Loading…")
            }
            Spacer()
            Button("Settings…") {
                SettingsOpener.action = openSettings
                SettingsOpener.open()
            }
            .keyboardShortcut(",")
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.isRefreshing ? "Looking for CLIs…" : "No supported CLIs found")
                .font(.headline)
            Text("Install Claude Code, Codex or Grok, or set a custom command in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

// MARK: - Provider card

struct ProviderCard: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    var snapshot: ProviderSnapshot?
    @State private var showResets = false

    var body: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                ProviderGlyph(provider, size: 20)
                Text(provider.displayName).font(.system(.body, weight: .semibold))
                if let plan = Fmt.planName(snapshot?.plan) {
                    Text(plan)
                        .font(.caption2.weight(.medium))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                }
                Spacer()
                if model.busy.contains("login.\(provider.rawValue)") {
                    ProgressView().controlSize(.small)
                }
            }

            switch snapshot?.status {
            case nil:
                HStack { ProgressView().controlSize(.small); Text("Loading…").foregroundStyle(.secondary) }
                    .font(.callout)
            case .loggedOut?:
                SignedOutBanner(provider: provider)
            case .error(let msg)?:
                Label(msg, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .textSelection(.enabled)
                windows(s)
            default:
                windows(s)
            }

            if let notes = snapshot?.notes, !notes.isEmpty {
                ForEach(notes, id: \.self) { n in
                    Text(n).font(.caption).foregroundStyle(.secondary)
                }
            }

            if s.showBankedResets, let snap = snapshot, snap.availableResetCount > 0 {
                BankedResetsSection(provider: provider, snapshot: snap)
            }
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    @ViewBuilder
    private func windows(_ s: AppSettings) -> some View {
        let windows = (snapshot?.sortedWindows ?? []).filter { s.showModelLimits || $0.kind == .session || $0.kind == .weekly }
        if windows.isEmpty, snapshot?.status == .ok {
            Text("No usage limits reported for this plan.")
                .font(.caption).foregroundStyle(.secondary)
        }
        TimelineView(.periodic(from: .now, by: 60)) { ctx in
            VStack(spacing: 10) {
                ForEach(windows) { w in
                    VStack(alignment: .leading, spacing: 4) {
                        WindowRow(window: w, provider: provider, showPace: s.showPaceMarker,
                                  colorByProvider: s.colorByProvider, now: ctx.date)
                        if w.isExhausted || Notifier.shared.isArmed(provider, w) {
                            ResetAlertToggle(provider: provider, window: w)
                        }
                    }
                }
            }
        }
    }
}

struct ResetAlertToggle: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    var window: UsageWindow
    @State private var armed = false

    var body: some View {
        Button {
            model.toggleResetAlert(provider, window: window)
            armed.toggle()
        } label: {
            Label(armed ? "You'll be notified when it resets" : "Notify me when it resets",
                  systemImage: armed ? "bell.fill" : "bell")
                .font(.caption)
        }
        .buttonStyle(.borderless)
        .tint(armed ? .accentColor : .secondary)
        .onAppear { armed = Notifier.shared.isArmed(provider, window) }
    }
}

struct SignedOutBanner: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.title2)
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Signed out").font(.callout.weight(.semibold))
                Text("\(provider.shortName) CLI isn't logged in.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Sign In…") { Task { await model.login(provider) } }
                .controlSize(.small)
                .buttonStyle(.borderedProminent)
                .disabled(model.busy.contains("login.\(provider.rawValue)"))
        }
        .padding(10)
        .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - Banked resets

struct BankedResetsSection: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    var snapshot: ProviderSnapshot
    @State private var expanded = false
    @State private var confirming: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: "arrow.counterclockwise.circle.fill").foregroundStyle(provider.tint)
                    Text("\(snapshot.availableResetCount) banked reset\(snapshot.availableResetCount == 1 ? "" : "s")")
                        .font(.callout.weight(.medium))
                    if let soonest = snapshot.bankedResets.compactMap(\.expiresAt).min() {
                        Text("· \(Fmt.expires(soonest).lowercased())")
                            .font(.caption).foregroundStyle(soonest.timeIntervalSinceNow < 3 * 86400 ? .orange : .secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .rotationEffect(.degrees(expanded ? 90 : 0))
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if snapshot.bankedResets.isEmpty {
                    resetRow(nil)
                }
                ForEach(snapshot.bankedResets) { r in resetRow(r) }
            }
        }
        .padding(.top, 2)
    }

    @ViewBuilder
    private func resetRow(_ r: BankedReset?) -> some View {
        let key = r?.id ?? "any"
        let busy = model.busy.contains("redeem.\(provider.rawValue).\(key)")
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(r?.title ?? "Rate limit reset").font(.callout)
                if let detail = r?.detail { Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                Text(Fmt.expires(r?.expiresAt))
                    .font(.caption)
                    .foregroundStyle((r?.expiresAt?.timeIntervalSinceNow ?? .infinity) < 3 * 86400 ? .orange : .secondary)
            }
            Spacer()
            if r?.redeemable ?? true {
                if busy {
                    ProgressView().controlSize(.small)
                } else if confirming == key {
                    HStack(spacing: 4) {
                        Button("Cancel") { confirming = nil }
                        Button("Use Now") {
                            confirming = nil
                            Task { await model.redeem(provider, reset: r) }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.orange)
                    }
                    .controlSize(.small)
                } else {
                    Button("Use…") {
                        if model.settings.confirmBeforeRedeem { confirming = key }
                        else { Task { await model.redeem(provider, reset: r) } }
                    }
                    .controlSize(.small)
                    .help("Immediately reset your \(provider.shortName) limits using this banked reset")
                }
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

// MARK: - History

struct HistoryCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        let providers = Set(model.visibleProviders)
        let metric: UsageHistory.Metric = model.history.hasCost ? s.historyMetric : .tokens
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Daily \(metric == .cost ? "cost" : "tokens")").font(.system(.body, weight: .semibold))
                Spacer()
                if model.history.hasCost {
                    Picker("", selection: $s.historyMetric) {
                        ForEach(UsageHistory.Metric.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                    .controlSize(.small)
                }
            }
            if model.history.days.isEmpty {
                Text(model.isLoadingHistory ? "Reading history…" : "No usage history found.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 60)
            } else {
                let week = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: .now))!
                let month = Calendar.current.date(byAdding: .day, value: -29, to: Calendar.current.startOfDay(for: .now))!
                HStack(spacing: 16) {
                    stat("Today", model.history.total(metric: metric, providers: providers, since: Calendar.current.startOfDay(for: .now)), metric)
                    stat("7 days", model.history.total(metric: metric, providers: providers, since: week), metric)
                    stat("30 days", model.history.total(metric: metric, providers: providers, since: month), metric)
                }
                if s.popoverShowsChart {
                    DailyUsageChart(points: model.history.series(lastDays: s.chartDays, metric: metric, providers: providers),
                                    metric: metric)
                        .frame(height: 130)
                }
                if s.popoverShowsHeatmap {
                    ActivityHeatmap(totals: model.history.dailyTotals(metric: metric, providers: providers),
                                    weeks: 19, tint: .green, spacing: 2.5, metric: metric)
                        .frame(height: 100)
                }
                Text("Source: \(model.history.source.rawValue)\(metric == .cost ? " · API-equivalent estimate" : "")")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator.opacity(0.6)))
    }

    private func stat(_ title: String, _ value: Double, _ metric: UsageHistory.Metric) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(Fmt.metric(value, metric)).font(.system(.callout, design: .rounded).weight(.semibold)).monospacedDigit()
        }
    }
}

struct ToastBar: View {
    var text: String
    var dismiss: () -> Void

    var body: some View {
        HStack {
            Image(systemName: "info.circle")
            Text(text).font(.caption).lineLimit(3)
            Spacer()
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.borderless)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.blue.opacity(0.08))
        .task(id: text) {
            try? await Task.sleep(for: .seconds(8))
            dismiss()
        }
    }
}
