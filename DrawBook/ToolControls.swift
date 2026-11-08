import SwiftUI
import PencilKit

/// One full-width row keeps tools close to the paper without a second floating palette.
struct ToolControls: View {
    @Binding var mode: CanvasMode
    @Binding var showPages: Bool
    @ObservedObject var controller: CanvasController
    @State private var brush: Brush = .pen
    @State private var inkColor: Color = .black
    @State private var inkWidth = 3.0
    @State private var eraserWidth = 24.0
    @State private var brushSettings: [Brush: BrushSettings] = [:]
    @State private var shapeKind: ShapeKind = .rectangle
    @State private var shapeColor: Color = Theme.accent
    @State private var shapeWidth = 3.0
    @State private var shapeFilled = false
    @State private var showingSize = false
    @State private var showingColor = false
    @State private var showingShapes = false
    @State private var textEdit: TextEdit?

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { showPages.toggle() } label: { Image(systemName: "sidebar.left") }
                    .frame(width: 36, height: 44)
                    .accessibilityLabel(showPages ? "Hide pages" : "Show pages")
                    .help(showPages ? "Hide pages" : "Show pages")
                HStack(spacing: 0) {
                    Button { controller.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                        .frame(width: 32, height: 44)
                        .disabled(!controller.canUndo).accessibilityLabel("Undo").help("Undo")
                    Button { controller.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                        .frame(width: 32, height: 44)
                        .disabled(!controller.canRedo).accessibilityLabel("Redo").help("Redo")
                }
            }
            .fixedSize()
            separator
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 3) {
                    ForEach(Brush.available) { item in
                        brushButton(item) {
                            showingShapes = false
                            showingSize = false
                            showingColor = false
                            if item == .laser { mode = .laser }
                            else { selectBrush(item) }
                        }
                    }
                    toolButton("Shapes", symbol: "square.on.circle", selected: mode == .shapes) {
                        mode = .shapes
                        showingShapes.toggle()
                    }
                    .popover(isPresented: $showingShapes, arrowEdge: .top) {
                        shapeOptions.padding(18).frame(width: 310)
                            .presentationCompactAdaptation(.popover)
                    }
                    toolButton("Add Text", symbol: "text.badge.plus", selected: false) {
                        mode = .shapes
                        textEdit = TextEdit(target: nil)
                    }
                    if mode == .shapes, let selectedText {
                        toolButton("Edit Text", symbol: "character.cursor.ibeam", selected: false) {
                            textEdit = TextEdit(target: selectedText)
                        }
                    }
                    if mode == .shapes && controller.selectedShape != nil {
                        Button(role: .destructive) { controller.deleteSelectedShape() } label: {
                            Image(systemName: "trash").frame(width: 34, height: 44)
                        }
                        .foregroundStyle(.red)
                            .accessibilityLabel("Delete selected object")
                            .help("Delete selected object")
                    }
                    toolButton("Ruler", symbol: "ruler", selected: controller.rulerActive && mode == .ink) {
                        if mode != .ink { mode = .ink; applyBrush() }
                        controller.toggleRuler()
                    }
                }
                .frame(height: 56)
            }
            .frame(maxWidth: .infinity)
            separator
            HStack(spacing: 8) {
                if mode == .laser {
                    Circle().fill(.red).frame(width: 23, height: 23)
                        .frame(width: 36, height: 44)
                        .accessibilityLabel("Laser color: red, fades after three seconds")
                } else {
                    Button { showingColor.toggle() } label: {
                        Circle().fill(activeColor.wrappedValue)
                            .overlay { Circle().stroke(Theme.secondary.opacity(0.35), lineWidth: 1) }
                            .frame(width: 25, height: 25).frame(width: 36, height: 44)
                    }
                    .accessibilityLabel(colorTitle)
                    .disabled(!canStyle)
                    .popover(isPresented: $showingColor, arrowEdge: .top) {
                        colorOptions.padding(18).frame(width: 280)
                            .presentationCompactAdaptation(.popover)
                    }
                }
                Button { showingSize.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "lineweight")
                        Text(activeWidth.wrappedValue, format: .number.precision(.fractionLength(0...1)))
                            .font(.caption.monospacedDigit())
                    }
                    .frame(width: 56, height: 44)
                    .contentShape(Rectangle())
                }
                .disabled(!canResize)
                .accessibilityLabel(sizeTitle)
                .accessibilityValue("\(activeWidth.wrappedValue.formatted()) points")
                .help("Size")
                .popover(isPresented: $showingSize, arrowEdge: .top) {
                    sizeOptions.padding(18).frame(width: 280)
                        .presentationCompactAdaptation(.popover)
                }
            }
            .fixedSize()
        }
        .buttonStyle(.plain)
        .font(.system(size: 17, weight: .medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12)
        .frame(height: 56)
        .background(.white.opacity(0.95))
        .onAppear { applyBrush() }
        .onChange(of: inkColor) { _, _ in if mode == .ink { applyBrush() } }
        .onChange(of: inkWidth) { _, _ in if mode == .ink { applyBrush() } }
        .onChange(of: eraserWidth) { _, _ in if mode == .ink && brush == .eraser { applyBrush() } }
        .sheet(item: $textEdit) { edit in
            TextEditSheet(target: edit.target, controller: controller) { text in
                if let target = edit.target {
                    guard controller.selectedShape?.id == target.id,
                          controller.selectedShape?.text == target.text else { return }
                    controller.updateSelectedText(text)
                } else {
                    controller.addText(text, color: RGBAColor(uiColor: UIColor(shapeColor)))
                }
            }
        }
    }

    private var separator: some View { Divider().frame(height: 22).padding(.horizontal, 3) }
    private var canStyle: Bool { mode == .shapes || (mode == .ink && brush.isInk) }
    private var isErasing: Bool { mode == .ink && brush == .eraser }
    private var canResize: Bool { canStyle || isErasing }
    private var selectedText: NoteShape? { controller.selectedShape.flatMap { $0.kind == .text ? $0 : nil } }
    private var isStylingText: Bool { mode == .shapes && selectedText != nil }
    private var colorTitle: String {
        if isStylingText { return "Text color" }
        return mode == .shapes ? "Shape color" : "Brush color"
    }
    private var sizeTitle: String {
        if isStylingText { return "Font size" }
        return mode == .shapes ? "Shape line width" : isErasing ? "Eraser diameter" : "Brush size"
    }
    private var sizeRange: ClosedRange<Double> {
        if isStylingText { return 6...144 }
        return isErasing ? 4...80 : 1...32
    }
    private var sizePresets: [Double] {
        if isStylingText { return [12, 18, 24, 36, 48] }
        return isErasing ? [8, 16, 24, 48, 80] : [1, 3, 6, 12, 24]
    }

    private func brushButton(_ item: Brush, action: @escaping () -> Void) -> some View {
        let selected = mode == .laser ? item == .laser : mode == .ink && brush == item
        let tint: Color = item == .laser ? .red : Theme.accent
        return Button(action: action) {
            Group {
                if item.isInk {
                    BrushNib(brush: item, color: item == brush ? inkColor : (brushSettings[item]?.color ?? item.defaultColor))
                        .frame(width: 27, height: 34)
                } else {
                    Image(systemName: item.symbol).font(.system(size: 21, weight: .regular))
                }
            }
            .frame(width: 34, height: 40)
            .foregroundStyle(selected ? tint : Theme.ink)
            .background(selected ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
            .frame(height: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(item.title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(item.title)
    }

    private func selectBrush(_ item: Brush) {
        if brush.isInk { brushSettings[brush] = BrushSettings(color: inkColor, width: inkWidth) }
        brush = item
        if item.isInk {
            let settings = brushSettings[item] ?? BrushSettings(color: item.defaultColor, width: item.defaultWidth)
            inkColor = settings.color
            inkWidth = settings.width
        }
        mode = .ink
        applyBrush()
    }

    private func toolButton(_ title: String, symbol: String, selected: Bool, tint: Color = Theme.accent, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 34, height: 40)
                .foregroundStyle(selected ? tint : Theme.secondary)
                .background(selected ? tint.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .frame(height: 44)
                .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .help(title)
    }

    private var sizeOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text(sizeTitle).font(.headline)
                Spacer()
                Text(activeWidth.wrappedValue, format: .number.precision(.fractionLength(0...1))).monospacedDigit()
            }
            Slider(value: activeWidth, in: sizeRange, step: 0.5)
                .accessibilityLabel(sizeTitle)
            HStack(spacing: 6) {
                ForEach(sizePresets, id: \.self) { width in
                    Button { activeWidth.wrappedValue = width } label: {
                        Group {
                            if isStylingText {
                                Text(width, format: .number).font(.subheadline.monospacedDigit())
                            } else {
                                Circle().fill(isErasing ? Theme.accent.opacity(0.12) : Theme.ink)
                                    .overlay { if isErasing { Circle().stroke(Theme.accent, lineWidth: 1) } }
                                    .frame(width: max(3, min(width, 32)), height: max(3, min(width, 32)))
                            }
                        }
                        .frame(minWidth: 44, maxWidth: .infinity, minHeight: 44)
                        .background(abs(activeWidth.wrappedValue - width) < 0.1 ? Theme.accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 8))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).accessibilityLabel("\(Int(width)) points")
                }
            }
            if isErasing {
                HStack {
                    Spacer()
                    Circle().fill(Theme.accent.opacity(0.08))
                        .overlay { Circle().stroke(Theme.accent, lineWidth: 1) }
                        .frame(width: eraserWidth, height: eraserWidth)
                        .frame(height: 80)
                        .accessibilityLabel("Eraser diameter preview")
                    Spacer()
                }
                Text("Rub over ink or shapes to erase only the area you touch.")
                    .font(.caption).foregroundStyle(Theme.secondary)
            }
        }
    }

    private var colorOptions: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(colorTitle).font(.headline)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                ForEach(Array(palette.enumerated()), id: \.offset) { item in
                    Button {
                        activeColor.wrappedValue = item.element.1
                        showingColor = false
                    } label: {
                        Circle().fill(item.element.1)
                            .overlay { Circle().stroke(Theme.secondary.opacity(0.3), lineWidth: 1) }
                            .frame(width: 30, height: 30).frame(height: 36)
                    }
                    .buttonStyle(.plain).accessibilityLabel(item.element.0)
                }
            }
            ColorPicker("More colors & opacity", selection: activeColor, supportsOpacity: true)
        }
    }

    private var palette: [(String, Color)] {
        [("Black", .black), ("Gray", .gray), ("White", .white), ("Red", .red), ("Orange", .orange), ("Yellow", .yellow),
         ("Green", .green), ("Teal", .teal), ("Blue", .blue), ("Indigo", .indigo), ("Purple", .purple), ("Pink", .pink)]
    }

    private var shapeOptions: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let selected = controller.selectedShape, !selected.kind.isPrimitive {
                Text("Edit \(selected.kind.title.lowercased())").font(.headline)
                if selected.kind == .path && selected.closed {
                    Toggle("Fill path", isOn: selectedFill)
                }
            } else {
                Text(controller.selectedShape == nil ? "Add a shape" : "Edit shape").font(.headline)
                Picker("Shape", selection: selectedKind) {
                    ForEach(ShapeKind.allCases.filter(\.isPrimitive)) { item in
                        Label(item.title, systemImage: item.symbol).tag(item)
                    }
                }
                .pickerStyle(.menu)
                Toggle("Fill shape", isOn: selectedFill)
                    .disabled(selectedKind.wrappedValue == .line || selectedKind.wrappedValue == .arrow)
                Button("Add \(selectedKind.wrappedValue.title.lowercased())", systemImage: "plus") {
                    controller.addShape(kind: selectedKind.wrappedValue,
                                        color: RGBAColor(uiColor: UIColor(selectedColor.wrappedValue)),
                                        lineWidth: selectedWidth.wrappedValue, filled: selectedFill.wrappedValue)
                    showingShapes = false
                }
                .buttonStyle(.borderedProminent)
            }
            if let selected = controller.selectedShape {
                Divider()
                HStack {
                    Button("Rotate left", systemImage: "rotate.left") { controller.updateSelectedShape(rotation: selected.rotation - 15) }
                    Spacer()
                    Button("Rotate right", systemImage: "rotate.right") { controller.updateSelectedShape(rotation: selected.rotation + 15) }
                }
                .labelStyle(.iconOnly).font(.title3)
                Button("Duplicate", systemImage: "plus.square.on.square") { controller.duplicateSelectedShape(); showingShapes = false }
                Button("Delete \(selected.kind.title.lowercased())", systemImage: "trash", role: .destructive) {
                    controller.deleteSelectedShape()
                    showingShapes = false
                }
            }
            Text("Drag an object to move it. Drag its blue corner to resize.")
                .font(.caption).foregroundStyle(Theme.secondary)
        }
    }

    private var activeColor: Binding<Color> { mode == .shapes ? selectedColor : $inkColor }
    private var activeWidth: Binding<Double> {
        if isStylingText {
            return Binding(get: { selectedText?.fontSize ?? 24 }, set: { controller.updateSelectedShape(fontSize: $0) })
        }
        return mode == .shapes ? selectedWidth : isErasing ? $eraserWidth : $inkWidth
    }
    private var selectedKind: Binding<ShapeKind> {
        Binding(get: { controller.selectedShape?.kind ?? shapeKind }, set: { shapeKind = $0; controller.updateSelectedShape(kind: $0) })
    }
    private var selectedColor: Binding<Color> {
        Binding(get: { controller.selectedShape?.color.color ?? shapeColor }, set: {
            shapeColor = $0; controller.updateSelectedShape(color: RGBAColor(uiColor: UIColor($0)))
        })
    }
    private var selectedWidth: Binding<Double> {
        Binding(get: { controller.selectedShape?.lineWidth ?? shapeWidth }, set: { shapeWidth = $0; controller.updateSelectedShape(lineWidth: $0) })
    }
    private var selectedFill: Binding<Bool> {
        Binding(get: { controller.selectedShape?.filled ?? shapeFilled }, set: { shapeFilled = $0; controller.updateSelectedShape(filled: $0) })
    }
    private func applyBrush() {
        switch brush {
        case .eraser: controller.useEraser(width: eraserWidth)
        case .lasso: controller.useLasso()
        case .laser: break
        default:
            if let inkType = brush.inkType {
                controller.configureInk(type: inkType, color: UIColor(inkColor), width: inkWidth)
            }
        }
    }

    private struct BrushSettings {
        var color: Color
        var width: Double
    }

    private struct TextEdit: Identifiable {
        let id = UUID()
        let target: NoteShape?
    }

    private struct TextEditSheet: View {
        @Environment(\.dismiss) private var dismiss
        @FocusState private var editingText: Bool
        @State private var text: String
        @ObservedObject private var controller: CanvasController
        let target: NoteShape?
        let onSave: (String) -> Void

        init(target: NoteShape?, controller: CanvasController, onSave: @escaping (String) -> Void) {
            self.target = target
            self.controller = controller
            self.onSave = onSave
            _text = State(initialValue: target?.text ?? "")
        }

        /// Text taller than the page would be clipped on the canvas and in exports.
        private var tooTall: Bool {
            !ShapeRenderer.textFitsPage(text, width: target?.frame.width ?? ShapeRenderer.newTextWidth,
                                        fontSize: target?.fontSize ?? NoteShape(kind: .text, frame: .zero).fontSize)
        }

        private var targetChanged: Bool {
            guard let target else { return false }
            return controller.selectedShape?.id != target.id || controller.selectedShape?.text != target.text
        }

        var body: some View {
            NavigationStack {
                VStack(alignment: .leading, spacing: 10) {
                    TextEditor(text: $text)
                        .accessibilityLabel("Page text")
                        .focused($editingText)
                        .padding(6)
                        .scrollContentBackground(.hidden)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    if targetChanged {
                        Text("The selected text changed. Reopen it to edit the latest version.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if text.utf8.count > 4_000 {
                        Text("This text is too long. Shorten it before saving.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if tooTall {
                        Text("This text is taller than the page. Shorten it or split it into several text boxes.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .padding()
                .navigationTitle(target == nil ? "Add Text" : "Edit Text")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(target == nil ? "Add" : "Save") {
                            onSave(text)
                            dismiss()
                        }
                        .disabled(targetChanged || text.utf8.count > 4_000 || tooTall ||
                                  text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            .onAppear { editingText = true }
        }
    }

    private enum Brush: String, CaseIterable, Identifiable {
        case pen, monoline, marker, fountainPen, reed, pencil, watercolor, crayon, eraser, lasso, laser
        var id: String { rawValue }
        static var available: [Brush] {
            allCases.filter { item in
                if item == .reed { if #available(iOS 26.0, *) { return true }; return false }
                return true
            }
        }
        var title: String {
            switch self {
            case .pen: return "Ballpoint pen"
            case .monoline: return "Monoline pen"
            case .marker: return "Highlighter"
            case .fountainPen: return "Fountain pen"
            case .reed: return "Reed pen"
            case .watercolor: return "Watercolor brush"
            case .lasso: return "Select ink"
            case .eraser: return "Rubber eraser"
            default: return rawValue.capitalized
            }
        }
        var inkType: PKInkingTool.InkType? {
            switch self {
            case .pen: return .pen
            case .monoline: return .monoline
            case .marker: return .marker
            case .fountainPen: return .fountainPen
            case .reed: if #available(iOS 26.0, *) { return .reed }; return nil
            case .pencil: return .pencil
            case .watercolor: return .watercolor
            case .crayon: return .crayon
            default: return nil
            }
        }
        var isInk: Bool { inkType != nil }
        var defaultColor: Color {
            switch self {
            case .marker: return .yellow
            case .pencil, .crayon: return Color(red: 0.90, green: 0.52, blue: 0.36)
            default: return .black
            }
        }
        var defaultWidth: Double {
            switch self {
            case .monoline: return 2
            case .fountainPen, .reed: return 5
            case .marker, .crayon: return 16
            case .watercolor: return 18
            default: return 3
            }
        }
        var symbol: String {
            switch self {
            case .eraser: return "eraser"
            case .lasso: return "lasso"
            case .laser: return "laser.burst"
            default: return "pencil.tip"
            }
        }
    }

    /// Small, distinct nib silhouettes make the material visible before selecting it.
    private struct BrushNib: View {
        var brush: Brush
        var color: Color

        var body: some View {
            Canvas { context, _ in
                let outline = Color(white: 0.20)
                func polygon(_ points: [CGPoint], fill: Color) {
                    var path = Path()
                    path.addLines(points)
                    path.closeSubpath()
                    context.fill(path, with: .color(fill))
                    context.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: 1.2, lineJoin: .round))
                }
                func line(_ points: [CGPoint], color: Color = Color(white: 0.20), width: CGFloat = 1.2) {
                    var path = Path()
                    path.addLines(points)
                    context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round))
                }
                switch brush {
                case .pen, .fountainPen:
                    polygon([CGPoint(x: 13.5, y: 1), CGPoint(x: 23, y: 13), CGPoint(x: 20, y: 29), CGPoint(x: 7, y: 29), CGPoint(x: 4, y: 13)], fill: Color(white: 0.12))
                    line([CGPoint(x: 13.5, y: 3), CGPoint(x: 13.5, y: 17)], color: .white.opacity(0.85), width: 1)
                    let hole = Path(ellipseIn: CGRect(x: 11, y: 15, width: 5, height: 5))
                    context.stroke(hole, with: .color(.white.opacity(0.85)), lineWidth: 1)
                    polygon([CGPoint(x: 5, y: 29), CGPoint(x: 22, y: 29), CGPoint(x: 22, y: 33), CGPoint(x: 5, y: 33)], fill: color)
                    if brush == .fountainPen {
                        line([CGPoint(x: 5, y: 13), CGPoint(x: 10, y: 22), CGPoint(x: 8, y: 28)], color: .white.opacity(0.55), width: 0.8)
                    }
                case .monoline:
                    polygon([CGPoint(x: 13.5, y: 3), CGPoint(x: 21, y: 19), CGPoint(x: 21, y: 32), CGPoint(x: 6, y: 32), CGPoint(x: 6, y: 19)], fill: Color(white: 0.12))
                    line([CGPoint(x: 8, y: 18), CGPoint(x: 19, y: 18)], color: .white.opacity(0.7))
                    line([CGPoint(x: 7, y: 28), CGPoint(x: 20, y: 28)], color: color, width: 3)
                case .marker:
                    polygon([CGPoint(x: 8, y: 1), CGPoint(x: 19, y: 1), CGPoint(x: 19, y: 8), CGPoint(x: 22, y: 13), CGPoint(x: 22, y: 32), CGPoint(x: 5, y: 32), CGPoint(x: 5, y: 13), CGPoint(x: 8, y: 8)], fill: color)
                    line([CGPoint(x: 8, y: 7), CGPoint(x: 19, y: 7)])
                    line([CGPoint(x: 6, y: 14), CGPoint(x: 21, y: 14)])
                case .reed:
                    polygon([CGPoint(x: 8, y: 4), CGPoint(x: 19, y: 1), CGPoint(x: 19, y: 15), CGPoint(x: 22, y: 20), CGPoint(x: 22, y: 32), CGPoint(x: 5, y: 32), CGPoint(x: 5, y: 20), CGPoint(x: 8, y: 15)], fill: Color(white: 0.16))
                    line([CGPoint(x: 9, y: 12), CGPoint(x: 18, y: 12)], color: color, width: 3)
                    line([CGPoint(x: 6, y: 22), CGPoint(x: 21, y: 22)], color: .gray)
                case .pencil:
                    let wood = Color(red: 1, green: 0.77, blue: 0.60)
                    polygon([CGPoint(x: 13.5, y: 1), CGPoint(x: 22, y: 14), CGPoint(x: 22, y: 32), CGPoint(x: 5, y: 32), CGPoint(x: 5, y: 14)], fill: color)
                    polygon([CGPoint(x: 13.5, y: 1), CGPoint(x: 22, y: 14), CGPoint(x: 17, y: 18), CGPoint(x: 13.5, y: 14), CGPoint(x: 10, y: 18), CGPoint(x: 5, y: 14)], fill: wood)
                    polygon([CGPoint(x: 13.5, y: 1), CGPoint(x: 17, y: 6), CGPoint(x: 10, y: 6)], fill: color)
                    line([CGPoint(x: 10, y: 18), CGPoint(x: 10, y: 32)])
                    line([CGPoint(x: 17, y: 18), CGPoint(x: 17, y: 32)])
                case .watercolor:
                    var tip = Path()
                    tip.move(to: CGPoint(x: 18, y: 1))
                    tip.addCurve(to: CGPoint(x: 8, y: 21), control1: CGPoint(x: 4, y: 8), control2: CGPoint(x: 4, y: 15))
                    tip.addLine(to: CGPoint(x: 20, y: 21))
                    tip.addCurve(to: CGPoint(x: 18, y: 1), control1: CGPoint(x: 25, y: 13), control2: CGPoint(x: 16, y: 9))
                    context.fill(tip, with: .color(color))
                    context.stroke(tip, with: .color(outline), lineWidth: 1.2)
                    polygon([CGPoint(x: 8, y: 24), CGPoint(x: 20, y: 24), CGPoint(x: 18, y: 33), CGPoint(x: 10, y: 33)], fill: Color(white: 0.28))
                case .crayon:
                    polygon([CGPoint(x: 10, y: 1), CGPoint(x: 17, y: 1), CGPoint(x: 22, y: 13), CGPoint(x: 22, y: 33), CGPoint(x: 5, y: 33), CGPoint(x: 5, y: 13)], fill: color)
                    line([CGPoint(x: 6, y: 13), CGPoint(x: 21, y: 13)])
                    line([CGPoint(x: 6, y: 19), CGPoint(x: 21, y: 19)])
                    line([CGPoint(x: 6, y: 29), CGPoint(x: 21, y: 29)])
                default: break
                }
            }
            .accessibilityHidden(true)
        }
    }
}
