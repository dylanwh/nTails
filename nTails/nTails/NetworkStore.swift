import SwiftUI
import Observation

@MainActor
@Observable
final class NetworkStore {
    var networks: [Network] = []
    var settings: Settings = .default

    var activeLoginNetwork: Network? = nil
    var showingAddSheet: Bool = false
    var showingSettingsSheet: Bool = false
    var networkToLogout: Network? = nil
    var errorMessage: String? = nil
    var isBackendConnected: Bool = false
    var isLoading: Bool = false
    var invalidConfigErrors: [RPCError] = []

    private(set) var rpcService: RPCService?

    init(usePreviewData: Bool = false) {
        let sshManager = SSHConfigManager.shared
        self.settings = Settings(
            proxyStatus: .default,
            updateSshConfig: sshManager.autoUpdate,
            sshConfigPath: sshManager.savedPath
        )
        if usePreviewData {
            loadPreviewData()
        } else {
            let rpc = RPCService(store: self)
            self.rpcService = rpc
            rpc.start()
            Task {
                await loadInitialState()
            }
        }
    }

    var activeDomains: [String] {
        Array(Set(networks.compactMap { net -> String? in
            let d = net.domain.trimmingCharacters(in: .whitespacesAndNewlines)
            return d.isEmpty ? nil : d
        })).sorted()
    }

    func handleInvalidConfig(_ error: RPCError) {
        if !invalidConfigErrors.contains(where: { $0.field == error.field }) {
            invalidConfigErrors.append(error)
        }
        let fieldName = error.field?.uppercased() ?? "proxy"
        errorMessage = "Port for \(fieldName) listener could not be bound because it is in use by another application."
    }

    func handleFatalError(_ error: RPCError) {
        errorMessage = error.localizedDescription
        isBackendConnected = false
    }

    func loadInitialState() async {
        guard let rpcService else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            async let fetchedNetworks = rpcService.listNetworks()
            async let fetchedSettings = rpcService.getPorts()
            let (nets, proxyStatus) = try await (fetchedNetworks, fetchedSettings)
            let sshManager = SSHConfigManager.shared
            self.settings = Settings(
                proxyStatus: proxyStatus,
                updateSshConfig: sshManager.autoUpdate,
                sshConfigPath: sshManager.savedPath
            )
            // list_networks is a one-shot snapshot requested before this
            // response arrives, but the live event stream has been running
            // since rpc.start() and may already be further ahead for any
            // network the backend auto-reconnects at startup. Only fill in
            // networks the live stream hasn't told us about yet (notably,
            // ones left disconnected, which never emit a startup event) --
            // never overwrite one it already has, or a stale snapshot can
            // regress a network's displayed status backward with no later
            // event ever arriving to correct it (the backend only emits on
            // change).
            for net in nets where !networks.contains(where: { $0.id == net.id }) {
                updateNetwork(from: net)
            }
            if self.settings.updateSshConfig {
                try? SSHConfigManager.shared.writeSSHConfig(domains: self.activeDomains)
            }
            rpcService.markStartedSuccessfully()
        } catch {
            print("[NetworkStore] FATAL: Failed to initialize with ntails backend on startup: \(error)")
            if !rpcService.hasStartedSuccessfully {
                RPCService.quitApp(exitCode: 1)
            }
        }
    }

    func loadPreviewData() {
        self.isBackendConnected = true
        self.networks = [
            Network(
                id: "net-1",
                controlUrl: "",
                domain: "workplace.tailc7714.ts.net",
                status: "connected",
                loginUrl: ""
            ),
            Network(
                id: "net-2",
                controlUrl: "https://headscale.internal.corp",
                domain: "lab-infra.corp",
                status: "disconnected",
                loginUrl: ""
            ),
            Network(
                id: "net-3",
                controlUrl: "https://headscale.myhomelab.org",
                domain: "homelab.net",
                status: "waiting for login",
                loginUrl: "https://headscale.myhomelab.org/register/m3t2b87f"
            ),
            Network(
                id: "net-4",
                controlUrl: "",
                domain: "personal.ts.net",
                status: "connecting",
                loginUrl: ""
            ),
            Network(
                id: "net-5",
                controlUrl: "",
                domain: "backup.ts.net",
                status: "error",
                loginUrl: "",
                error: RPCError(code: "connect_failed", detail: "dial tcp: lookup controlplane.tailscale.com: no such host")
            )
        ]
    }

    // MARK: - Network Lifecycle Actions

    /// Creates a new tailnet entry and immediately begins connecting (corresponds to `login_network`).
    func loginNetwork(controlUrl: String) {
        let trimmed = controlUrl.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let rpcService else {
            // Preview fallback
            let newNetwork = Network(
                id: UUID().uuidString,
                controlUrl: trimmed,
                domain: "",
                status: "connecting",
                loginUrl: ""
            )
            networks.append(newNetwork)
            return
        }

        Task {
            do {
                let network = try await rpcService.loginNetwork(controlUrl: trimmed)
                // A network_changed event for this id may already have arrived and been
                // applied (by the time this continuation resumes, per docs/rpc-protocol.md's
                // event-before-response ordering) with a status newer than this response's
                // snapshot -- same hazard as loadInitialState. Don't overwrite it.
                if !networks.contains(where: { $0.id == network.id }) {
                    updateNetwork(from: network)
                }
                activeLoginNetwork = networks.first(where: { $0.id == network.id }) ?? network
            } catch {
                errorMessage = "Failed to add network: \(error.localizedDescription)"
            }
        }
    }

    /// Reconnects an existing disconnected or errored network (corresponds to `connect_network`).
    func connectNetwork(id: String) {
        let previousStatus = networks.first(where: { $0.id == id })?.status ?? "disconnected"
        if let index = networks.firstIndex(where: { $0.id == id }) {
            networks[index].status = "connecting"
            networks[index].error = nil
        }

        guard let rpcService else { return }

        Task {
            do {
                try await rpcService.connectNetwork(id: id)
            } catch {
                errorMessage = "Failed to connect network: \(error.localizedDescription)"
                if let index = networks.firstIndex(where: { $0.id == id }) {
                    networks[index].status = previousStatus
                }
            }
        }
    }

    /// Tears down the connection without discarding saved session (corresponds to `disconnect_network`).
    func disconnectNetwork(id: String) {
        let previous = networks.first(where: { $0.id == id })
        let previousActiveLogin = activeLoginNetwork
        if let index = networks.firstIndex(where: { $0.id == id }) {
            networks[index].status = "disconnected"
            networks[index].loginUrl = ""
            networks[index].error = nil
        }
        if activeLoginNetwork?.id == id {
            activeLoginNetwork = nil
        }

        guard let rpcService else { return }

        Task {
            do {
                try await rpcService.disconnectNetwork(id: id)
            } catch {
                errorMessage = "Failed to disconnect: \(error.localizedDescription)"
                // No corrective network_changed event is coming for a failed request --
                // revert the optimistic update ourselves, matching connectNetwork's behavior.
                if let previous, let index = networks.firstIndex(where: { $0.id == id }) {
                    networks[index] = previous
                }
                if activeLoginNetwork == nil, previousActiveLogin?.id == id {
                    activeLoginNetwork = previousActiveLogin
                }
            }
        }
    }

    /// Terminal action: logs out, invalidates session, forgets entry (corresponds to `logout_network`).
    func logoutNetwork(id: String) {
        networks.removeAll { $0.id == id }
        if activeLoginNetwork?.id == id {
            activeLoginNetwork = nil
        }
        if networkToLogout?.id == id {
            networkToLogout = nil
        }

        guard let rpcService else { return }

        Task {
            do {
                try await rpcService.logoutNetwork(id: id)
            } catch {
                errorMessage = "Failed to log out: \(error.localizedDescription)"
            }
        }
    }

    func simulateConnected(id: String) {
        guard let index = networks.firstIndex(where: { $0.id == id }) else { return }
        networks[index].status = "connected"
        networks[index].error = nil
        if networks[index].domain.isEmpty {
            networks[index].domain = networks[index].isHeadscale ? "lab.internal" : "device.ts.net"
        }
        if activeLoginNetwork?.id == id {
            activeLoginNetwork = nil
        }
    }

    func updateNetwork(from incoming: Network) {
        let prevDomains = activeDomains
        if let index = networks.firstIndex(where: { $0.id == incoming.id }) {
            networks[index] = incoming
        } else {
            networks.append(incoming)
        }

        if activeLoginNetwork?.id == incoming.id {
            if incoming.isConnected {
                activeLoginNetwork = nil
            } else {
                activeLoginNetwork = incoming
            }
        }

        if settings.updateSshConfig && activeDomains != prevDomains {
            try? SSHConfigManager.shared.writeSSHConfig(domains: activeDomains)
        }
    }

    func removeNetwork(id: String) {
        let prevDomains = activeDomains
        networks.removeAll { $0.id == id }
        if activeLoginNetwork?.id == id {
            activeLoginNetwork = nil
        }
        if networkToLogout?.id == id {
            networkToLogout = nil
        }

        if settings.updateSshConfig && activeDomains != prevDomains {
            try? SSHConfigManager.shared.writeSSHConfig(domains: activeDomains)
        }
    }

    func saveSettings(_ newSettings: Settings) {
        let previous = self.settings
        self.settings = newSettings

        let sshManager = SSHConfigManager.shared
        sshManager.savedPath = newSettings.sshConfigPath
        sshManager.autoUpdate = newSettings.updateSshConfig

        if newSettings.updateSshConfig {
            do {
                try sshManager.writeSSHConfig(domains: activeDomains)
            } catch {
                print("[NetworkStore] Error writing SSH config: \(error)")
                errorMessage = "Failed to update SSH config: \(error.localizedDescription)"
            }
        }

        guard let rpcService else { return }

        Task {
            do {
                let status = try await rpcService.savePorts(newSettings.proxy)
                self.settings.proxyStatus = status
                self.invalidConfigErrors.removeAll()
            } catch {
                self.settings = previous
                self.errorMessage = "Failed to save settings: \(error.localizedDescription)"
            }
        }
    }

    func stopSync() {
        rpcService?.stopSync()
    }
}
