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
            NoteShape(kind: .path, frame: CGRect(x: 248, y: 452, width: 132, height: 63), color: green, lineWidth: 6,
                      points: [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 1)]),
            NoteShape(kind: .line, frame: CGRect(x: 380, y: 552, width: 87, height: 64), color: green, lineWidth: 6)
        ].map { shape in
            var compact = shape
            compact.frame = CGRect(x: (shape.frame.minX - 384) * 0.45 + 384,
                                   y: shape.frame.minY * 0.45 + 30,
                                   width: shape.frame.width * 0.45,
                                   height: shape.frame.height * 0.45)
            compact.lineWidth *= 0.65
            return compact
        }, notebookID: journal, pageID: page.id)
        try await capture(LibraryView().environmentObject(store), name: "library", settings: AISettings())
        let settings = AISettings.screenshotConfiguration()
        let workspace = editor(NotebookEditor(notebookID: journal), store: store)
        try await capture(workspace, name: "editor", settings: settings)
        let chat = DrawingAIChat(screenshotBubbles: [
            .init(text: "Add two green leaves to the stem.", fromUser: true),
            .init(text: "I added two green leaves. You can move or resize them in Shapes mode.", fromUser: false)
        ])
        // Host the real chat view in the snapshot window so XCTest captures it with the canvas.
        let workspaceWithChat = workspace.overlay(alignment: .bottomTrailing) {
            DrawingAIChatView(chat: chat, provider: settings.provider, model: settings.model,
                              imageInput: settings.imageInput, pageNumber: 1, pageCount: 2,
                              includeInk: .constant(true), onSend: {}, onClose: {})
                .frame(width: 400, height: 360)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
                .overlay { RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.accent.opacity(0.16)) }
                .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
                .padding(.trailing, 12)
                .padding(.bottom, 118)
        }
        try await capture(workspaceWithChat, name: "drawing-ai", settings: settings)
    }

    private func editor(_ editor: NotebookEditor, store: NotebookStore) -> some View {
        NavigationStack {
            editor
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Notebooks", systemImage: "chevron.left") {}
                    }
                }
        }.environmentObject(store)
    }

    @MainActor
    private func capture<V: View>(_ view: V, name: String, settings: AISettings) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let original = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        defer {
            window.isHidden = true
            original?.makeKeyAndVisible()
        }
        window.frame = CGRect(x: 0, y: 0, width: 1194, height: 834)
        // These standalone hosts do not inherit the environment from DrawBookApp.
        let host = UIHostingController(rootView: view
            .environmentObject(settings)
            .tint(Theme.accent)
            .preferredColorScheme(.light)
            .environment(\.horizontalSizeClass, .regular)
            .environment(\.locale, Locale(identifier: "en_US")))
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
        let image = UIGraphicsImageRenderer(bounds: window.bounds, format: format).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        let attachment = XCTAttachment(data: try XCTUnwrap(image.pngData()), uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
