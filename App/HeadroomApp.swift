import SwiftUI
import AppKit

@main
struct HeadroomApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel.shared

    var body: some Scene {
        MenuBarExtra {
            MenuContentView()
                .environment(model)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Window("Dashboard", id: "dashboard") {
            DashboardView()
                .environment(model)
        }
        .defaultSize(width: 860, height: 760)

        Settings {
            SettingsView()
                .environment(model)
        }
        .windowResizability(.contentSize)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        if let i = CommandLine.arguments.firstIndex(of: "--render"), i + 1 < CommandLine.arguments.count {
            Task { @MainActor in
                await DebugRenderer.run(dir: CommandLine.arguments[i + 1])
                exit(0)
            }
            return
        }
        #endif
        if CommandLine.arguments.contains("--dump") {
            // Headless diagnostics: fetch everything once and print it.
            Task { @MainActor in
                let m = AppModel.shared
                await m.refreshAll(includeHistory: CommandLine.arguments.contains("--history"))
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.dateEncodingStrategy = .iso8601
                var state = SharedState(providers: Array(m.snapshots.values), history: m.history,
                                        visibleProviders: m.visibleProviders)
                if !CommandLine.arguments.contains("--history") { state.history = .init() }
                else { state.history.days = Array(state.history.days.sorted { $0.day > $1.day }.prefix(12)) }
                print(String(decoding: try! enc.encode(state), as: UTF8.self))
                print("history source:", m.history.source.rawValue, "days:", Set(m.history.days.map(\.day)).count,
                      "cost30:", m.history.total(metric: .cost, providers: Set(ProviderID.allCases),
                                                 since: Date.now.addingTimeInterval(-30*86400)))
                let since = DayFormatter.string(from: Date.now.addingTimeInterval(-30*86400))
                var byKey: [String: (Double, Int)] = [:]
                for d in m.history.days where d.day >= since {
                    let k = "\(d.provider.rawValue) \(d.model ?? "-")"
                    byKey[k, default: (0, 0)].0 += d.costUSD ?? 0
                    byKey[k, default: (0, 0)].1 += d.totalTokens
                }
                for (k, v) in byKey.sorted(by: { $0.value.0 > $1.value.0 }) {
                    print(String(format: "  %-40@ $%9.2f  %@ tok", k as NSString, v.0, Fmt.tokens(Double(v.1)) as NSString))
                }
                exit(0)
            }
            return
        }
        if CommandLine.arguments.contains("--reset-setup") {
            // Puts Headroom back to a first-launch state so the setup assistant shows again:
            // removes the login item, disconnects T3 Code and forgets notification choices.
            Task { @MainActor in
                AppModel.shared.setLaunchAtLogin(false)
                await T3CodeHistory.revoke()
                let d = UserDefaults.standard
                for k in [SetupAssistant.completedKey, SetupAssistant.loginItemKey, "t3AccessRevoked",
                          "notifyWhenAnyLimitResets", "lowThresholdAlerts", "notifyResetExpiry", "notifyLoggedOut",
                          "armedResetAlertsV2", "lowAlerted"] {
                    d.removeObject(forKey: k)
                }
                d.synchronize()
                print("Setup reset. Launch Headroom to see the setup assistant.")
                exit(0)
            }
            return
        }
        Task { @MainActor in
            let firstLaunch = SetupAssistant.needsSetup()
            AppModel.shared.start()
            if firstLaunch { SetupAssistant.show() }
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        // headroom://refresh, headroom://settings (used by widgets & controls)
        for url in urls {
            switch url.host {
            case "settings":
                Task { @MainActor in SettingsOpener.open() }
            default:
                Task { @MainActor in await AppModel.shared.refreshAll() }
            }
        }
    }
}

@MainActor
enum SettingsOpener {
    static var action: OpenSettingsAction?

    static func open() {
        NSApp.activate()
        if let action { action() } else {
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
        }
        // Bring the settings window to front once it exists.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            NSApp.windows.first { $0.identifier?.rawValue.contains("Settings") == true || $0.title.contains("Settings") }?
                .makeKeyAndOrderFront(nil)
        }
    }
}
