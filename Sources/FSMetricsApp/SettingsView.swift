import FSMetricsCore
import SwiftUI

/// Settings scene: volumes, cadences, host label, thresholds, webhook URL,
/// and DB path. Edits are staged in `draft` and persisted through
/// `Settings.save()`; saving rewires and refreshes `AppModel`.
struct SettingsView: View {
    /// Stable-identity wrapper so volume rows stay correct while editing or
    /// deleting (the core `VolumeSettings` has no identity of its own).
    private struct VolumeDraft: Identifiable {
        let id = UUID()
        var settings: VolumeSettings
    }

    let model: AppModel
    @State private var draft: FSMetricsCore.Settings
    @State private var volumeDrafts: [VolumeDraft]
    @State private var savedAt: Date?

    init(model: AppModel) {
        self.model = model
        _draft = State(initialValue: model.settings)
        _volumeDrafts = State(initialValue: model.settings.volumes.map { VolumeDraft(settings: $0) })
    }

    var body: some View {
        Form {
            generalSection
            collectionSection
            volumesSection
            thresholdsSection
            actionsSection
        }
        .formStyle(.grouped)
        .frame(width: 620, height: 640)
    }

    // MARK: - Sections

    private var generalSection: some View {
        Section("General") {
            TextField("Host label", text: $draft.hostLabel)
            TextField("Database path", text: $draft.dbPath)
            TextField("Webhook URL", text: webhookBinding, prompt: Text("https://hooks.example.com/…"))
        }
    }

    private var collectionSection: some View {
        Section("Collection cadence") {
            TextField("Poll interval (seconds)", value: $draft.pollIntervalSeconds, format: .number)
            TextField(
                "Capacity scan interval (seconds)",
                value: $draft.capacityScanIntervalSeconds,
                format: .number
            )
        }
    }

    private var volumesSection: some View {
        Section("Volumes") {
            ForEach($volumeDrafts) { $volume in
                volumeEditor($volume)
                Divider()
            }
            Button("Add Volume") {
                volumeDrafts.append(VolumeDraft(settings: VolumeSettings(path: "/Volumes/New", kind: .other)))
            }
        }
    }

    private var thresholdsSection: some View {
        Section("Alert thresholds") {
            TextField(
                "Capacity warning (%)",
                value: $draft.thresholds.capacityPctWarn,
                format: .number
            )
            TextField(
                "Capacity critical (%)",
                value: $draft.thresholds.capacityPctCrit,
                format: .number
            )
            TextField(
                "User growth window (seconds)",
                value: $draft.thresholds.userGrowthWindow,
                format: .number
            )
            TextField(
                "User growth threshold (bytes)",
                value: $draft.thresholds.userGrowthThreshold,
                format: .number
            )
            TextField(
                "Throughput stall (seconds)",
                value: $draft.thresholds.throughputStallSeconds,
                format: .number
            )
            TextField(
                "Alert cooldown (seconds)",
                value: $draft.thresholds.cooldown,
                format: .number
            )
        }
    }

    private var actionsSection: some View {
        Section {
            HStack {
                Button("Revert to Saved") { revert() }
                Spacer()
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isDirty)
            }

            if let savedAt {
                Text("Saved \(savedAt.formatted(date: .omitted, time: .standard))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let lastError = model.lastError {
                Text(lastError)
                    .font(.caption)
                    .foregroundStyle(Color.fsCrit)
            }
        }
    }

    // MARK: - Rows

    private func volumeEditor(_ volume: Binding<VolumeDraft>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TextField("Mount path", text: volume.settings.path)
                Picker("Kind", selection: volume.settings.kind) {
                    ForEach(VolumeKind.allCases, id: \.self) { kind in
                        Text(kind.rawValue.uppercased()).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 100)
                Button(role: .destructive) {
                    let id = volume.wrappedValue.id
                    volumeDrafts.removeAll { $0.id == id }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove volume")
            }
            TextField("Label", text: volume.settings.label)
            Toggle("Watch users", isOn: volume.settings.watchUsers)
            TextField("Scan paths (comma separated)", text: scanPathsBinding(volume))
        }
        .padding(.vertical, 4)
    }

    // MARK: - Bindings and actions

    private var webhookBinding: Binding<String> {
        Binding(
            get: { draft.webhookURL ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                draft.webhookURL = trimmed.isEmpty ? nil : trimmed
            }
        )
    }

    private func scanPathsBinding(_ volume: Binding<VolumeDraft>) -> Binding<String> {
        Binding(
            get: { volume.wrappedValue.settings.scanPaths.joined(separator: ", ") },
            set: { newValue in
                volume.wrappedValue.settings.scanPaths = newValue
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            }
        )
    }

    /// The staged settings with the volume editor's rows folded back in.
    private var candidate: FSMetricsCore.Settings {
        var staged = draft
        staged.volumes = volumeDrafts.map(\.settings)
        return staged
    }

    private var isDirty: Bool {
        candidate != model.settings
    }

    private func save() {
        let staged = candidate
        model.save(staged)
        if model.lastError == nil {
            draft = staged
            savedAt = Date()
        }
    }

    private func revert() {
        let loaded = (try? FSMetricsCore.Settings.load()) ?? model.settings
        draft = loaded
        volumeDrafts = loaded.volumes.map { VolumeDraft(settings: $0) }
        savedAt = nil
    }
}
