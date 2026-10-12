import Foundation

// MARK: - RPC Error Model

/// Represents an error returned by the ntails backend as defined in docs/rpc-protocol.md.
struct RPCError: Error, Codable, Hashable, Sendable, LocalizedError {
    var code: String
    var field: String? = nil
    var fields: [String]? = nil
    var cmd: String? = nil
    var id: String? = nil
    var status: String? = nil
    var detail: String? = nil

    init(
        code: String,
        field: String? = nil,
        fields: [String]? = nil,
        cmd: String? = nil,
        id: String? = nil,
        status: String? = nil,
        detail: String? = nil
    ) {
        self.code = code
        self.field = field
        self.fields = fields
        self.cmd = cmd
        self.id = id
        self.status = status
        self.detail = detail
    }

    var errorDescription: String? {
        switch code {
        case "invalid_request":
            return "Invalid request sent to backend."
        case "invalid_args":
            if let field, !field.isEmpty {
                return "Invalid argument for '\(field)'."
            }
            return "Invalid command arguments."
        case "unknown_command":
            return "Unknown command: \(cmd ?? "unspecified")."
        case "network_not_found":
            return "Network not found."
        case "invalid_state":
            if let status, !status.isEmpty {
                return "Action invalid for network in '\(status)' status."
            }
            return "Action invalid for current network status."
        case "invalid_port":
            let target = field.map { " for \($0)" } ?? ""
            return "Invalid port\(target): must be between 1 and 65535."
        case "duplicate_port":
            let joined = fields?.joined(separator: " and ") ?? "multiple listeners"
            return "Duplicate port specified for \(joined)."
        case "port_unavailable":
            let target = field.map { " for \($0)" } ?? ""
            return "Port\(target) is already in use by another application."
        case "storage_failed":
            return "Failed to save configuration to disk."
        case "start_failed":
            return detail ?? "Failed to start tailnet node."
        case "connect_failed":
            return detail ?? "Failed to connect to coordination server."
        case "already_running":
            return "Another instance of ntails is already running."
        case "internal":
            return detail ?? "An internal backend error occurred."
        default:
            return detail ?? "Backend error (\(code))."
        }
    }
}

// MARK: - Network Status

enum NetworkStatusState: Hashable, Sendable {
    case disconnected
    case connecting
    case waitingForLogin
    case connected
    case error(RPCError)
    case unknown(String)

    init(rawStatus: String, error: RPCError? = nil) {
        let trimmed = rawStatus.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed {
        case "connected":
            self = .connected
        case "disconnected":
            self = .disconnected
        case "connecting":
            self = .connecting
        case "waiting for login":
            self = .waitingForLogin
        case "error":
            self = .error(error ?? RPCError(code: "connect_failed", detail: "Connection failed"))
        default:
            self = .unknown(trimmed)
        }
    }

    var title: String {
        switch self {
        case .connected:
            return "Connected"
        case .disconnected:
            return "Disconnected"
        case .connecting:
            return "Connecting…"
        case .waitingForLogin:
            return "Waiting for sign-in"
        case .error(let err):
            if let detail = err.detail, !detail.isEmpty {
                return "Error: \(detail)"
            }
            if err.code == "start_failed" {
                return "Failed to start"
            }
            return "Connection error"
        case .unknown(let raw):
            return raw.isEmpty ? "Unknown" : raw
        }
    }
}

// MARK: - Network Model

struct Network: Identifiable, Codable, Hashable, Sendable {
    let id: String
    var controlUrl: String
    var domain: String
    var status: String
    var loginUrl: String
    var error: RPCError? = nil

    var isHeadscale: Bool {
        !controlUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var displayName: String {
        let trimmedDomain = domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedDomain.isEmpty {
            return trimmedDomain
        }
        if isHeadscale {
            if let url = URL(string: controlUrl), let host = url.host {
                return host
            }
            return controlUrl
        }
        return "Tailscale"
    }

    var statusState: NetworkStatusState {
        NetworkStatusState(rawStatus: status, error: error)
    }

    var isConnected: Bool {
        statusState == .connected
    }

    var isDisconnected: Bool {
        statusState == .disconnected
    }

    var isError: Bool {
        if case .error = statusState { return true }
        return false
    }

    /// True if the network can be connected (currently disconnected or in error state)
    var canConnect: Bool {
        isDisconnected || isError
    }

    /// True if the network can be disconnected (connected, connecting, waiting for login, or in error state)
    var canDisconnect: Bool {
        !isDisconnected
    }

    var needsLogin: Bool {
        statusState == .waitingForLogin && !loginUrl.isEmpty
    }
}

// MARK: - Proxy Settings Model (RPC Wire Protocol)

struct ProxySettings: Codable, Hashable, Sendable {
    var socks: Int
    var pac: Int
    var http: Int

    static let `default` = ProxySettings(
        socks: 1080,
        pac: 1081,
        http: 1082
    )

    init(socks: Int = 1080, pac: Int = 1081, http: Int = 1082) {
        self.socks = socks
        self.pac = pac
        self.http = http
    }
}

// MARK: - Proxy Status Model (RPC Wire Protocol)

struct ProxyStatus: Codable, Hashable, Sendable {
    var requested: ProxySettings
    var effective: ProxySettings

    static let `default` = ProxyStatus(
        requested: .default,
        effective: .default
    )

    func isFailed(field: String) -> Bool {
        switch field {
        case "socks": return requested.socks != -1 && effective.socks == -1
        case "pac": return requested.pac != -1 && effective.pac == -1
        case "http": return requested.http != -1 && effective.http == -1
        default: return false
        }
    }

    func isOff(field: String) -> Bool {
        switch field {
        case "socks": return requested.socks == -1
        case "pac": return requested.pac == -1
        case "http": return requested.http == -1
        default: return false
        }
    }

    var hasAnyFailure: Bool {
        isFailed(field: "socks") || isFailed(field: "pac") || isFailed(field: "http")
    }
}

// MARK: - App Settings Model

struct Settings: Hashable, Sendable {
    var proxyStatus: ProxyStatus
    var updateSshConfig: Bool
    var sshConfigPath: String

    var proxy: ProxySettings {
        get { proxyStatus.requested }
        set { proxyStatus.requested = newValue }
    }

    var requested: ProxySettings {
        get { proxyStatus.requested }
        set { proxyStatus.requested = newValue }
    }

    var effective: ProxySettings {
        get { proxyStatus.effective }
        set { proxyStatus.effective = newValue }
    }

    var socks: Int {
        get { proxyStatus.requested.socks }
        set { proxyStatus.requested.socks = newValue }
    }

    var pac: Int {
        get { proxyStatus.requested.pac }
        set { proxyStatus.requested.pac = newValue }
    }

    var http: Int {
        get { proxyStatus.requested.http }
        set { proxyStatus.requested.http = newValue }
    }

    static var defaultSSHConfigPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return (home as NSString).appendingPathComponent(".ssh/config")
    }

    static let `default` = Settings(
        proxyStatus: .default,
        updateSshConfig: true,
        sshConfigPath: defaultSSHConfigPath
    )

    init(
        proxyStatus: ProxyStatus = .default,
        updateSshConfig: Bool = true,
        sshConfigPath: String = Settings.defaultSSHConfigPath
    ) {
        self.proxyStatus = proxyStatus
        self.updateSshConfig = updateSshConfig
        self.sshConfigPath = sshConfigPath
    }

    init(
        proxy: ProxySettings,
        effective: ProxySettings? = nil,
        updateSshConfig: Bool = true,
        sshConfigPath: String = Settings.defaultSSHConfigPath
    ) {
        self.proxyStatus = ProxyStatus(requested: proxy, effective: effective ?? proxy)
        self.updateSshConfig = updateSshConfig
        self.sshConfigPath = sshConfigPath
    }

    init(
        socks: Int,
        pac: Int,
        http: Int = 1082,
        updateSshConfig: Bool = true,
        sshConfigPath: String = Settings.defaultSSHConfigPath
    ) {
        let proxy = ProxySettings(socks: socks, pac: pac, http: http)
        self.proxyStatus = ProxyStatus(requested: proxy, effective: proxy)
        self.updateSshConfig = updateSshConfig
        self.sshConfigPath = sshConfigPath
    }
}

// MARK: - Wire Protocol Envelopes

enum RPCMessageType: String, Codable, Sendable {
    case response = "res"
    case event = "event"
}

struct RPCNotificationPayload: Codable, Sendable {
    let title: String
    let body: String
}

struct NetworkRemovedPayload: Codable, Sendable {
    let id: String
}
