import SwiftUI
import AppKit

/// Connection state mapped to Xcode Asset Catalog template icons for nTails.
public enum NTailsConnectionState: String, CaseIterable, Sendable {
    case connected = "MenuBarConnected"
    case connecting = "MenuBarConnecting"
    case disconnected = "MenuBarDisconnected"

    /// Returns a template-enabled SwiftUI Image for use inside `MenuBarExtra`.
    public var menuBarImage: Image {
        Image(self.rawValue)
            .renderingMode(.template)
    }

    /// Returns a template-enabled `NSImage` for AppKit `NSStatusItem` usage.
    public var statusItemImage: NSImage? {
        let image = NSImage(named: NSImage.Name(self.rawValue))
        image?.isTemplate = true
        return image
    }
}

/// Example usage in your main SwiftUI `App` struct:
/*
@main
struct NTailsApp: App {
    @State private var connectionState: NTailsConnectionState = .connected

    var body: some Scene {
        MenuBarExtra {
            Button("Connect All Tailnets") { connectionState = .connected }
            Button("Handshake...") { connectionState = .connecting }
            Button("Disconnect") { connectionState = .disconnected }
            Divider()
            Button("Quit nTails") { NSApplication.shared.terminate(nil) }
        } label: {
            connectionState.menuBarImage
                .accessibilityLabel("nTails (\(connectionState.rawValue))")
        }
    }
}
*/
