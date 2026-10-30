// Run from the repository root: swift Tools/Brand/export-icons.swift
// Run node Tools/Brand/export-avatar.mjs first. macOS uses an Icon Composer
// bundle (MacAppIcon.icon) for full-bleed Liquid Glass rendering; iOS/watchOS
// apply their own mask to 1024×1024 PNGs.
import AppKit
import ImageIO
import UniformTypeIdentifiers

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("docs/design/brand/avatar-front.svg")
var sourceRect = NSRect(x: 0, y: 0, width: 1024, height: 1024)
guard let input = NSImage(contentsOf: source),
      let artwork = input.cgImage(forProposedRect: &sourceRect, context: nil, hints: [.ctm: NSAffineTransform()]),
      artwork.width == 1024, artwork.height == 1024 else { fatalError("Missing front-facing avatar artwork") }

func export(_ path: String, size: Int) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    let alpha = CGImageAlphaInfo.noneSkipLast
    guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                                  bytesPerRow: size * 4, space: colorSpace,
                                  bitmapInfo: alpha.rawValue) else { fatalError("Cannot allocate icon") }
    context.interpolationQuality = .high
    let edge = CGFloat(size)
    context.draw(artwork, in: CGRect(x: 0, y: 0, width: edge, height: edge))
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

let svgURL = root.appendingPathComponent("docs/design/brand/avatar-front-template.svg")
let templateSVG = try String(contentsOf: svgURL, encoding: .utf8)
guard templateSVG.contains("fill=\"#000000\"") else { fatalError("Unexpected avatar-front-template.svg fill") }
let macIconDir = root.appendingPathComponent("Apps/MacApp/Desktop/MacAppIcon.icon")
let macIconAssetsDir = macIconDir.appendingPathComponent("Assets")
try FileManager.default.createDirectory(at: macIconAssetsDir, withIntermediateDirectories: true)
let foregroundSVG = templateSVG.replacingOccurrences(of: "fill=\"#000000\"", with: "fill=\"#f4f4f4\"")
try foregroundSVG.write(to: macIconAssetsDir.appendingPathComponent("momo-foreground.svg"), atomically: true, encoding: .utf8)
let iconManifest = """
{
  "fill" : {
    "solid" : "srgb:0.09020,0.09020,0.09020,1.00000"
  },
  "groups" : [
    {
      "layers" : [
        {
          "glass" : false,
          "image-name" : "momo-foreground.svg",
          "name" : "MoMo"
        }
      ],
      "specular" : false
    }
  ],
  "supported-platforms" : {
    "squares" : [
      "macOS"
    ]
  }
}

"""
try iconManifest.write(to: macIconDir.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
print("Icon Composer  Apps/MacApp/Desktop/MacAppIcon.icon")

// The menu bar uses MoMo's avatar silhouette as a monochrome template icon.
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
