import SwiftUI

struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let currentSettings: Settings
    let onSave: (Settings) -> Void

    enum Tab: String, CaseIterable, Identifiable {
        case listeners = "Proxy Listeners"
        case ssh = "SSH"

        var id: String { rawValue }
    }

    @State private var selectedTab: Tab = .listeners

    // PAC
    @State private var pacEnabled: Bool
    @State private var pacText: String

    // SOCKS5
    @State private var socksEnabled: Bool
    @State private var socksText: String

    // HTTP
    @State private var httpEnabled: Bool
    @State private var httpText: String

    @State private var updateSshConfig: Bool
    @State private var sshConfigPath: String
    @State private var validationError: String? = nil

    init(currentSettings: Settings, onSave: @escaping (Settings) -> Void) {
        self.currentSettings = currentSettings
        self.onSave = onSave

        // Seed editor from requested settings (converting backend sentinels -1 and 0 into user-facing controls)
        let reqPac = currentSettings.requested.pac
        _pacEnabled = State(initialValue: reqPac != -1)
        _pacText = State(initialValue: reqPac > 0 ? String(reqPac) : (reqPac == 0 ? "" : "1081"))

        let reqSocks = currentSettings.requested.socks
        _socksEnabled = State(initialValue: reqSocks != -1)
        _socksText = State(initialValue: reqSocks > 0 ? String(reqSocks) : (reqSocks == 0 ? "" : "1080"))

        let reqHttp = currentSettings.requested.http
        _httpEnabled = State(initialValue: reqHttp != -1)
        _httpText = State(initialValue: reqHttp > 0 ? String(reqHttp) : (reqHttp == 0 ? "" : "1082"))

        _updateSshConfig = State(initialValue: currentSettings.updateSshConfig)
        _sshConfigPath = State(initialValue: currentSettings.sshConfigPath)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Settings")
                    .font(.title2.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 16)

            // Tabs Picker
            Picker("Settings Section", selection: $selectedTab) {
                ForEach(Tab.allCases) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 24)
            .padding(.bottom, 16)

            Divider()

            // Tab Content
            VStack(alignment: .leading, spacing: 0) {
                switch selectedTab {
                case .listeners:
                    listenersView
                case .ssh:
                    sshView
                }

                Spacer(minLength: 0)

                if let error = validationError {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.red)
                        Text(error)
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                    .padding(.top, 8)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()

            // Actions Footer
            HStack {
                Button("Restore Defaults") {
                    pacEnabled = true
                    pacText = "1081"

                    socksEnabled = true
                    socksText = "1080"

                    httpEnabled = true
                    httpText = "1082"

                    updateSshConfig = true
                    sshConfigPath = Settings.defaultSSHConfigPath
                    validationError = nil
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Reset all settings to default values")

                Spacer()

                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                Button("Save") {
                    save()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 16)
        }
        .frame(width: 540, height: 480)
    }

    @ViewBuilder
    private var listenersView: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Listener failure alert banner
            if currentSettings.proxyStatus.hasAnyFailure {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.title3)

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Listener Port Conflict")
                            .font(.headline)
                            .foregroundStyle(.primary)

                        Text("One or more listeners failed to start because their configured ports are in use by another application. Adjust the ports or click Retry.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Button("Retry Starting Listeners") {
                            save()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .padding(.top, 4)
                    }
                }
                .padding(12)
                .background(Color.orange.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Local Proxy Listeners")
                    .font(.headline)

                Text("nTails routes connections to your active tailnets through local loopback listeners (127.0.0.1).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                listenerRow(
                    title: "PAC Server",
                    isEnabled: $pacEnabled,
                    portText: $pacText,
                    effectivePort: currentSettings.effective.pac,
                    requestedPort: currentSettings.requested.pac,
                    copyUrl: currentSettings.effective.pac > 0 ? "http://127.0.0.1:\(currentSettings.effective.pac)/proxy.pac" : nil,
                    tooltip: "Serves a proxy auto-configuration (PAC) script to automatically route tailnet domains."
                )

                listenerRow(
                    title: "SOCKS5 Proxy",
                    isEnabled: $socksEnabled,
                    portText: $socksText,
                    effectivePort: currentSettings.effective.socks,
                    requestedPort: currentSettings.requested.socks,
                    copyUrl: currentSettings.effective.socks > 0 ? "socks5://127.0.0.1:\(currentSettings.effective.socks)" : nil,
                    tooltip: "Local SOCKS5 proxy listener that routes connections to your active tailnets."
                )

                listenerRow(
                    title: "HTTP Proxy",
                    isEnabled: $httpEnabled,
                    portText: $httpText,
                    effectivePort: currentSettings.effective.http,
                    requestedPort: currentSettings.requested.http,
                    copyUrl: currentSettings.effective.http > 0 ? "http://127.0.0.1:\(currentSettings.effective.http)" : nil,
                    tooltip: "Local HTTP CONNECT proxy listener for applications that only support HTTP proxies."
                )
            }

            Text("Leave port empty for macOS to assign an available port automatically.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func listenerRow(
        title: String,
        isEnabled: Binding<Bool>,
        portText: Binding<String>,
        effectivePort: Int,
        requestedPort: Int,
        copyUrl: String?,
        tooltip: String
    ) -> some View {
        HStack(spacing: 12) {
            Toggle(title, isOn: isEnabled)
                .toggleStyle(.checkbox)
                .frame(width: 140, alignment: .leading)
                .help(tooltip)

            HStack(spacing: 6) {
                Text("Port:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                TextField("Automatic", text: portText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 85)
                    .disabled(!isEnabled.wrappedValue)
                    .help("Listening port (1–65535). Leave empty for automatic assignment.")
            }

            Spacer()

            HStack(spacing: 8) {
                listenerStatusTag(effective: effectivePort, requested: requestedPort)

                if let copyUrl {
                    Button("Copy URL") {
                        copyToClipboard(copyUrl)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .help("Copy proxy URL to clipboard")
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(NSColor.controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .help(tooltip)
    }

    @ViewBuilder
    private func listenerStatusTag(effective: Int, requested: Int) -> some View {
        if effective > 0 {
            if requested == 0 {
                Text("Bound: \(String(effective))")
                    .font(.caption.monospacedDigit())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.15))
                    .foregroundStyle(.green)
                    .clipShape(Capsule())
                    .help("Dynamically assigned port: \(String(effective)).")
            }
        } else if requested == -1 {
            Text("Off")
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.15))
                .foregroundStyle(.secondary)
                .clipShape(Capsule())
                .help("Listener is disabled.")
        } else {
            Text("Failed to Bind")
                .font(.caption.weight(.medium))
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.red.opacity(0.15))
                .foregroundStyle(.red)
                .clipShape(Capsule())
                .help("Listener failed to start because the port is in use or unavailable.")
        }
    }

    @ViewBuilder
    private var sshView: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("SSH Integration")
                    .font(.headline)

                Text("When enabled, nTails automatically maintains ProxyCommand routing for active tailnets in your SSH configuration.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Toggle("Automatically update ~/.ssh/config", isOn: $updateSshConfig)
                .font(.body)
                .help("Automatically maintain ProxyCommand entries for active tailnets in your SSH config.")

            if updateSshConfig {
                VStack(alignment: .leading, spacing: 6) {
                    Text("SSH Config Path:")
                        .font(.subheadline.weight(.medium))

                    HStack {
                        Text(SSHConfigManager.displayablePath(from: sshConfigPath))
                            .font(.system(.body, design: .monospaced))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(NSColor.textBackgroundColor))
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                            .help(sshConfigPath)

                        Button("Choose…") {
                            SSHConfigManager.shared.promptSelectFile { url in
                                if let url {
                                    sshConfigPath = url.path
                                }
                            }
                        }
                        .buttonStyle(.bordered)
                        .help("Choose a custom SSH config file location")

                        Button("Reset") {
                            sshConfigPath = Settings.defaultSSHConfigPath
                            SSHConfigManager.shared.resetToDefault()
                        }
                        .buttonStyle(.bordered)
                        .disabled(sshConfigPath == Settings.defaultSSHConfigPath)
                        .help("Reset to the default ~/.ssh/config path")
                    }
                }
                .padding(.top, 4)
            }
        }
    }

    private func isValidPort(_ port: Int) -> Bool {
        port >= 1 && port <= 65535
    }

    private func save() {
        let resolvedPac: Int
        if !pacEnabled {
            resolvedPac = -1
        } else {
            let trimmed = pacText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "auto" || trimmed == "0" {
                resolvedPac = 0
            } else if let port = Int(trimmed), isValidPort(port) {
                resolvedPac = port
            } else {
                selectedTab = .listeners
                validationError = "PAC Server port must be between 1 and 65535, or empty for automatic."
                return
            }
        }

        let resolvedSocks: Int
        if !socksEnabled {
            resolvedSocks = -1
        } else {
            let trimmed = socksText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "auto" || trimmed == "0" {
                resolvedSocks = 0
            } else if let port = Int(trimmed), isValidPort(port) {
                resolvedSocks = port
            } else {
                selectedTab = .listeners
                validationError = "SOCKS5 port must be between 1 and 65535, or empty for automatic."
                return
            }
        }

        let resolvedHttp: Int
        if !httpEnabled {
            resolvedHttp = -1
        } else {
            let trimmed = httpText.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed.lowercased() == "auto" || trimmed == "0" {
                resolvedHttp = 0
            } else if let port = Int(trimmed), isValidPort(port) {
                resolvedHttp = port
            } else {
                selectedTab = .listeners
                validationError = "HTTP Proxy port must be between 1 and 65535, or empty for automatic."
                return
            }
        }

        // Check for duplicate custom ports among enabled listeners
        if resolvedPac > 0 && resolvedPac == resolvedSocks {
            selectedTab = .listeners
            validationError = "Duplicate port: PAC and SOCKS5 cannot share the same port."
            return
        }
        if resolvedPac > 0 && resolvedPac == resolvedHttp {
            selectedTab = .listeners
            validationError = "Duplicate port: PAC and HTTP cannot share the same port."
            return
        }
        if resolvedSocks > 0 && resolvedSocks == resolvedHttp {
            selectedTab = .listeners
            validationError = "Duplicate port: SOCKS5 and HTTP cannot share the same port."
            return
        }

        validationError = nil

        let updatedProxy = ProxySettings(
            socks: resolvedSocks,
            pac: resolvedPac,
            http: resolvedHttp
        )

        let newSettings = Settings(
            proxy: updatedProxy,
            effective: currentSettings.effective,
            updateSshConfig: updateSshConfig,
            sshConfigPath: sshConfigPath.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        onSave(newSettings)
        dismiss()
    }

    private func copyToClipboard(_ str: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(str, forType: .string)
    }
}

#Preview {
    SettingsSheet(
        currentSettings: Settings(
            proxyStatus: ProxyStatus(
                requested: ProxySettings(socks: 0, pac: 1081, http: -1),
                effective: ProxySettings(socks: 50861, pac: 1081, http: -1)
            ),
            updateSshConfig: true,
            sshConfigPath: "~/.ssh/config"
        ),
        onSave: { _ in }
    )
}
