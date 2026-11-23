import SwiftUI

/// Chooses between server selection and the web shell.
struct RootView: View {
    @EnvironmentObject private var store: ServerStore

    var body: some View {
        if let server = store.selected {
            WebShellView(server: server).id(server)
        } else {
            ServerSelectionView()
        }
    }
}
