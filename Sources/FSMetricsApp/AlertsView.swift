import SwiftUI

/// Recent alerts: the native translation of the Flask "Recent alerts" table,
/// with the whole row colored by severity as the Flask CSS did.
struct AlertsPanel: View {
    let model: AppModel

    var body: some View {
        Panel("Recent alerts") {
            if model.alerts.isEmpty {
                Text("No alerts yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    alertHeader
                    Divider()
                    ForEach(model.alerts) { alert in
                        AlertRowView(alert: alert)
                        Divider()
                    }
                }
            }
        }
    }

    private var alertHeader: some View {
        HStack(spacing: 10) {
            Text("Time").frame(width: 90, alignment: .leading)
            Text("Severity").frame(width: 70, alignment: .leading)
            Text("Volume").frame(width: 180, alignment: .leading)
            Text("Category").frame(width: 100, alignment: .leading)
            Text("Message").frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.vertical, 4)
    }
}

struct AlertRowView: View {
    let alert: AlertRow

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(MetricsFormat.time(alert.ts))
                .monospacedDigit()
                .frame(width: 90, alignment: .leading)
            Text(alert.severity.rawValue.uppercased())
                .fontWeight(.semibold)
                .frame(width: 70, alignment: .leading)
            Text(alert.volume)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: 180, alignment: .leading)
            Text(alert.category)
                .frame(width: 100, alignment: .leading)
            Text(alert.message)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
        .foregroundStyle(alert.severity == .critical ? Color.fsCrit : Color.fsWarn)
        .textSelection(.enabled)
        .padding(.vertical, 4)
    }
}
