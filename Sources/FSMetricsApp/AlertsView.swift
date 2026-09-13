import SwiftUI

/// Recent alerts, styled as a Grafana alert list: a severity chip per row
/// instead of coloring the whole line, so long messages stay readable while
/// severity still reads instantly down the left edge.
struct AlertsPanel: View {
    let model: AppModel

    private var criticalCount: Int {
        model.alerts.filter { $0.severity == .critical }.count
    }

    private var warningCount: Int {
        model.alerts.count - criticalCount
    }

    var body: some View {
        Panel("Recent alerts", accessory: {
            HStack(spacing: 6) {
                if criticalCount > 0 {
                    Badge(text: "\(criticalCount) critical", level: .critical)
                }
                if warningCount > 0 {
                    Badge(text: "\(warningCount) warning", level: .warning)
                }
                if !model.alerts.isEmpty {
                    Button("Clear") {
                        Task { await model.deleteAllAlerts() }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                    .help("Remove all alerts")
                }
            }
        }) {
            if model.alerts.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "checkmark.circle")
                        .font(.system(size: 20))
                        .foregroundStyle(Color.fsOK)
                    Text("No alerts recorded")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 100)
            } else {
                VStack(spacing: 0) {
                    ForEach(model.alerts) { alert in
                        AlertRowView(
                            alert: alert,
                            activityPath: model.activityDirectory(for: alert),
                            onViewActivity: { model.revealActivity(for: alert) },
                            onDismiss: { Task { await model.deleteAlert(alert) } }
                        )
                        if alert.id != model.alerts.last?.id {
                            Divider().overlay(Color.fsPanelBorder)
                        }
                    }
                }
            }
        }
    }
}

struct AlertRowView: View {
    let alert: AlertRow

    /// Directory to reveal when the user clicks View activity; nil hides the button.
    var activityPath: String?
    var onViewActivity: () -> Void = {}
    var onDismiss: () -> Void = {}

    private var level: StatusLevel {
        alert.severity == .critical ? .critical : .warning
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            // Severity stripe: scannable down the left edge of the list.
            RoundedRectangle(cornerRadius: 1.5)
                .fill(level.color)
                .frame(width: 3)
                .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Badge(text: alert.severity.rawValue.uppercased(), level: level, filled: true)
                    Text(alert.category)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(alert.volume)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(alert.message)
                    .font(.system(size: 12))
                    .foregroundStyle(.primary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            if let activityPath {
                Button(action: onViewActivity) {
                    Label("View activity", systemImage: "folder")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.fsAccent)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Color.fsAccent.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Reveal \(activityPath) in Finder")
            }

            Text(MetricsFormat.time(alert.ts))
                .font(.system(size: 10))
                .monospacedDigit()
                .foregroundStyle(.tertiary)
                .frame(width: 78, alignment: .trailing)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this alert")
        }
        .padding(.vertical, 8)
        .textSelection(.enabled)
    }
}
