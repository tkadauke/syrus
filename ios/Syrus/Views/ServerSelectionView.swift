import SwiftUI

struct ServerSelectionView: View {
    @EnvironmentObject private var store: ServerStore
    @State private var input = ""
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("syrus.example.com", text: $input)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .submitLabel(.go)
                        .onSubmit(connect)
                        .accessibilityIdentifier("server-url-field")
                    if let errorMessage {
                        Text(errorMessage).font(.footnote).foregroundStyle(.red)
                    }
                    Button("Connect", action: connect).disabled(input.trimmingCharacters(in: .whitespaces).isEmpty)
                } header: {
                    Text("Server address")
                } footer: {
                    Text("Enter the address of your Syrus server. https is assumed unless it is a local address.")
                }

                if !store.suggestions.isEmpty {
                    Section("Recent") {
                        ForEach(store.suggestions, id: \.self) { url in
                            Button(url.absoluteString) { store.select(url) }
                                .swipeActions { Button("Forget", role: .destructive) { store.forget(url) } }
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
            errorMessage = "That doesn't look like a valid server address."
        }
    }
}
