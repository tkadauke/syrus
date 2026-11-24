import SwiftUI

/// First screen: choose which Syrus server to load.
struct ConnectionView: View {
    @ObservedObject var store: ServerStore
    @State private var input: String = ServerStore.developmentDefault ?? ""
    @State private var errorMessage: String?
    @FocusState private var fieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("syrus.example.com", text: $input)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.go)
                        .focused($fieldFocused)
                        .onSubmit(connect)
                        .accessibilityIdentifier("server-url-field")
                } header: {
                    Text("Server address")
                } footer: {
                    if let errorMessage {
                        Text(errorMessage).foregroundStyle(.red).accessibilityIdentifier("server-url-error")
                    } else {
                        Text("Enter the address of your Syrus instance. Plain http is only suggested for local development servers.")
                    }
                }

                Section {
                    Button("Connect", action: connect)
                        .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                        .accessibilityIdentifier("connect-button")
                }

                if !store.recent.isEmpty {
                    Section("Recent servers") {
                        ForEach(store.recent, id: \.self) { server in
                            Button(server.description) { store.select(server) }
                                .foregroundStyle(.primary)
                        }
                        .onDelete { offsets in
                            offsets.map { store.recent[$0] }.forEach(store.forget)
                        }
                    }
                }
            }
            .navigationTitle("Connect to Syrus")
        }
    }

    private func connect() {
        do {
            store.select(try ServerURL.parse(input))
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
