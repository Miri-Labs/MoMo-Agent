import AppKit
import Foundation

@main
struct MacStickerArtworkTests {
    static func visiblePixels(_ image: NSImage) -> Int {
        let image = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 0 }.count
        }
    }

    static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("sticker-framing-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        // Asymmetric shapes at opposite edges catch vertical-origin mistakes and clipped artwork.
        for (index, rect) in [CGRect(x: 4, y: 70, width: 20, height: 14),
                              CGRect(x: 90, y: 3, width: 25, height: 30),
                              CGRect(x: 0, y: 0, width: 120, height: 100), CGRect.zero].enumerated() {
            let context = CGContext(data: nil, width: 120, height: 100, bitsPerComponent: 8,
                bytesPerRow: 480, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.setFillColor(CGColor(red: 0.8, green: 0.3, blue: 0.1, alpha: 0.75))
            context.fill(rect)
            let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
            let url = root.appendingPathComponent("\(index).png")
            try data.write(to: url)
            let original = NSImage(data: data)!
            let framed = await LifeIllustrationImageCache.shared.loadArtwork(url)!
            precondition(visiblePixels(original) == visiblePixels(framed), "Framing clipped visible pixels")
            let saved = try Data(contentsOf: url)
            precondition(saved == data, "Sharing asset was modified")
            if index < 2 {
                precondition(framed.size.width < 120 && framed.size.height < 100, "Transparent margins remained")
            } else {
                precondition(framed.size == original.size, "Opaque/empty canvas changed")
            }
            let reused = await LifeIllustrationImageCache.shared.loadArtwork(url)!
            precondition(reused === framed, "Repeated selection should reuse decoded artwork")
        }
        print("Passed 4 artwork framing cases: visible pixels, original bytes and cache reuse preserved")
    }
}
