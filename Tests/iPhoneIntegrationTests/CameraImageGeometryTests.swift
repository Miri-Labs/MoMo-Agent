import ImageIO
import UIKit
import XCTest
@testable import MoMoAgent

final class CameraImageGeometryTests: XCTestCase {
    func testCameraPreservesPixelsAndLandmarksForEveryOrientationAndScale() throws {
        let original = ChatImageTestFixture.image()
        for orientation in ChatImageTestFixture.orientations {
            for scale: CGFloat in [1, 3] {
                let input = UIImage(cgImage: try XCTUnwrap(original.cgImage), scale: scale, orientation: orientation)
                let attachment = try ChatAttachmentImporter.cameraImage(input)
                let full = try XCTUnwrap(UIImage(data: XCTUnwrap(attachment.data)))
                let thumbnail = try XCTUnwrap(UIImage(data: XCTUnwrap(attachment.preview)))
                let swapsAxes = [.left, .right, .leftMirrored, .rightMirrored].contains(orientation)
                XCTAssertEqual(full.imageOrientation, .up)
                XCTAssertEqual(full.size, swapsAxes ? CGSize(width: 768, height: 1_536) : CGSize(width: 1_536, height: 768),
                               "orientation \(orientation.rawValue), scale \(scale)")
                for image in [full, thumbnail] {
                    try ChatImageTestFixture.assertGeometry(image, orientation: orientation)
                }
            }
        }
    }

    func testPhotoImportPreservesTheSameLandmarks() throws {
        let bytes = try XCTUnwrap(ChatImageTestFixture.image().pngData())
        let attachment = try ChatAttachmentImporter.image(bytes)
        try ChatImageTestFixture.assertGeometry(XCTUnwrap(UIImage(data: XCTUnwrap(attachment.data))), orientation: .up)
        try ChatImageTestFixture.assertGeometry(XCTUnwrap(UIImage(data: XCTUnwrap(attachment.preview))), orientation: .up)
    }
}

enum ChatImageTestFixture {
    static let orientations: [UIImage.Orientation] = [.up, .down, .left, .right, .upMirrored, .downMirrored, .leftMirrored, .rightMirrored]

    static func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: CGSize(width: 2_048, height: 1_024), format: format).image { renderer in
            let context = renderer.cgContext
            context.setFillColor(UIColor.white.cgColor)
            context.fill(CGRect(x: 0, y: 0, width: 2_048, height: 1_024))
            context.setStrokeColor(UIColor.lightGray.cgColor)
            context.setLineWidth(2)
            for x in stride(from: 0, through: 2_048, by: 128) {
                context.move(to: CGPoint(x: x, y: 0))
                context.addLine(to: CGPoint(x: x, y: 1_024))
            }
            for y in stride(from: 0, through: 1_024, by: 128) {
                context.move(to: CGPoint(x: 0, y: y))
                context.addLine(to: CGPoint(x: 2_048, y: y))
            }
            context.strokePath()
            context.setFillColor(UIColor.red.cgColor)
            context.fill(CGRect(x: 128, y: 128, width: 384, height: 384))
            context.setFillColor(UIColor.blue.cgColor)
            context.fillEllipse(in: CGRect(x: 1_280, y: 256, width: 256, height: 256))
        }
    }

    static func assertGeometry(_ image: UIImage, orientation: UIImage.Orientation,
                               file: StaticString = #filePath, line: UInt = #line) throws {
        let cgImage = try XCTUnwrap(image.cgImage, file: file, line: line)
        let width = cgImage.width, height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                file: file, line: line)
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        for blue in [false, true] {
            var minX = width, minY = height, maxX = -1, maxY = -1
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    let red = pixels[offset], green = pixels[offset + 1], b = pixels[offset + 2]
                    if green < 100 && (blue ? b > 150 && red < 100 : red > 150 && b < 100) {
                        minX = min(minX, x); minY = min(minY, y)
                        maxX = max(maxX, x); maxY = max(maxY, y)
                    }
                }
            }
            XCTAssertGreaterThanOrEqual(maxX, minX, "Missing \(blue ? "circle" : "square")", file: file, line: line)
            guard maxX >= minX else { continue }
            let measured = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
            XCTAssertEqual(measured.width, measured.height, accuracy: 2, "A circle or square must not stretch", file: file, line: line)
            let original = blue ? CGRect(x: 1_280, y: 256, width: 256, height: 256)
                                : CGRect(x: 128, y: 128, width: 384, height: 384)
            let center = CGPoint(x: original.midX / 2_048, y: original.midY / 1_024)
            let expected = oriented(center, orientation)
            XCTAssertEqual(measured.midX, expected.x * CGFloat(width), accuracy: 2, file: file, line: line)
            XCTAssertEqual(measured.midY, expected.y * CGFloat(height), accuracy: 2, file: file, line: line)
            let expectedSide = original.width * CGFloat(max(width, height)) / 2_048
            XCTAssertEqual(measured.width, expectedSide, accuracy: 2, file: file, line: line)
        }
    }

    private static func oriented(_ point: CGPoint, _ orientation: UIImage.Orientation) -> CGPoint {
        let x = point.x, y = point.y
        switch orientation {
        case .up: return CGPoint(x: x, y: y)
        case .down: return CGPoint(x: 1 - x, y: 1 - y)
        case .left: return CGPoint(x: y, y: 1 - x)
        case .right: return CGPoint(x: 1 - y, y: x)
        case .upMirrored: return CGPoint(x: 1 - x, y: y)
        case .downMirrored: return CGPoint(x: x, y: 1 - y)
        case .leftMirrored: return CGPoint(x: y, y: x)
        case .rightMirrored: return CGPoint(x: 1 - y, y: 1 - x)
        @unknown default: return point
        }
    }
}
