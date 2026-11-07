import UIKit
import PencilKit
import PDFKit

/// Every page uses these document coordinates, independent of screen size or zoom.
@MainActor
enum PageRenderer {
    static let pageSize = CGSize(width: 768, height: 1024)
    static let pageBounds = CGRect(origin: .zero, size: pageSize)

    enum ExportError: LocalizedError {
        case imageEncoding
        case unreadablePDF
        var errorDescription: String? {
            switch self {
            case .imageEncoding: return "The page could not be converted to an image. Please try again."
            case .unreadablePDF: return "An imported PDF page could not be read. The export was stopped to avoid leaving it out."
            }
        }
    }

    static func thumbnail(drawing: PKDrawing, paper: PaperStyle, backgroundURL: URL?, shapes: [NoteShape] = []) -> UIImage {
        image(drawing: drawing, paper: paper, backgroundURL: backgroundURL, shapes: shapes, scale: 0.4)
    }

    static func png(drawing: PKDrawing, paper: PaperStyle, backgroundURL: URL?, shapes: [NoteShape] = []) throws -> URL {
        try validateBackground(backgroundURL)
        let rendered = image(drawing: drawing, paper: paper, backgroundURL: backgroundURL, shapes: shapes, scale: 2)
        guard let data = rendered.pngData() else { throw ExportError.imageEncoding }
        let url = try exportURL(name: "Page", extension: "png")
        try data.write(to: url, options: .atomic)
        return url
    }

    static func pdf(notebook: Notebook, store: NotebookStore) throws -> URL {
        // Load before opening the renderer so a damaged ink file aborts the
        // export instead of quietly producing an empty page.
        var drawings: [UUID: PKDrawing] = [:]
        var shapes: [UUID: [NoteShape]] = [:]
        for page in notebook.pages {
            try validateBackground(store.backgroundURL(notebookID: notebook.id, pageID: page.id))
            drawings[page.id] = try store.drawingForExport(notebookID: notebook.id, pageID: page.id)
            shapes[page.id] = try store.shapes(notebookID: notebook.id, pageID: page.id)
        }
        let url = try exportURL(name: notebook.title, extension: "pdf")
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: notebook.title,
                               kCGPDFContextCreator as String: "DrawBook"]
        let renderer = UIGraphicsPDFRenderer(bounds: pageBounds, format: format)
        try renderer.writePDF(to: url) { output in
            for page in notebook.pages {
                output.beginPage()
                drawBackground(paper: page.paper,
                               backgroundURL: store.backgroundURL(notebookID: notebook.id, pageID: page.id),
                               in: output.cgContext)
                let ink = drawings[page.id] ?? PKDrawing()
                ink.image(from: pageBounds, scale: 2).draw(in: pageBounds)
                ShapeRenderer.draw(shapes[page.id] ?? [], in: output.cgContext)
            }
        }
        return url
    }

    /// Drawn by the on-screen paper view and every export, so guides and ink align.
    static func drawBackground(paper: PaperStyle, backgroundURL: URL?, in context: CGContext) {
        context.saveGState()
        defer { context.restoreGState() }
        context.setFillColor(UIColor.white.cgColor)
        context.fill(pageBounds)
        if let url = backgroundURL,
           let document = CGPDFDocument(url as CFURL), let page = document.page(at: 1) {
            context.translateBy(x: 0, y: pageSize.height)
            context.scaleBy(x: 1, y: -1)
            context.concatenate(page.getDrawingTransform(.cropBox, rect: pageBounds, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            return
        }

        let guide = UIColor(red: 0.79, green: 0.83, blue: 0.82, alpha: 0.65)
        context.setStrokeColor(guide.cgColor)
        context.setFillColor(guide.cgColor)
        context.setLineWidth(0.65)
        switch paper {
        case .blank:
            break
        case .ruled:
            for y in stride(from: CGFloat(76), through: pageSize.height - 28, by: 32) {
                context.move(to: CGPoint(x: 32, y: y))
                context.addLine(to: CGPoint(x: pageSize.width - 32, y: y))
            }
            context.strokePath()
            context.setStrokeColor(UIColor(red: 0.86, green: 0.63, blue: 0.60, alpha: 0.5).cgColor)
            context.move(to: CGPoint(x: 76, y: 32))
            context.addLine(to: CGPoint(x: 76, y: pageSize.height - 32))
            context.strokePath()
        case .grid:
            for x in stride(from: CGFloat(24), through: pageSize.width - 24, by: 24) {
                context.move(to: CGPoint(x: x, y: 24))
                context.addLine(to: CGPoint(x: x, y: pageSize.height - 24))
            }
            for y in stride(from: CGFloat(24), through: pageSize.height - 24, by: 24) {
                context.move(to: CGPoint(x: 24, y: y))
                context.addLine(to: CGPoint(x: pageSize.width - 24, y: y))
            }
            context.strokePath()
        case .dotted:
            for x in stride(from: CGFloat(32), through: pageSize.width - 32, by: 24) {
                for y in stride(from: CGFloat(32), through: pageSize.height - 32, by: 24) {
                    context.fillEllipse(in: CGRect(x: x - 1, y: y - 1, width: 2, height: 2))
                }
            }
        }
    }

    private static func image(drawing: PKDrawing, paper: PaperStyle, backgroundURL: URL?, shapes: [NoteShape], scale: CGFloat) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        return UIGraphicsImageRenderer(size: pageSize, format: format).image { output in
            drawBackground(paper: paper, backgroundURL: backgroundURL, in: output.cgContext)
            drawing.image(from: pageBounds, scale: max(scale, 1)).draw(in: pageBounds)
            ShapeRenderer.draw(shapes, in: output.cgContext)
        }
    }

    static func validateBackground(_ url: URL?) throws {
        guard let url else { return }
        guard let document = CGPDFDocument(url as CFURL), document.numberOfPages > 0 else {
            throw ExportError.unreadablePDF
        }
    }

    private static func exportURL(name: String, extension fileExtension: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DrawBook-Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
        let safeName = String(name.unicodeScalars.map { allowed.contains($0) ? Character(String($0)) : "-" }.prefix(80))
        return directory.appendingPathComponent(safeName.isEmpty ? "Notebook" : safeName)
            .appendingPathExtension(fileExtension)
    }
}
