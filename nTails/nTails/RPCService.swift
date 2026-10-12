import Foundation
import SwiftUI
import UserNotifications

/// Thread-safe helper that buffers incoming bytes from a stream and splits them into lines.
private final class StreamLineBuffer: @unchecked Sendable {
    private nonisolated(unsafe) var buffer = Data()
    private let lock = NSLock()

    nonisolated func appendAndExtractLines(_ data: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        if data.isEmpty {
            // EOF reached: flush remaining buffer if non-empty
            if !buffer.isEmpty {
                let remainder = buffer
                buffer.removeAll()
                if let str = String(data: remainder, encoding: .utf8), !str.isEmpty {
                    return [str]
                }
            }
            return []
        }

        buffer.append(data)
        var lines: [String] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) { // '\n'
            let lineData = buffer.prefix(upTo: newlineIndex)
            buffer.removeSubrange(0...newlineIndex)
            if let lineStr = String(data: lineData, encoding: .utf8) {
                lines.append(lineStr)
            }
        }
        return lines
    }

    nonisolated func reset() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
    }
}

/// Handles JSON-Lines RPC communication over stdin / stdout with `ntailsd rpc`.
@MainActor
final class RPCService {
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?

    private let stdoutLineBuffer = StreamLineBuffer()
    private let stderrLineBuffer = StreamLineBuffer()

    private var nextRequestId: Int = 1
    private var pendingRequests: [Int: CheckedContinuation<Data, Error>] = [:]

    /// A response with a null `id` (e.g. for an over-long request line, per
    /// docs/rpc-protocol.md) never resolves a pendingRequests entry, so every
    /// request needs a bound on how long it waits for one.
    private static let requestTimeout: TimeInterval = 30

    private(set) var hasStartedSuccessfully = false
    private(set) var fatalError: RPCError? = nil
    private var isShuttingDown = false

    weak var store: NetworkStore?

    init(store: NetworkStore?) {
        self.store = store
    }

    /// Terminates the application when the RPC backend cannot be started.
    static func quitApp(exitCode: Int32 = 1) {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCODE_RUNNING_FOR_PREVIEWS"] == "1" {
            return
        }
        #endif

        DispatchQueue.main.async {
            NSApp?.terminate(nil)
            exit(exitCode)
        }
        // Fallback in case main event loop is not yet running
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            exit(exitCode)
        }
    }

    func markStartedSuccessfully() {
        hasStartedSuccessfully = true
    }

    /// Locates the `ntailsd` Go backend binary. This is always built fresh by
    /// the "Build ntails backend" Xcode build phase (build-backend.sh) into
    /// Contents/Helpers/ntailsd, Debug or Release -- there is no other
    /// supported source for this binary.
    static func locateExecutableURL() -> URL? {
        let helpersURL = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ntailsd")
        return checkAndEnsureExecutable(at: helpersURL) ? helpersURL : nil
    }

    private static func checkAndEnsureExecutable(at url: URL) -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        if !FileManager.default.isExecutableFile(atPath: url.path) {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        return FileManager.default.isExecutableFile(atPath: url.path)
    }

    /// Launches the `ntailsd rpc` subprocess and begins streaming events and responses.
    func start(customBinaryPath: String? = nil) {
        let execURL: URL
        if let customPath = customBinaryPath {
            execURL = URL(fileURLWithPath: customPath)
        } else if let foundURL = Self.locateExecutableURL() {
            execURL = foundURL
        } else {
            fputs("[nTails] FATAL: Could not locate ntails backend binary. Quitting.\n", stderr)
            store?.errorMessage = "Could not find ntails backend binary in the application bundle."
            Self.quitApp(exitCode: 1)
            return
        }

        let proc = Process()
        proc.executableURL = execURL
        proc.arguments = ["rpc"]

        // Clean out any DYLD injection variables inherited from Xcode debugger/previews
        var cleanEnv = ProcessInfo.processInfo.environment
        cleanEnv.removeValue(forKey: "DYLD_INSERT_LIBRARIES")
        cleanEnv.removeValue(forKey: "DYLD_FRAMEWORK_PATH")
        cleanEnv.removeValue(forKey: "DYLD_LIBRARY_PATH")
        cleanEnv.removeValue(forKey: "DYLD_FALLBACK_FRAMEWORK_PATH")
        cleanEnv.removeValue(forKey: "DYLD_FALLBACK_LIBRARY_PATH")
        cleanEnv.removeValue(forKey: "__XPC_DYLD_FRAMEWORK_PATH")
        cleanEnv.removeValue(forKey: "__XPC_DYLD_LIBRARY_PATH")
        proc.environment = cleanEnv

        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()

        proc.standardInput = inPipe
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        proc.terminationHandler = { [weak self] p in
            Task { @MainActor [weak self] in
                self?.handleProcessTermination(status: p.terminationStatus)
            }
        }

        self.process = proc
        self.stdinPipe = inPipe
        self.stdoutPipe = outPipe
        self.stderrPipe = errPipe

        // Read stdout line-by-line using readabilityHandler for prompt, non-blocking delivery
        stdoutLineBuffer.reset()
        let outLineBuffer = stdoutLineBuffer
        outPipe.fileHandleForReading.readabilityHandler = { [weak self, outLineBuffer] handle in
            let data = handle.availableData
            let lines = outLineBuffer.appendAndExtractLines(data)
            let isEOF = data.isEmpty
            if isEOF {
                handle.readabilityHandler = nil
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                for line in lines {
                    self.handleLine(line)
                }
                if isEOF {
                    self.handleStdoutEOF()
                }
            }
        }

        // Stream stderr for logging/diagnostics
        stderrLineBuffer.reset()
        let errLineBuffer = stderrLineBuffer
        errPipe.fileHandleForReading.readabilityHandler = { [errLineBuffer] handle in
            let data = handle.availableData
            let lines = errLineBuffer.appendAndExtractLines(data)
            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            for line in lines {
                print("[ntails backend] \(line)")
            }
        }

        do {
            try proc.run()
            store?.isBackendConnected = true
        } catch {
            fputs("[nTails] FATAL: Failed to launch ntailsd rpc: \(error). Quitting.\n", stderr)
            store?.isBackendConnected = false
            store?.errorMessage = "Failed to start ntails backend: \(error.localizedDescription)"
            Self.quitApp(exitCode: 1)
        }
    }

    /// Stops the server gracefully as specified in docs/rpc-protocol.md:
    /// Sends {"cmd":"quit"} request, awaits response, closes stdin, and waits for backend to exit cleanly.
    func stop() async {
        isShuttingDown = true
        guard let proc = process, proc.isRunning else {
            cleanupPipes()
            return
        }

        // 1. Send cooperative quit request and await the server's response
        _ = try? await sendCommand(cmd: "quit", args: nil)

        // 2. Close stdin to signal EOF
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil

        // 3. Wait up to 2.0s for backend to finish releasing network connections and exit
        let deadline = Date().addingTimeInterval(2.0)
        while proc.isRunning && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
        }

        if proc.isRunning {
            proc.terminate()
        }

        cleanupPipes()
    }

    /// Synchronous shutdown used on app termination.
    func stopSync() {
        isShuttingDown = true
        guard let proc = process, proc.isRunning else {
            cleanupPipes()
            return
        }

        let quitPayload = "{\"id\":999999,\"cmd\":\"quit\"}\n"
        if let data = quitPayload.data(using: .utf8) {
            try? stdinPipe?.fileHandleForWriting.write(contentsOf: data)
        }

        // Close stdin so EOF is sent
        try? stdinPipe?.fileHandleForWriting.close()
        stdinPipe = nil

        // Wait up to 1.5s for backend to exit
        let deadline = Date().addingTimeInterval(1.5)
        while proc.isRunning && Date() < deadline {
            usleep(50_000) // 50ms
        }

        if proc.isRunning {
            proc.terminate()
        }

        cleanupPipes()
    }

    private func cleanupPipes() {
        stdoutPipe?.fileHandleForReading.readabilityHandler = nil
        stderrPipe?.fileHandleForReading.readabilityHandler = nil
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    /// Per docs/rpc-protocol.md: if stdout closes without a `fatal` event, the server
    /// exited unexpectedly -- fail every outstanding request now rather than waiting
    /// for `terminationHandler`, which can lag behind the pipe closing.
    private func handleStdoutEOF() {
        guard !isShuttingDown, !pendingRequests.isEmpty else { return }
        let error = fatalError ?? RPCError(code: "internal", detail: "Backend closed stdout unexpectedly")
        for (_, cont) in pendingRequests {
            cont.resume(throwing: error)
        }
        pendingRequests.removeAll()
    }

    private func handleProcessTermination(status: Int32) {
        if isShuttingDown {
            print("[RPCService] Backend exited cleanly during shutdown (status \(status))")
            store?.isBackendConnected = false
            return
        }

        print("[RPCService] Backend process terminated with status \(status)")
        let error: Error
        if let fatalErr = fatalError {
            error = fatalErr
        } else {
            error = NSError(
                domain: "nTailsRPC",
                code: Int(status),
                userInfo: [NSLocalizedDescriptionKey: "Backend process terminated (exit code \(status))"]
            )
        }

        for (_, cont) in pendingRequests {
            cont.resume(throwing: error)
        }
        pendingRequests.removeAll()
        store?.isBackendConnected = false

        if !hasStartedSuccessfully {
            let reason = fatalError?.localizedDescription ?? "status \(status)"
            fputs("[nTails] FATAL: ntailsd rpc terminated during startup with \(reason). Quitting.\n", stderr)
            Self.quitApp(exitCode: 1)
        }
    }

    // MARK: - API Commands

    func listNetworks() async throws -> [Network] {
        let data = try await sendCommand(cmd: "list_networks", args: nil)
        return try JSONDecoder().decode([Network].self, from: data)
    }

    func getSettings() async throws -> ProxyStatus {
        let data = try await sendCommand(cmd: "get_settings", args: nil)
        return try JSONDecoder().decode(ProxyStatus.self, from: data)
    }

    /// Creates a new tailnet entry and immediately begins connecting.
    func loginNetwork(controlUrl: String) async throws -> Network {
        let args = ["controlUrl": controlUrl]
        let data = try await sendCommand(cmd: "login_network", args: args)
        return try JSONDecoder().decode(Network.self, from: data)
    }

    /// Connects an existing network that is currently disconnected or in error.
    func connectNetwork(id: String) async throws {
        let args = ["id": id]
        _ = try await sendCommand(cmd: "connect_network", args: args)
    }

    /// Tears down the tailnet connection without discarding its saved session.
    func disconnectNetwork(id: String) async throws {
        let args = ["id": id]
        _ = try await sendCommand(cmd: "disconnect_network", args: args)
    }

    /// Invalidates the session, shuts down the connection, and forgets the entry entirely.
    func logoutNetwork(id: String) async throws {
        let args = ["id": id]
        _ = try await sendCommand(cmd: "logout_network", args: args)
    }

    func saveSettings(_ settings: ProxySettings) async throws -> ProxyStatus {
        let data = try JSONEncoder().encode(settings)
        guard let argsObj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw RPCError(code: "invalid_args", detail: "Could not serialize settings")
        }
        let resData = try await sendCommand(cmd: "save_settings", args: argsObj)
        return try JSONDecoder().decode(ProxyStatus.self, from: resData)
    }

    // MARK: - Low-level Wire Transport

    private func sendCommand(cmd: String, args: [String: Any]?) async throws -> Data {
        guard let proc = process, proc.isRunning, let stdinPipe else {
            throw NSError(
                domain: "nTailsRPC",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Backend process is not running"]
            )
        }

        let id = nextRequestId
        nextRequestId += 1

        // docs/rpc-protocol.md: Requests are exactly {id, cmd, args} -- no "type" key
        var payload: [String: Any] = [
            "id": id,
            "cmd": cmd
        ]
        if let args {
            payload["args"] = args
        }

        let jsonData = try JSONSerialization.data(withJSONObject: payload)
        guard var lineData = String(data: jsonData, encoding: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }
        lineData.append("\n")

        guard let data = lineData.data(using: .utf8) else {
            throw URLError(.cannotDecodeRawData)
        }

        let fileHandle = stdinPipe.fileHandleForWriting

        return try await withCheckedThrowingContinuation { continuation in
            pendingRequests[id] = continuation

            // The write syscall runs off the main actor so a full pipe (backend stalled
            // and not draining stdin) blocks a detached task, not the UI.
            Task.detached {
                do {
                    try fileHandle.write(contentsOf: data)
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self, let cont = self.pendingRequests.removeValue(forKey: id) else { return }
                        cont.resume(throwing: error)
                    }
                }
            }

            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.requestTimeout * 1_000_000_000))
                guard let self, let cont = self.pendingRequests.removeValue(forKey: id) else { return }
                cont.resume(throwing: RPCError(code: "internal", detail: "Request timed out waiting for backend response"))
            }
        }
    }

    private func handleLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let data = trimmed.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = json["type"] as? String else {
            return
        }

        switch type {
        case "res":
            guard let id = json["id"] as? Int, let cont = pendingRequests.removeValue(forKey: id) else {
                return
            }
            let ok = json["ok"] as? Bool ?? false
            if ok {
                if let rawData = json["data"] {
                    if let serialized = try? JSONSerialization.data(withJSONObject: rawData) {
                        cont.resume(returning: serialized)
                    } else {
                        cont.resume(returning: Data())
                    }
                } else {
                    cont.resume(returning: Data())
                }
            } else {
                if let errDict = json["error"] as? [String: Any],
                   let errData = try? JSONSerialization.data(withJSONObject: errDict),
                   let decodedErr = try? JSONDecoder().decode(RPCError.self, from: errData) {
                    cont.resume(throwing: decodedErr)
                } else {
                    cont.resume(throwing: RPCError(code: "internal", detail: "Malformed error response from backend"))
                }
            }

        case "event":
            guard let eventName = json["name"] as? String,
                  let eventData = json["data"] else { return }

            handleEvent(name: eventName, data: eventData)

        default:
            break
        }
    }

    private func handleEvent(name: String, data: Any) {
        switch name {
        case "network_changed":
            if let serialized = try? JSONSerialization.data(withJSONObject: data),
               let network = try? JSONDecoder().decode(Network.self, from: serialized) {
                store?.updateNetwork(from: network)
            }

        case "network_removed":
            if let serialized = try? JSONSerialization.data(withJSONObject: data),
               let payload = try? JSONDecoder().decode(NetworkRemovedPayload.self, from: serialized) {
                store?.removeNetwork(id: payload.id)
            }

        case "notification":
            if let serialized = try? JSONSerialization.data(withJSONObject: data),
               let notif = try? JSONDecoder().decode(RPCNotificationPayload.self, from: serialized) {
                print("[nTails Notification] \(notif.title): \(notif.body)")
                deliverNotification(title: notif.title, body: notif.body)
            }

        case "invalid_config":
            if let serialized = try? JSONSerialization.data(withJSONObject: data),
               let err = try? JSONDecoder().decode(RPCError.self, from: serialized) {
                print("[ntails backend] Invalid config event: \(err.localizedDescription)")
                store?.handleInvalidConfig(err)
            }

        case "fatal":
            if let serialized = try? JSONSerialization.data(withJSONObject: data),
               let err = try? JSONDecoder().decode(RPCError.self, from: serialized) {
                print("[ntails backend] Fatal event: \(err.localizedDescription)")
                self.fatalError = err
                store?.handleFatalError(err)
            }

        default:
            break
        }
    }

    private func deliverNotification(title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                print("[RPCService] Failed to deliver system notification: \(error)")
            }
        }
    }
}
