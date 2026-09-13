import Charts
import FSMetricsCore
import SwiftUI

// MARK: - Dashboard

/// A Grafana-style operations dashboard: a stat strip of headline numbers,
/// then collapsible rows of panels ordered by how urgently an admin needs
/// them — overview, volumes, performance, capacity, shared storage, alerts.
///
/// Every panel is scoped by the single volume picker in the header, the way a
/// Grafana template variable scopes a whole dashboard at once.
struct DashboardView: View {
    @Bindable var model: AppModel

    private static let tileColumns = [GridItem(.adaptive(minimum: 190), spacing: 10)]
    private static let chartColumns = [GridItem(.adaptive(minimum: 380), spacing: 10)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                statStrip
                volumesSection
                performanceSection
                capacitySection
                if !model.nfs.isEmpty { sharedStorageSection }
                alertsSection
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color.fsCanvas)
        .preferredColorScheme(.dark)
        .frame(minWidth: 900, minHeight: 620)
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
        .onChange(of: model.selectedVolume) {
            Task { await model.refresh() }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            VStack(alignment: .leading, spacing: 1) {
                Text("macOS_FSMetrics")
                    .font(.system(size: 17, weight: .semibold))
                Text(model.settings.hostLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider().frame(height: 26)

            // The Grafana "template variable" — one picker, whole dashboard.
            HStack(spacing: 6) {
                Text("VOLUME")
                    .font(.system(size: 10, weight: .semibold))
                    .tracking(0.6)
                    .foregroundStyle(.secondary)
                if model.volumeNames.isEmpty {
                    Text("none")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                } else {
                    Picker("Volume", selection: $model.selectedVolume) {
                        ForEach(model.volumeNames, id: \.self) { name in
                            Text(name).tag(name as String?)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 240)
                }
            }

            Spacer()

            if model.isCollecting {
                ProgressView()
                    .controlSize(.small)
            }

            Label("Last 1 hour", systemImage: "clock")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.fsPanel, in: RoundedRectangle(cornerRadius: 5))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(Color.fsPanelBorder, lineWidth: 1)
                )

            Text(model.lastRefresh.map { MetricsFormat.time($0) } ?? "—")
                .font(.system(size: 11))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Stat strip

    /// The headline row. These are the numbers that have to be readable from
    /// the back of a room, so they get the largest type on the screen.
    private var statStrip: some View {
        LazyVGrid(columns: Self.tileColumns, spacing: 10) {
            StatTile(
                title: "Capacity used",
                value: MetricsFormat.pct(model.fleetUsedPct),
                caption: model.fleetUsedBytes.map {
                    "\(MetricsFormat.bytes($0)) of \(MetricsFormat.bytes(model.fleetTotalBytes))"
                } ?? "no capacity sample",
                level: model.fleetCapacitySeverity,
                symbol: "internaldrive",
                spark: model.capacityPoints,
                sparkColor: model.fleetCapacitySeverity.color
            )

            StatTile(
                title: "Throughput",
                value: MetricsFormat.stat(model.focusedVolume?.throughputGbps),
                caption: "GB/s · \(MetricsFormat.age(secondsAgo: model.focusedVolume?.throughputAgeSeconds))",
                level: model.throughputSeverity,
                symbol: "speedometer",
                spark: model.throughputPoints,
                sparkColor: .fsAccent
            )

            StatTile(
                title: "IOPS",
                value: MetricsFormat.count(model.latestIOPS),
                caption: model.latestIOSizeKB.map {
                    "transfers/s · \(MetricsFormat.stat($0, decimals: 0)) KB avg"
                } ?? "transfers/s",
                level: model.latestIOPS == nil ? StatusLevel.none : .ok,
                symbol: "arrow.left.arrow.right",
                spark: model.iopsPoints,
                sparkColor: .fsCyan
            )

            StatTile(
                title: "Free space",
                value: MetricsFormat.bytes(model.fleetFreeBytes),
                caption: "across \(model.localVolumeCount) local volume\(model.localVolumeCount == 1 ? "" : "s")",
                level: model.fleetCapacitySeverity == .critical ? .critical : StatusLevel.none,
                symbol: "externaldrive.badge.checkmark",
                spark: [],
                sparkColor: .fsPurple
            )

            StatTile(
                title: "Health",
                value: "\(model.healthyVolumeCount)/\(model.volumes.count)",
                caption: model.healthSeverity == .critical ? "volume needs attention" : "volumes healthy",
                level: model.healthSeverity,
                symbol: "heart.text.square",
                spark: []
            )

            StatTile(
                title: "Active alerts",
                value: "\(model.activeAlerts.count)",
                caption: model.activeAlerts.isEmpty ? "nothing firing" : "in the alert window",
                level: model.activeAlertSeverity,
                symbol: "bell",
                spark: []
            )
        }
    }

    // MARK: Volumes

    private var volumesSection: some View {
        SectionRow("Volumes", subtitle: "capacity and health per mount") {
            Panel("Volume status") {
                if model.volumes.isEmpty {
                    Text("No data yet — run a collection cycle.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, minHeight: 80)
                } else {
                    VStack(spacing: 14) {
                        // Radial gauges read fastest when several volumes sit
                        // side by side.
                        HStack(alignment: .top, spacing: 8) {
                            ForEach(model.volumes) { volume in
                                CapacityGauge(
                                    label: volume.label,
                                    sublabel: MetricsFormat.bytes(volume.freeBytes) + " free",
                                    pct: volume.displayUsedPct,
                                    level: volume.capacitySeverity(thresholds: model.settings.thresholds)
                                )
                            }
                            if model.volumes.count < 3 { Spacer() }
                        }

                        Divider().overlay(Color.fsPanelBorder)

                        VStack(spacing: 0) {
                            ForEach(model.volumes) { volume in
                                VolumeRow(
                                    volume: volume,
                                    thresholds: model.settings.thresholds,
                                    isSelected: volume.path == model.selectedVolume
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { model.selectedVolume = volume.path }
                                if volume.id != model.volumes.last?.id {
                                    Divider().overlay(Color.fsPanelBorder)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: Performance

    private var performanceSection: some View {
        SectionRow("Performance", subtitle: model.selectedVolume) {
            LazyVGrid(columns: Self.chartColumns, spacing: 10) {
                TimeSeriesPanel(
                    title: "Throughput",
                    unit: "GB/s",
                    points: model.throughputPoints,
                    color: .fsAccent,
                    emptyText: "No I/O samples in the last hour"
                )
                TimeSeriesPanel(
                    title: "IOPS",
                    unit: "transfers/s",
                    points: model.iopsPoints,
                    color: .fsCyan,
                    emptyText: "No transfer samples in the last hour"
                )
                TimeSeriesPanel(
                    title: "Average I/O size",
                    unit: "KB/transfer",
                    points: model.ioSizePoints,
                    color: .fsPurple,
                    emptyText: "No transfer samples in the last hour"
                )
            }
        }
    }

    // MARK: Capacity

    private var capacitySection: some View {
        SectionRow("Capacity", subtitle: "last scan \(model.lastScanDescription)") {
            LazyVGrid(columns: Self.chartColumns, spacing: 10) {
                TimeSeriesPanel(
                    title: "Capacity used over time",
                    unit: "%",
                    points: model.capacityPoints,
                    color: .fsWarn,
                    emptyText: "No capacity samples in the last 6 hours",
                    yDomain: 0...100,
                    thresholds: (
                        warn: model.settings.thresholds.capacityPctWarn,
                        crit: model.settings.thresholds.capacityPctCrit
                    )
                )
                UsersPanel(model: model)
            }
        }
    }

    // MARK: Shared storage

    private var sharedStorageSection: some View {
        SectionRow("Shared storage", subtitle: "NFS / pNFS client state") {
            Panel("Mounts") {
                VStack(spacing: 0) {
                    ForEach(model.nfs) { mount in
                        NFSRow(mount: mount)
                        if mount.id != model.nfs.last?.id {
                            Divider().overlay(Color.fsPanelBorder)
                        }
                    }
                }
            }
        }
    }

    // MARK: Alerts

    private var alertsSection: some View {
        SectionRow("Alerts", subtitle: model.alerts.isEmpty ? "none recorded" : "\(model.alerts.count) recent") {
            AlertsPanel(model: model)
        }
    }
}

// MARK: - Volume row

struct VolumeRow: View {
    let volume: VolumeSummary
    let thresholds: AlertThresholds
    let isSelected: Bool

    private var severity: StatusLevel {
        volume.capacitySeverity(thresholds: thresholds)
    }

    /// Container usage is the meaningful number on APFS (all volumes share
    /// the same free space); the volume's own allocation is context.
    private var capacityDetail: String {
        let throughput = MetricsFormat.gbps(volume.throughputGbps)
        if volume.container != nil,
           let used = volume.displayCapacityUsedBytes,
           let total = volume.containerTotalBytes ?? volume.totalBytes {
            var detail = "\(MetricsFormat.bytes(used)) used of \(MetricsFormat.bytes(total)) (container)"
            if let own = volume.usedBytes {
                detail += " · \(MetricsFormat.bytes(own)) on this volume"
            }
            return "\(detail) · \(throughput)"
        }
        return "\(MetricsFormat.bytes(volume.displayUsedBytes)) used of \(MetricsFormat.bytes(volume.totalBytes)) · \(throughput)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(max(severity, volume.healthSeverity()).color)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(volume.label)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    if volume.kind == .nfs || volume.kind == .smb {
                        Badge(text: volume.kind.rawValue.uppercased(), level: StatusLevel.none)
                    }
                    if volume.smartOK == false {
                        Badge(text: "SMART FAIL", level: .critical)
                    }
                    if volume.writable == false {
                        Badge(text: "READ-ONLY", level: .warning)
                    }
                }
                Text(capacityDetail)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 10)

            UsedBar(pct: volume.displayUsedPct, level: severity, width: 120)
            Text(MetricsFormat.pct(volume.displayUsedPct))
                .font(.system(size: 11, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(severity.color)
                .frame(width: 52, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .background(isSelected ? Color.white.opacity(0.04) : .clear)
    }
}

// MARK: - NFS row

struct NFSRow: View {
    let mount: NFSSummary

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(mount.severity.color)
                .frame(width: 7, height: 7)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(mount.label)
                        .font(.system(size: 12))
                    if mount.pnfsEnabled == true {
                        Badge(text: "pNFS", level: .ok)
                    }
                }
                Text(mount.mountOK == false ? "mount is down" : "mount is up")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 10)

            MetricPill(label: "timeouts", value: MetricsFormat.count(mount.timeouts),
                        level: (mount.timeouts ?? 0) > 0 ? .warning : .ok)
            MetricPill(label: "retransmits", value: MetricsFormat.count(mount.retransmits),
                        level: (mount.retransmits ?? 0) > 0 ? .warning : .ok)
        }
        .padding(.vertical, 7)
    }
}

struct MetricPill: View {
    let label: String
    let value: String
    let level: StatusLevel

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
            Text(value)
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(level.color)
            Text(label.uppercased())
                .font(.system(size: 9))
                .tracking(0.4)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 84, alignment: .trailing)
    }
}

// MARK: - Time series panel

/// One Grafana time-series panel: gradient area under a line, muted grid,
/// optional threshold rules drawn across the plot.
struct TimeSeriesPanel: View {
    let title: String
    let unit: String
    let points: [ChartPoint]
    let color: Color
    let emptyText: String
    var yDomain: ClosedRange<Double>? = nil
    var thresholds: (warn: Double, crit: Double)? = nil

    var body: some View {
        Panel(title, accessory: {
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
        }) {
            if points.isEmpty {
                EmptyChartPlaceholder(text: emptyText)
            } else {
                Chart {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value("Time", point.ts),
                            y: .value(unit, point.value)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [color.opacity(0.35), color.opacity(0.02)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Time", point.ts),
                            y: .value(unit, point.value)
                        )
                        .foregroundStyle(color)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                        .interpolationMethod(.monotone)
                    }

                    // Threshold lines make the capacity chart self-explaining:
                    // the audience can see how close the volume is to the
                    // configured warn/critical levels without reading Settings.
                    if let thresholds {
                        RuleMark(y: .value("Warn", thresholds.warn))
                            .foregroundStyle(Color.fsWarn.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        RuleMark(y: .value("Critical", thresholds.crit))
                            .foregroundStyle(Color.fsCrit.opacity(0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    }
                }
                .chartYScale(domain: yDomain ?? 0...Self.upperBound(for: points))
                .fsChartAxes()
                .frame(height: 180)
            }
        }
    }

    private static func upperBound(for points: [ChartPoint]) -> Double {
        let maximum = points.map(\.value).max() ?? 0
        return max(0.1, maximum * 1.2)
    }
}
