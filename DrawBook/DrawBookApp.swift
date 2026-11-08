import SwiftUI

@main
struct DrawBookApp: App {
    @StateObject private var store = NotebookStore()
    @StateObject private var aiSettings = AISettings()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environmentObject(aiSettings)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
        }
    }
}
