import SwiftUI

struct MenuBarView: View {
    @Bindable var store: NetworkStore
    @Environment(\.openWindow) private var openWindow

    private func bringMainWindowToFront() {
        NSApp.activate()
        openWindow(id: "main")
        DispatchQueue.main.async {
            for window in NSApp.windows where window.canBecomeMain {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
            }
        }
    }

    var body: some View {
        VStack {
            if store.networks.isEmpty {
                Text("No Networks Configured")
            } else {
                let connectedCount = store.networks.filter { $0.isConnected }.count
                let disconnectedCount = store.networks.filter { $0.isDisconnected }.count

                Text("\(connectedCount) Connected • \(disconnectedCount) Disconnected")
                    .font(.caption)

                Divider()

                ForEach(store.networks) { network in
                    Menu {
                        if network.isDisconnected {
                            Button("Connect") {
                                store.connectNetwork(id: network.id)
                            }
                        } else if network.isError {
                            Button("Retry") {
                                store.connectNetwork(id: network.id)
                            }
                            Button("Cancel") {
                                store.disconnectNetwork(id: network.id)
                            }
                        } else {
                            Button("Disconnect") {
                                store.disconnectNetwork(id: network.id)
                            }
                        }

                        if network.needsLogin {
                            Button("Sign In…") {
                                bringMainWindowToFront()
                                store.activeLoginNetwork = network
                            }
                        }

                        Divider()

                        Button(role: .destructive) {
                            bringMainWindowToFront()
                            store.networkToLogout = network
                        } label: {
                            Text("Log Out & Remove…")
                        }
                    } label: {
                        HStack {
                            statusIcon(for: network)
                            Text(network.displayName)
                            Spacer()
                            Text(network.statusState.title)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            Button("Open nTails") {
                bringMainWindowToFront()
            }

            Button("Log In to Tailnet…") {
                bringMainWindowToFront()
                store.showingAddSheet = true
            }

            Button("Settings…") {
                bringMainWindowToFront()
                store.showingSettingsSheet = true
            }

            Menu("Proxy Configuration") {
                let effectivePac = store.settings.effective.pac
                if effectivePac > 0 {
                    Button("Copy PAC URL (\(String(effectivePac)))") {
                        let url = "http://127.0.0.1:\(effectivePac)/proxy.pac"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                } else {
                    Button("PAC File (Off)") {}
                        .disabled(true)
                }

                let effectiveSocks = store.settings.effective.socks
                if effectiveSocks > 0 {
                    Button("Copy SOCKS5 URL (\(String(effectiveSocks)))") {
                        let url = "socks5://127.0.0.1:\(effectiveSocks)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                } else {
                    Button("SOCKS5 Proxy (Off)") {}
                        .disabled(true)
                }

                let effectiveHttp = store.settings.effective.http
                if effectiveHttp > 0 {
                    Button("Copy HTTP Proxy URL (\(String(effectiveHttp)))") {
                        let url = "http://127.0.0.1:\(effectiveHttp)"
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url, forType: .string)
                    }
                } else {
                    Button("HTTP Proxy (Off)") {}
                        .disabled(true)
                }

                Divider()

                Button("Open macOS Network Settings…") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Network-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    } else if let fallback = URL(string: "x-apple.systempreferences:com.apple.preference.network") {
                        NSWorkspace.shared.open(fallback)
                    }
                }
            }

            Divider()

            Button("Quit nTails") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
    }

    @ViewBuilder
    private func statusIcon(for network: Network) -> some View {
        switch network.statusState {
        case .connected:
            Image(systemName: "circle.fill")
                .foregroundStyle(.green)
        case .disconnected:
            Image(systemName: "circle.slash")
                .foregroundStyle(.secondary)
        case .connecting:
            Image(systemName: "circle.fill")
                .foregroundStyle(.blue)
        case .waitingForLogin:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.orange)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(.red)
        case .unknown:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        }
    }
}
