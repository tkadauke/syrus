import SwiftUI

@main
struct SyrusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var serverStore = ServerStore()
    @StateObject private var pushManager = PushManager()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(serverStore)
                .environmentObject(pushManager)
                .onAppear { appDelegate.pushManager = pushManager }
        }
    }
}
