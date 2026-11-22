import SwiftUI

struct MenuContentView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 300

    /// MenuBarExtra windows don't give a ScrollView any height of its own, so we measure the
    /// content and size the scroll area explicitly (capped to the screen).
    private var maxScrollHeight: CGFloat {
        let screen = NSScreen.main?.visibleFrame.height ?? 900
        return max(300, screen - 260)
    }

    var body: some View {
        let s = model.settings
        VStack(spacing: 0) {
            header
            ScrollView {
                // Sections sit directly on the panel's material, separated by inset hairlines.
                VStack(spacing: 0) {
                    if model.visibleProviders.isEmpty {
                        emptyState
                    }
                    ForEach(Array(model.visibleProviders.enumerated()), id: \.element) { i, p in
                        if i > 0 { SectionDivider() }
                        ProviderSection(provider: p, snapshot: model.snapshots[p])
                    }
                    if !model.visibleProviders.isEmpty && (s.popoverShowsChart || s.popoverShowsHeatmap) {
                        SectionDivider()
                        HistorySection()
                    }
                }
                .padding(.bottom, 4)
                .overlayScroller()
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(height: min(contentHeight, maxScrollHeight))
            if let toast = model.toast {
                ToastBar(text: toast) { model.toast = nil }
            }
            MenuDivider()
            menuRows
        }
        .padding(.bottom, 5)
        .frame(width: 360)
        .environment(\.headroomAnimates, true)
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
            if let last = model.lastRefresh {
                Group {
                    if model.isRefreshing {
                        Text("Updating…")
                    } else {
                        Text("Updated \(Text(last, style: .relative)) ago")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 2)
    }

    @ViewBuilder
    private var menuRows: some View {
        @Bindable var s = model.settings
        VStack(spacing: 0) {
            MenuRow(title: "Refresh Now", systemImage: "arrow.clockwise", shortcut: "⌘R", busy: model.isRefreshing) {
                Task { await model.refreshAll(includeHistory: true) }
            }
            .keyboardShortcut("r")
            MenuRow(title: "Dashboard", systemImage: "chart.bar.xaxis", shortcut: "⌘D") {
                dismiss()
                NSApp.activate()
                openWindow(id: "dashboard")
            }
            .keyboardShortcut("d")
            MenuRow(title: "Settings…", systemImage: "gearshape", shortcut: "⌘,") {
                dismiss()
                SettingsOpener.action = openSettings
                SettingsOpener.open()
            }
            .keyboardShortcut(",")
            MenuDivider()
            MenuRow(title: "Quit Headroom", systemImage: "rectangle.portrait.and.arrow.right", shortcut: "⌘Q") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 5)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "terminal")
                .font(.system(size: 28))
                .foregroundStyle(.secondary)
            Text(model.isRefreshing ? "Looking for CLIs…" : "No supported CLIs found")
                .font(.headline)
            Text("Install Claude Code, Codex, Grok or Antigravity, or set a custom command in Settings.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }
}

/// A row that looks and behaves like a native menu item (hover highlight, checkmark, shortcut hint).
struct MenuRow: View {
    var title: String
    var systemImage: String
    var shortcut: String? = nil
    var checked: Bool? = nil
    var busy: Bool = false
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if busy { ProgressView().controlSize(.mini) } else { Image(systemName: systemImage) }
                }
                .frame(width: 16)
                .foregroundStyle(hovering ? .white : .secondary)
                Text(title)
                Spacer()
                if let checked {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.semibold))
                        .opacity(checked ? 1 : 0)
                }
                if let shortcut {
                    Text(shortcut).foregroundStyle(hovering ? .white.opacity(0.8) : .secondary)
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(hovering ? .white : .primary)
            .padding(.horizontal, 9)
            .frame(height: 24)
            .background(hovering ? Color.accentColor : .clear, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct MenuDivider: View {
    var body: some View {
        Divider().padding(.horizontal, 14).padding(.vertical, 5)
    }
}

/// Hairline between panel sections, inset to the content edges.
struct SectionDivider: View {
    var body: some View {
        Rectangle()
            .fill(.separator)
            .frame(height: 1)
            .padding(.horizontal, 14)
    }
}

private extension View {
    /// Spacing for a panel section: aligned with the header and menu rows, with room to breathe above and below.
    func panelSection() -> some View {
        padding(.horizontal, 14).padding(.vertical, 14)
    }
}

// MARK: - Provider section

struct ProviderSection: View {
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

            if let reason = snapshot?.staleReason {
                Label(reason, systemImage: "clock.badge.exclamationmark")
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSection()
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
                                  colorByProvider: s.colorByProvider, now: ctx.date, asOf: snapshot?.dataAsOf)
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
            Label {
                Text(armed ? "You'll be notified when it resets" : "Notify me when it resets")
                    .foregroundStyle(armed ? .primary : .secondary)
            } icon: {
                Image(systemName: armed ? "bell.fill" : "bell")
                    .foregroundStyle(armed ? Color.accentColor : .secondary)
            }
            .font(.caption.weight(armed ? .medium : .regular))
        }
        .buttonStyle(.borderless)
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
                        Text("· " + Fmt.expires(soonest).lowercasingFirst)
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
                ExpiryText(r?.expiresAt)
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
                    Button("Use Reset") {
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

struct HistorySection: View {
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
                                    weeks: 19, spacing: 2.5, metric: metric)
                        .frame(height: 100)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelSection()
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
