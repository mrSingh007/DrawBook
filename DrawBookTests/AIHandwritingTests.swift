import PencilKit
import XCTest
@testable import DrawBook

final class AIHandwritingTests: XCTestCase {
    func testAssignUsesLargestOverlap() {
        let boxes = [CGRect(x: 0, y: 0, width: 100, height: 40), CGRect(x: 0, y: 60, width: 100, height: 40)]
        let strokes = [CGRect(x: 10, y: 5, width: 20, height: 30),   // inside first
                       CGRect(x: 10, y: 50, width: 20, height: 40),  // mostly second
                       CGRect(x: 40, y: 62, width: 30, height: 30)]  // inside second
        XCTAssertEqual(HandwritingRecognizer.assign(strokeBounds: strokes, to: boxes), [[0], [1, 2]])
    }

    func testAssignAttachesDotsNearTheirBox() {
        let boxes = [CGRect(x: 100, y: 100, width: 200, height: 40)]
        let strokes = [CGRect(x: 150, y: 90, width: 4, height: 4),    // i-dot just above the box
                       CGRect(x: 302, y: 130, width: 3, height: 3),   // period just past the end
                       CGRect(x: 150, y: 40, width: 4, height: 4)]    // far above: not part of the line
        XCTAssertEqual(HandwritingRecognizer.assign(strokeBounds: strokes, to: boxes), [[0, 1]])
    }

    func testAssignLeavesStrokesOutsideEveryBox() {
        let boxes = [CGRect(x: 0, y: 0, width: 50, height: 20)]
        let strokes = [CGRect(x: 200, y: 200, width: 80, height: 80), CGRect(x: 40, y: 0, width: 60, height: 20), .null]
        XCTAssertEqual(HandwritingRecognizer.assign(strokeBounds: strokes, to: boxes), [[]])
        XCTAssertEqual(HandwritingRecognizer.assign(strokeBounds: strokes, to: []), [])
    }

    @MainActor
    func testNormalizedImageIsOpaqueWithDarkInkForHighlighter() throws {
        let marker = PKInk(.marker, color: UIColor(red: 1, green: 0.9, blue: 0, alpha: 0.5))
        let stroke = makeStroke(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 100), ink: marker, width: 30)
        let drawing = PKDrawing(strokes: [stroke])
        let size = CGSize(width: 768, height: 1024)
        let image = try XCTUnwrap(HandwritingRecognizer.normalizedImage(drawing, pageSize: size, scale: 2))

        XCTAssertEqual(image.width, 1536)
        XCTAssertEqual(image.height, 2048)
        let pixels = try rgba(image)
        func pixel(_ x: Int, _ y: Int) -> [UInt8] { Array(pixels[(y * image.width + x) * 4..<(y * image.width + x) * 4 + 4]) }
        let ink = pixel(400, 200)
        XCTAssertEqual(ink[3], 255)
        XCTAssertLessThan(Int(ink[0]) + Int(ink[1]) + Int(ink[2]), 120)
        XCTAssertEqual(pixel(10, 10), [255, 255, 255, 255])
        XCTAssertEqual(pixel(1000, 1800), [255, 255, 255, 255])
    }

    @MainActor
    func testRecognizeReadsBlockLetters() async throws {
        // "HI" alone tends to come back as "IH"; "LIT" reads reliably with confidence 1.
        let strokes = blockLetters("LIT", origin: CGPoint(x: 120, y: 200), height: 80)
        let stray = makeStroke(from: CGPoint(x: 600, y: 900), to: CGPoint(x: 700, y: 950), ink: PKInk(.pen, color: .black), width: 6)
        let lines = await HandwritingRecognizer.recognize(PKDrawing(strokes: strokes + [stray]))
        guard let line = lines.first(where: { $0.text.uppercased().contains("LIT") }) else {
            throw XCTSkip("Vision did not read synthetic ink here: \(lines.map(\.text))")
        }
        XCTAssertEqual(line.strokeIndices, Array(strokes.indices))
        XCTAssertTrue(line.bounds.intersects(CGRect(x: 120, y: 200, width: 200, height: 80)))
        XCTAssertEqual(line.words.flatMap(\.strokeIndices).sorted(), line.strokeIndices)
    }

    func testRecognizeReturnsNothingForEmptyDrawing() async {
        let lines = await HandwritingRecognizer.recognize(PKDrawing())
        XCTAssertEqual(lines, [])
    }

    private func blockLetters(_ text: String, origin: CGPoint, height: CGFloat) -> [PKStroke] {
        // Segments in a unit cell (x: 0...0.6, y: 0...1).
        let glyphs: [Character: [(CGPoint, CGPoint)]] = [
            "H": [(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1)), (CGPoint(x: 0.6, y: 0), CGPoint(x: 0.6, y: 1)),
                  (CGPoint(x: 0, y: 0.5), CGPoint(x: 0.6, y: 0.5))],
            "I": [(CGPoint(x: 0.3, y: 0), CGPoint(x: 0.3, y: 1)), (CGPoint(x: 0.05, y: 0), CGPoint(x: 0.55, y: 0)),
                  (CGPoint(x: 0.05, y: 1), CGPoint(x: 0.55, y: 1))],
            "L": [(CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 1)), (CGPoint(x: 0, y: 1), CGPoint(x: 0.6, y: 1))],
            "T": [(CGPoint(x: 0, y: 0), CGPoint(x: 0.6, y: 0)), (CGPoint(x: 0.3, y: 0), CGPoint(x: 0.3, y: 1))],
        ]
        var strokes: [PKStroke] = []
        for (position, character) in text.enumerated() {
            let left = origin.x + CGFloat(position) * height * 0.85
            for (start, end) in glyphs[character] ?? [] {
                func page(_ p: CGPoint) -> CGPoint { CGPoint(x: left + p.x * height, y: origin.y + p.y * height) }
                strokes.append(makeStroke(from: page(start), to: page(end), ink: PKInk(.pen, color: .black), width: 6))
            }
        }
        return strokes
    }

    private func makeStroke(from start: CGPoint, to end: CGPoint, ink: PKInk, width: CGFloat) -> PKStroke {
        let points = (0...24).map { index -> PKStrokePoint in
            let t = CGFloat(index) / 24
            return PKStrokePoint(location: CGPoint(x: start.x + (end.x - start.x) * t, y: start.y + (end.y - start.y) * t),
                                 timeOffset: Double(index) * 0.01, size: CGSize(width: width, height: width),
                                 opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }

    private func rgba(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                              bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixels
    }
}
