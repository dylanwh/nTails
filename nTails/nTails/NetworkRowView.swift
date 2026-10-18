import SwiftUI

struct NetworkRowView: View {
    let network: Network
    let onConnect: () -> Void
    let onDisconnect: () -> Void
    let onSelectLogin: () -> Void
    let onRequestLogout: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Status Icon Indicator
            statusIcon
                .frame(width: 32, height: 32)

            // Network Info
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(network.displayName)
                        .font(.system(.body, design: .rounded, weight: .semibold))
                        .foregroundStyle(network.isDisconnected ? .secondary : .primary)

                    providerBadge
                }

                HStack(spacing: 6) {
                    Text(network.statusState.title)
                        .font(.subheadline)
                        .foregroundStyle(statusColor)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(network.statusState.title)

                    if !network.domain.isEmpty && network.isHeadscale {
                        Text("•")
                            .foregroundStyle(.secondary)
                        Text(network.controlUrl)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
            }

            Spacer()

            // Trailing Actions
            HStack(spacing: 8) {
                if network.needsLogin {
                    Button(action: onSelectLogin) {
                        Label("Sign In", systemImage: "key.fill")
                            .font(.subheadline.weight(.medium))
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .controlSize(.small)

                    Button("Cancel", action: onDisconnect)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Cancel connection attempt")
                } else if network.isError {
                    Button("Retry", action: onConnect)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help("Retry connecting to this network")

                    Button("Cancel", action: onDisconnect)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .help("Cancel connection attempt")
                } else if network.isDisconnected {
                    Button("Connect", action: onConnect)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                } else if network.isConnected {
                    Button("Disconnect", action: onDisconnect)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    // Connecting
                    Button("Cancel", action: onDisconnect)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                }

                // Row action menu (Copy, Log Out)
                Menu {
                    if network.isDisconnected {
                        Button {
                            onConnect()
                        } label: {
                            Label("Connect", systemImage: "bolt.fill")
                        }
                    } else if network.isError {
                        Button {
                            onConnect()
                        } label: {
                            Label("Retry Connection", systemImage: "arrow.clockwise")
                        }
                        Button {
                            onDisconnect()
                        } label: {
                            Label("Cancel", systemImage: "xmark")
                        }
                    } else {
                        Button {
                            onDisconnect()
                        } label: {
                            Label("Disconnect", systemImage: "bolt.slash")
                        }
                    }

                    if network.needsLogin {
                        Button {
                            onSelectLogin()
                        } label: {
                            Label("Sign In…", systemImage: "qrcode")
                        }
                    }

                    Divider()

                    if !network.domain.isEmpty {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(network.domain, forType: .string)
                        } label: {
                            Label("Copy Domain", systemImage: "doc.on.doc")
                        }
                    }

                    if network.isHeadscale {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(network.controlUrl, forType: .string)
                        } label: {
                            Label("Copy Server URL", systemImage: "link")
                        }
                    }

                    Divider()

                    Button(role: .destructive) {
                        onRequestLogout()
                    } label: {
                        Label("Log Out…", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .foregroundStyle(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .frame(width: 24, height: 24)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if network.needsLogin {
                onSelectLogin()
            }
        }
        .contextMenu {
            if network.isDisconnected {
                Button {
                    onConnect()
                } label: {
                    Label("Connect", systemImage: "bolt.fill")
                }
            } else if network.isError {
                Button {
                    onConnect()
                } label: {
                    Label("Retry Connection", systemImage: "arrow.clockwise")
                }
                Button {
                    onDisconnect()
                } label: {
                    Label("Cancel", systemImage: "xmark")
                }
            } else {
                Button {
                    onDisconnect()
                } label: {
                    Label("Disconnect", systemImage: "bolt.slash")
                }
            }

            if network.needsLogin {
                Button {
                    onSelectLogin()
                } label: {
                    Label("Sign In to Complete Setup", systemImage: "qrcode")
                }
            }

            if !network.domain.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(network.domain, forType: .string)
                } label: {
                    Label("Copy Domain (\(network.domain))", systemImage: "doc.on.doc")
                }
            }

            if network.isHeadscale {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(network.controlUrl, forType: .string)
                } label: {
                    Label("Copy Control Server URL", systemImage: "link")
                }
            }

            Divider()

            Button(role: .destructive) {
                onRequestLogout()
            } label: {
                Label("Log Out & Remove…", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch network.statusState {
        case .connected:
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            }
        case .disconnected:
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: "circle.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        case .connecting:
            ZStack {
                Circle()
                    .fill(Color.blue.opacity(0.15))
                ProgressView()
                    .controlSize(.small)
            }
        case .waitingForLogin:
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(0.15))
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(.orange)
            }
        case .error:
            ZStack {
                Circle()
                    .fill(Color.red.opacity(0.15))
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.red)
            }
        case .unknown:
            ZStack {
                Circle()
                    .fill(Color.secondary.opacity(0.15))
                Image(systemName: "questionmark.circle")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var providerBadge: some View {
        Group {
            if network.isHeadscale {
                Text("HEADSCALE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.purple.opacity(0.15))
                    .foregroundStyle(.purple)
                    .clipShape(Capsule())
            } else {
                Text("TAILSCALE")
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }
        }
    }

    private var statusColor: Color {
        switch network.statusState {
        case .connected:
            return .green
        case .disconnected:
            return .secondary
        case .connecting:
            return .blue
        case .waitingForLogin:
            return .orange
        case .error:
            return .red
        case .unknown:
            return .secondary
        }
    }
}

#Preview {
    List {
        NetworkRowView(
            network: Network(
                id: "1",
                controlUrl: "",
                domain: "tailc7714.ts.net",
                status: "connected",
                loginUrl: ""
            ),
            onConnect: {},
            onDisconnect: {},
            onSelectLogin: {},
            onRequestLogout: {}
        )
        NetworkRowView(
            network: Network(
                id: "2",
                controlUrl: "https://headscale.mycompany.com",
                domain: "infra.internal",
                status: "disconnected",
                loginUrl: ""
            ),
            onConnect: {},
            onDisconnect: {},
            onSelectLogin: {},
            onRequestLogout: {}
        )
        NetworkRowView(
            network: Network(
                id: "3",
                controlUrl: "",
                domain: "backup.ts.net",
                status: "error",
                loginUrl: "",
                error: RPCError(code: "connect_failed", detail: "dial tcp: connection refused")
            ),
            onConnect: {},
            onDisconnect: {},
            onSelectLogin: {},
            onRequestLogout: {}
        )
    }
    .frame(width: 520, height: 280)
}
