// Compiled only in the temporary project created by capture-screenshots.sh.
// Renders the real SwiftUI screens with fictional data; never edits a user's library.
import SwiftUI

final class DocumentationScreenshots: XCTestCase {
    @MainActor
    func testCaptureScreenshots() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = NotebookStore(rootURL: root)
        let journal = try XCTUnwrap(store.createNotebook(title: "Everyday ideas", cover: .sage, paper: .dotted))
        _ = store.createNotebook(title: "Weekend sketches", cover: .terracotta, paper: .blank)
        _ = store.createNotebook(title: "Things to learn", cover: .blue, paper: .ruled)
        _ = store.createNotebook(title: "Small adventures", cover: .gold, paper: .grid)
        let page = try XCTUnwrap(store.notebook(id: journal)?.pages.first)
        _ = store.addPage(notebookID: journal, paper: .ruled)
        let green = RGBAColor(red: 0.22, green: 0.37, blue: 0.30)
        let amber = RGBAColor(red: 0.85, green: 0.61, blue: 0.29)
        try store.saveShapes([
            NoteShape(kind: .ellipse, frame: CGRect(x: 310, y: 160, width: 148, height: 148), color: amber, lineWidth: 4, filled: true),
            NoteShape(kind: .ellipse, frame: CGRect(x: 168, y: 400, width: 160, height: 105), color: green, lineWidth: 4, filled: true, rotation: 30),
            NoteShape(kind: .ellipse, frame: CGRect(x: 387, y: 500, width: 160, height: 105), color: green, lineWidth: 4, filled: true, rotation: -30),
            NoteShape(kind: .line, frame: CGRect(x: 380, y: 313, width: 1, height: 400), color: green, lineWidth: 7),
            NoteShape(kind: .line, frame: CGRect(x: 275, y: 475, width: 105, height: 85), color: green, lineWidth: 6),
            NoteShape(kind: .line, frame: CGRect(x: 380, y: 560, width: 100, height: 50), color: green, lineWidth: 6, rotation: -50)
        ].map { shape in
            var compact = shape
            compact.frame = CGRect(x: (shape.frame.minX - 384) * 0.45 + 384,
                                   y: shape.frame.minY * 0.45 + 30,
                                   width: shape.frame.width * 0.45,
                                   height: shape.frame.height * 0.45)
            compact.lineWidth *= 0.65
            return compact
        }, notebookID: journal, pageID: page.id)
        try await capture(LibraryView().environmentObject(store).tint(Theme.accent).preferredColorScheme(.light), name: "library")
        try await capture(NavigationStack {
            NotebookEditor(notebookID: journal)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Notebooks", systemImage: "chevron.left") {}
                    }
                }
        }.environmentObject(store).tint(Theme.accent).preferredColorScheme(.light), name: "editor")
    }

    @MainActor
    private func capture<V: View>(_ view: V, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        let host = UIHostingController(rootView: view.environment(\.horizontalSizeClass, .regular).environment(\.locale, Locale(identifier: "en_US")))
        window.rootViewController = host
        window.overrideUserInterfaceStyle = .light
        window.makeKeyAndVisible()
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        try await Task.sleep(nanoseconds: 1_500_000_000)
        host.view.layoutIfNeeded()
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds, format: format).image { _ in
            host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        window.isHidden = true
        original?.makeKeyAndVisible()
    }
}
