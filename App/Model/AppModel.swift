import Foundation
import SwiftUI
import AppKit
import WidgetKit
import UserNotifications
import ServiceManagement

enum InstallState: Equatable {
    case unknown, installed(version: String?), missing
    var isInstalled: Bool { if case .installed = self { true } else { false } }
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    let settings = AppSettings.shared
    var snapshots: [ProviderID: ProviderSnapshot] = [:]
    var install: [ProviderID: InstallState] = [:]
    var history = UsageHistory()
    var t3Installed = false
    var isRefreshing = false
    var isLoadingHistory = false
    var lastRefresh: Date?
    var busy: Set<String> = []          // ids of in-flight actions (login, redeem)
    var toast: String?
    var launchAtLogin = SMAppService.mainApp.status == .enabled
    var t3Access = T3AccessState.unknown

    private var timer: Timer?
    private var lastHistoryLoad: Date?
    private var previous: [ProviderID: ProviderSnapshot] = [:]

    private init() {
        if let cached = SharedStore.load() {
            for s in cached.providers { snapshots[s.provider] = s }
            history = cached.history
            for p in cached.visibleProviders { install[p] = .installed(version: cached.snapshot(for: p)?.cliVersion) }
        }
    }

    // MARK: Derived

    /// Enabled + installed providers, in the user's order.
    var visibleProviders: [ProviderID] {
        settings.order.filter { (settings.enabled[$0] ?? true) && (install[$0]?.isInstalled ?? false) }
    }

    var visibleSnapshots: [ProviderSnapshot] { visibleProviders.compactMap { snapshots[$0] } }

    var hasProblem: Bool { visibleSnapshots.contains { $0.status.isProblem } }

    // MARK: Lifecycle

    func start() {
        // Open at login by default (once); the user can turn it off from the panel or Settings.
        if !UserDefaults.standard.bool(forKey: "didConfigureLoginItem") {
            UserDefaults.standard.set(true, forKey: "didConfigureLoginItem")
            setLaunchAtLogin(true)
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
        Task { await refreshAll(includeHistory: true) }
        scheduleTimer()
        DarwinNotify.observe(DarwinNotify.refresh) {
            Task { @MainActor in await AppModel.shared.refreshAll() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { _ in
            Task { @MainActor in await AppModel.shared.refreshAll() }
        }
    }

    func scheduleTimer() {
        timer?.invalidate()
        let interval = max(1, settings.refreshMinutes) * 60
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            Task { @MainActor in await AppModel.shared.refreshAll() }
        }
        timer?.tolerance = 20
    }

    // MARK: Refresh

    func detectCLIs(force: Bool = false) async {
        if force { await Shell.shared.invalidate() }
        await withTaskGroup(of: (ProviderID, InstallState).self) { group in
            for p in ProviderID.allCases {
                let cmd = settings.command(for: p)
                group.addTask {
                    guard await Shell.shared.resolve(cmd) != nil else { return (p, .missing) }
                    let v = await Providers.all[p]?.cliVersion(command: cmd)
                    return (p, .installed(version: v))
                }
            }
            for await (p, state) in group { install[p] = state }
        }
        t3Installed = T3CodeHistory.isInstalled
    }

    func refreshAll(includeHistory: Bool = false) async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        await detectCLIs()
        let targets = visibleProviders
        await withTaskGroup(of: ProviderSnapshot?.self) { group in
            for p in targets {
                let cmd = settings.command(for: p)
                group.addTask { await Providers.all[p]?.fetch(command: cmd) }
            }
            for await snap in group {
                guard var snap else { continue }
                if case .installed(let v) = install[snap.provider] { snap.cliVersion = v }
                // Keep the last good numbers visible on transient errors.
                if case .error = snap.status, let old = snapshots[snap.provider], snap.windows.isEmpty {
                    snap.windows = old.windows
                    snap.bankedResets = old.bankedResets
                    snap.plan = snap.plan ?? old.plan
                }
                snapshots[snap.provider] = snap
            }
        }
        lastRefresh = .now
        Notifier.shared.evaluate(old: previous, new: snapshots, providers: targets)
        previous = snapshots

        publish()
        let stale = lastHistoryLoad.map { Date.now.timeIntervalSince($0) > 15 * 60 } ?? true
        if (includeHistory || stale) && !isLoadingHistory {
            if CommandLine.arguments.contains("--dump") || CommandLine.arguments.contains("--render") {
                await reloadHistory()
            } else {
                Task { await reloadHistory() }
            }
        }
    }

    func refresh(_ p: ProviderID) async {
        guard let provider = Providers.all[p] else { return }
        var snap = await provider.fetch(command: settings.command(for: p))
        if case .installed(let v) = install[p] { snap.cliVersion = v }
        snapshots[p] = snap
        publish()
    }

    func reloadHistory() async {
        isLoadingHistory = true
        defer { isLoadingHistory = false }
        let pref = settings.historySource
        let providers = visibleProviders
        var commands: [ProviderID: String] = [:]
        for p in ProviderID.allCases { commands[p] = settings.command(for: p) }
        let loaded = await Task.detached(priority: .utility) {
            await HistoryLoader.load(preference: pref, providers: providers, commands: commands)
        }.value
        history = loaded
        lastHistoryLoad = .now
        publish()
    }

    /// Writes the shared snapshot for widgets and asks WidgetKit to reload.
    func publish() {
        let state = SharedState(providers: Array(snapshots.values), history: history,
                                updatedAt: .now, visibleProviders: visibleProviders)
        SharedStore.save(state)
        WidgetCenter.shared.reloadAllTimelines()
        ControlCenter.shared.reloadAllControls()
    }

    // MARK: Actions

    func setLaunchAtLogin(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            toast = "Couldn't change login item: \(error.localizedDescription)"
        }
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    // MARK: T3 Code access

    func refreshT3Access() async {
        t3Access = await T3CodeHistory.accessState()
    }

    func grantT3Access() async {
        busy.insert("t3")
        defer { busy.remove("t3") }
        do {
            UserDefaults.standard.set(false, forKey: "t3AccessRevoked")
            _ = try await T3CodeHistory.issueToken()
            toast = "T3 Code access granted"
        } catch {
            toast = error.localizedDescription
        }
        await refreshT3Access()
        await reloadHistory()
    }

    func revokeT3Access() async {
        busy.insert("t3")
        defer { busy.remove("t3") }
        await T3CodeHistory.revoke()
        UserDefaults.standard.set(true, forKey: "t3AccessRevoked")
        await refreshT3Access()
        await reloadHistory()
    }

    func login(_ p: ProviderID) async {
        let key = "login.\(p.rawValue)"
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            try await Providers.all[p]?.login(command: settings.command(for: p))
            toast = "\(p.shortName): signed in"
        } catch {
            toast = "\(p.shortName) sign-in failed: \(error.localizedDescription)"
        }
        await refresh(p)
    }

    func redeem(_ p: ProviderID, reset: BankedReset?) async {
        let key = "redeem.\(p.rawValue).\(reset?.id ?? "any")"
        busy.insert(key)
        defer { busy.remove(key) }
        do {
            toast = try await Providers.all[p]?.redeem(reset: reset, command: settings.command(for: p))
        } catch {
            toast = "Couldn't redeem: \(error.localizedDescription)"
        }
        await refresh(p)
    }

    func toggleResetAlert(_ p: ProviderID, window: UsageWindow) {
        Notifier.shared.toggleResetAlert(provider: p, window: window)
    }
}
