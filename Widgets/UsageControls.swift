import WidgetKit
import SwiftUI
import AppIntents

/// Control Center / menu bar control showing what's left for one provider.
struct UsageControlConfiguration: ControlConfigurationIntent {
    static let title: LocalizedStringResource = "Usage Limit"
    @Parameter(title: "Provider", default: .automatic) var provider: ProviderOption
    @Parameter(title: "Limit", default: .tightest) var limit: LimitOption
}

struct UsageControlValue {
    var provider: ProviderID
    var text: String
    var symbol: String
}

struct UsageControlProvider: AppIntentControlValueProvider {
    func previewValue(configuration: UsageControlConfiguration) -> UsageControlValue {
        UsageControlValue(provider: .claude, text: "62% left", symbol: "gauge.with.dots.needle.67percent")
    }

    func currentValue(configuration: UsageControlConfiguration) async throws -> UsageControlValue {
        let state = SharedStore.load() ?? SharedState()
        let pid = configuration.provider.resolve(in: state) ?? .claude
        guard let snap = state.snapshot(for: pid) else {
            return UsageControlValue(provider: pid, text: "No data", symbol: "gauge.with.dots.needle.0percent")
        }
        if snap.status == .loggedOut {
            return UsageControlValue(provider: pid, text: "Signed out", symbol: "person.crop.circle.badge.exclamationmark")
        }
        guard let w = configuration.limit.pick(snap) else {
            return UsageControlValue(provider: pid, text: "—", symbol: "gauge.with.dots.needle.0percent")
        }
        let r = w.remainingFraction
        let symbol = r > 0.83 ? "gauge.with.dots.needle.100percent" : r > 0.5 ? "gauge.with.dots.needle.67percent"
            : r > 0.17 ? "gauge.with.dots.needle.33percent" : "gauge.with.dots.needle.0percent"
        let text = w.isExhausted ? (w.resetsAt.map { "Resets in \(Fmt.duration($0.timeIntervalSinceNow))" } ?? "Limit hit")
            : "\(Fmt.percent(r)) left"
        return UsageControlValue(provider: pid, text: text, symbol: symbol)
    }
}

struct UsageControl: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(kind: "UsageControl", provider: UsageControlProvider()) { value in
            ControlWidgetButton(action: RefreshUsageIntent()) {
                Label {
                    Text(value.provider.shortName)
                    Text(value.text)
                } icon: {
                    Image(systemName: value.symbol)
                }
            }
            .tint(value.provider.tint)
        }
        .displayName("Usage Limit")
        .description("What's left of a CLI's session or weekly limit.")
    }
}

@main
struct HeadroomWidgets: WidgetBundle {
    var body: some Widget {
        ProviderLimitsWidget()
        OverviewWidget()
        SingleGaugeWidget()
        ChartWidget()
        HeatmapWidget()
        UsageControl()
    }
}
