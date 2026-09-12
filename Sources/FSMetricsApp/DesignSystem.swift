import Charts
import SwiftUI

// MARK: - Palette

/// Grafana's dark-theme palette. Using the same hues an ops audience already
/// reads fluently (green = healthy, amber = warning, red = critical, blue =
/// throughput) means a judge or admin can interpret the screen without a
/// legend.
extension Color {
    // Status. `fsOK` / `fsWarn` / `fsCrit` / `fsAccent` keep their original
    // names because MenuBarView and SettingsView reference them.
    static let fsOK = Color(red: 115.0 / 255.0, green: 191.0 / 255.0, blue: 105.0 / 255.0)
    static let fsWarn = Color(red: 255.0 / 255.0, green: 152.0 / 255.0, blue: 48.0 / 255.0)
    static let fsCrit = Color(red: 242.0 / 255.0, green: 73.0 / 255.0, blue: 92.0 / 255.0)
    static let fsAccent = Color(red: 87.0 / 255.0, green: 148.0 / 255.0, blue: 242.0 / 255.0)

    // Secondary series colors, used so each chart is distinguishable at a
    // glance when several are on screen together.
    static let fsPurple = Color(red: 184.0 / 255.0, green: 119.0 / 255.0, blue: 217.0 / 255.0)
    static let fsCyan = Color(red: 87.0 / 255.0, green: 199.0 / 255.0, blue: 227.0 / 255.0)

    // Chrome.
    static let fsPanel = Color(red: 24.0 / 255.0, green: 27.0 / 255.0, blue: 31.0 / 255.0)
    static let fsPanelBorder = Color(red: 44.0 / 255.0, green: 50.0 / 255.0, blue: 53.0 / 255.0)
    static let fsCanvas = Color(red: 17.0 / 255.0, green: 18.0 / 255.0, blue: 23.0 / 255.0)
    static let fsGrid = Color.white.opacity(0.07)
}

extension StatusLevel {
    var color: Color {
        switch self {
        case .none: return .secondary
        case .ok: return .fsOK
        case .warning: return .fsWarn
        case .critical: return .fsCrit
        }
    }
}

// MARK: - Panel chrome

/// A Grafana panel: thin border, dark fill, small uppercase title bar, and an
/// optional trailing accessory (a picker, a unit hint, a count).
struct Panel<Content: View, Accessory: View>: View {
    let title: String
    let accessory: Accessory
    let content: Content

    init(
        _ title: String,
        @ViewBuilder accessory: () -> Accessory,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .tracking(0.6)
                Spacer(minLength: 8)
                accessory
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider().overlay(Color.fsPanelBorder)

            content
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fsPanel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.fsPanelBorder, lineWidth: 1)
        )
    }
}

extension Panel where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.init(title, accessory: { EmptyView() }, content: content)
    }
}

/// A Grafana "row": a collapsible section divider that groups panels so the
/// dashboard reads as Overview → Performance → Capacity → Alerts instead of
/// one undifferentiated wall of charts.
struct SectionRow<Content: View>: View {
    let title: String
    let subtitle: String?
    @State private var expanded = true
    let content: Content

    init(_ title: String, subtitle: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { expanded.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                    Text(title)
                        .font(.system(size: 13, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                content
            }
        }
    }
}

// MARK: - Stat tile

/// Grafana's "stat" panel: one large threshold-colored number over an optional
/// sparkline. This is the single highest-value element for a room full of
/// people — the headline numbers stay readable from the back.
struct StatTile: View {
    let title: String
    let value: String
    let caption: String?
    let level: StatusLevel
    let symbol: String?
    var spark: [ChartPoint] = []
    var sparkColor: Color = .fsAccent

    private var valueColor: Color {
        level == .none ? .primary : level.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 5) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.system(size: 10, weight: .semibold))
                }
                Text(title.uppercased())
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Text(value)
                .font(.system(size: 30, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .padding(.horizontal, 12)
                .padding(.top, 2)

            if let caption {
                Text(caption)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.top, 1)
            }

            Spacer(minLength: 6)

            Sparkline(points: spark, color: sparkColor)
                .frame(height: 34)
        }
        .frame(height: 124, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.fsPanel, in: RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.fsPanelBorder, lineWidth: 1)
        )
        .overlay(alignment: .top) {
            // Grafana colors the top edge of a stat panel by threshold.
            Rectangle()
                .fill(valueColor)
                .frame(height: 2)
                .opacity(level == .none ? 0 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

/// The filled mini-chart at the bottom of a stat tile. Renders nothing (not
/// even an axis) when there's no data, so an empty tile stays clean.
struct Sparkline: View {
    let points: [ChartPoint]
    let color: Color

    var body: some View {
        if points.count < 2 {
            Color.clear
        } else {
            Chart(points) { point in
                AreaMark(
                    x: .value("Time", point.ts),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [color.opacity(0.45), color.opacity(0.02)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.monotone)

                LineMark(
                    x: .value("Time", point.ts),
                    y: .value("Value", point.value)
                )
                .foregroundStyle(color)
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                .interpolationMethod(.monotone)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            .chartLegend(.hidden)
            .chartYScale(domain: Self.domain(for: points))
        }
    }

    /// Pads the domain slightly so a flat series still draws a visible band
    /// rather than a line pinned to the very bottom or top edge.
    private static func domain(for points: [ChartPoint]) -> ClosedRange<Double> {
        let values = points.map(\.value)
        let low = values.min() ?? 0
        let high = values.max() ?? 1
        if high - low < 0.0001 {
            let pad = max(abs(high) * 0.1, 0.5)
            return (low - pad)...(high + pad)
        }
        let pad = (high - low) * 0.15
        return (low - pad)...(high + pad)
    }
}

// MARK: - Gauge

/// Grafana's radial gauge, used for per-volume capacity. Reads faster than a
/// bar when several volumes sit side by side.
struct CapacityGauge: View {
    let label: String
    let sublabel: String
    let pct: Double?
    let level: StatusLevel

    var body: some View {
        VStack(spacing: 6) {
            Gauge(value: min(max((pct ?? 0) / 100, 0), 1)) {
                EmptyView()
            } currentValueLabel: {
                Text(MetricsFormat.pct(pct))
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(level.color)
            }
            .gaugeStyle(.accessoryCircularCapacity)
            .tint(level.color)
            .scaleEffect(1.15)
            .frame(height: 78)

            Text(label)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(sublabel)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Small parts

struct Badge: View {
    let text: String
    let level: StatusLevel
    var filled: Bool = false

    var body: some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                level.color.opacity(filled ? 0.9 : 0.16),
                in: RoundedRectangle(cornerRadius: 4)
            )
            .foregroundStyle(filled ? Color.black.opacity(0.85) : level.color)
    }
}

/// A horizontal bar gauge — Grafana's "bar gauge" panel, used inline in the
/// volume list and the per-user table.
struct UsedBar: View {
    let pct: Double?
    let level: StatusLevel
    var width: CGFloat = 140
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(Color.white.opacity(0.08))
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(level.color)
                    .frame(width: proxy.size.width * clampedFraction)
            }
        }
        .frame(width: width, height: height)
    }

    private var clampedFraction: Double {
        min(max((pct ?? 0) / 100, 0), 1)
    }
}

struct EmptyChartPlaceholder: View {
    let text: String
    var height: CGFloat = 180

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 18))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, minHeight: height)
    }
}

/// Shared axis styling so every time-series panel looks like it came from the
/// same dashboard.
extension View {
    func fsChartAxes() -> some View {
        chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.fsGrid)
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine().foregroundStyle(Color.fsGrid)
                AxisValueLabel()
                    .font(.system(size: 10))
                    .foregroundStyle(Color.secondary)
            }
        }
    }
}
