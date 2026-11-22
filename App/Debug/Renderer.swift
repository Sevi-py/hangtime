#if DEBUG
import SwiftUI
import AppKit
import WidgetKit

/// `Hangtime --render <dir>`: renders the panel, settings panes and widgets to PNGs (light + dark, @2x)
/// for visual review without touching the menu bar.
///
/// Options (e.g. for README screenshots):
/// - `--providers claude,codex`: only these providers in the panel and menu bar label.
/// - `--limits-provider codex`, `--gauge-provider grok`: provider of the small Provider Limits and Single Limit widgets.
/// - `-AppleLocale en_US`: render dates and times in another locale.
@MainActor
enum DebugRenderer {
    private static func option(_ name: String) -> String? {
        guard let i = CommandLine.arguments.firstIndex(of: name), i + 1 < CommandLine.arguments.count else { return nil }
        return CommandLine.arguments[i + 1]
    }

    static func run(dir: String) async {
        let model = AppModel.shared
        await model.refreshAll(includeHistory: true)
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let state = SharedState(providers: Array(model.snapshots.values), history: model.history,
                                visibleProviders: model.visibleProviders)
        let panelProviders = option("--providers")?.split(separator: ",").compactMap { ProviderID(rawValue: String($0)) }
        var limitsConfig = ProviderLimitsIntent()
        if let p = option("--limits-provider").flatMap(ProviderOption.init(rawValue:)) { limitsConfig.provider = p }
        var gaugeConfig = SingleGaugeIntent()
        if let p = option("--gauge-provider").flatMap(ProviderOption.init(rawValue:)) {
            gaugeConfig.provider = p
            gaugeConfig.limit = .tightest
        }
        model.debugProviders = panelProviders

        let items: [(ProviderID, UsageWindow?, Bool)] = model.visibleProviders.map { p in
            let snap = model.snapshots[p]
            return (p, snap.flatMap { model.settings.menuBarWindow.pick(from: $0) }, snap?.status.isProblem ?? false)
        }
        model.debugProviders = nil
        for style in [MenuBarStyle.rings, .perProvider] {
            let img = MenuBarLabel.render(items: items, style: style, showReset: false, scale: 2)
            // Write the largest (Retina) representation.
            if let rep = img.representations.compactMap({ $0 as? NSBitmapImageRep }).max(by: { $0.pixelsWide < $1.pixelsWide })
                ?? img.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)) {
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("menubar-\(style.rawValue).png"))
            }
        }

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            model.debugProviders = panelProviders
            await snap(AnyView(MenuContentView().environment(model)), size: nil, dark: dark,
                       to: out.appendingPathComponent("panel-\(suffix).png"))
            model.debugProviders = nil
            await snap(AnyView(DashboardView().environment(model)), size: CGSize(width: 860, height: 1300), dark: dark,
                       to: out.appendingPathComponent("dashboard-\(suffix).png"))
            for step in SetupStep.allCases {
                await snap(AnyView(SetupView(step: step).environment(model)), size: SetupView.size, dark: dark,
                           to: out.appendingPathComponent("setup-\(step.rawValue)-\(suffix).png"))
            }
            for tab in ["general", "providers", "appearance", "history", "about"] {
                await snap(AnyView(SettingsView(tab: tab).environment(model)), size: nil, dark: dark,
                           to: out.appendingPathComponent("settings-\(tab)-\(suffix).png"))
            }
            let widgets: [(String, CGSize, AnyView)] = [
                ("limits-small", .init(width: 170, height: 170), AnyView(ProviderLimitsView(entry: .init(date: .now, state: state, intent: nil), config: limitsConfig, familyOverride: .systemSmall))),
                ("limits-medium", .init(width: 364, height: 170), AnyView(ProviderLimitsView(entry: .init(date: .now, state: state, intent: nil), config: ProviderLimitsIntent(), familyOverride: .systemMedium))),
                ("overview-medium", .init(width: 364, height: 170), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemMedium))),
                ("overview-large", .init(width: 364, height: 382), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemLarge))),
                ("overview-large-square", .init(width: 344, height: 344), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemLarge))),
                ("overview-medium-short", .init(width: 344, height: 150), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemMedium))),
                ("overview-small", .init(width: 170, height: 170), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemSmall))),
                ("gauge-small", .init(width: 170, height: 170), AnyView(SingleGaugeView(entry: .init(date: .now, state: state, intent: nil), config: gaugeConfig))),
                ("chart-medium", .init(width: 364, height: 170), AnyView(ChartWidgetView(entry: .init(date: .now, state: state, intent: nil), config: ChartIntent(), familyOverride: .systemMedium))),
                ("heatmap-medium", .init(width: 364, height: 170), AnyView(HeatmapWidgetView(entry: .init(date: .now, state: state, intent: nil), config: HeatmapIntent(), familyOverride: .systemMedium))),
                ("heatmap-large-square", .init(width: 344, height: 344), AnyView(HeatmapWidgetView(entry: .init(date: .now, state: state, intent: nil), config: HeatmapIntent(), familyOverride: .systemLarge))),
                ("heatmap-large", .init(width: 364, height: 382), AnyView(HeatmapWidgetView(entry: .init(date: .now, state: state, intent: nil), config: HeatmapIntent(), familyOverride: .systemLarge))),
            ]
            var variants = widgets
            // The All Providers layout with fewer providers, to check it fills the space either way.
            for n in 1..<max(1, state.visibleProviders.count) {
                var sub = state
                sub.visibleProviders = Array(state.visibleProviders.prefix(n))
                for (fam, label, size) in [(WidgetFamily.systemMedium, "medium", CGSize(width: 364, height: 170)),
                                           (.systemLarge, "large", CGSize(width: 364, height: 382))] {
                    variants.append(("overview-\(label)-\(n)p", size, AnyView(OverviewView(entry: .init(date: .now, state: sub, intent: nil), config: OverviewIntent(), familyOverride: fam))))
                }
            }
            for (name, size, view) in variants {
                let framed = AnyView(view.padding(16).frame(width: size.width, height: size.height)
                    .background(Color(nsColor: .windowBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous)))
                await snap(framed, size: size, dark: dark, to: out.appendingPathComponent("w-\(name)-\(suffix).png"))
            }
        }
    }

    static func snap(_ view: AnyView, size: CGSize?, dark: Bool, to url: URL) async {
        let host = NSHostingView(rootView: view)
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let fitting = size ?? host.fittingSize
        host.frame = NSRect(origin: .zero, size: fitting)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = host.appearance
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
        window.orderFrontRegardless()
        try? await Task.sleep(for: .milliseconds(1200))
        host.layoutSubtreeIfNeeded()
        // Always @2x, so the PNGs are sharp on Retina displays (and usable as README screenshots).
        let scale = 2.0
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(host.bounds.width * scale),
                                         pixelsHigh: Int(host.bounds.height * scale), bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        rep.size = host.bounds.size
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif
