import AppKit
import SwiftUI

/// The menu-bar status item's title: severity symbol plus the latest
/// throughput, so the worst state is visible without opening the menu.
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        Label(model.menuBarTitle, systemImage: model.worstSeverity.symbolName)
    }
}

/// Contents of the menu-bar dropdown (`.window` style).
struct MenuBarView: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            statusGrid

            if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(Color.fsCrit)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack(spacing: 8) {
                Button("Open Dashboard") { openDashboard() }
                Spacer()
                Button(model.isCollecting ? "Collecting…" : "Collect Now") {
                    Task { await model.runOnce() }
                }
                .disabled(model.isCollecting)
                .help("Run a full collection cycle now")
            }

            HStack(spacing: 8) {
                SettingsLink { Text("Settings…") }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 320)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.worstSeverity.symbolName)
                .foregroundStyle(model.worstSeverity.color)
            VStack(alignment: .leading, spacing: 1) {
                Text("macOS FS Metrics").font(.headline)
                Text(model.settings.hostLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusGrid: some View {
        Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 4) {
            GridRow {
                Text("Status").foregroundStyle(.secondary)
                Text(model.worstSeverity.label)
                    .fontWeight(.semibold)
                    .foregroundStyle(model.worstSeverity.color)
            }
            GridRow {
                Text("Throughput").foregroundStyle(.secondary)
                Text(MetricsFormat.gbps(model.latestThroughput))
            }
            GridRow {
                Text("Capacity scan").foregroundStyle(.secondary)
                Text(model.lastScanDescription)
            }
        }
        .font(.callout)
    }

    private func openDashboard() {
        openWindow(id: WindowID.dashboard)
        NSApp.activate()
    }
}
