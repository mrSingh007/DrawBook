import UIKit

/// Shared vector geometry keeps editable objects and flattened exports aligned.
@MainActor
enum ShapeRenderer {
    static func path(for shape: NoteShape) -> UIBezierPath {
        let frame = shape.frame.standardized
        let path: UIBezierPath
        switch shape.kind {
        case .rectangle, .text:
            path = UIBezierPath(rect: frame)
        case .path:
            path = UIBezierPath()
            for (index, point) in shape.points.enumerated() {
                let vertex = CGPoint(x: frame.minX + point.x * frame.width,
                                     y: frame.minY + point.y * frame.height)
                if index == 0 { path.move(to: vertex) }
                else { path.addLine(to: vertex) }
            }
            if shape.closed { path.close() }
        case .ellipse:
            path = UIBezierPath(ovalIn: frame)
        case .triangle:
            path = UIBezierPath()
            path.move(to: CGPoint(x: frame.midX, y: frame.minY))
            path.addLine(to: CGPoint(x: frame.maxX, y: frame.maxY))
            path.addLine(to: CGPoint(x: frame.minX, y: frame.maxY))
            path.close()
        case .line, .arrow:
            path = UIBezierPath()
            let start = CGPoint(x: frame.minX, y: frame.maxY)
            let end = CGPoint(x: frame.maxX, y: frame.minY)
            path.move(to: start)
            path.addLine(to: end)
            if shape.kind == .arrow {
                let angle = atan2(end.y - start.y, end.x - start.x)
                let head = min(CGFloat(28), max(CGFloat(12), hypot(frame.width, frame.height) * 0.18))
                let spread = CGFloat.pi / 6
                for side in [-spread, spread] {
                    path.move(to: end)
                    path.addLine(to: CGPoint(x: end.x - head * cos(angle + side), y: end.y - head * sin(angle + side)))
                }
            }
        }
        if shape.rotation != 0 {
            path.apply(rotation(for: shape))
        }
        path.lineWidth = shape.lineWidth
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        return path
    }

    private static func rotation(for shape: NoteShape) -> CGAffineTransform {
        let frame = shape.frame.standardized
        return CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: shape.rotation * .pi / 180)
            .translatedBy(x: -frame.midX, y: -frame.midY)
    }

    private static let textDrawingOptions: NSStringDrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    /// Width of a text box made with Add Text.
    static let newTextWidth: CGFloat = 320

    /// Whether the text box's full text fits within the page height at its width and font size.
    static func textFitsPage(_ shape: NoteShape) -> Bool {
        textFitsPage(shape.text ?? "", width: shape.frame.width, fontSize: shape.fontSize)
    }

    static func textFitsPage(_ text: String, width: CGFloat, fontSize: Double) -> Bool {
        textHeight(text, width: width, fontSize: fontSize) <= PageRenderer.pageSize.height
    }

    static func textHeight(_ text: String, width: CGFloat, fontSize: Double) -> CGFloat {
        guard width.isFinite, width > 0, (6...144).contains(fontSize) else { return 0 }
        let font = UIFont.systemFont(ofSize: fontSize)
        let bounds = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: textDrawingOptions,
            attributes: [.font: font],
            context: nil
        )
        return ceil(max(font.lineHeight, bounds.height))
    }

    private static func drawText(_ shape: NoteShape, in context: CGContext) {
        guard let text = shape.text else { return }
        let frame = shape.frame.standardized
        context.saveGState()
        defer { context.restoreGState() }
        context.concatenate(rotation(for: shape))
        context.clip(to: frame)
        UIGraphicsPushContext(context)
        defer { UIGraphicsPopContext() }
        (text as NSString).draw(with: frame, options: textDrawingOptions, attributes: [
            .font: UIFont.systemFont(ofSize: shape.fontSize),
            .foregroundColor: shape.color.uiColor
        ], context: nil)
    }

    /// Converts normalized mask coordinates into the current, rotated page space.
    private static func maskTransform(for shape: NoteShape) -> CGAffineTransform {
        let frame = shape.frame.standardized
        return CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: shape.rotation * .pi / 180)
            .translatedBy(x: -frame.width / 2, y: -frame.height / 2)
            // A horizontal/vertical line still needs an invertible local space.
            .scaledBy(x: max(1, frame.width), y: max(1, frame.height))
    }

    private static func maskPath(_ mask: ShapeErasureMask, shape: NoteShape) -> CGPath {
        let path = CGMutablePath()
        guard let first = mask.points.first else { return path }
        let transform = maskTransform(for: shape)
        path.move(to: first.applying(transform))
        for point in mask.points.dropFirst() { path.addLine(to: point.applying(transform)) }
        path.closeSubpath()
        return path
    }

    private static func paintedPath(for shape: NoteShape) -> CGPath {
        let path = path(for: shape).cgPath
        var painted = path
        if shape.kind != .text {
            let stroke = path.copy(strokingWithWidth: shape.lineWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
            painted = shape.fillsPath ? stroke.union(path) : stroke
        }
        for mask in shape.erasureMasks { painted = painted.subtracting(maskPath(mask, shape: shape)) }
        return painted
    }

    static func hitTest(_ point: CGPoint, shape: NoteShape, tolerance: CGFloat) -> Bool {
        // Selecting through a hole should reach the object underneath it.
        guard !shape.erasureMasks.contains(where: { maskPath($0, shape: shape).contains(point) }) else { return false }
        let painted = paintedPath(for: shape)
        if painted.contains(point) { return true }
        guard tolerance > 0 else { return false }
        return painted.copy(strokingWithWidth: tolerance * 2, lineCap: .round, lineJoin: .round, miterLimit: 10).contains(point)
    }

    /// Retains the remaining paint for one rubber gesture. Replaying every old
    /// persisted cut for every stylus sample made long swipes progressively slower.
    @MainActor
    struct ErasureSession {
        private struct Entry {
            var shape: NoteShape
            var remaining: CGPath
            var inverse: CGAffineTransform
            var bounds: CGRect
        }
        private var entries: [UUID: Entry] = [:]

        /// A batch may contain several swept capsules as separate subpaths.
        /// Keep those subpaths separate when persisting them: joining their
        /// vertices would erase shortcuts across bends in a fast swipe.
        mutating func erasing(_ shape: NoteShape, footprint: CGPath) -> NoteShape {
            let footprintBounds = footprint.boundingBoxOfPath
            guard !footprintBounds.isNull, !footprintBounds.isInfinite else { return shape }
            var entry: Entry
            if let cached = entries[shape.id], cached.shape == shape {
                entry = cached
            } else {
                let bounds = ShapeRenderer.path(for: shape).bounds.insetBy(dx: -shape.lineWidth / 2, dy: -shape.lineWidth / 2)
                // Most objects on a page are far away from the current rubber.
                guard bounds.intersects(footprintBounds) else { return shape }
                entry = Entry(shape: shape, remaining: ShapeRenderer.paintedPath(for: shape),
                              inverse: ShapeRenderer.maskTransform(for: shape).inverted(), bounds: bounds)
            }
            guard entry.bounds.intersects(footprintBounds) else { return shape }
            let outlines = footprint.flattened(threshold: 0.15)
            guard entry.remaining.intersects(outlines) else {
                entries[shape.id] = entry
                return shape
            }
            let polygons = Self.polygons(in: outlines)
            // Rubber batches use convex swept capsules. A compound path with a
            // larger contour must be split into capsules by its caller rather
            // than silently dropping vertices or cutting a diagonal shortcut.
            guard !polygons.isEmpty, polygons.allSatisfy({ (3...256).contains($0.count) }) else { return shape }
            var changed = shape
            for points in polygons {
                let mask = ShapeErasureMask(points: points.map { $0.applying(entry.inverse) })
                if !changed.erasureMasks.contains(mask) { changed.erasureMasks.append(mask) }
            }
            guard changed.erasureMasks.count != shape.erasureMasks.count else {
                entries[shape.id] = entry
                return shape
            }
            entry.remaining = entry.remaining.subtracting(outlines)
            entry.shape = changed
            entries[shape.id] = entry
            return changed
        }

        fileprivate func remainingPath(for shape: NoteShape) -> CGPath? {
            guard let entry = entries[shape.id], entry.shape == shape else { return nil }
            return entry.remaining
        }

        private static func polygons(in path: CGPath) -> [[CGPoint]] {
            var polygons: [[CGPoint]] = []
            var current: [CGPoint] = []
            path.applyWithBlock { element in
                switch element.pointee.type {
                case .moveToPoint:
                    if !current.isEmpty { polygons.append(current) }
                    current = [element.pointee.points[0]]
                case .addLineToPoint:
                    current.append(element.pointee.points[0])
                case .closeSubpath:
                    if !current.isEmpty { polygons.append(current); current = [] }
                default: break // The caller supplies a flattened path.
                }
            }
            if !current.isEmpty { polygons.append(current) }
            return polygons
        }
    }

    /// Convenience for an individual swept capsule; interactive erasing reuses
    /// ErasureSession across display frames instead of rebuilding it per point.
    static func erasing(_ shape: NoteShape, from start: CGPoint, to end: CGPoint, width: CGFloat) -> NoteShape {
        guard width.isFinite, width > 0,
              [start.x, start.y, end.x, end.y].allSatisfy({ $0.isFinite }) else { return shape }
        let footprint: CGPath
        if hypot(end.x - start.x, end.y - start.y) < 0.001 {
            footprint = CGPath(ellipseIn: CGRect(x: start.x - width / 2, y: start.y - width / 2, width: width, height: width), transform: nil)
        } else {
            let line = CGMutablePath()
            line.move(to: start); line.addLine(to: end)
            footprint = line.copy(strokingWithWidth: width, lineCap: .round, lineJoin: .round, miterLimit: 10)
        }
        var session = ErasureSession()
        return session.erasing(shape, footprint: footprint)
    }

    static func draw(_ shapes: [NoteShape], in context: CGContext, erasureSession: ErasureSession? = nil) {
        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: PageRenderer.pageBounds)
        for shape in shapes {
            context.saveGState()
            if shape.kind != .text, let remaining = erasureSession?.remainingPath(for: shape) {
                // During a rubber gesture, reuse the already-cut geometry rather
                // than recreating an offscreen layer and replaying every mask.
                context.setFillColor(shape.color.uiColor.cgColor)
                context.addPath(remaining)
                context.fillPath()
                context.restoreGState()
                continue
            }
            // Each shape gets its own isolated layer: holes reveal lower ink,
            // shapes, ruled paper, and PDF backgrounds without clearing them.
            if !shape.erasureMasks.isEmpty { context.beginTransparencyLayer(auxiliaryInfo: nil) }
            if shape.kind == .text {
                drawText(shape, in: context)
            } else {
                let path = path(for: shape)
                context.setStrokeColor(shape.color.uiColor.cgColor)
                context.setFillColor(shape.color.uiColor.cgColor)
                context.setLineWidth(shape.lineWidth)
                context.setLineCap(.round)
                context.setLineJoin(.round)
                context.addPath(path.cgPath)
                if shape.fillsPath { context.drawPath(using: .fillStroke) }
                else { context.strokePath() }
            }
            if !shape.erasureMasks.isEmpty {
                context.setBlendMode(.destinationOut)
                context.setFillColor(UIColor.black.cgColor)
                for mask in shape.erasureMasks {
                    context.addPath(maskPath(mask, shape: shape))
                    context.fillPath()
                }
                context.setBlendMode(.normal)
                context.endTransparencyLayer()
            }
            context.restoreGState()
        }
    }
}
