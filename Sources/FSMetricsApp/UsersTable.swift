import SwiftUI

/// Per-user capacity attribution: the native `Table` translation of the Flask
/// "Per-user usage" panel. Rows are already sorted descending by bytes by
/// `DashboardLoader`, using the newest `capacity.user_bytes` sample per uid.
struct UsersPanel: View {
    @Bindable var model: AppModel

    var body: some View {
        Panel("Per-user usage") {
            VolumeSelectorHeader(
                selection: $model.selectedUsersVolume,
                names: model.volumeNames
            )
            if model.users.isEmpty {
                Text("No per-user data yet")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                Table(model.users) {
                    TableColumn("User") { user in
                        Text(user.displayName)
                    }
                    TableColumn("UID") { user in
                        Text(user.uid).monospacedDigit()
                    }
                    TableColumn("Bytes used") { user in
                        Text(MetricsFormat.bytes(user.bytes)).monospacedDigit()
                    }
                }
                .frame(height: 200)
            }
        }
    }
}
