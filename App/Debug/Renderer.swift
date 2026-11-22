#if DEBUG
import SwiftUI
import AppKit
import WidgetKit

/// `Headroom --render <dir>`: renders the panel, settings panes and widgets to PNGs (light + dark)
/// for visual review without touching the menu bar.
@MainActor
enum DebugRenderer {
    static func run(dir: String) async {
        let model = AppModel.shared
        await model.refreshAll(includeHistory: true)
        let out = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let state = SharedState(providers: Array(model.snapshots.values), history: model.history,
                                visibleProviders: model.visibleProviders)

        let items: [(ProviderID, UsageWindow?, Bool)] = model.visibleProviders.map { p in
            let snap = model.snapshots[p]
            return (p, snap.flatMap { model.settings.menuBarWindow.pick(from: $0) }, snap?.status.isProblem ?? false)
        }
        for style in [MenuBarStyle.rings, .perProvider] {
            let img = MenuBarLabel.render(items: items, style: style, showReset: false)
            if let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
                try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("menubar-\(style.rawValue).png"))
            }
        }

        for dark in [false, true] {
            let suffix = dark ? "dark" : "light"
            await snap(AnyView(MenuContentView().environment(model)), size: nil, dark: dark,
                       to: out.appendingPathComponent("panel-\(suffix).png"))
            await snap(AnyView(DashboardView().environment(model)), size: CGSize(width: 860, height: 1300), dark: dark,
                       to: out.appendingPathComponent("dashboard-\(suffix).png"))
            for tab in ["general", "providers", "appearance", "history", "about"] {
                await snap(AnyView(SettingsView(tab: tab).environment(model)), size: nil, dark: dark,
                           to: out.appendingPathComponent("settings-\(tab)-\(suffix).png"))
            }
            let widgets: [(String, CGSize, AnyView)] = [
                ("limits-small", .init(width: 170, height: 170), AnyView(ProviderLimitsView(entry: .init(date: .now, state: state, intent: nil), config: ProviderLimitsIntent(), familyOverride: .systemSmall))),
                ("limits-medium", .init(width: 364, height: 170), AnyView(ProviderLimitsView(entry: .init(date: .now, state: state, intent: nil), config: ProviderLimitsIntent(), familyOverride: .systemMedium))),
                ("overview-medium", .init(width: 364, height: 170), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemMedium))),
                ("overview-large", .init(width: 364, height: 382), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemLarge))),
                ("overview-large-square", .init(width: 344, height: 344), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemLarge))),
                ("overview-medium-short", .init(width: 344, height: 150), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemMedium))),
                ("overview-small", .init(width: 170, height: 170), AnyView(OverviewView(entry: .init(date: .now, state: state, intent: nil), config: OverviewIntent(), familyOverride: .systemSmall))),
                ("gauge-small", .init(width: 170, height: 170), AnyView(SingleGaugeView(entry: .init(date: .now, state: state, intent: nil), config: SingleGaugeIntent()))),
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
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
        window.orderOut(nil)
    }
}
#endif
