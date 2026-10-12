import SwiftUI

struct ContentView: View {
    @Bindable var store: NetworkStore = NetworkStore(usePreviewData: true)

    var body: some View {
        NavigationStack {
            Group {
                if store.networks.isEmpty && !store.isLoading {
                    emptyStateView
                } else {
                    networkListView
                }
            }
            .navigationTitle("nTails")
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button {
                        store.showingSettingsSheet = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .help("Proxy and SSH Settings")

                    Button {
                        store.showingAddSheet = true
                    } label: {
                        Label("Log In to Network", systemImage: "plus")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("Log in to an official Tailscale or self-hosted Headscale network")
                }
            }
            .sheet(isPresented: $store.showingAddSheet) {
                AddNetworkSheet { controlUrl in
                    store.loginNetwork(controlUrl: controlUrl)
                }
            }
            .sheet(item: $store.activeLoginNetwork) { network in
                LoginSheet(
                    network: network,
                    onConnectedSimulated: {
                        store.simulateConnected(id: network.id)
                    }
                )
            }
            .sheet(isPresented: $store.showingSettingsSheet) {
                SettingsSheet(
                    currentSettings: store.settings
                ) { updated in
                    store.saveSettings(updated)
                }
            }
            .confirmationDialog(
                "Log Out of Network",
                isPresented: Binding(
                    get: { store.networkToLogout != nil },
                    set: { if !$0 { store.networkToLogout = nil } }
                ),
                presenting: store.networkToLogout
            ) { network in
                Button("Log Out of \(network.displayName)", role: .destructive) {
                    store.logoutNetwork(id: network.id)
                }
                Button("Cancel", role: .cancel) {
                    store.networkToLogout = nil
                }
            } message: { network in
                Text("Logging out tears down the connection, forgets your session with the coordination server, and removes this network from nTails.")
            }
            .alert(
                "Backend Error",
                isPresented: Binding(
                    get: { store.errorMessage != nil },
                    set: { if !$0 { store.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {
                    store.errorMessage = nil
                }
            } message: {
                if let msg = store.errorMessage {
                    Text(msg)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 340)
    }

    private var emptyStateView: some View {
        VStack(spacing: 16) {
            Image(systemName: "point.3.filled.connected.trianglepath.dotted")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            VStack(spacing: 6) {
                Text("No Tailnets Connected")
                    .font(.title3.weight(.medium))

                Text("Log in to an official Tailscale or Headscale network to start routing local traffic.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 320)
            }

            Button {
                store.showingAddSheet = true
            } label: {
                Label("Log In to Tailnet", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .padding(.top, 4)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var networkListView: some View {
        List {
            Section {
                ForEach(store.networks) { network in
                    NetworkRowView(
                        network: network,
                        onConnect: {
                            store.connectNetwork(id: network.id)
                        },
                        onDisconnect: {
                            store.disconnectNetwork(id: network.id)
                        },
                        onSelectLogin: {
                            store.activeLoginNetwork = network
                        },
                        onRequestLogout: {
                            store.networkToLogout = network
                        }
                    )
                }
            } header: {
                HStack {
                    Text("Connected Networks")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    if store.isLoading {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
            }
        }
        .listStyle(.inset(alternatesRowBackgrounds: true))
    }
}

#Preview {
    ContentView()
}
