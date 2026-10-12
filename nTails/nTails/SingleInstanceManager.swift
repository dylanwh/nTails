import Cocoa

/// Enforces that only a single instance of nTails runs at any time.
/// If another instance is already running, this activates the existing instance and terminates the new one.
final class SingleInstanceManager {
    static let shared = SingleInstanceManager()

    private var lockFileDescriptor: Int32 = -1

    private init() {}

    deinit {
        if lockFileDescriptor >= 0 {
            close(lockFileDescriptor)
        }
    }

    private var lockFileURL: URL {
        let bundleID = Bundle.main.bundleIdentifier ?? "horse.default.nTails"
        return FileManager.default.temporaryDirectory.appendingPathComponent("\(bundleID).lock")
    }

    /// Attempts to become the sole running instance. On success (`true`), the lock is
    /// held for the process's lifetime -- released automatically, even on a crash, when
    /// it exits -- and the caller should proceed with normal startup. On failure
    /// (`false`), another instance already holds the lock: that instance is activated
    /// and the caller should exit immediately without starting the backend.
    func acquireLockOrActivateExisting() -> Bool {
        let fd = open(lockFileURL.path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else {
            // Can't open the lock file; let the app proceed rather than block launch.
            return true
        }
        if flock(fd, LOCK_EX | LOCK_NB) == 0 {
            lockFileDescriptor = fd
            return true
        }
        close(fd)
        activateExistingInstance()
        return false
    }

    private func activateExistingInstance() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let currentPID = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.bundleIdentifier == bundleID && app.processIdentifier != currentPID {
            app.activate(options: [])
        }
    }
}
