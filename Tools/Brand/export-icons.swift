// Run from the repository root: swift Tools/Brand/export-icons.swift
// Run node Tools/Brand/export-avatar.mjs first. macOS keeps its existing inset
// and rounded tile; iOS/watchOS apply their own mask.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("docs/design/brand/avatar-front.svg")
guard let input = NSImage(contentsOf: source),
      let artwork = input.cgImage(forProposedRect: nil, context: nil, hints: nil),
      artwork.width == 1024, artwork.height == 1024 else { fatalError("Missing front-facing avatar artwork") }

func export(_ path: String, size: Int, mac: Bool = false) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = mac ? CGImageAlphaInfo.premultipliedLast : .noneSkipLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: colorSpace,
                                  bitmapInfo: alpha.rawValue) else { fatalError("Cannot allocate icon") }
    context.interpolationQuality = .high
    let edge = CGFloat(size)
    let inset = mac ? edge * 100 / 1024 : 0
    let tile = CGRect(x: inset, y: inset, width: edge - 2 * inset, height: edge - 2 * inset)
    if mac {
        let radius = edge * 185 / 1024
        context.addPath(CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil))
        context.clip()
    }
    context.draw(artwork, in: tile)
    let url = root.appendingPathComponent(path)
    guard let image = context.makeImage(),
          let output = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { fatalError("Cannot write \(path)") }
    CGImageDestinationAddImage(output, image, nil)
    guard CGImageDestinationFinalize(output) else { fatalError("Cannot finalize \(path)") }
    print("\(size) × \(size)  \(path)")
}

for path in [
    "Apps/iPhoneApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "Apps/WatchApp/Resources/Assets.xcassets/AppIcon.appiconset/AppIcon.png",
    "Apps/iPhoneApp/Resources/Assets.xcassets/PhoneBrandIcon.imageset/momoagent-icon.png",
    "Apps/iPhoneApp/Features/Assistant/Rendering/Web/brand-thinking.png",
    "docs/assets/app-icon.png",
    "docs/assets/momo-avatar.png",
] { try export(path, size: 1024) }

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        try export("Apps/MacApp/Desktop/Assets.xcassets/MacAppIcon.appiconset/icon_\(points)x\(points)@\(scale)x.png",
                   size: points * scale, mac: true)
    }
}

// The menu bar uses MoMo's avatar silhouette as a monochrome template icon.
let svgURL = root.appendingPathComponent("docs/design/brand/avatar-front-template.svg")
guard let svgImage = NSImage(contentsOf: svgURL) else { fatalError("Cannot load avatar-front-template.svg") }
let renderSize = 512
let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: renderSize, pixelsHigh: renderSize,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: renderSize * 4, bitsPerPixel: 32
)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
svgImage.draw(in: NSRect(x: 0, y: 0, width: renderSize, height: renderSize))
NSGraphicsContext.restoreGraphicsState()
var minX = renderSize, minY = renderSize, maxX = 0, maxY = 0
for y in 0..<renderSize {
    for x in 0..<renderSize {
        if (rep.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.05 {
            minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
        }
    }
}
let bw = maxX - minX + 1, bh = maxY - minY + 1, side = max(bw, bh) + 16
let cgCropped = rep.cgImage!.cropping(to: CGRect(x: minX - (side - bw) / 2, y: minY - (side - bh) / 2, width: side, height: side))!
let outSize = 144
let outRep = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: outSize, pixelsHigh: outSize,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
    colorSpaceName: .deviceRGB, bytesPerRow: outSize * 4, bitsPerPixel: 32
)!
NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: outRep)!
ctx.imageInterpolation = .high
NSGraphicsContext.current = ctx
NSImage(cgImage: cgCropped, size: NSSize(width: outSize, height: outSize)).draw(in: NSRect(x: 0, y: 0, width: outSize, height: outSize))
NSGraphicsContext.restoreGraphicsState()
try outRep.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(
    "Apps/MacApp/Desktop/Assets.xcassets/MoMoMenuMark.imageset/MoMoMenuMark.png"))
