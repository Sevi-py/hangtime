import SwiftUI
import AppKit

/// The status item. Rendered into a template image so it adapts to light/dark menu bars
/// and the selected/highlighted state exactly like system items.
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings
        let items: [(ProviderID, UsageWindow?, Bool)] = model.visibleProviders
            .filter { s.inMenuBar[$0] ?? true }
            .map { p in
                let snap = model.snapshots[p]
                let w = snap.flatMap { snap in
                    s.menuBarWindow.pick(from: snap).map { s.zeroWhenBlocked ? snap.blocked($0) : $0 }
                }
                return (p, w, snap?.status.isProblem ?? false)
            }
        Image(nsImage: Self.render(items: items, style: s.menuBarStyle, showReset: s.menuBarShowsResetTime))
            .accessibilityLabel(accessibility(items))
    }

    private func accessibility(_ items: [(ProviderID, UsageWindow?, Bool)]) -> String {
        items.map { "\($0.0.shortName) \($0.1.map { Fmt.percent($0.remainingFraction) } ?? "unknown") left" }
            .joined(separator: ", ")
    }

    @MainActor
    static func render(items: [(ProviderID, UsageWindow?, Bool)], style: MenuBarStyle, showReset: Bool, scale: CGFloat? = nil) -> NSImage {
        let content = LabelContent(items: items, style: style, showReset: showReset)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale ?? NSScreen.main?.backingScaleFactor ?? 2
        let image = renderer.nsImage ?? NSImage(systemSymbolName: "gauge.with.dots.needle.33percent", accessibilityDescription: nil)!
        image.isTemplate = true
        return image
    }
}

private struct LabelContent: View {
    var items: [(ProviderID, UsageWindow?, Bool)]
    var style: MenuBarStyle
    var showReset: Bool

    var body: some View {
        HStack(spacing: 6) {
            if items.isEmpty || style == .iconOnly {
                Image(systemName: items.contains { $0.2 } ? "exclamationmark.triangle" : "gauge.with.dots.needle.50percent")
                    .font(.system(size: 14, weight: .medium))
            } else {
                switch style {
                case .percent:
                    let tightest = items.compactMap { i in i.1.map { (i.0, $0) } }.min { $0.1.remainingFraction < $1.1.remainingFraction }
                    Image(systemName: "gauge.with.dots.needle.50percent").font(.system(size: 13, weight: .medium))
                    if let t = tightest { text(t.1) }
                    if items.contains(where: { $0.2 }) { warn }
                case .perProvider:
                    ForEach(items, id: \.0) { item in
                        HStack(spacing: 3) {
                            Image(item.0.logo).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 13, height: 13)
                            if item.2 { warn } else if let w = item.1 { text(w) } else { Text("–") }
                        }
                    }
                case .rings, .iconOnly:
                    ForEach(items, id: \.0) { item in
                        MiniRing(remaining: item.1?.remainingFraction ?? 0, pace: item.1?.evenPaceRemaining(),
                                 logo: item.0.logo, problem: item.2)
                    }
                }
            }
        }
        .font(.system(size: 12, weight: .medium).monospacedDigit())
        .foregroundStyle(.black)
        .padding(.horizontal, style == .rings && !items.isEmpty ? 0 : 1)
        .frame(height: 21)
    }

    private var warn: some View {
        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10))
    }

    @ViewBuilder
    private func text(_ w: UsageWindow) -> some View {
        if showReset, w.isExhausted, let r = w.resetsAt {
            Text(Fmt.duration(r.timeIntervalSinceNow, compact: false))
        } else {
            Text(Fmt.percent(w.remainingFraction))
        }
    }
}

private struct MiniRing: View {
    var remaining: Double
    var pace: Double?
    var logo: String
    var problem: Bool

    var body: some View {
        // Strokes are inset so the whole ring stays inside the 21pt label (a centred stroke got clipped at the bottom).
        let lw: CGFloat = 1.9
        ZStack {
            Circle().inset(by: lw / 2).stroke(.black.opacity(0.28), lineWidth: lw)
            Circle().inset(by: lw / 2).trim(from: 0, to: remaining)
                .stroke(.black, style: StrokeStyle(lineWidth: lw, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if problem {
                Image(systemName: "exclamationmark").font(.system(size: 11, weight: .heavy))
            } else {
                Image(logo).renderingMode(.template).resizable().aspectRatio(contentMode: .fit)
                    // Antigravity's mark fills its whole box, so it needs a little more room from the ring.
                    .frame(width: logo == ProviderID.antigravity.logo ? 11 : 12.5, height: logo == ProviderID.antigravity.logo ? 11 : 12.5)
            }
        }
        .frame(width: 21, height: 21)
    }
}
