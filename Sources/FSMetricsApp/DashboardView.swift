import Charts
import FSMetricsCore
import SwiftUI

// MARK: - Flask palette

extension Color {
    static let fsOK = Color(red: 63.0 / 255.0, green: 185.0 / 255.0, blue: 80.0 / 255.0)
    static let fsWarn = Color(red: 210.0 / 255.0, green: 153.0 / 255.0, blue: 34.0 / 255.0)
    static let fsCrit = Color(red: 248.0 / 255.0, green: 81.0 / 255.0, blue: 73.0 / 255.0)
    static let fsAccent = Color(red: 88.0 / 255.0, green: 166.0 / 255.0, blue: 255.0 / 255.0)
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

// MARK: - Dashboard

/// SwiftUI translation of the retired Flask admin page: volume cards,
/// throughput and capacity history charts, the per-user table, and alerts.
struct DashboardView: View {
    let model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                volumesSection
                chartsSection
                UsersPanel(model: model)
                AlertsPanel(model: model)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 780, minHeight: 560)
        .toolbar {
            ToolbarItem {
                Button {
                    Task { await model.runOnce() }
                } label: {
                    Label("Collect Now", systemImage: "arrow.clockwise")
                }
                .disabled(model.isCollecting)
                .help("Run a full collection cycle now")
            }
        }
        .onChange(of: model.selectedThroughputVolume) {
            Task { await model.refresh() }
        }
        .onChange(of: model.selectedCapacityVolume) {
            Task { await model.refresh() }
        }
        .onChange(of: model.selectedUsersVolume) {
            Task { await model.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("macOS FS Metrics — Admin Dashboard")
                    .font(.title2)
                    .fontWeight(.semibold)
                Text("\(model.settings.hostLabel) — local + shared volume monitoring")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(model.lastRefresh.map { "last refreshed \(MetricsFormat.time($0))" } ?? "refreshing…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var volumesSection: some View {
        Panel("Volumes") {
            if model.volumes.isEmpty {
                Text("No data yet — run a collection cycle.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(
                    columns: [GridItem(.adaptive(minimum: 360), spacing: 12)],
                    spacing: 12
                ) {
                    ForEach(model.volumes) { volume in
                        VolumeCard(volume: volume, thresholds: model.settings.thresholds)
                    }
                }
            }
        }
    }

    private var chartsSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 420), spacing: 16)],
            spacing: 16
        ) {
            ThroughputPanel(model: model)
            CapacityPanel(model: model)
        }
    }
}

// MARK: - Volume card

struct VolumeCard: View {
    let volume: VolumeSummary
    let thresholds: AlertThresholds

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text(volume.label).font(.headline)
                if volume.smartOK == false {
                    Badge(text: "SMART FAIL", level: .critical)
                }
                if volume.writable == false {
                    Badge(text: "READ-ONLY", level: .critical)
                }
                Spacer()
                if volume.kind == .nfs {
                    Text(volume.kind.rawValue.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 6) {
                GridRow {
                    Text("\(MetricsFormat.bytes(volume.displayUsedBytes)) used of \(MetricsFormat.bytes(volume.totalBytes))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    UsedBar(
                        pct: volume.usedPct,
                        level: volume.capacitySeverity(thresholds: thresholds)
                    )
                    Badge(
                        text: MetricsFormat.pct(volume.usedPct),
                        level: volume.capacitySeverity(thresholds: thresholds)
                    )
                }
                GridRow {
                    Text(throughputDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .gridCellColumns(3)
                }
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
    }

    private var throughputDescription: String {
        guard let value = volume.throughputGbps else { return "no I/O sample" }
        let age = MetricsFormat.age(secondsAgo: volume.throughputAgeSeconds)
        return "\(MetricsFormat.gbps(value)) · \(age)"
    }
}

// MARK: - Charts

struct ThroughputPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Panel("Throughput (GB/s)") {
            VolumeSelectorHeader(
                selection: $model.selectedThroughputVolume,
                names: model.volumeNames
            )
            if model.throughputPoints.isEmpty {
                EmptyChartPlaceholder(text: "No I/O samples in the last hour")
            } else {
                Chart(model.throughputPoints) { point in
                    LineMark(
                        x: .value("Time", point.ts),
                        y: .value("GB/s", point.value)
                    )
                    .foregroundStyle(Color.fsAccent)
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...Self.upperBound(for: model.throughputPoints))
                .frame(height: 200)
            }
        }
    }

    private static func upperBound(for points: [ChartPoint]) -> Double {
        let maximum = points.map(\.value).max() ?? 0
        return max(0.1, (maximum * 1.1).rounded(.up))
    }
}

struct CapacityPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Panel("Capacity over time (%)") {
            VolumeSelectorHeader(
                selection: $model.selectedCapacityVolume,
                names: model.volumeNames
            )
            if model.capacityPoints.isEmpty {
                EmptyChartPlaceholder(text: "No capacity samples in the last 6 hours")
            } else {
                Chart(model.capacityPoints) { point in
                    LineMark(
                        x: .value("Time", point.ts),
                        y: .value("% used", point.value)
                    )
                    .foregroundStyle(Color.fsWarn)
                    .interpolationMethod(.monotone)
                }
                .chartYScale(domain: 0...100)
                .frame(height: 200)
            }
        }
    }
}

/// Flask's `<select>` above each chart.
struct VolumeSelectorHeader: View {
    @Binding var selection: String?
    let names: [String]

    var body: some View {
        HStack {
            Spacer()
            if names.isEmpty {
                Text("no volumes")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Picker("Volume", selection: $selection) {
                    ForEach(names, id: \.self) { name in
                        Text(name).tag(name as String?)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 260)
            }
        }
    }
}

// MARK: - Shared chrome

struct Panel<Content: View>: View {
    let title: String
    let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased())
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .tracking(0.5)
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(.quaternary))
    }
}

struct Badge: View {
    let text: String
    let level: StatusLevel

    var body: some View {
        Text(text)
            .font(.caption2)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(level.color.opacity(0.18), in: Capsule())
            .foregroundStyle(level.color)
    }
}

/// The Flask `.bar-bg` / `.bar-fill` capacity bar.
struct UsedBar: View {
    let pct: Double?
    let level: StatusLevel

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(level.color)
                    .frame(width: proxy.size.width * clampedFraction)
            }
        }
        .frame(width: 140, height: 8)
    }

    private var clampedFraction: Double {
        min(max((pct ?? 0) / 100, 0), 1)
    }
}

struct EmptyChartPlaceholder: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 200)
    }
}
