import SwiftUI

@main
struct DrawBookApp: App {
    @StateObject private var store = NotebookStore()

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .tint(Theme.accent)
                .preferredColorScheme(.light)
        }
    }
}
