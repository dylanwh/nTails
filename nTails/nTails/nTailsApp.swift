import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag {
            for window in sender.windows where window.canBecomeMain {
                if window.isMiniaturized {
                    window.deminiaturize(nil)
                }
                window.makeKeyAndOrderFront(nil)
                window.orderFrontRegardless()
                return true
            }
        }
        return true
    }
}

@main
struct nTailsApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store: NetworkStore

    init() {
        if !SingleInstanceManager.shared.acquireLockOrActivateExisting() {
            exit(0)
        }
        _store = State(initialValue: NetworkStore(usePreviewData: false))
    }

    var body: some Scene {
        Window("nTails", id: "main") {
            ContentView(store: store)
                .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
                    store.stopSync()
                }
        }
        .windowResizability(.contentMinSize)

        MenuBarExtra("nTails", systemImage: "point.3.filled.connected.trianglepath.dotted") {
            MenuBarView(store: store)
        }
    }
}
