import SwiftUI

/// Shown until the operator picks a server (and again whenever they switch).
struct ServerSelectionView: View {
    @ObservedObject var store: ServerStore
    @State private var input: String
    @State private var errorMessage: String?
    @FocusState private var focused: Bool

    init(store: ServerStore) {
        self.store = store
        _input = State(initialValue: store.suggestion?.absoluteString ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("syrus.example.com", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .submitLabel(.go)
                        .focused($focused)
                        .onSubmit(connect)
                        .accessibilityIdentifier("server-url-field")
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                            .accessibilityIdentifier("server-url-error")
                    }
                } header: {
                    Text("Syrus server")
                } footer: {
                    Text("Enter the address you use in the browser. Hosts without a scheme use https, except localhost and private network addresses, which use http.")
                }

                Section {
                    Button("Connect", action: connect)
                        .accessibilityIdentifier("connect-button")
                }

                if !store.recents.isEmpty {
                    Section("Recent servers") {
                        ForEach(store.recents, id: \.self) { server in
                            Button {
                                store.select(server)
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(server.host)
                                    Text(server.absoluteString).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .swipeActions { Button("Forget", role: .destructive) { store.forget(server) } }
                        }
                    }
                }
            }
            .navigationTitle("Connect to Syrus")
        }
    }

    private func connect() {
        switch ServerURL.parse(input) {
        case .success(let server):
            errorMessage = nil
            store.select(server)
        case .failure(let error):
            errorMessage = ServerSelectionView.message(for: error)
        }
    }

    static func message(for error: ServerURL.ParseError) -> String {
        switch error {
        case .empty: return "Enter a server address."
        case .invalid: return "That doesn't look like a valid address."
        case .unsupportedScheme(let scheme): return "Unsupported scheme “\(scheme)”. Use http or https."
        }
    }
}
