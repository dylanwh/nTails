import SwiftUI

struct LoginSheet: View {
    @Environment(\.dismiss) private var dismiss
    let network: Network
    let onConnectedSimulated: (() -> Void)?

    @State private var hasCopied = false

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 4) {
                Text("Sign In")
                    .font(.title2.weight(.bold))

                Text("Authenticate **\(network.displayName)** to join the tailnet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 4)

            if network.loginUrl.isEmpty {
                // Waiting for URL from backend
                VStack(spacing: 16) {
                    ProgressView()
                        .controlSize(.large)

                    Text("Waiting for authentication link from server…")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxHeight: .infinity)
            } else {
                // QR Code Card
                VStack(spacing: 16) {
                    QRCodeView(urlString: network.loginUrl)
                        .frame(width: 200, height: 200)

                    Text("Scan with your phone's camera, or authenticate directly on this Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 20)

                    // URL row & Actions
                    HStack(spacing: 10) {
                        Button {
                            if let url = URL(string: network.loginUrl) {
                                NSWorkspace.shared.open(url)
                            }
                        } label: {
                            Label("Open in Browser", systemImage: "safari")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.regular)

                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(network.loginUrl, forType: .string)
                            withAnimation(.spring(response: 0.3)) {
                                hasCopied = true
                            }
                            DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                                withAnimation {
                                    hasCopied = false
                                }
                            }
                        } label: {
                            Label(hasCopied ? "Copied!" : "Copy Link",
                                  systemImage: hasCopied ? "checkmark" : "doc.on.doc")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.regular)
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.vertical, 8)
            }

            Spacer(minLength: 0)

            // Footer
            HStack {
                #if DEBUG
                if let onConnectedSimulated {
                    Button("Simulate Sign-In") {
                        onConnectedSimulated()
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .font(.caption)
                }
                #endif

                Spacer()

                Button("Close") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 460)
        .onChange(of: network.statusState) { _, newState in
            if newState == .connected {
                dismiss()
            }
        }
    }
}

#Preview("With URL") {
    LoginSheet(
        network: Network(
            id: "1",
            controlUrl: "",
            domain: "tailc7714.ts.net",
            status: "waiting for login",
            loginUrl: "https://login.tailscale.com/a/sample-code-test"
        ),
        onConnectedSimulated: {}
    )
}

#Preview("Waiting for Link") {
    LoginSheet(
        network: Network(
            id: "2",
            controlUrl: "https://headscale.example.com",
            domain: "",
            status: "waiting for login",
            loginUrl: ""
        ),
        onConnectedSimulated: {}
    )
}
