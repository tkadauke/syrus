import SwiftUI

@main
struct SyrusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .task { await model.push.refreshAuthorization() }
                .onChange(of: scenePhase) { _, phase in
                    guard phase == .active else { return }
                    Task { await model.push.refreshAuthorization() }
                    model.syncPush()
                }
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if let server = model.servers.selected {
            WebContainerView(
                server: server,
                model: model.web,
                onSwitchServer: { Task { await model.switchServer() } },
                onEnableNotifications: { Task { await model.push.enableNotifications() } },
                onShowDiagnostics: { model.showsDiagnostics = true },
                notificationsStatus: model.push.statusLabel
            )
            .task(id: server) { model.connect() }
            .sheet(isPresented: $model.showsDiagnostics) { DiagnosticsView(model: model) }
        } else {
            ConnectionView(store: model.servers)
        }
    }
}
