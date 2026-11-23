import SwiftUI

@main
struct SyrusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = ServerStore()
    @StateObject private var web = WebController()

    var body: some Scene {
        WindowGroup {
            RootView(store: store, web: web, push: appDelegate.push)
        }
    }
}
