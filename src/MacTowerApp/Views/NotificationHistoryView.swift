import MacTowerCore
import SwiftUI

struct NotificationHistoryView: View {
    @ObservedObject var daemon: DaemonClient
    @StateObject private var presentation = NotificationHistoryPresentationModel()

    private var filteredRecords: [NotificationRecord] {
        let query = presentation.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return daemon.notificationHistory }
        return daemon.notificationHistory.filter { record in
            record.event.sourceID.rawValue.localizedCaseInsensitiveContains(query)
                || record.event.title.localizedCaseInsensitiveContains(query)
                || record.event.message.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField(
                    "Filter loaded history",
                    text: Binding(
                        get: { presentation.search },
                        set: { presentation.search = $0 })
                )
                .textFieldStyle(.roundedBorder)
                Button("Reload") {
                    Task { await daemon.loadNotificationHistory(limit: 100) }
                }
                .disabled(daemon.isBusy)
            }
            .padding()

            Divider()

            if filteredRecords.isEmpty {
                ContentUnavailableView(
                    presentation.search.isEmpty
                        ? "No notifications" : "No matching notifications",
                    systemImage: "bell.slash"
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filteredRecords, id: \.event.eventID) { record in
                    NotificationHistoryRow(record: record, daemon: daemon)
                }
            }

            if let cursor = daemon.notificationHistoryNextCursor {
                Divider()
                Button("Load older") {
                    Task {
                        await daemon.loadNotificationHistory(
                            limit: 100, before: cursor, append: true)
                    }
                }
                .disabled(daemon.isBusy)
                .padding(8)
            }
        }
        .task {
            if daemon.notificationHistory.isEmpty {
                await daemon.loadNotificationHistory(limit: 100)
            }
        }
    }
}

@MainActor
private final class NotificationHistoryPresentationModel: ObservableObject {
    @Published var search = ""
}

private struct NotificationHistoryRow: View {
    let record: NotificationRecord
    @ObservedObject var daemon: DaemonClient

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(record.event.title, systemImage: severityIcon)
                    .font(.headline)
                Spacer()
                Text(record.lastSeenAt, format: .dateTime.month().day().hour().minute())
                    .foregroundStyle(.secondary)
            }
            Text(record.event.message)
                .lineLimit(3)
            HStack {
                Text(record.event.sourceID.rawValue)
                if record.occurrenceCount > 1 {
                    Text("×\(record.occurrenceCount)")
                }
                ForEach(NotificationChannel.allCases, id: \.rawValue) { channel in
                    if let delivery = record.deliveries[channel] {
                        Text(
                            "\(channel.rawValue): \(NotificationPresentation.deliveryLabel(delivery.state))"
                        )
                    }
                }
                Spacer()
                if record.isActive && record.event.severity == .critical {
                    Button("Acknowledge") {
                        Task {
                            await daemon.acknowledgeNotification(eventID: record.event.eventID)
                            await daemon.loadNotificationHistory(limit: 100)
                        }
                    }
                    .disabled(daemon.isBusy)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var severityIcon: String {
        switch record.event.severity {
        case .info: "info.circle"
        case .warning: "exclamationmark.triangle"
        case .critical: "exclamationmark.octagon.fill"
        }
    }
}
