import Foundation
import SwiftUI
import UIKit

enum PaperStyle: String, Codable, CaseIterable, Identifiable {
    case blank, ruled, grid, dotted

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

enum CoverColor: String, Codable, CaseIterable, Identifiable {
    case sage, terracotta, blue, plum, gold

    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .sage: Color(red: 0.35, green: 0.48, blue: 0.39)
        case .terracotta: Color(red: 0.73, green: 0.39, blue: 0.29)
        case .blue: Color(red: 0.29, green: 0.43, blue: 0.60)
        case .plum: Color(red: 0.47, green: 0.35, blue: 0.49)
        case .gold: Color(red: 0.70, green: 0.54, blue: 0.26)
        }
    }
}

struct NotePage: Codable, Identifiable, Equatable {
    var id = UUID()
    var paper: PaperStyle = .ruled
    var backgroundFile: String?
    var shapes: [NoteShape] = []

    private enum CodingKeys: String, CodingKey { case id, paper, backgroundFile, shapes }

    init(id: UUID = UUID(), paper: PaperStyle = .ruled, backgroundFile: String? = nil, shapes: [NoteShape] = []) {
        self.id = id
        self.paper = paper
        self.backgroundFile = backgroundFile
        self.shapes = shapes
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        paper = try values.decode(PaperStyle.self, forKey: .paper)
        backgroundFile = try values.decodeIfPresent(String.self, forKey: .backgroundFile)
        shapes = try values.decodeIfPresent([NoteShape].self, forKey: .shapes) ?? []
    }
}

enum ShapeKind: String, Codable, CaseIterable, Identifiable {
    case rectangle, ellipse, triangle, line, arrow, text, path
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var isPrimitive: Bool { self != .text && self != .path }
    var symbol: String {
        switch self {
        case .rectangle: return "rectangle"
        case .ellipse: return "oval"
        case .triangle: return "triangle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .text: return "textformat"
        case .path: return "scribble"
        }
    }
}

struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    static let red = RGBAColor(red: 1, green: 0, blue: 0)
    static let black = RGBAColor(red: 0, green: 0, blue: 0)

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(uiColor: UIColor) {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 1
        if !uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            var white: CGFloat = 0
            uiColor.getWhite(&white, alpha: &alpha)
            red = white; green = white; blue = white
        }
        // ColorPicker can provide extended-gamut colors; the persisted model uses
        // normalized sRGB components so every export and validator agrees.
        func normalized(_ value: CGFloat, fallback: Double = 0) -> Double {
            value.isFinite ? Double(min(1, max(0, value))) : fallback
        }
        self.init(red: normalized(red), green: normalized(green), blue: normalized(blue), alpha: normalized(alpha, fallback: 1))
    }

    var uiColor: UIColor { UIColor(red: red, green: green, blue: blue, alpha: alpha) }
    var color: Color { Color(uiColor: uiColor) }
}

/// A closed eraser footprint in shape-relative coordinates. Keeping the outline
/// local lets erased areas follow later moves, resizes, and rotations.
struct ShapeErasureMask: Codable, Equatable {
    var points: [CGPoint]
}

struct NoteShape: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: ShapeKind
    var frame: CGRect
    var color: RGBAColor = .black
    var lineWidth: Double = 3
    var filled = false
    var rotation: Double = 0
    var erasureMasks: [ShapeErasureMask] = []
    var text: String?
    var fontSize: Double = 24
    /// Vertices normalized to the unrotated frame, so they move and resize with it.
    var points: [CGPoint] = []
    var closed = false

    private enum CodingKeys: String, CodingKey {
        case id, kind, frame, color, lineWidth, filled, rotation, erasureMasks, text, fontSize, points, closed
    }

    init(id: UUID = UUID(), kind: ShapeKind, frame: CGRect, color: RGBAColor = .black,
         lineWidth: Double = 3, filled: Bool = false, rotation: Double = 0,
         erasureMasks: [ShapeErasureMask] = [], text: String? = nil, fontSize: Double = 24,
         points: [CGPoint] = [], closed: Bool = false) {
        self.id = id; self.kind = kind; self.frame = frame; self.color = color
        self.lineWidth = lineWidth; self.filled = filled; self.rotation = rotation
        self.erasureMasks = erasureMasks; self.text = text; self.fontSize = fontSize
        self.points = points; self.closed = closed
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        kind = try values.decode(ShapeKind.self, forKey: .kind)
        frame = try values.decode(CGRect.self, forKey: .frame)
        color = try values.decode(RGBAColor.self, forKey: .color)
        lineWidth = try values.decode(Double.self, forKey: .lineWidth)
        filled = try values.decode(Bool.self, forKey: .filled)
        rotation = try values.decode(Double.self, forKey: .rotation)
        erasureMasks = try values.decodeIfPresent([ShapeErasureMask].self, forKey: .erasureMasks) ?? []
        text = try values.decodeIfPresent(String.self, forKey: .text)
        fontSize = try values.decodeIfPresent(Double.self, forKey: .fontSize) ?? 24
        points = try values.decodeIfPresent([CGPoint].self, forKey: .points) ?? []
        closed = try values.decodeIfPresent(Bool.self, forKey: .closed) ?? false
    }

    var fillsPath: Bool {
        switch kind {
        case .rectangle, .ellipse, .triangle: return filled
        case .path: return filled && closed
        case .line, .arrow, .text: return false
        }
    }

    var hasValidContent: Bool {
        switch kind {
        case .text:
            guard let text else { return false }
            return text.utf8.count <= 4_000
                && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && (6...144).contains(fontSize)
        case .path:
            guard (2...101).contains(points.count), let first = points.first else { return false }
            return points.allSatisfy { (0...1).contains($0.x) && (0...1).contains($0.y) }
                && points.contains { $0 != first }
        case .rectangle, .ellipse, .triangle, .line, .arrow:
            return true
        }
    }
}

struct Notebook: Codable, Identifiable, Equatable {
    var id = UUID()
    var title: String
    var createdAt = Date()
    var updatedAt = Date()
    var cover: CoverColor = .sage
    var pages: [NotePage] = [NotePage()]
}
