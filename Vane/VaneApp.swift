import SwiftUI

@main struct VaneApp: App {
    var body: some Scene {
        WindowGroup("Vane") {
            ContentView()
        }
        #if os(macOS)
        // Tall enough to show the radar below the forecast on most screens;
        // macOS shrinks it to fit smaller ones, and the content scrolls.
        .defaultSize(width: 560, height: 920)
        .windowResizability(.contentMinSize)
        #endif
    }
}
