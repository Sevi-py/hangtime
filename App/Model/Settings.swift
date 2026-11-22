import Foundation
import SwiftUI

enum MenuBarStyle: String, CaseIterable, Identifiable, Codable {
    case iconOnly, percent, perProvider, rings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .iconOnly: "Icon only"
        case .percent: "Lowest remaining"
        case .perProvider: "Each provider"
        case .rings: "Mini rings"
        }
    }
}

enum MenuBarWindowChoice: String, CaseIterable, Identifiable, Codable {
    case tightest, session, weekly
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tightest: "Most constrained limit"
        case .session: "Session limit"
        case .weekly: "Weekly limit"
        }
    }

    func pick(from snap: ProviderSnapshot) -> UsageWindow? {
        switch self {
        case .tightest: snap.tightest
        case .session: snap.session ?? snap.tightest
        case .weekly: snap.weekly ?? snap.tightest
        }
    }
}

enum HistorySourcePreference: String, CaseIterable, Identifiable, Codable {
    case automatic, t3code, cliLogs
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .t3code: "T3 Code"
        case .cliLogs: "CLI session logs"
        }
    }
}

/// User preferences, persisted in UserDefaults (display prefs mirrored to the app group for widgets).
@MainActor
@Observable
final class AppSettings {
    static let shared = AppSettings()
    private let d = UserDefaults.standard

    var commands: [ProviderID: String] { didSet { save() } }
    var enabled: [ProviderID: Bool] { didSet { save() } }
    var inMenuBar: [ProviderID: Bool] { didSet { save() } }
    var order: [ProviderID] { didSet { save() } }

    var refreshMinutes: Double { didSet { save() } }
    var menuBarStyle: MenuBarStyle { didSet { save() } }
    var menuBarWindow: MenuBarWindowChoice { didSet { save() } }
    var menuBarShowsResetTime: Bool { didSet { save() } }

    var showPaceMarker: Bool { didSet { save() } }
    var colorByProvider: Bool { didSet { save() } }
    var showModelLimits: Bool { didSet { save() } }
    var showBankedResets: Bool { didSet { save() } }
    var confirmBeforeRedeem: Bool { didSet { save() } }

    var popoverShowsChart: Bool { didSet { save() } }
    var popoverShowsHeatmap: Bool { didSet { save() } }
    var historySource: HistorySourcePreference { didSet { save() } }
    var historyMetric: UsageHistory.Metric { didSet { save() } }
    var chartDays: Int { didSet { save() } }

    var notifyWhenAnyLimitResets: Bool { didSet { save() } }
    var lowThresholdAlerts: Bool { didSet { save() } }
    var lowThreshold: Double { didSet { save() } }
    var notifyResetExpiry: Bool { didSet { save() } }
    var notifyLoggedOut: Bool { didSet { save() } }

    /// Claude: when Anthropic blocks usage checks, read the limits off a tiny Haiku request instead.
    var claudeProbe: Bool { didSet { save() } }

    private init() {
        func dict<T>(_ key: String, _ def: (ProviderID) -> T) -> [ProviderID: T] {
            let stored = UserDefaults.standard.dictionary(forKey: key) ?? [:]
            return Dictionary(uniqueKeysWithValues: ProviderID.allCases.map { ($0, (stored[$0.rawValue] as? T) ?? def($0)) })
        }
        commands = dict("commands") { $0.defaultCommand }
        enabled = dict("enabled") { _ in true }
        inMenuBar = dict("inMenuBar") { _ in true }
        let storedOrder = (d.stringArray(forKey: "order") ?? []).compactMap(ProviderID.init)
        order = storedOrder + ProviderID.allCases.filter { !storedOrder.contains($0) }

        refreshMinutes = d.object(forKey: "refreshMinutes") as? Double ?? 0
        menuBarStyle = MenuBarStyle(rawValue: d.string(forKey: "menuBarStyle") ?? "") ?? .perProvider
        menuBarWindow = MenuBarWindowChoice(rawValue: d.string(forKey: "menuBarWindow") ?? "") ?? .session
        menuBarShowsResetTime = d.object(forKey: "menuBarShowsResetTime") as? Bool ?? false

        showPaceMarker = d.object(forKey: "showPaceMarker") as? Bool ?? true
        colorByProvider = d.object(forKey: "colorByProvider") as? Bool ?? true
        showModelLimits = d.object(forKey: "showModelLimits") as? Bool ?? true
        showBankedResets = d.object(forKey: "showBankedResets") as? Bool ?? true
        confirmBeforeRedeem = d.object(forKey: "confirmBeforeRedeem") as? Bool ?? true

        popoverShowsChart = d.object(forKey: "popoverShowsChart") as? Bool ?? true
        popoverShowsHeatmap = d.object(forKey: "popoverShowsHeatmap") as? Bool ?? true
        historySource = HistorySourcePreference(rawValue: d.string(forKey: "historySource") ?? "") ?? .automatic
        historyMetric = UsageHistory.Metric(rawValue: d.string(forKey: "historyMetric") ?? "") ?? .cost
        chartDays = d.object(forKey: "chartDays") as? Int ?? 30

        notifyWhenAnyLimitResets = d.object(forKey: "notifyWhenAnyLimitResets") as? Bool ?? false
        lowThresholdAlerts = d.object(forKey: "lowThresholdAlerts") as? Bool ?? false
        lowThreshold = d.object(forKey: "lowThreshold") as? Double ?? 0.1
        notifyResetExpiry = d.object(forKey: "notifyResetExpiry") as? Bool ?? true
        notifyLoggedOut = d.object(forKey: "notifyLoggedOut") as? Bool ?? true
        claudeProbe = d.object(forKey: ClaudeProvider.probeSettingKey) as? Bool ?? true
    }

    private func save() {
        func raw<T>(_ m: [ProviderID: T]) -> [String: T] { Dictionary(uniqueKeysWithValues: m.map { ($0.key.rawValue, $0.value) }) }
        d.set(raw(commands), forKey: "commands")
        d.set(raw(enabled), forKey: "enabled")
        d.set(raw(inMenuBar), forKey: "inMenuBar")
        d.set(order.map(\.rawValue), forKey: "order")
        d.set(refreshMinutes, forKey: "refreshMinutes")
        d.set(menuBarStyle.rawValue, forKey: "menuBarStyle")
        d.set(menuBarWindow.rawValue, forKey: "menuBarWindow")
        d.set(menuBarShowsResetTime, forKey: "menuBarShowsResetTime")
        d.set(showPaceMarker, forKey: "showPaceMarker")
        d.set(colorByProvider, forKey: "colorByProvider")
        d.set(showModelLimits, forKey: "showModelLimits")
        d.set(showBankedResets, forKey: "showBankedResets")
        d.set(confirmBeforeRedeem, forKey: "confirmBeforeRedeem")
        d.set(popoverShowsChart, forKey: "popoverShowsChart")
        d.set(popoverShowsHeatmap, forKey: "popoverShowsHeatmap")
        d.set(historySource.rawValue, forKey: "historySource")
        d.set(historyMetric.rawValue, forKey: "historyMetric")
        d.set(chartDays, forKey: "chartDays")
        d.set(notifyWhenAnyLimitResets, forKey: "notifyWhenAnyLimitResets")
        d.set(lowThresholdAlerts, forKey: "lowThresholdAlerts")
        d.set(lowThreshold, forKey: "lowThreshold")
        d.set(notifyResetExpiry, forKey: "notifyResetExpiry")
        d.set(notifyLoggedOut, forKey: "notifyLoggedOut")
        d.set(claudeProbe, forKey: ClaudeProvider.probeSettingKey)

        let g = SharedStore.defaults
        g.set(showPaceMarker, forKey: SharedStore.Key.showPaceMarker)
        g.set(colorByProvider, forKey: SharedStore.Key.colorByProvider)
        g.set(historyMetric.rawValue, forKey: SharedStore.Key.historyMetric)
    }

    func command(for p: ProviderID) -> String {
        let c = commands[p]?.trimmingCharacters(in: .whitespaces) ?? ""
        return c.isEmpty ? p.defaultCommand : c
    }

    func binding(command p: ProviderID) -> Binding<String> {
        Binding(get: { self.commands[p] ?? p.defaultCommand }, set: { self.commands[p] = $0 })
    }

    func binding(enabled p: ProviderID) -> Binding<Bool> {
        Binding(get: { self.enabled[p] ?? true }, set: { self.enabled[p] = $0 })
    }

    func binding(inMenuBar p: ProviderID) -> Binding<Bool> {
        Binding(get: { self.inMenuBar[p] ?? true }, set: { self.inMenuBar[p] = $0 })
    }
}
