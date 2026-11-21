import SwiftUI
import Charts

// MARK: - Limit bar with even-pace marker

/// Horizontal capsule that shows what's *left*. A small tick marks where you would be
/// if you had used the limit perfectly evenly.
public extension EnvironmentValues {
    /// Animate value changes (only in the open panel and the Dashboard, not in widgets).
    @Entry var headroomAnimates: Bool = false
}

public struct LimitBar: View {
    @Environment(\.headroomAnimates) private var animates
    public var remaining: Double
    public var pace: Double?
    public var color: Color
    public var height: CGFloat

    public init(remaining: Double, pace: Double?, color: Color, height: CGFloat = 6) {
        self.remaining = remaining
        self.pace = pace
        self.color = color
        self.height = height
    }

    public var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(color.gradient)
                    .frame(width: max(remaining > 0 ? height : 0, w * remaining))
                if let pace {
                    // Outlined so it stays visible on any bar color (incl. Grok's near-black/near-white).
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(.primary)
                        .frame(width: 2.5, height: height + 6)
                        .overlay(RoundedRectangle(cornerRadius: 1.5).strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 0.75)
                            .padding(-0.75))
                        .offset(x: min(max(w * pace - 1.25, 0), w - 2.5))
                }
            }
            .frame(height: height + 6)
        }
        .frame(height: height + 6)
        .animation(animates ? .smooth(duration: 0.7) : nil, value: remaining)
        .animation(animates ? .smooth(duration: 0.7) : nil, value: pace)
        .accessibilityElement()
        .accessibilityLabel("\(Fmt.percent(remaining)) left")
    }
}

// MARK: - Ring gauge

public struct RingGauge: View {
    @Environment(\.headroomAnimates) private var animates
    public var remaining: Double
    public var pace: Double?
    public var color: Color
    public var lineWidth: CGFloat
    public var label: String?

    public init(remaining: Double, pace: Double?, color: Color, lineWidth: CGFloat = 7, label: String? = nil) {
        self.remaining = remaining
        self.pace = pace
        self.color = color
        self.lineWidth = lineWidth
        self.label = label
    }

    public var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: remaining)
                .stroke(color.gradient, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(Fmt.percent(remaining))
                    .font(.system(.body, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .minimumScaleFactor(0.5)
                    .contentTransition(animates ? .numericText(value: remaining) : .identity)
                if let label {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                }
            }
            .padding(lineWidth + 2)
        }
        .overlay {
            if let pace {
                GeometryReader { geo in
                    let r = min(geo.size.width, geo.size.height) / 2
                    let angle = Angle.degrees(360 * pace - 90)
                    Capsule()
                        .fill(.primary)
                        .overlay(Capsule().strokeBorder(Color(nsColor: .windowBackgroundColor), lineWidth: 0.75).padding(-0.75))
                        .frame(width: 2.5, height: lineWidth + 5)
                        .rotationEffect(angle + .degrees(90))
                        .position(x: geo.size.width / 2 + r * cos(angle.radians),
                                  y: geo.size.height / 2 + r * sin(angle.radians))
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .animation(animates ? .smooth(duration: 0.8) : nil, value: remaining)
        .animation(animates ? .smooth(duration: 0.8) : nil, value: pace)
    }
}

// MARK: - Self-updating relative times

/// "Resets in 4 hr, 59 min" – counts down on its own (also inside widgets), switching to an
/// absolute weekday/time when the reset is more than a day away.
public struct ResetText: View {
    public var date: Date?
    public var notStarted: Bool
    public var now: Date
    public init(date: Date?, notStarted: Bool = false, now: Date = .now) {
        self.date = date
        self.notStarted = notStarted
        self.now = now
    }

    public var body: some View {
        if notStarted {
            Text("Not started")
        } else if let date {
            let soon = date.timeIntervalSince(now) < 86_400
            if date <= now {
                Text("Resetting…")
            } else {
                switch DateFmt.resetPref {
                case .relative where soon:
                    Text("Resets in \(Text(date, style: .relative))")
                case .both where soon:
                    Text("Resets in \(Text(date, style: .relative)) · \(DateFmt.time(date))")
                default:
                    Text("Resets \(DateFmt.dayTime(date, now: now))")
                }
            }
        }
    }
}

/// "Expires in 2 days, 3 hr" (self-updating) or "Expires 12 Dec".
public struct ExpiryText: View {
    public var date: Date?
    public var now: Date
    public init(_ date: Date?, now: Date = .now) {
        self.date = date
        self.now = now
    }

    public var body: some View {
        if let date {
            let soon = date.timeIntervalSince(now) < 7 * 86_400
            if date <= now {
                Text("Expired")
            } else {
                switch DateFmt.resetPref {
                case .relative where soon:
                    Text("Expires in \(Text(date, style: .relative))")
                case .both where soon:
                    Text("Expires in \(Text(date, style: .relative)) · \(DateFmt.dateTime(date))")
                default:
                    Text("Expires \(DateFmt.dateTime(date))")
                }
            }
        } else {
            Text("No expiry")
        }
    }
}

// MARK: - Window row

public struct WindowRow: View {
    public var window: UsageWindow
    public var provider: ProviderID
    public var showPace: Bool
    public var colorByProvider: Bool
    public var compact: Bool
    public var now: Date
    /// When the numbers were read (for stale values).
    public var asOf: Date?
    @Environment(\.headroomAnimates) private var animates

    private var stale: Bool { window.isStale == true }
    /// A stale window that hadn't started when we last saw it: we can't know what's left now.
    private var unknown: Bool { stale && window.resetsAt == nil && window.usedFraction == 0 && window.kind == .session }

    public init(window: UsageWindow, provider: ProviderID, showPace: Bool = true,
                colorByProvider: Bool = false, compact: Bool = false, now: Date = .now, asOf: Date? = nil) {
        self.asOf = asOf
        self.window = window
        self.provider = provider
        self.showPace = showPace
        self.colorByProvider = colorByProvider
        self.compact = compact
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: compact ? 2 : 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(window.title)
                    .font(compact ? .caption : .callout)
                    .fontWeight(.medium)
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text(unknown ? "—" : "\(stale ? "~" : "")\(Fmt.percent(window.remainingFraction)) left")
                    .font(compact ? .caption : .callout)
                    .monospacedDigit()
                    .contentTransition(animates ? .numericText(value: window.remainingFraction) : .identity)
                    .animation(animates ? .smooth : nil, value: window.remainingFraction)
                    .foregroundStyle(window.isExhausted && !stale ? .red : stale ? .secondary : .primary)
            }
            LimitBar(remaining: unknown ? 0 : window.remainingFraction,
                     pace: showPace && !stale ? window.evenPaceRemaining(at: now) : nil,
                     color: Theme.color(for: window, provider: provider, byProvider: colorByProvider),
                     height: compact ? 4 : 6)
                .opacity(stale ? 0.45 : 1)
            if !compact {
                HStack {
                    if unknown {
                        Text("Unknown – no recent data")
                    } else if stale, let asOf {
                        Text("As of \(asOf.formatted(.relative(presentation: .named)))")
                    } else {
                        ResetText(date: window.resetsAt, notStarted: window.resetsAt == nil && window.usedFraction == 0, now: now)
                    }
                    Spacer()
                    if showPace, !stale, let delta = window.paceDelta(at: now) {
                        PaceLabel(delta: delta)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }
}

public struct PaceLabel: View {
    public var delta: Double
    public init(delta: Double) { self.delta = delta }

    public var body: some View {
        let pts = Int((abs(delta) * 100).rounded())
        if pts < 3 {
            Label("On pace", systemImage: "equal.circle")
        } else if delta > 0 {
            Label("\(pts)% to spare", systemImage: "leaf")
                .foregroundStyle(.secondary)
        } else {
            Label("\(pts)% over pace", systemImage: "flame")
                .foregroundStyle(.orange)
        }
    }
}

// MARK: - Provider glyph

public struct ProviderGlyph: View {
    public var provider: ProviderID
    public var size: CGFloat
    public init(_ provider: ProviderID, size: CGFloat = 18) {
        self.provider = provider
        self.size = size
    }

    public var body: some View {
        Group {
            switch provider {
            case .claude:
                Image(provider.logo).renderingMode(.template).resizable().foregroundStyle(provider.tint)
            case .codex, .grok:
                // OpenAI's and xAI's marks are monochrome: black on light backgrounds, white on dark.
                Image(provider.logo).renderingMode(.template).resizable().foregroundStyle(.primary)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: size, height: size)
        .accessibilityLabel(provider.displayName)
    }
}

// MARK: - Activity heatmap (GitHub-style)

public struct ActivityHeatmap: View {
    public var totals: [String: Double]
    public var weeks: Int
    public var tint: Color
    public var spacing: CGFloat
    public var showLabels: Bool
    public var metric: UsageHistory.Metric
    public var now: Date

    public init(totals: [String: Double], weeks: Int, tint: Color = HeatmapPalette.current.color, spacing: CGFloat = 3,
                showLabels: Bool = true, metric: UsageHistory.Metric = .tokens, now: Date = .now) {
        self.totals = totals
        self.weeks = weeks
        self.tint = tint
        self.spacing = spacing
        self.showLabels = showLabels
        self.metric = metric
        self.now = now
    }

    private var columns: [[Date?]] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: now)
        let weekday = (cal.component(.weekday, from: today) - cal.firstWeekday + 7) % 7
        guard let start = cal.date(byAdding: .day, value: -(weeks - 1) * 7 - weekday, to: today) else { return [] }
        return (0..<weeks).map { w in
            (0..<7).map { d in
                guard let date = cal.date(byAdding: .day, value: w * 7 + d, to: start) else { return nil }
                return date > today ? nil : date
            }
        }
    }

    private func level(_ value: Double, max: Double) -> Double {
        guard value > 0, max > 0 else { return 0 }
        // 4 buckets like GitHub, scaled with sqrt so light days still show.
        let r = (value / max).squareRoot()
        return r > 0.75 ? 1 : r > 0.5 ? 0.75 : r > 0.25 ? 0.5 : 0.3
    }

    public var body: some View {
        let cols = columns
        let maxValue = totals.values.max() ?? 0
        GeometryReader { geo in
            let labelW: CGFloat = showLabels ? 24 : 0
            let cell = max(2, min((geo.size.width - labelW - spacing * CGFloat(weeks - 1)) / CGFloat(weeks),
                                  (geo.size.height - (showLabels ? 12 : 0) - spacing * 6) / 7))
            VStack(alignment: .leading, spacing: 2) {
                if showLabels {
                    HStack(spacing: spacing) {
                        Color.clear.frame(width: labelW - spacing, height: 10)
                        ForEach(Array(cols.enumerated()), id: \.offset) { idx, col in
                            let first = col.compactMap { $0 }.first
                            let showMonth = first.map { Calendar.current.component(.day, from: $0) <= 7 } ?? false
                            Text(showMonth && idx < cols.count - 1 ? first!.formatted(.dateTime.month(.abbreviated)) : "")
                                .font(.system(size: 8))
                                .foregroundStyle(.secondary)
                                .fixedSize()
                                .frame(width: cell, height: 10, alignment: .leading)
                        }
                    }
                }
                HStack(alignment: .top, spacing: spacing) {
                    if showLabels {
                        VStack(alignment: .leading, spacing: spacing) {
                            ForEach(0..<7, id: \.self) { d in
                                Text(d % 2 == 0 && d < 6 ? weekdaySymbol(d) : "")
                                    .font(.system(size: 8))
                                    .foregroundStyle(.secondary)
                                    .frame(width: labelW - spacing, height: cell, alignment: .leading)
                            }
                        }
                    }
                    ForEach(Array(cols.enumerated()), id: \.offset) { _, col in
                        VStack(spacing: spacing) {
                            ForEach(0..<7, id: \.self) { d in
                                let date = col[d]
                                let value = date.map { totals[DayFormatter.string(from: $0)] ?? 0 } ?? 0
                                RoundedRectangle(cornerRadius: max(1.5, cell * 0.22), style: .continuous)
                                    .fill(date == nil ? Color.clear :
                                            value > 0 ? tint.opacity(level(value, max: maxValue)) : Color.primary.opacity(0.07))
                                    .frame(width: cell, height: cell)
                                    .help(date.map { "\(DateFmt.date($0)): \(Fmt.metric(value, metric))" } ?? "")
                            }
                        }
                    }
                }
            }
        }
    }

    private func weekdaySymbol(_ index: Int) -> String {
        let cal = Calendar.current
        let symbols = cal.shortWeekdaySymbols
        return symbols[(index + cal.firstWeekday - 1) % 7]
    }
}

// MARK: - Daily usage chart (area chart like the console)

public struct DailyUsageChart: View {
    public var points: [DayPoint]
    public var metric: UsageHistory.Metric
    public var showAxes: Bool
    public var stacked: Bool

    public init(points: [DayPoint], metric: UsageHistory.Metric, showAxes: Bool = true, stacked: Bool = false) {
        self.points = points
        self.metric = metric
        self.showAxes = showAxes
        self.stacked = stacked
    }

    public var body: some View {
        Chart(points) { p in
            if stacked {
                BarMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value))
                    .foregroundStyle(by: .value("Provider", p.provider.shortName))
                    .cornerRadius(2)
            } else {
                AreaMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value),
                         stacking: .unstacked)
                    .foregroundStyle(by: .value("Provider", p.provider.shortName))
                    .interpolationMethod(.monotone)
                    .opacity(0.15)
                LineMark(x: .value("Day", p.date, unit: .day), y: .value(metric.title, p.value))
                    .foregroundStyle(by: .value("Provider", p.provider.shortName))
                    .interpolationMethod(.monotone)
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
            }
        }
        .chartForegroundStyleScale(domain: ProviderID.allCases.map(\.shortName),
                                   range: ProviderID.allCases.map(\.tint))
        .chartLegend(showAxes ? .visible : .hidden)
        .chartXAxis(showAxes ? .automatic : .hidden)
        .chartYAxis {
            if showAxes {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                    AxisValueLabel {
                        if let v = value.as(Double.self) { Text(Fmt.metric(v, metric)) }
                    }
                }
            }
        }
    }
}
