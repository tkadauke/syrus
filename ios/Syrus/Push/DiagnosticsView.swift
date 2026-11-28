import SwiftUI

/// Push-setup diagnostics for physical-device testing: shows where each step
/// (session → permission → APNs token → server sync → delivery → deep link)
/// stands, and can send a test notification to the signed-in user's device.
/// Shows no secrets and never a full device token.
struct DiagnosticsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var push: PushCoordinator
    @Environment(\.dismiss) private var dismiss

    init(model: AppModel) {
        self.model = model
        _push = ObservedObject(wrappedValue: model.push)
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Push setup") {
                    ForEach(push.diagnosticsRows(server: model.servers.selected)) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.title).font(.footnote).foregroundStyle(.secondary)
                            Label(row.value, systemImage: icon(row.status))
                                .foregroundStyle(color(row.status))
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityIdentifier("diagnostics-\(row.title)")
                    }
                }
                Section {
                    Button("Refresh", systemImage: "arrow.clockwise") { Task { await refresh() } }
                    Button("Send test notification", systemImage: "paperplane") { Task { await sendTest() } }
                    if let outcome = push.testOutcome {
                        Text(message(for: outcome)).font(.footnote).accessibilityIdentifier("diagnostics-test-result")
                    }
                } footer: {
                    Text("The test push is sent only to your own registered devices. Tap it to confirm the app opens the Notifications page.")
                }
                .disabled(push.isBusy)
            }
            .navigationTitle("Diagnostics")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done") { dismiss() } }
            .task { await refresh() }
        }
        .accessibilityIdentifier("diagnostics")
    }

    private func refresh() async {
        await push.refreshDiagnostics(server: model.servers.selected, via: model.web)
    }

    private func sendTest() async {
        await push.sendTestNotification(via: model.web)
    }

    private func message(for outcome: TestPushOutcome) -> String {
        switch outcome {
        case .sent(let link): return String(localized: "Sent. Background the app and tap the notification; it should open \(link).")
        case .apnsNotConfigured: return String(localized: "The server has no APNs credentials (SYRUS_APNS_* settings).")
        case .noRegisteredDevice: return String(localized: "The server has no active device for you. Enable notifications, then Refresh.")
        case .signedOut: return String(localized: "You are signed out. Sign in, then try again.")
        case .pageNotReady: return String(localized: "The web page isn’t loaded yet.")
        case .tokenRejected(let reason): return String(localized: "APNs rejected this device’s token (\(reason)). Check the sandbox/production environment and bundle id.")
        case .failed(let detail): return String(localized: "Test push failed: \(detail)")
        }
    }

    private func icon(_ status: DiagnosticsRow.Status) -> String {
        switch status {
        case .ok: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .problem: return "xmark.octagon.fill"
        case .info: return "info.circle"
        }
    }

    private func color(_ status: DiagnosticsRow.Status) -> Color {
        switch status {
        case .ok: return .green
        case .warning: return .orange
        case .problem: return .red
        case .info: return .primary
        }
    }
}
