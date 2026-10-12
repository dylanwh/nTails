import Foundation
import AppKit

@MainActor
final class SSHConfigManager {
    static let shared = SSHConfigManager()

    private let bookmarkKey = "nTailsSSHConfigBookmark"
    private let pathKey = "nTailsSSHConfigPath"
    private let autoUpdateKey = "nTailsSSHConfigAutoUpdate"

    private let beginMarker = "# BEGIN NTAILS CONFIG"
    private let endMarker = "# END NTAILS CONFIG"

    private init() {}

    // MARK: - Persistence

    var savedPath: String {
        get {
            UserDefaults.standard.string(forKey: pathKey) ?? Settings.defaultSSHConfigPath
        }
        set {
            UserDefaults.standard.set(newValue, forKey: pathKey)
        }
    }

    var autoUpdate: Bool {
        get {
            if UserDefaults.standard.object(forKey: autoUpdateKey) == nil {
                return true
            }
            return UserDefaults.standard.bool(forKey: autoUpdateKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: autoUpdateKey)
        }
    }

    var bookmarkData: Data? {
        get {
            UserDefaults.standard.data(forKey: bookmarkKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: bookmarkKey)
        }
    }

    func saveBookmark(for url: URL) {
        savedPath = url.path
        do {
            let data = try url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarkData = data
        } catch {
            print("[SSHConfigManager] Failed to create security-scoped bookmark: \(error)")
        }
    }

    func resetToDefault() {
        savedPath = Settings.defaultSSHConfigPath
        bookmarkData = nil
    }

    // MARK: - Helpers

    /// Formats a full path to display `~` instead of the full user home directory.
    static func displayablePath(from fullPath: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if fullPath.hasPrefix(home) {
            return "~" + fullPath.dropFirst(home.count)
        }
        return fullPath
    }

    func executablePath() -> String {
        if let execURL = RPCService.locateExecutableURL() {
            return execURL.path
        }
        let bundleHelper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/ntailsd").path
        if FileManager.default.isExecutableFile(atPath: bundleHelper) {
            return bundleHelper
        }
        return "/Applications/nTails.app/Contents/Helpers/ntailsd"
    }

    // MARK: - Snippet Generation

    func generateBlockContent(domains: [String]) -> String {
        let cleanDomains = Array(Set(domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let exe = executablePath()
        let escapedExe = exe.contains(" ") ? "\"\(exe)\"" : exe

        var lines: [String] = []
        lines.append(beginMarker)
        if cleanDomains.isEmpty {
            lines.append("# No active tailnet domains configured yet.")
            lines.append("# Once a tailnet connects, nTails will populate its Host patterns here.")
        } else {
            let hostPatterns = cleanDomains.map { d in
                d.hasPrefix("*.") ? d : "*.\(d)"
            }.joined(separator: " ")
            lines.append("Host \(hostPatterns)")
            lines.append("    ProxyCommand \(escapedExe) connect %h %p")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    func previewSnippet(domains: [String]) -> String {
        let cleanDomains = Array(Set(domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        let exe = executablePath()
        let escapedExe = exe.contains(" ") ? "\"\(exe)\"" : exe

        if cleanDomains.isEmpty {
            return "Host *.tailc7714.ts.net *.on.default.horse\n    ProxyCommand \(escapedExe) connect %h %p"
        } else {
            let hostPatterns = cleanDomains.map { d in
                d.hasPrefix("*.") ? d : "*.\(d)"
            }.joined(separator: " ")
            return "Host \(hostPatterns)\n    ProxyCommand \(escapedExe) connect %h %p"
        }
    }

    // MARK: - File Writing

    func writeSSHConfig(domains: [String], targetPath: String? = nil) throws {
        let path = targetPath ?? savedPath
        let expandedPath = (path as NSString).expandingTildeInPath
        let targetURL = URL(fileURLWithPath: expandedPath)

        var resolvedURL: URL?
        var isStale = false
        if let bookmark = bookmarkData {
            if let url = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &isStale) {
                resolvedURL = url
                if isStale {
                    if let newBookmark = try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil) {
                        bookmarkData = newBookmark
                    }
                }
            }
        }

        let writeURL = resolvedURL ?? targetURL
        let isSecurityScoped = writeURL.startAccessingSecurityScopedResource()
        defer {
            if isSecurityScoped {
                writeURL.stopAccessingSecurityScopedResource()
            }
        }

        let parentDir = writeURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parentDir.path) {
            try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true, attributes: [
                .posixPermissions: 0o700
            ])
        }

        let block = generateBlockContent(domains: domains)

        var newContent: String
        if FileManager.default.fileExists(atPath: writeURL.path) {
            let existingContent = try String(contentsOf: writeURL, encoding: .utf8)
            if let beginRange = existingContent.range(of: beginMarker),
               let endRange = existingContent.range(of: endMarker, range: beginRange.upperBound..<existingContent.endIndex) {
                let fullBlockRange = beginRange.lowerBound..<endRange.upperBound
                newContent = existingContent.replacingCharacters(in: fullBlockRange, with: block)
            } else {
                let separator = existingContent.hasSuffix("\n\n") ? "" : (existingContent.hasSuffix("\n") ? "\n" : "\n\n")
                newContent = existingContent + separator + block + "\n"
            }
        } else {
            newContent = block + "\n"
        }

        guard let data = newContent.data(using: .utf8) else {
            throw NSError(
                domain: "nTailsSSH",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Failed to encode SSH config into UTF-8"]
            )
        }

        try data.write(to: writeURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: writeURL.path)
    }

    // MARK: - Panel Presentations

    func promptSelectFile(window: NSWindow? = nil, completion: @escaping (URL?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Select SSH Config File"
        panel.prompt = "Select"
        panel.message = "Choose an SSH configuration file to update (e.g. ~/.ssh/config)"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.showsHiddenFiles = true
        panel.treatsFilePackagesAsDirectories = false

        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: sshDir.path) {
            panel.directoryURL = sshDir
        }

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let selectedURL = panel.url else {
                completion(nil)
                return
            }
            self?.saveBookmark(for: selectedURL)
            completion(selectedURL)
        }

        if let window {
            panel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            let res = panel.runModal()
            handler(res)
        }
    }

    func promptCreateFile(window: NSWindow? = nil, completion: @escaping (URL?) -> Void) {
        let savePanel = NSSavePanel()
        savePanel.title = "Create SSH Config File"
        savePanel.prompt = "Save"
        savePanel.message = "Create or choose a destination file for nTails SSH configuration"
        savePanel.showsHiddenFiles = true
        savePanel.canCreateDirectories = true
        savePanel.nameFieldStringValue = "config"

        let sshDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
        if FileManager.default.fileExists(atPath: sshDir.path) {
            savePanel.directoryURL = sshDir
        }

        let handler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let selectedURL = savePanel.url else {
                completion(nil)
                return
            }
            self?.saveBookmark(for: selectedURL)
            completion(selectedURL)
        }

        if let window {
            savePanel.beginSheetModal(for: window, completionHandler: handler)
        } else {
            let res = savePanel.runModal()
            handler(res)
        }
    }
}
