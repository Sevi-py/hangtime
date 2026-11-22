import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @State var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            Tab("General", systemImage: "gearshape", value: "general") { GeneralSettings() }
            Tab("Providers", systemImage: "terminal", value: "providers") { ProviderSettings() }
            Tab("Appearance", systemImage: "paintpalette", value: "appearance") { AppearanceSettings() }
            Tab("Notifications", systemImage: "bell.badge", value: "notifications") { NotificationSettings() }
            Tab("History", systemImage: "chart.bar.xaxis", value: "history") { HistorySettings() }
            Tab("About", systemImage: "info.circle", value: "about") { AboutSettings() }
        }
        .frame(width: 580)
    }
}

// MARK: General

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Toggle("Open at login", isOn: Binding(get: { model.launchAtLogin }, set: { model.setLaunchAtLogin($0) }))
                HStack {
                    Text("Setup assistant")
                    Spacer()
                    Button("Show Setup Again…") { SetupAssistant.show() }
                }
            }
            Section("Refreshing") {
                Picker("Check usage", selection: $s.refreshMinutes) {
                    Text("As often as possible").tag(0.0)
                    Divider()
                    Text("Every minute").tag(1.0)
                    Text("Every 2 minutes").tag(2.0)
                    Text("Every 5 minutes").tag(5.0)
                    Text("Every 10 minutes").tag(10.0)
                    Text("Every 15 minutes").tag(15.0)
                    Text("Every 30 minutes").tag(30.0)
                }
                .onChange(of: s.refreshMinutes) { model.scheduleTimer() }
                LabeledContent("Last updated") {
                    if let d = model.lastRefresh { Text(DateFmt.time(d)) } else { Text("Never") }
                }
                HStack {
                    Spacer()
                    Button("Refresh Now") { Task { await model.refreshAll(includeHistory: true) } }
                        .disabled(model.isRefreshing)
                }
            }
            Section("Banked resets") {
                Toggle("Show banked resets", isOn: $s.showBankedResets)
                Toggle("Ask for confirmation before using a reset", isOn: $s.confirmBeforeRedeem)
            }
        }
        .formStyle(.grouped)
        .frame(height: 380)
    }
}

// MARK: Providers

private struct ProviderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var selection: ProviderID = .claude

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ForEach(model.settings.order) { p in
                    ProviderTile(provider: p, selected: selection == p, status: statusText(p), color: statusColor(p)) {
                        selection = p
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 16)
            ProviderDetail(provider: selection).id(selection)
        }
        .frame(height: 520)
    }

    private func statusText(_ p: ProviderID) -> String {
        guard model.settings.enabled[p] ?? true else { return "Hidden" }
        switch model.install[p] {
        case .installed?:
            switch model.snapshots[p]?.status {
            case .loggedOut?: return "Signed out"
            case .error?: return "Error"
            default: return Fmt.planName(model.snapshots[p]?.plan) ?? "Installed"
            }
        case .missing?: return "Not installed"
        default: return "Checking…"
        }
    }

    private func statusColor(_ p: ProviderID) -> Color {
        guard model.settings.enabled[p] ?? true, model.install[p]?.isInstalled == true else { return .secondary.opacity(0.5) }
        return (model.snapshots[p]?.status.isProblem ?? false) ? .orange : .green
    }
}

private struct ProviderTile: View {
    var provider: ProviderID
    var selected: Bool
    var status: String
    var color: Color
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                ProviderGlyph(provider, size: 20)
                VStack(alignment: .leading, spacing: 1) {
                    Text(provider.displayName).font(.system(size: 13, weight: .medium)).foregroundStyle(.primary)
                        .lineLimit(1).minimumScaleFactor(0.85)
                    HStack(spacing: 4) {
                        Circle().fill(color).frame(width: 6, height: 6)
                        Text(status).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(selected ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: selected ? 1.5 : 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct ProviderDetail: View {
    @Environment(AppModel.self) private var model
    var provider: ProviderID
    @State private var draftCommand = ""
    @State private var checking = false

    var body: some View {
        let s = model.settings
        Form {
            Section {
                Toggle("Show \(provider.displayName)", isOn: s.binding(enabled: provider))
                Toggle("Show in menu bar", isOn: s.binding(inMenuBar: provider))
                    .disabled(!(s.enabled[provider] ?? true))
            }
            Section {
                TextField("Command", text: $draftCommand, prompt: Text(provider.defaultCommand))
                    .font(.system(.body, design: .monospaced))
                    .onSubmit(apply)
                HStack {
                    installStatus
                    Spacer()
                    if draftCommand != s.command(for: provider) && !(draftCommand.isEmpty && s.command(for: provider) == provider.defaultCommand) {
                        Button("Apply", action: apply).buttonStyle(.borderedProminent)
                    }
                    Button(checking ? "Checking…" : "Detect") {
                        Task { checking = true; await model.detectCLIs(force: true); await model.refreshAll(); checking = false }
                    }
                    .disabled(checking)
                }
            } header: {
                Text("Terminal command")
            } footer: {
                Text("The command you type in a terminal to start the CLI. Paths, aliases resolved by your shell, and wrappers like `npx -y @openai/codex` work too.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Account") {
                let snap = model.snapshots[provider]
                LabeledContent("Status") {
                    switch snap?.status {
                    case .ok?: Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    case .loggedOut?: Label("Signed out", systemImage: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    case .error(let m)?: Text(m).foregroundStyle(.orange).lineLimit(3).textSelection(.enabled)
                    default: Text("—")
                    }
                }
                if let plan = Fmt.planName(snap?.plan) { LabeledContent("Plan", value: plan) }
                if let acc = snap?.account { LabeledContent("Account", value: acc) }
                if let snap, !snap.windows.isEmpty {
                    LabeledContent("Limits") {
                        Text(snap.sortedWindows.map(\.title).joined(separator: ", "))
                            .multilineTextAlignment(.trailing)
                    }
                }
                HStack {
                    Spacer()
                    Button(snap?.status == .loggedOut ? "Sign In…" : "Sign In Again…") {
                        Task { await model.login(provider) }
                    }
                    .disabled(model.busy.contains("login.\(provider.rawValue)") || !(model.install[provider]?.isInstalled ?? false))
                }
            }
            if provider == .claude {
                @Bindable var s = s
                Section {
                    Toggle("Check with a tiny request when usage checks are blocked", isOn: $s.claudeProbe)
                } header: {
                    Text("Usage checks")
                } footer: {
                    Text("Anthropic often blocks usage checks for a while. Headroom then sends a one-token request, at most every 10 minutes, and reads your limits from the reply: Fable for session, weekly and Fable usage, and Haiku when Fable is used up or not needed. It uses a tiny bit of your session, and starts a new session if none is running. Banked resets update once regular checks work again.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { draftCommand = s.commands[provider] ?? provider.defaultCommand }
    }

    @ViewBuilder
    private var installStatus: some View {
        switch model.install[provider] {
        case .installed(let v)?:
            Label(v.map { "Found · \($0)" } ?? "Found", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green).font(.callout).lineLimit(1)
        case .missing?:
            Label("Not found", systemImage: "xmark.circle.fill").foregroundStyle(.red).font(.callout)
        default:
            Label("Checking…", systemImage: "circle.dotted").foregroundStyle(.secondary).font(.callout)
        }
    }

    private func apply() {
        model.settings.commands[provider] = draftCommand.trimmingCharacters(in: .whitespaces)
        Task { await model.detectCLIs(force: true); await model.refreshAll() }
    }
}

// MARK: Appearance

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section("Menu bar") {
                Picker("Show", selection: $s.menuBarStyle) {
                    ForEach(MenuBarStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.radioGroup)
                Picker("Limit", selection: $s.menuBarWindow) {
                    ForEach(MenuBarWindowChoice.allCases) { Text($0.title).tag($0) }
                }
                .disabled(s.menuBarStyle == .iconOnly)
                Toggle("Show time until reset when a limit is used up", isOn: $s.menuBarShowsResetTime)
                Toggle("Show 0% when the session or weekly limit is used up", isOn: $s.zeroWhenBlocked)
                Text("Either one being used up blocks you, whichever limit is shown. Also applies to the Single Limit widget and the Control Center control.")
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Preview") {
                    MenuBarLabel()
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 5))
                }
            }
            Section("Limits") {
                Toggle("Show even-pace marker", isOn: $s.showPaceMarker)
                Text("A tick on each bar shows how much would be left if you spread your usage evenly over the window.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show model-specific limits (e.g. Fable, Opus)", isOn: $s.showModelLimits)
                Picker("Bar color", selection: $s.colorByProvider) {
                    Text("Provider color").tag(true)
                    Text("Traffic light (by remaining)").tag(false)
                }
            }
            DateTimeSection()
            Section("Usage panel") {
                Toggle("Show daily chart", isOn: $s.popoverShowsChart)
                Toggle("Show activity heatmap", isOn: $s.popoverShowsHeatmap)
                HeatmapColorPicker()
            }
        }
        .formStyle(.grouped)
        .frame(height: 600)
        .onChange(of: s.showPaceMarker) { model.publish() }
        .onChange(of: s.colorByProvider) { model.publish() }
        .onChange(of: s.zeroWhenBlocked) { model.publish() }
    }
}

// MARK: Notifications

private struct NotificationSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Toggle("Notify when a used-up limit resets", isOn: $s.notifyWhenAnyLimitResets)
                Text("You can also turn this on for a single limit from the menu bar panel whenever a limit is used up.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section {
                Toggle("Warn when a limit is running low", isOn: $s.lowThresholdAlerts)
                if s.lowThresholdAlerts {
                    LabeledContent("Threshold") {
                        HStack {
                            Slider(value: $s.lowThreshold, in: 0.05...0.5, step: 0.05)
                            Text("\(Fmt.percent(s.lowThreshold)) left").monospacedDigit().frame(width: 64, alignment: .trailing)
                        }
                    }
                }
            }
            Section {
                Toggle("Remind me a day before a banked reset expires", isOn: $s.notifyResetExpiry)
                Toggle("Notify when a CLI gets signed out", isOn: $s.notifyLoggedOut)
            }
            Section {
                HStack {
                    Spacer()
                    Button("Open Notification Settings…") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 360)
        // Ask for notification permission only once the user turns an alert on.
        .onChange(of: s.notifyWhenAnyLimitResets) { _, on in if on { requestPermission() } }
        .onChange(of: s.lowThresholdAlerts) { _, on in if on { requestPermission() } }
        .onChange(of: s.notifyResetExpiry) { _, on in if on { requestPermission() } }
        .onChange(of: s.notifyLoggedOut) { _, on in if on { requestPermission() } }
    }

    private func requestPermission() {
        Task { await Notifier.shared.requestAuthorization() }
    }
}

// MARK: History

private struct HistorySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var s = model.settings
        Form {
            Section {
                Picker("Read usage from", selection: $s.historySource) {
                    ForEach(HistorySourcePreference.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: s.historySource) { Task { await model.reloadHistory() } }
                LabeledContent("Currently using", value: model.history.source.rawValue)
            } footer: {
                Text("Automatic uses T3 Code's usage records (all environments) when it's installed and falls back to the CLIs' local session logs.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            T3AccessSection()
            Section("Charts") {
                Picker("Show", selection: $s.historyMetric) {
                    ForEach(UsageHistory.Metric.allCases) { Text($0.title).tag($0) }
                }
                Picker("Chart range", selection: $s.chartDays) {
                    Text("2 weeks").tag(14)
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                }
                .onChange(of: s.historyMetric) { model.publish() }
            }
            Section {
                LabeledContent("Days with activity", value: "\(Set(model.history.days.map(\.day)).count)")
                HStack {
                    Spacer()
                    Button(model.isLoadingHistory ? "Reading…" : "Reload History") {
                        Task { await model.reloadHistory() }
                    }
                    .disabled(model.isLoadingHistory)
                }
            }
        }
        .formStyle(.grouped)
        .frame(height: 520)
    }
}

/// Lets the user grant / renew / revoke Headroom's read-only access to T3 Code without a terminal.
private struct T3AccessSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let busy = model.busy.contains("t3")
        Section {
            LabeledContent("Status") {
                switch model.t3Access {
                case .unknown:
                    ProgressView().controlSize(.small)
                case .notInstalled:
                    Label("T3 Code not installed", systemImage: "minus.circle").foregroundStyle(.secondary)
                case .none:
                    Label("Not connected", systemImage: "circle.dashed").foregroundStyle(.secondary)
                case .revoked:
                    Label("Access turned off", systemImage: "nosign").foregroundStyle(.secondary)
                case .invalid:
                    Label("Access was revoked in T3 Code", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                case .granted(let exp, let used):
                    VStack(alignment: .trailing, spacing: 2) {
                        Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        if let exp { Text("Renews automatically · expires \(DateFmt.date(exp))").font(.caption).foregroundStyle(.secondary) }
                        if let used { Text("Last used \(used.formatted(.relative(presentation: .named)))").font(.caption).foregroundStyle(.secondary) }
                    }
                }
            }
            if model.t3Access != .notInstalled {
                HStack {
                    if busy { ProgressView().controlSize(.small) }
                    Spacer()
                    switch model.t3Access {
                    case .granted:
                        Button("Revoke Access", role: .destructive) { Task { await model.revokeT3Access() } }
                        Button("Renew") { Task { await model.grantT3Access() } }
                    case .unknown:
                        EmptyView()
                    default:
                        Button("Connect to T3 Code") { Task { await model.grantT3Access() } }
                            .buttonStyle(.borderedProminent)
                    }
                }
                .disabled(busy)
            }
        } header: {
            Text("T3 Code access")
        } footer: {
            Text("Headroom uses a read-only T3 Code session (usage statistics only) to read your usage across providers. It shows up as “Headroom” under Sharing & access in T3 Code.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await model.refreshT3Access() }
    }
}

private struct HeatmapColorPicker: View {
    @Environment(AppModel.self) private var model
    @AppStorage(SharedStore.Key.heatmapPalette, store: SharedStore.defaults) private var palette = HeatmapPalette.violet.rawValue

    var body: some View {
        LabeledContent("Heatmap color") {
            HStack(spacing: 8) {
                ForEach(HeatmapPalette.allCases) { p in
                    Button {
                        palette = p.rawValue
                        model.publish()
                    } label: {
                        Circle().fill(p.color.gradient)
                            .frame(width: 16, height: 16)
                            .overlay(Circle().strokeBorder(.primary.opacity(palette == p.rawValue ? 0.9 : 0), lineWidth: 2).padding(-3))
                    }
                    .buttonStyle(.plain)
                    .help(p.title)
                }
            }
        }
    }
}

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Headroom").font(.title.weight(.semibold))
            Text("Version \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0") (\(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"))")
                .foregroundStyle(.secondary)
            Text("See what's left of your Claude Code, Codex, Grok and Antigravity subscriptions.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            HStack {
                Link("Source on GitHub", destination: URL(string: "https://github.com/Sevi-py/usage-widget")!)
            }
            .padding(.top, 6)
            Spacer()
            Text("Provider logos from LobeHub Icons (MIT). Logos are trademarks of their respective owners.")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .padding(30)
        .frame(maxWidth: .infinity)
        .frame(height: 340)
    }
}

private struct DateTimeSection: View {
    @Environment(AppModel.self) private var model
    @AppStorage(DateFmt.Key.time, store: SharedStore.defaults) private var time = TimeFormatPref.system.rawValue
    @AppStorage(DateFmt.Key.date, store: SharedStore.defaults) private var date = DateFormatPref.system.rawValue
    @AppStorage(DateFmt.Key.reset, store: SharedStore.defaults) private var reset = ResetDisplayPref.relative.rawValue

    private let sample = Calendar.current.date(bySettingHour: 14, minute: 30, second: 0,
                                               of: Calendar.current.date(byAdding: .day, value: 3, to: .now)!)!

    var body: some View {
        Section {
            Picker("Time format", selection: $time) {
                ForEach(TimeFormatPref.allCases) { p in
                    Text("\(p.title)  (\(DateFmt.time(sample, p)))").tag(p.rawValue)
                }
            }
            Picker("Date format", selection: $date) {
                ForEach(DateFormatPref.allCases) { p in
                    Text("\(p.title)  (\(DateFmt.date(sample, p)))").tag(p.rawValue)
                }
            }
            Picker("Show reset times as", selection: $reset) {
                ForEach(ResetDisplayPref.allCases) { Text($0.title).tag($0.rawValue) }
            }
            LabeledContent("Preview") {
                VStack(alignment: .trailing, spacing: 2) {
                    ResetText(date: .now.addingTimeInterval(3 * 3600 + 25 * 60))
                    ResetText(date: sample)
                    ExpiryText(sample.addingTimeInterval(9 * 86400))
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .id("\(time)\(date)\(reset)")
            }
        } header: {
            Text("Dates & times")
        } footer: {
            Text("System follows your Mac's Language & Region settings.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onChange(of: time) { model.publish() }
        .onChange(of: date) { model.publish() }
        .onChange(of: reset) { model.publish() }
    }
}
