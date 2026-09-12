import SwiftUI

/// Per-user capacity attribution, drawn as a Grafana bar-gauge list rather
/// than a plain table: each row's bar is scaled against the largest user on
/// the volume, so the distribution is obvious at a glance instead of needing
/// the numbers to be compared by eye.
///
/// Rows arrive already sorted descending by bytes from `DashboardLoader`,
/// using the newest `capacity.user_bytes` sample per uid.
struct UsersPanel: View {
    let model: AppModel

    private var maxBytes: Double {
        model.users.map(\.bytes).max() ?? 1
    }

    private var totalBytes: Double {
        model.users.map(\.bytes).reduce(0, +)
    }

    var body: some View {
        Panel("Per-user usage", accessory: {
            if !model.users.isEmpty {
                Text("\(model.users.count) users · \(MetricsFormat.bytes(totalBytes))")
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
        }) {
            if model.users.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "person.2")
                        .font(.system(size: 18))
                        .foregroundStyle(.tertiary)
                    Text("No per-user data yet — the capacity scan runs on its own interval")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(model.users) { user in
                            UserRow(user: user, maxBytes: maxBytes)
                            if user.id != model.users.last?.id {
                                Divider().overlay(Color.fsPanelBorder)
                            }
                        }
                    }
                }
                .frame(height: 180)
            }
        }
    }
}

struct UserRow: View {
    let user: UserUsage
    let maxBytes: Double

    private var fraction: Double {
        guard maxBytes > 0 else { return 0 }
        return min(max(user.bytes / maxBytes, 0), 1)
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(user.displayName)
                        .font(.system(size: 12))
                        .lineLimit(1)
                    Text("uid \(user.uid)")
                        .font(.system(size: 9))
                        .monospacedDigit()
                        .foregroundStyle(.tertiary)
                }
                // Scaled against the heaviest user, not against the volume:
                // the point of this panel is relative share between users.
                UsedBar(pct: fraction * 100, level: .ok, width: 160, height: 5)
            }

            Spacer(minLength: 8)

            Text(MetricsFormat.bytes(user.bytes))
                .font(.system(size: 12, weight: .medium))
                .monospacedDigit()
                .frame(width: 86, alignment: .trailing)
        }
        .padding(.vertical, 7)
        .padding(.trailing, 2)
    }
}
