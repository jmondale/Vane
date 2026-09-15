import SwiftUI

@main struct VaneApp: App {
    var body: some Scene {
        WindowGroup("Vane") {
            ContentView()
        }
        #if os(macOS)
        .defaultSize(width: 560, height: 600)
        .windowResizability(.contentMinSize)
        #endif
    }
}
