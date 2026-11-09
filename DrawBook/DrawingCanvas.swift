import SwiftUI
import PencilKit

/// Drawing tools and presentation-only laser marks share the same page coordinates.
enum CanvasMode: String, CaseIterable, Identifiable {
    case ink, shapes, laser
    var id: String { rawValue }
    var title: String { switch self { case .ink: return "Draw"; case .shapes: return "Shapes"; case .laser: return "Laser" } }
    var symbol: String { switch self { case .ink: return "pencil.tip"; case .shapes: return "square.on.circle"; case .laser: return "laser.burst" } }
}

enum PageTurnDirection: Equatable { case previous, next }
enum PageEntryPosition: Equatable { case top, bottom }

@MainActor
final class CanvasController: ObservableObject {
    fileprivate weak var host: PaperCanvasHost?
    fileprivate var preferredTool: PKTool?
    /// The last ink brush chosen in the toolbar, kept while the eraser or lasso is active.
    private(set) var currentInk = PKInkingTool(.pen, color: .black, width: 3)
    @Published private(set) var canUndo = false
    @Published private(set) var canRedo = false
    @Published private(set) var selectedShape: NoteShape?
    @Published private(set) var rulerActive = false

    func undo() { host?.canvas.historyUndoManager.undo(); refreshHistory() }
    func redo() { host?.canvas.historyUndoManager.redo(); refreshHistory() }
    func clear() { host?.clearPage(); refreshHistory() }
    func finishEditing() -> PKDrawing? { host?.finishErasing(); return host?.canvas.drawing }
    func finishEditing(pageID: UUID) -> PKDrawing? {
        guard host?.pageID == pageID else { return nil }
        host?.finishErasing()
        return host?.canvas.drawing
    }
    func finishShapes(pageID: UUID) -> [NoteShape]? {
        guard host?.pageID == pageID else { return nil }
        host?.finishShapeGesture()
        return host?.shapes
    }
    func applyAIPage(_ changed: AIPageContent, replacing original: AIPageContent, pageID: UUID) -> Bool {
        guard let host, host.pageID == pageID else { return false }
        return host.applyAIPage(changed, replacing: original)
    }
    func focus() { host?.focusCanvas() }
    func discardTransientMarks() { host?.clearLaserTrails() }

    func configureInk(type: PKInkingTool.InkType, color: UIColor, width: CGFloat) {
        let tool = PKInkingTool(type, color: color, width: max(0.5, min(width, 40)))
        preferredTool = tool
        currentInk = tool
        host?.applyTool(tool)
    }
    func useEraser(width: CGFloat = 24) {
        let tool = PKEraserTool(.fixedWidthBitmap, width: max(4, min(width, 80)))
        preferredTool = tool
        host?.applyTool(tool)
    }
    func useLasso() {
        let tool = PKLassoTool()
        preferredTool = tool
        host?.applyTool(tool)
    }
    func toggleRuler() {
        rulerActive.toggle()
        host?.canvas.isRulerActive = rulerActive && host?.mode == .ink
    }
    func addShape(kind: ShapeKind, color: RGBAColor, lineWidth: Double, filled: Bool) {
        host?.addShape(kind: kind, color: color, lineWidth: lineWidth, filled: filled)
    }
    func updateSelectedShape(kind: ShapeKind? = nil, color: RGBAColor? = nil, lineWidth: Double? = nil,
                             filled: Bool? = nil, rotation: Double? = nil, fontSize: Double? = nil) {
        host?.updateSelectedShape(kind: kind, color: color, lineWidth: lineWidth, filled: filled,
                                  rotation: rotation, fontSize: fontSize)
    }
    func addText(_ text: String, color: RGBAColor) { host?.addText(text, color: color) }
    func updateSelectedText(_ text: String) { host?.updateSelectedText(text) }
    func deleteSelectedShape() { host?.deleteSelectedShape() }
    func duplicateSelectedShape() { host?.duplicateSelectedShape() }

    func attach(_ host: PaperCanvasHost) {
        self.host = host
        host.controller = self
        if let preferredTool { host.applyTool(preferredTool) }
        DispatchQueue.main.async { [weak self, weak host] in
            guard let self, self.host === host else { return }
            self.refreshHistory()
            self.selectedShape = host?.selectedShape
        }
    }
    fileprivate func selectionChanged(_ shape: NoteShape?) {
        if selectedShape != shape { selectedShape = shape }
    }
    fileprivate func refreshHistory() {
        let undo = host?.canvas.historyUndoManager.canUndo ?? false
        let redo = host?.canvas.historyUndoManager.canRedo ?? false
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }
}

/// Metapen models recognized as pencils use PencilKit; touch-only pens use Touch drawing.
struct DrawingCanvas: UIViewRepresentable {
    var pageID: UUID
    var drawing: PKDrawing
    var paper: PaperStyle
    var backgroundURL: URL?
    var fingerDrawing: Bool
    var controller: CanvasController
    var onChange: (PKDrawing) -> Void
    var shapes: [NoteShape] = []
    var mode: CanvasMode = .ink
    var onShapesChange: ([NoteShape]) -> Void = { _ in }
    var canGoPrevious = false
    var canGoNext = false
    var entryPosition: PageEntryPosition = .top
    var onPageTurn: (PageTurnDirection) -> Void = { _ in }

    func makeUIView(context: Context) -> PaperCanvasHost {
        let host = PaperCanvasHost(pageID: pageID, drawing: drawing, paper: paper, backgroundURL: backgroundURL, shapes: shapes)
        host.onChange = onChange
        host.onShapesChange = onShapesChange
        host.configurePageNavigation(canGoPrevious: canGoPrevious, canGoNext: canGoNext, entryPosition: entryPosition, onTurn: onPageTurn)
        controller.attach(host)
        host.configure(mode: mode, fingerDrawing: fingerDrawing)
        return host
    }
    func updateUIView(_ host: PaperCanvasHost, context: Context) {
        host.onChange = onChange
        host.onShapesChange = onShapesChange
        host.configurePageNavigation(canGoPrevious: canGoPrevious, canGoNext: canGoNext, entryPosition: entryPosition, onTurn: onPageTurn)
        host.controller = controller
        controller.host = host
        host.configure(mode: mode, fingerDrawing: fingerDrawing)
        host.setPaper(paper, backgroundURL: backgroundURL)
        host.setShapes(shapes)
        // The live canvas owns its ink; reapplying snapshots would interrupt a stroke.
    }
    static func dismantleUIView(_ host: PaperCanvasHost, coordinator: ()) {
        host.finishShapeGesture()
        host.onChange?(host.canvas.drawing)
        host.stopTools()
        if host.controller?.host === host {
            let controller = host.controller
            controller?.host = nil
            DispatchQueue.main.async { [weak controller] in
                // A new page may already have attached before this deferred
                // cleanup runs. Never clear that page's current selection.
                guard controller?.host == nil else { return }
                controller?.refreshHistory()
                controller?.selectionChanged(nil)
            }
        }
    }
}

@MainActor
final class PaperCanvasHost: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    let pageID: UUID
    private(set) var canvas = PageCanvasView()
    private let paperView: PaperSurface
    private let overlay = EditingSurface()
    private var editPan: UIPanGestureRecognizer!
    private var editTap: UITapGestureRecognizer!
    private var eraserGesture: RubberGestureRecognizer!
    private var fingerDrawing = false
    private var eraserStartDrawing: PKDrawing?
    private var eraserStartShapes: [NoteShape]?
    private var eraserLastPoint: CGPoint?
    private var eraserChangedInk = false
    private var eraserPendingPoints: [CGPoint] = []
    private struct NativeErasureOrigin {
        var ink: PKDrawing
        var shapes: [NoteShape]
        var undoRegistered = false
    }
    private var nativeErasureOrigin: NativeErasureOrigin?
    private var eraserShapeSession = ShapeRenderer.ErasureSession()
    private var eraserDisplayLink: CADisplayLink?
    private(set) var eraserFrameCommitCount = 0
    private var eraserWidth: CGFloat { (canvas.tool as? PKEraserTool)?.width ?? 24 }
    private var isErasing: Bool { mode == .ink && canvas.tool is PKEraserTool }
    private var canGoPrevious = false
    private var canGoNext = false
    private var pageEntryPosition: PageEntryPosition = .top
    private var appliedPageEntry = false
    private var onPageTurn: ((PageTurnDirection) -> Void)?
    private var pagePanStart: (offset: CGPoint, top: CGFloat, bottom: CGFloat, zoom: CGFloat)?
    private var pagePanCandidate: PageTurnDirection?
    private var pagePanGeneration = 0
    private var nativeToolActive = false
    private var lastWidth: CGFloat = 0
    private var isLayingOut = false
    private(set) var mode: CanvasMode = .ink
    private(set) var shapes: [NoteShape]
    private(set) var selectedID: UUID?
    var selectedShape: NoteShape? { shapes.first { $0.id == selectedID } }
    private var gestureStartShapes: [NoteShape]?
    private var gestureStartPoint = CGPoint.zero
    private var gestureIsResize = false
    private var laserTrails: [LaserTrail] = []
    private var laserTimer: Timer?
    var visibleLaserTrailCount: Int { laserTrails.count }
    weak var controller: CanvasController?
    var onChange: ((PKDrawing) -> Void)?
    var onShapesChange: (([NoteShape]) -> Void)?

    init(pageID: UUID, drawing: PKDrawing, paper: PaperStyle, backgroundURL: URL?, shapes: [NoteShape] = []) {
        self.pageID = pageID
        self.shapes = shapes
        paperView = PaperSurface(paper: paper, backgroundURL: backgroundURL)
        super.init(frame: .zero)
        backgroundColor = UIColor(red: 0.91, green: 0.92, blue: 0.90, alpha: 1)
        clipsToBounds = true
        paperView.isUserInteractionEnabled = false
        paperView.layer.shadowColor = UIColor.black.cgColor
        paperView.layer.shadowOpacity = 0.10
        paperView.layer.shadowRadius = 10
        paperView.layer.shadowOffset = CGSize(width: 0, height: 4)
        addSubview(paperView)
        setUpCanvas(canvas)
        canvas.drawing = drawing
        canvas.minimumZoomScale = 0.1
        canvas.maximumZoomScale = 4
        canvas.delegate = self
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        addSubview(canvas)
        overlay.isUserInteractionEnabled = false
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        overlay.host = self
        addSubview(overlay)
        editPan = UIPanGestureRecognizer(target: self, action: #selector(editDragged(_:)))
        editPan.minimumNumberOfTouches = 1
        editPan.maximumNumberOfTouches = 1
        editPan.delegate = self
        editPan.cancelsTouchesInView = false
        canvas.addGestureRecognizer(editPan)
        editTap = UITapGestureRecognizer(target: self, action: #selector(editTapped(_:)))
        editTap.delegate = self
        editTap.cancelsTouchesInView = false
        editTap.require(toFail: editPan)
        canvas.addGestureRecognizer(editTap)
        eraserGesture = RubberGestureRecognizer()
        eraserGesture.delegate = self
        eraserGesture.cancelsTouchesInView = false
        eraserGesture.coordinateView = self
        eraserGesture.onBegin = { [weak self] point in
            guard let self else { return }
            self.beginErasing(at: self.documentPoint(point))
        }
        eraserGesture.onMove = { [weak self] point in
            guard let self else { return }
            self.continueErasing(at: self.documentPoint(point))
        }
        eraserGesture.onEnd = { [weak self] cancelled in self?.finishErasing(cancelled: cancelled) }
        canvas.addGestureRecognizer(eraserGesture)
        configure(mode: .ink, fingerDrawing: false)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    /// Settings every canvas instance needs; see `replaceCanvas(with:)`.
    private func setUpCanvas(_ canvas: PageCanvasView) {
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.contentSize = PageRenderer.pageSize
        canvas.alwaysBounceVertical = true
        canvas.panGestureRecognizer.addTarget(self, action: #selector(pagePanned(_:)))
        canvas.accessibilityLabel = "Notebook drawing page"
        canvas.accessibilityHint = "Use the selected tool. Pinch to zoom. Drag with a finger in Pencil mode, or two fingers with Touch drawing, to move the page. Drag past the bottom or top edge to change pages. In Shapes mode, drag a shape to move it or its corner handle to resize it."
    }
    /// Swaps in a brand-new PencilKit canvas showing `drawing`. PencilKit caches rendered
    /// tiles per canvas and, after a programmatic replacement (Clear page, AI edits, or
    /// their undo), can keep showing pieces of removed ink until the next touch. A fresh
    /// canvas has no cache, so nothing stale can remain. The page's undo history, tool,
    /// zoom, scroll position, and gestures carry over.
    private func replaceCanvas(with drawing: PKDrawing) {
        let old = canvas
        let wasFocused = old.isFirstResponder
        let fresh = PageCanvasView(history: old.historyUndoManager)
        setUpCanvas(fresh)
        fresh.setDrawingWithoutUndo(drawing)
        fresh.tool = old.tool
        fresh.usesNativeEraserUndo = old.usesNativeEraserUndo
        fresh.minimumZoomScale = old.minimumZoomScale
        fresh.maximumZoomScale = old.maximumZoomScale
        fresh.frame = old.frame
        fresh.contentInset = old.contentInset
        fresh.zoomScale = old.zoomScale
        fresh.contentOffset = old.contentOffset
        for gesture: UIGestureRecognizer in [editPan, editTap, eraserGesture] {
            old.removeGestureRecognizer(gesture)
            fresh.addGestureRecognizer(gesture)
        }
        old.delegate = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        insertSubview(fresh, aboveSubview: old)
        canvas = fresh
        fresh.delegate = self
        old.removeFromSuperview()
        configure(mode: mode, fingerDrawing: fingerDrawing)
        positionPaper()
        CATransaction.commit()
        if wasFocused { focusCanvas() }
    }
    deinit { laserTimer?.invalidate(); eraserDisplayLink?.invalidate() }

    func configure(mode: CanvasMode, fingerDrawing: Bool) {
        self.fingerDrawing = fingerDrawing
        let changed = self.mode != mode
        if changed {
            finishErasing()
            finishShapeGesture()
            self.mode = mode
            clearLaserTrails()
            if mode != .shapes { select(nil) }
        }
        canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        // In Pencil mode a finger drag moves the page (and pulls past an edge to turn it).
        // With Touch drawing one finger draws, so moving the page takes two fingers.
        // The pencil never pans: it always draws or edits.
        canvas.panGestureRecognizer.minimumNumberOfTouches = fingerDrawing ? 2 : 1
        canvas.panGestureRecognizer.allowedTouchTypes = [UITouch.TouchType.direct, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        canvas.drawingGestureRecognizer.isEnabled = mode == .ink
        eraserGesture.isEnabled = isErasing
        canvas.isRulerActive = mode == .ink && (controller?.rulerActive ?? false)
        editPan.isEnabled = mode != .ink
        editTap.isEnabled = mode != .ink
        let inputTypes = fingerDrawing ? [UITouch.TouchType.direct.rawValue, UITouch.TouchType.pencil.rawValue, UITouch.TouchType.indirectPointer.rawValue] : [UITouch.TouchType.pencil.rawValue]
        editPan.allowedTouchTypes = inputTypes.map { NSNumber(value: $0) }
        editTap.allowedTouchTypes = inputTypes.map { NSNumber(value: $0) }
        eraserGesture.allowedTouchTypes = inputTypes.map { NSNumber(value: $0) }
        if changed { focusCanvas() }
        overlay.setNeedsDisplay()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0, bounds.height > 0, !isLayingOut else { return }
        isLayingOut = true
        canvas.frame = bounds
        overlay.frame = bounds
        if abs(lastWidth - bounds.width) > 1 {
            let minimum = max(0.1, (bounds.width - 32) / PageRenderer.pageSize.width)
            let ratio = lastWidth == 0 ? 1 : canvas.zoomScale / canvas.minimumZoomScale
            canvas.minimumZoomScale = minimum
            canvas.maximumZoomScale = max(4, minimum * 4)
            canvas.zoomScale = min(canvas.maximumZoomScale, max(minimum, minimum * ratio))
            lastWidth = bounds.width
            centerPaper()
            if ratio == 1 { canvas.contentOffset = CGPoint(x: -canvas.contentInset.left, y: -canvas.contentInset.top) }
        } else { centerPaper() }
        if !appliedPageEntry {
            appliedPageEntry = true
            canvas.contentOffset.y = pageEntryPosition == .bottom ? pageBottomOffset : pageTopOffset
        }
        positionPaper()
        isLayingOut = false
    }
    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { stopTools(); return }
        focusCanvas()
    }
    func focusCanvas() {
        guard window != nil else { return }
        canvas.becomeFirstResponder()
    }
    func applyTool(_ tool: PKTool) {
        finishErasing()
        canvas.tool = tool
        if tool is PKEraserTool { canvas.usesNativeEraserUndo = true }
        configure(mode: mode, fingerDrawing: fingerDrawing)
    }
    func setPaper(_ paper: PaperStyle, backgroundURL: URL?) {
        guard paperView.paper != paper || paperView.backgroundURL != backgroundURL else { return }
        paperView.paper = paper
        paperView.backgroundURL = backgroundURL
        paperView.setNeedsDisplay()
    }
    func stopTools() {
        pagePanGeneration += 1
        resetPagePan()
        finishErasing()
        canvas.resignFirstResponder()
        clearLaserTrails()
    }
    func setShapes(_ incoming: [NoteShape]) {
        guard gestureStartShapes == nil, eraserStartShapes == nil, incoming != shapes else { return }
        shapes = incoming
        if !shapes.contains(where: { $0.id == selectedID }) { select(nil) }
        else { publishSelection() }
        overlay.setNeedsDisplay()
    }
    /// Removes ink, text, and shapes as one undoable step. Paper and PDF backgrounds stay.
    func clearPage() {
        finishErasing()
        finishShapeGesture()
        guard !canvas.drawing.strokes.isEmpty || !shapes.isEmpty else { return }
        replacePageWithUndo(AIPageContent(drawing: PKDrawing(), shapes: []), selected: nil, name: "Clear Page")
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        nativeToolActive = true
        resetPagePan()
        if !isErasing {
            // Keep the scratch route after eraser lift for delayed native
            // callbacks. A new ink/lasso gesture starts normal native history.
            nativeErasureOrigin = nil
            canvas.usesNativeEraserUndo = false
        }
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { nativeToolActive = false }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        if let original = nativeErasureOrigin, canvasView.drawing != original.ink {
            eraserChangedInk = true
            if eraserStartDrawing != nil { return }
            registerNativeErasureUndoIfNeeded()
        } else if eraserStartDrawing != nil { return }
        onChange?(canvasView.drawing)
        DispatchQueue.main.async { [weak self] in self?.controller?.refreshHistory() }
    }
    func configurePageNavigation(canGoPrevious: Bool, canGoNext: Bool, entryPosition: PageEntryPosition = .top,
                                 onTurn: @escaping (PageTurnDirection) -> Void) {
        self.canGoPrevious = canGoPrevious
        self.canGoNext = canGoNext
        if !appliedPageEntry { pageEntryPosition = entryPosition }
        onPageTurn = onTurn
    }
    private var pageTopOffset: CGFloat { -canvas.adjustedContentInset.top }
    private var pageBottomOffset: CGFloat {
        max(pageTopOffset, PageRenderer.pageSize.height * canvas.zoomScale - canvas.bounds.height + canvas.adjustedContentInset.bottom)
    }
    @objc private func pagePanned(_ pan: UIPanGestureRecognizer) {
        // The host stays still while the canvas scrolls underneath the fingers.
        trackPagePan(pan.state, translation: pan.translation(in: self), velocity: pan.velocity(in: self))
    }
    private var pagePanConflictsWithTool: Bool {
        nativeToolActive || gestureStartShapes != nil || eraserStartDrawing != nil
    }
    private func resetPagePan() {
        pagePanStart = nil
        pagePanCandidate = nil
    }
    func trackPagePan(_ state: UIGestureRecognizer.State, translation: CGPoint = .zero, velocity: CGPoint = .zero) {
        switch state {
        case .began:
            pagePanGeneration += 1
            resetPagePan()
            guard !pagePanConflictsWithTool else { return }
            pagePanStart = (canvas.contentOffset, pageTopOffset, pageBottomOffset, canvas.zoomScale)
        case .changed:
            guard !pagePanConflictsWithTool else { resetPagePan(); return }
            pagePanCandidate = pageTurnDirection(translation: translation, velocity: velocity)
        case .ended:
            // Use the last movement sample. UIKit may already be settling the offset on release.
            let direction = pagePanCandidate
            resetPagePan()
            guard !pagePanConflictsWithTool, let direction else { return }
            let generation = pagePanGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.pagePanGeneration == generation,
                      direction == .next ? self.canGoNext : self.canGoPrevious else { return }
                self.onPageTurn?(direction)
            }
        case .cancelled, .failed:
            resetPagePan()
        default:
            break
        }
    }
    private func pageTurnDirection(translation: CGPoint, velocity: CGPoint) -> PageTurnDirection? {
        guard let start = pagePanStart else { return nil }
        let offset = canvas.contentOffset
        // Retain rubber-band navigation for scrolling input with no touch translation.
        let movement = translation == .zero ? CGPoint(x: start.offset.x - offset.x, y: start.offset.y - offset.y) : translation
        guard abs(movement.y) > abs(movement.x) else { return nil }
        let movingUp = movement.y < 0
        guard movingUp ? canGoNext : canGoPrevious else { return nil }
        let direction: PageTurnDirection = movingUp ? .next : .previous
        let overscroll = movingUp ? offset.y - pageBottomOffset : pageTopOffset - offset.y
        if overscroll >= 28 { return direction }

        // A deliberate pull can turn the page even when the canvas stays at the edge.
        let edgeSlack: CGFloat = 8
        let distanceToEdge = movingUp ? start.bottom - start.offset.y : start.offset.y - start.top
        guard distanceToEdge <= edgeSlack || overscroll >= -edgeSlack else { return nil }
        let travelPastEdge = abs(translation.y) - max(0, distanceToEdge - edgeSlack)
        let outwardVelocity = movingUp ? -velocity.y : velocity.y
        return travelPastEdge > 44 || (travelPastEdge > 20 && outwardVelocity > 500) ? direction : nil
    }
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        positionPaper()
        // UIKit can apply the offset after our pan target sees the change.
        let pan = canvas.panGestureRecognizer
        if pagePanStart != nil, pan.state == .changed, pan.translation(in: self) == .zero {
            trackPagePan(.changed)
        }
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        // A little pinch drift is normal during a two-finger drag.
        if let start = pagePanStart, abs(canvas.zoomScale / start.zoom - 1) > 0.04 {
            resetPagePan()
        }
        centerPaper()
        positionPaper()
    }
    private func centerPaper() {
        let width = PageRenderer.pageSize.width * canvas.zoomScale
        let height = PageRenderer.pageSize.height * canvas.zoomScale
        let horizontal = max(16, (bounds.width - width) / 2)
        let vertical = max(16, (bounds.height - height) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }
    private func positionPaper() {
        paperView.frame = CGRect(x: -canvas.contentOffset.x, y: -canvas.contentOffset.y,
                                 width: PageRenderer.pageSize.width * canvas.zoomScale,
                                 height: PageRenderer.pageSize.height * canvas.zoomScale)
        overlay.setNeedsDisplay()
    }

    // MARK: Editable vector shapes
    func addShape(kind: ShapeKind, color: RGBAColor, lineWidth: Double, filled: Bool) {
        guard kind.isPrimitive else { return }
        let center = documentPoint(CGPoint(x: bounds.midX, y: bounds.midY))
        let frame = bounded(CGRect(x: center.x - 90, y: center.y - 65, width: 180, height: 130))
        let shape = NoteShape(kind: kind, frame: frame, color: color, lineWidth: lineWidth, filled: filled)
        replaceShapesWithUndo(shapes + [shape], selected: shape.id, name: "Add Shape")
    }
    func addText(_ text: String, color: RGBAColor) {
        let center = documentPoint(CGPoint(x: bounds.midX, y: bounds.midY))
        var shape = NoteShape(kind: .text, frame: CGRect(x: center.x - 160, y: center.y, width: ShapeRenderer.newTextWidth, height: 30),
                              color: color, text: text)
        guard shape.hasValidContent, ShapeRenderer.textFitsPage(shape) else { return }
        fitText(&shape)
        replaceShapesWithUndo(shapes + [shape], selected: shape.id, name: "Add Text")
    }
    func updateSelectedText(_ text: String) {
        guard let index = shapes.firstIndex(where: { $0.id == selectedID && $0.kind == .text }),
              shapes[index].text != text else { return }
        var changed = shapes
        changed[index].text = text
        guard changed[index].hasValidContent, ShapeRenderer.textFitsPage(changed[index]) else { return }
        fitText(&changed[index])
        replaceShapesWithUndo(changed, selected: selectedID, name: "Edit Text")
    }
    private func fitText(_ shape: inout NoteShape) {
        guard let text = shape.text else { return }
        shape.frame.size.height = ShapeRenderer.textHeight(text, width: shape.frame.width, fontSize: shape.fontSize)
        shape.frame = bounded(shape.frame)
    }
    func updateSelectedShape(kind: ShapeKind? = nil, color: RGBAColor? = nil, lineWidth: Double? = nil,
                             filled: Bool? = nil, rotation: Double? = nil, fontSize: Double? = nil) {
        guard let index = shapes.firstIndex(where: { $0.id == selectedID }) else { return }
        var changed = shapes
        if let kind, kind.isPrimitive, changed[index].kind.isPrimitive, changed[index].kind != kind {
            changed[index].kind = kind
            // A flat line becomes a closed shape with two positive sides, which storage requires.
            changed[index].frame = bounded(changed[index].frame, kind: kind)
        }
        if let color { changed[index].color = color }
        if let lineWidth, lineWidth.isFinite { changed[index].lineWidth = min(40, max(0.5, lineWidth)) }
        if let filled { changed[index].filled = filled }
        if let rotation, rotation.isFinite { changed[index].rotation = rotation.truncatingRemainder(dividingBy: 360) }
        if let fontSize, (6...144).contains(fontSize), changed[index].kind == .text {
            changed[index].fontSize = fontSize
            // A larger font must not push text past the page, where it would be clipped.
            guard ShapeRenderer.textFitsPage(changed[index]) else { return }
            fitText(&changed[index])
        }
        guard changed != shapes else { return }
        replaceShapesWithUndo(changed, selected: selectedID, name: "Change Shape")
    }
    func deleteSelectedShape() {
        guard let selectedID else { return }
        replaceShapesWithUndo(shapes.filter { $0.id != selectedID }, selected: nil, name: "Delete Shape")
    }
    func duplicateSelectedShape() {
        guard var copy = selectedShape else { return }
        copy.id = UUID()
        copy.frame = bounded(copy.frame.offsetBy(dx: 24, dy: 24), kind: copy.kind)
        replaceShapesWithUndo(shapes + [copy], selected: copy.id, name: "Duplicate Shape")
    }
    fileprivate func applyAIPage(_ changed: AIPageContent, replacing original: AIPageContent) -> Bool {
        guard changed != original else { return true }
        // Ink IDs refer to the captured drawing. A gesture still in progress
        // can change the page even before PencilKit publishes its first stroke.
        guard !nativeToolActive, eraserStartDrawing == nil, gestureStartShapes == nil,
              shapes == original.shapes,
              canvas.drawing.dataRepresentation() == original.drawing.dataRepresentation() else { return false }
        let selection = selectedID.flatMap { id in changed.shapes.contains { $0.id == id } ? id : nil }
        replacePageWithUndo(changed, selected: selection, name: "AI Canvas Edits")
        return true
    }
    private func replacePageWithUndo(_ changed: AIPageContent, selected: UUID?, name: String) {
        let previous = AIPageContent(drawing: canvas.drawing, shapes: shapes)
        let oldSelection = selectedID
        canvas.historyUndoManager.registerUndo(withTarget: self) {
            $0.replacePageWithUndo(previous, selected: oldSelection, name: name)
        }
        canvas.historyUndoManager.setActionName(name)
        if changed.drawing != previous.drawing {
            nativeErasureOrigin = nil
            replaceCanvas(with: changed.drawing)
            onChange?(changed.drawing)
        }
        if changed.shapes != previous.shapes {
            shapes = changed.shapes
            select(selected)
            onShapesChange?(shapes)
        }
        overlay.setNeedsDisplay()
        controller?.refreshHistory()
    }
    private func replaceShapesWithUndo(_ changed: [NoteShape], selected: UUID?, name: String) {
        let previous = shapes
        let oldSelection = selectedID
        canvas.historyUndoManager.registerUndo(withTarget: self) { $0.replaceShapesWithUndo(previous, selected: oldSelection, name: name) }
        canvas.historyUndoManager.setActionName(name)
        shapes = changed
        select(selected)
        overlay.setNeedsDisplay()
        onShapesChange?(changed)
        controller?.refreshHistory()
    }
    private func select(_ id: UUID?) {
        selectedID = id
        publishSelection()
        overlay.setNeedsDisplay()
    }
    private func publishSelection() {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.controller?.host === self else { return }
            self.controller?.selectionChanged(self.selectedShape)
        }
    }
    /// Scroll-view local coordinates already include bounds.origin/contentOffset.
    /// Convert to host coordinates before adding the offset exactly once.
    func documentPoint(fromCanvasPoint point: CGPoint) -> CGPoint {
        documentPoint(canvas.convert(point, to: self))
    }
    private func documentPoint(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x + canvas.contentOffset.x) / canvas.zoomScale,
                y: (point.y + canvas.contentOffset.y) / canvas.zoomScale)
    }
    private func bounded(_ frame: CGRect, kind: ShapeKind = .rectangle) -> CGRect {
        // Use the signed size and original anchor. CGRect's standardized
        // dimensions/minimums would flip a shape after dragging past its origin.
        let requestedWidth = frame.size.width
        let requestedHeight = frame.size.height
        let minimumSide: CGFloat = kind == .path ? 1 : 20
        let allowsFlatSide = kind == .line || kind == .arrow
        let width = max(allowsFlatSide && requestedWidth == 0 ? 0 : minimumSide, min(requestedWidth, PageRenderer.pageSize.width))
        let height = max(allowsFlatSide && requestedHeight == 0 ? 0 : minimumSide, min(requestedHeight, PageRenderer.pageSize.height))
        return CGRect(x: min(max(frame.origin.x, 0), PageRenderer.pageSize.width - width),
                      y: min(max(frame.origin.y, 0), PageRenderer.pageSize.height - height), width: width, height: height)
    }
    private func shape(at point: CGPoint) -> NoteShape? {
        for shape in shapes.reversed() {
            if ShapeRenderer.hitTest(point, shape: shape, tolerance: 9 / canvas.zoomScale) { return shape }
        }
        return nil
    }
    private func selectionBounds(_ shape: NoteShape) -> CGRect { ShapeRenderer.path(for: shape).bounds }
    private func handlePoint(_ shape: NoteShape) -> CGPoint {
        let frame = selectionBounds(shape)
        return CGPoint(x: frame.maxX, y: frame.maxY)
    }
    private func isResizeHandle(_ point: CGPoint, shape: NoteShape) -> Bool {
        let handle = handlePoint(shape)
        return hypot(point.x - handle.x, point.y - handle.y) <= 20 / canvas.zoomScale
    }
    @objc private func editTapped(_ gesture: UITapGestureRecognizer) {
        let point = documentPoint(gesture.location(in: self))
        guard PageRenderer.pageBounds.contains(point) else { return }
        if mode == .shapes { select(shape(at: point)?.id) }
        else if mode == .laser {
            beginLaser(at: point)
            endLaser()
        }
    }
    @objc private func editDragged(_ gesture: UIPanGestureRecognizer) {
        let point = documentPoint(gesture.location(in: self))
        if mode == .laser {
            switch gesture.state {
            case .began: beginLaser(at: point)
            case .changed: appendLaser(at: point)
            case .ended: appendLaser(at: point); endLaser()
            case .cancelled, .failed: clearLaserTrails()
            default: break
            }
            return
        }
        guard mode == .shapes else { return }
        switch gesture.state {
        case .began:
            if let selected = selectedShape, isResizeHandle(point, shape: selected) { gestureIsResize = true }
            else { select(shape(at: point)?.id); gestureIsResize = false }
            guard selectedID != nil else { return }
            gestureStartPoint = point
            gestureStartShapes = shapes
        case .changed:
            guard let original = gestureStartShapes,
                  let index = original.firstIndex(where: { $0.id == selectedID }) else { return }
            var changed = original
            let dx = point.x - gestureStartPoint.x, dy = point.y - gestureStartPoint.y
            let frame = original[index].frame
            let requested = gestureIsResize
                ? CGRect(x: frame.minX, y: frame.minY, width: frame.width + dx, height: frame.height + dy)
                : frame.offsetBy(dx: dx, dy: dy)
            changed[index].frame = bounded(requested, kind: changed[index].kind)
            shapes = changed
            publishSelection()
            overlay.setNeedsDisplay()
        case .ended: finishShapeGesture()
        case .cancelled, .failed:
            if let original = gestureStartShapes { shapes = original; publishSelection(); overlay.setNeedsDisplay() }
            gestureStartShapes = nil
        default: break
        }
    }
    func finishShapeGesture() {
        finishErasing()
        guard let original = gestureStartShapes else { return }
        gestureStartShapes = nil
        guard original != shapes else { return }
        let changed = shapes
        shapes = original
        replaceShapesWithUndo(changed, selected: selectedID, name: gestureIsResize ? "Resize Shape" : "Move Shape")
    }
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === eraserGesture || otherGestureRecognizer === eraserGesture {
            // The companion only observes input; PencilKit owns ink erasure.
            return true
        }
        return otherGestureRecognizer === canvas.panGestureRecognizer || otherGestureRecognizer === canvas.pinchGestureRecognizer
    }
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === eraserGesture {
            return isErasing && PageRenderer.pageBounds.contains(documentPoint(gestureRecognizer.location(in: self)))
        }
        guard gestureRecognizer === editPan || gestureRecognizer === editTap else { return true }
        guard mode != .ink, gestureRecognizer.numberOfTouches <= 1 else { return false }
        let point = documentPoint(gestureRecognizer.location(in: self))
        return PageRenderer.pageBounds.contains(point) || (mode == .shapes && selectedShape.map { isResizeHandle(point, shape: $0) } == true)
    }

    // MARK: Sized rubber, with one undo action for both ink and vectors
    func beginErasing(at point: CGPoint) {
        guard isErasing, PageRenderer.pageBounds.contains(point) else { return }
        finishErasing()
        eraserStartDrawing = canvas.drawing
        eraserStartShapes = shapes
        nativeErasureOrigin = NativeErasureOrigin(ink: canvas.drawing, shapes: shapes)
        canvas.usesNativeEraserUndo = true
        canvas.clearNativeEraserHistory()
        eraserShapeSession = ShapeRenderer.ErasureSession()
        eraserLastPoint = point
        eraserChangedInk = false
        eraserFrameCommitCount = 0
        continueErasing(at: point)
        guard !shapes.isEmpty else { return }
        let target = EraserFrameTarget(host: self)
        let displayLink = CADisplayLink(target: target, selector: #selector(EraserFrameTarget.tick))
        displayLink.preferredFramesPerSecond = 60
        displayLink.add(to: .main, forMode: .common)
        eraserDisplayLink = displayLink
    }
    func continueErasing(at point: CGPoint) {
        guard eraserStartDrawing != nil, !shapes.isEmpty, point.x.isFinite, point.y.isFinite else { return }
        // These samples affect vector shapes only. PencilKit handles ink
        // directly, with its native low-latency eraser and precise touch input.
        if eraserPendingPoints.last != point {
            // Exact straight runs need just their endpoints. Keep every corner
            // and reversal, including within one burst of coalesced samples.
            if eraserPendingPoints.count >= 2 {
                let anchor = eraserPendingPoints[eraserPendingPoints.count - 2]
                let last = eraserPendingPoints[eraserPendingPoints.count - 1]
                let dx = last.x - anchor.x, dy = last.y - anchor.y
                let nextX = point.x - last.x, nextY = point.y - last.y
                if abs(dx * nextY - dy * nextX) < 0.000001 && dx * nextX + dy * nextY > 0 {
                    eraserPendingPoints[eraserPendingPoints.count - 1] = point
                } else { eraserPendingPoints.append(point) }
            } else { eraserPendingPoints.append(point) }
        }
    }
    func flushErasingFrame() {
        guard var previous = eraserLastPoint, !eraserPendingPoints.isEmpty else { return }
        let points = eraserPendingPoints
        eraserPendingPoints.removeAll(keepingCapacity: true)
        guard !shapes.isEmpty else { eraserLastPoint = points.last; return }
        let rubber = CGMutablePath()
        for point in points {
            let capsule: CGPath
            if previous == point {
                capsule = CGPath(ellipseIn: CGRect(x: point.x - eraserWidth / 2, y: point.y - eraserWidth / 2,
                                                   width: eraserWidth, height: eraserWidth), transform: nil)
            } else {
                let segment = CGMutablePath()
                segment.move(to: previous)
                segment.addLine(to: point)
                capsule = segment.copy(strokingWithWidth: eraserWidth, lineCap: .round, lineJoin: .round, miterLimit: 10)
            }
            rubber.addPath(capsule)
            previous = point
        }
        eraserLastPoint = previous
        shapes = shapes.map { eraserShapeSession.erasing($0, footprint: rubber) }
        eraserFrameCommitCount += 1
        overlay.setNeedsDisplay()
    }
    func finishErasing(cancelled: Bool = false) {
        guard let originalInk = eraserStartDrawing, let originalShapes = eraserStartShapes else { return }
        eraserDisplayLink?.invalidate()
        eraserDisplayLink = nil
        // A quick tap/swipe can finish before its first display frame. Commit its
        // final samples immediately; cancellation discards that unrendered work.
        if !cancelled { flushErasingFrame() }
        eraserPendingPoints.removeAll(keepingCapacity: true)
        eraserShapeSession = ShapeRenderer.ErasureSession()
        eraserStartDrawing = nil
        eraserStartShapes = nil
        eraserLastPoint = nil
        overlay.setNeedsDisplay()
        let changedShapes = shapes != originalShapes
        eraserChangedInk = eraserChangedInk || canvas.drawing != originalInk
        if cancelled {
            nativeErasureOrigin = nil
            // Stop any in-flight native eraser interaction before restoring.
            canvas.drawingGestureRecognizer.isEnabled = false
            canvas.setDrawingWithoutUndo(originalInk)
            canvas.drawingGestureRecognizer.isEnabled = mode == .ink
            shapes = originalShapes
            if eraserChangedInk { onChange?(originalInk) }
            return
        }
        if eraserChangedInk || changedShapes { registerNativeErasureUndoIfNeeded() }
        // Do not capture a final ink snapshot here. PencilKit may deliver a final
        // drawingDidChange after tool-end; the pending origin handles that too.
        if eraserChangedInk { onChange?(canvas.drawing) }
        if changedShapes { onShapesChange?(shapes); publishSelection() }
        controller?.refreshHistory()
    }
    private func registerNativeErasureUndoIfNeeded() {
        guard var origin = nativeErasureOrigin, !origin.undoRegistered else { return }
        origin.undoRegistered = true
        nativeErasureOrigin = origin
        canvas.historyUndoManager.registerUndo(withTarget: self) { $0.restoreErasure(ink: origin.ink, shapes: origin.shapes) }
        canvas.historyUndoManager.setActionName("Erase")
        controller?.refreshHistory()
    }
    private func restoreErasure(ink: PKDrawing, shapes: [NoteShape]) {
        nativeErasureOrigin = nil
        let previousInk = canvas.drawing, previousShapes = self.shapes
        canvas.historyUndoManager.registerUndo(withTarget: self) { $0.restoreErasure(ink: previousInk, shapes: previousShapes) }
        canvas.historyUndoManager.setActionName("Erase")
        canvas.setDrawingWithoutUndo(ink)
        self.shapes = shapes
        onChange?(ink)
        onShapesChange?(shapes)
        publishSelection()
        overlay.setNeedsDisplay()
        controller?.refreshHistory()
    }

    // MARK: Transient laser (never enters ink or shape persistence)
    struct LaserTrail {
        var points: [CGPoint]
        var endedAt: TimeInterval?
    }
    func beginLaser(at point: CGPoint, time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard mode == .laser, PageRenderer.pageBounds.contains(point) else { return }
        laserTrails.append(LaserTrail(points: [point]))
        startLaserTimer()
        overlay.setNeedsDisplay()
    }
    func appendLaser(at point: CGPoint) {
        guard mode == .laser, !laserTrails.isEmpty, laserTrails[laserTrails.count - 1].endedAt == nil else { return }
        let clamped = CGPoint(x: min(max(0, point.x), PageRenderer.pageSize.width), y: min(max(0, point.y), PageRenderer.pageSize.height))
        laserTrails[laserTrails.count - 1].points.append(clamped)
        overlay.setNeedsDisplay()
    }
    func endLaser(time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        guard !laserTrails.isEmpty else { return }
        laserTrails[laserTrails.count - 1].endedAt = time
        overlay.setNeedsDisplay()
    }
    func expireLaserTrails(at time: TimeInterval = Date.timeIntervalSinceReferenceDate) {
        laserTrails.removeAll { $0.endedAt.map { time - $0 >= 3 } ?? false }
        overlay.setNeedsDisplay()
        if laserTrails.isEmpty { laserTimer?.invalidate(); laserTimer = nil }
    }
    func clearLaserTrails() {
        laserTrails.removeAll()
        laserTimer?.invalidate()
        laserTimer = nil
        overlay.setNeedsDisplay()
    }
    private func startLaserTimer() {
        guard laserTimer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expireLaserTrails() }
        }
        RunLoop.main.add(timer, forMode: .common)
        laserTimer = timer
    }
    fileprivate func drawOverlay(in context: CGContext) {
        let zoom = canvas.zoomScale
        context.saveGState()
        defer { context.restoreGState() }
        context.translateBy(x: -canvas.contentOffset.x, y: -canvas.contentOffset.y)
        context.scaleBy(x: zoom, y: zoom)
        context.clip(to: PageRenderer.pageBounds)
        ShapeRenderer.draw(shapes, in: context, erasureSession: eraserStartDrawing == nil ? nil : eraserShapeSession)
        if mode == .shapes, let selected = selectedShape {
            let frame = selectionBounds(selected).insetBy(dx: -5 / zoom, dy: -5 / zoom)
            context.setStrokeColor(UIColor.systemBlue.cgColor)
            context.setLineWidth(1.5 / zoom)
            context.setLineDash(phase: 0, lengths: [5 / zoom, 4 / zoom])
            context.stroke(frame)
            context.setLineDash(phase: 0, lengths: [])
            let handle = handlePoint(selected)
            context.setFillColor(UIColor.systemBlue.cgColor)
            context.fillEllipse(in: CGRect(x: handle.x - 6 / zoom, y: handle.y - 6 / zoom, width: 12 / zoom, height: 12 / zoom))
        }
        let now = Date.timeIntervalSinceReferenceDate
        for trail in laserTrails {
            guard let first = trail.points.first else { continue }
            let opacity = trail.endedAt.map { max(0, 1 - (now - $0) / 3) } ?? 1
            context.saveGState()
            context.setAlpha(CGFloat(opacity))
            context.setStrokeColor(UIColor.red.cgColor)
            context.setFillColor(UIColor.red.cgColor)
            context.setShadow(offset: .zero, blur: 8, color: UIColor.red.cgColor)
            context.setLineWidth(5)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            if trail.points.count == 1 { context.fillEllipse(in: CGRect(x: first.x - 3, y: first.y - 3, width: 6, height: 6)) }
            else {
                context.move(to: first)
                for point in trail.points.dropFirst() { context.addLine(to: point) }
                context.strokePath()
            }
            context.restoreGState()
        }
    }
}

@MainActor
private final class EditingSurface: UIView {
    weak var host: PaperCanvasHost?
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        host?.drawOverlay(in: context)
    }
}

/// Undo actions stay on the page whose canvas recorded them.
@MainActor
final class PageCanvasView: PKCanvasView {
    let historyUndoManager: UndoManager
    private lazy var nativeEraserUndoManager = NativeEraserUndoManager(history: historyUndoManager)
    var usesNativeEraserUndo = false
    /// Pass the previous canvas's history when replacing a page's canvas so undo keeps working.
    init(history: UndoManager = UndoManager()) {
        historyUndoManager = history
        super.init(frame: .zero)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override var undoManager: UndoManager? { usesNativeEraserUndo ? nativeEraserUndoManager : historyUndoManager }
    func clearNativeEraserHistory() { nativeEraserUndoManager.removeAllActions() }
    func setDrawingWithoutUndo(_ drawing: PKDrawing) {
        historyUndoManager.disableUndoRegistration()
        nativeEraserUndoManager.disableUndoRegistration()
        self.drawing = drawing
        nativeEraserUndoManager.enableUndoRegistration()
        historyUndoManager.enableUndoRegistration()
    }
}

/// Keep PencilKit's eraser registrations isolated, while responder-chain undo
/// (keyboard, edit menu, and system undo gestures) uses the same page history as
/// the toolbar. Native cancellation can still use its own nested undo groups.
@MainActor
private final class NativeEraserUndoManager: UndoManager {
    private weak var history: UndoManager?
    init(history: UndoManager) { self.history = history; super.init() }
    override var canUndo: Bool { history?.canUndo ?? false }
    override var canRedo: Bool { history?.canRedo ?? false }
    override var undoActionName: String { history?.undoActionName ?? "" }
    override var redoActionName: String { history?.redoActionName ?? "" }
    override func undo() { history?.undo() }
    override func redo() { history?.redo() }
}

@MainActor
private final class PaperSurface: UIView {
    var paper: PaperStyle
    var backgroundURL: URL?
    init(paper: PaperStyle, backgroundURL: URL?) {
        self.paper = paper
        self.backgroundURL = backgroundURL
        super.init(frame: PageRenderer.pageBounds)
        backgroundColor = .white
        isOpaque = true
        contentMode = .redraw
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        context.saveGState()
        context.scaleBy(x: bounds.width / PageRenderer.pageSize.width, y: bounds.height / PageRenderer.pageSize.height)
        PageRenderer.drawBackground(paper: paper, backgroundURL: backgroundURL, in: context)
        context.restoreGState()
    }
}

@MainActor
private final class RubberGestureRecognizer: UIGestureRecognizer {
    weak var coordinateView: UIView?
    var onBegin: ((CGPoint) -> Void)?
    var onMove: ((CGPoint) -> Void)?
    var onEnd: ((Bool) -> Void)?
    private var trackedTouch: UITouch?
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard trackedTouch == nil, touches.count == 1, event.allTouches?.filter({ $0.phase != .ended && $0.phase != .cancelled }).count == 1,
              let touch = touches.first else {
            let wasActive = trackedTouch != nil
            if wasActive { onEnd?(true) }
            trackedTouch = nil
            state = wasActive ? .cancelled : .failed
            return
        }
        trackedTouch = touch
        state = .began
        onBegin?(touch.preciseLocation(in: coordinateView ?? view))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] { onMove?(sample.preciseLocation(in: coordinateView ?? view)) }
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        onMove?(touch.preciseLocation(in: coordinateView ?? view))
        trackedTouch = nil
        onEnd?(false)
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        trackedTouch = nil
        onEnd?(true)
        state = .cancelled
    }
    override func reset() {
        if trackedTouch != nil { onEnd?(true) }
        trackedTouch = nil
        super.reset()
    }
}

/// CADisplayLink retains its target; keep the canvas owner weak across frames.
@MainActor
private final class EraserFrameTarget: NSObject {
    weak var host: PaperCanvasHost?
    init(host: PaperCanvasHost) { self.host = host }
    @objc func tick() { host?.flushErasingFrame() }
}
