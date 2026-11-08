import PencilKit
import UIKit
import Vision

struct HandwritingWord: Equatable, Sendable {
    let text: String
    let bounds: CGRect
    let strokeIndices: [Int]
}

struct HandwritingLine: Equatable, Sendable {
    let text: String
    /// Page coordinates, top-left origin.
    let bounds: CGRect
    let confidence: Float
    /// Sorted indices into `drawing.strokes`.
    let strokeIndices: [Int]
    let words: [HandwritingWord]
}

/// On-device handwriting recognition, so the AI receives text instead of images.
enum HandwritingRecognizer {
    private struct Observation: Sendable {
        let text: String
        let box: CGRect
        let confidence: Float
        let words: [(text: String, box: CGRect)]
    }

    private static let renderScale: CGFloat = 2
    private static let inkWidth: ClosedRange<CGFloat> = 2.5...7

    @MainActor
    static func recognize(_ drawing: PKDrawing, pageSize: CGSize? = nil) async -> [HandwritingLine] {
        // Optional so the main-actor default isn't evaluated in a nonisolated default-argument context.
        let pageSize = pageSize ?? PageRenderer.pageSize
        let strokes = drawing.strokes
        guard !strokes.isEmpty, pageSize.width > 0, pageSize.height > 0,
              let image = normalizedImage(drawing, pageSize: pageSize, scale: renderScale) else { return [] }
        let observations = await Task.detached(priority: .userInitiated) { recognizeText(in: image) }.value
        guard !Task.isCancelled, !observations.isEmpty else { return [] }

        func page(_ box: CGRect) -> CGRect {
            CGRect(x: box.minX * pageSize.width, y: (1 - box.maxY) * pageSize.height,
                   width: box.width * pageSize.width, height: box.height * pageSize.height)
        }
        let strokeBounds = strokes.map(\.renderBounds)
        let lineBoxes = observations.map { page($0.box) }
        let lineStrokes = assign(strokeBounds: strokeBounds, to: lineBoxes)
        return observations.indices.map { index in
            let observation = observations[index]
            let members = lineStrokes[index]
            let wordBoxes = observation.words.map { page($0.box) }
            let wordStrokes = assign(strokeBounds: members.map { strokeBounds[$0] }, to: wordBoxes)
            let words = observation.words.indices.map { word in
                HandwritingWord(text: observation.words[word].text, bounds: wordBoxes[word],
                                strokeIndices: wordStrokes[word].map { members[$0] })
            }
            return HandwritingLine(text: observation.text, bounds: lineBoxes[index],
                                   confidence: observation.confidence, strokeIndices: members, words: words)
        }
    }

    /// Black, crisp, opaque ink on white so translucent or textured brushes read like pen.
    @MainActor
    static func normalizedImage(_ drawing: PKDrawing, pageSize: CGSize, scale: CGFloat) -> CGImage? {
        guard pageSize.width > 0, pageSize.height > 0, scale > 0 else { return nil }
        let strokes = drawing.strokes.map { stroke -> PKStroke in
            let points = stroke.path.map { point -> PKStrokePoint in
                let side = min(max(min(point.size.width, point.size.height), inkWidth.lowerBound), inkWidth.upperBound)
                return PKStrokePoint(location: point.location, timeOffset: point.timeOffset,
                                     size: CGSize(width: side, height: side), opacity: 1, force: 1,
                                     azimuth: point.azimuth, altitude: point.altitude)
            }
            return PKStroke(ink: PKInk(.monoline, color: .black),
                            path: PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate),
                            transform: stroke.transform, mask: stroke.mask)
        }
        let bounds = CGRect(origin: .zero, size: pageSize)
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        format.opaque = true
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            let ink = PKDrawing(strokes: strokes).image(from: bounds, scale: scale)
            image = UIGraphicsImageRenderer(size: pageSize, format: format).image { output in
                UIColor.white.setFill()
                output.fill(bounds)
                ink.draw(in: bounds)
            }
        }
        return image?.cgImage
    }

    /// Indices of strokes belonging to each box, sorted. A stroke joins the box covering
    /// most of it; small marks (dots, punctuation) join a box that contains their center.
    static func assign(strokeBounds: [CGRect], to boxes: [CGRect]) -> [[Int]] {
        var result = Array(repeating: [Int](), count: boxes.count)
        guard !boxes.isEmpty else { return result }
        for (index, stroke) in strokeBounds.enumerated() {
            guard !stroke.isNull, !stroke.isInfinite else { continue }
            let area = stroke.width * stroke.height
            var best: (box: Int, score: CGFloat)?
            if area > 0 {
                for (box, rect) in boxes.enumerated() {
                    let overlap = stroke.intersection(rect)
                    guard !overlap.isNull else { continue }
                    let score = overlap.width * overlap.height / area
                    if score > (best?.score ?? 0) { best = (box, score) }
                }
            }
            if let best, best.score >= 0.5 {
                result[best.box].append(index)
                continue
            }
            let center = CGPoint(x: stroke.midX, y: stroke.midY)
            var nearest: (box: Int, distance: CGFloat)?
            for (box, rect) in boxes.enumerated() {
                let small = max(stroke.width, stroke.height) <= max(16, rect.height * 0.5)
                let pad = rect.height * 0.25
                guard small, rect.insetBy(dx: -pad, dy: -pad).contains(center) else { continue }
                let distance = hypot(center.x - rect.midX, center.y - rect.midY)
                if distance < (nearest?.distance ?? .infinity) { nearest = (box, distance) }
            }
            if let nearest { result[nearest.box].append(index) }
        }
        return result
    }

    private static func recognizeText(in image: CGImage) -> [Observation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        request.minimumTextHeight = 0.01
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        } catch {
            return []
        }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            var words: [(text: String, box: CGRect)] = []
            for word in candidate.string.split(whereSeparator: \.isWhitespace) {
                let range = word.startIndex..<word.endIndex
                let box = (try? candidate.boundingBox(for: range))?.boundingBox ?? observation.boundingBox
                words.append((String(word), box))
            }
            return Observation(text: text, box: observation.boundingBox,
                               confidence: candidate.confidence, words: words)
        }
    }
}
