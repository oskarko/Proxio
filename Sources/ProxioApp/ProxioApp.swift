import SwiftUI
import AppKit

@main
struct ProxioApp: App {
    @State private var model = AppModel()

    init() {
        // Running from `swift run` (no bundle) still needs a regular, activatable app.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Proxio") {
            ContentView(model: model)
                .frame(minWidth: 960, minHeight: 520)
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Proxy") {
                Button(model.isRunning ? "Stop" : "Start") { model.toggleProxy() }.keyboardShortcut("r")
                Button("Clear Session") { model.clear() }.keyboardShortcut("k")
            }
        }
    }
}
