import SwiftUI

struct AddNetworkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onLogin: (String) -> Void

    enum NetworkType: String, CaseIterable, Identifiable {
        case tailscale = "Tailscale"
        case headscale = "Headscale"

        var id: String { rawValue }
    }

    @State private var selectedType: NetworkType = .tailscale
    @State private var headscaleUrl: String = ""
    @State private var validationError: String? = nil

    var body: some View {
        VStack(spacing: 20) {
            // Header
            VStack(spacing: 6) {
                Image(systemName: "network.badge.shield.half.filled")
                    .font(.system(size: 38))
                    .foregroundStyle(.tint)

                Text("Log In to Tailnet")
                    .font(.title2.weight(.bold))

                Text("Add and sign in to an official Tailscale or self-hosted Headscale network.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.top, 8)

            // Provider Selection
            Picker("Provider", selection: $selectedType) {
                ForEach(NetworkType.allCases) { type in
                    Text(type.rawValue).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            // Conditional inputs
            if selectedType == .tailscale {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: "checkmark.shield.fill")
                            .font(.title3)
                            .foregroundStyle(.blue)

                        VStack(alignment: .leading, spacing: 4) {
                            Text("Official Tailscale Coordination")
                                .font(.headline)
                            Text("Connects via login.tailscale.com. You will be prompted to authenticate in your browser or with a QR code.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Headscale Server URL")
                        .font(.headline)

                    TextField("https://headscale.example.com", text: $headscaleUrl)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()

                    if let error = validationError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.red)
                    } else {
                        Text("Enter the full URL including scheme (e.g. https://headscale.corp.net)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }

            Spacer(minLength: 0)

            // Bottom Buttons
            HStack {
                Button("Cancel", role: .cancel) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Spacer()

                Button("Log In") {
                    submit()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 440, height: 360)
    }

    private func submit() {
        if selectedType == .tailscale {
            onLogin("")
            dismiss()
        } else {
            let trimmed = headscaleUrl.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                validationError = "Server URL cannot be empty."
                return
            }
            guard let url = URL(string: trimmed), url.scheme != nil, url.host != nil else {
                validationError = "Please enter a valid URL with https:// or http://"
                return
            }
            validationError = nil
            onLogin(trimmed)
            dismiss()
        }
    }
}

#Preview {
    AddNetworkSheet(onLogin: { _ in })
}
