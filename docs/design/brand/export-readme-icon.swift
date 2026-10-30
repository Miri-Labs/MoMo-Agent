// Run from the repository root: swift docs/design/brand/export-readme-icon.swift
import AppKit
import ImageIO
import UniformTypeIdentifiers

// GitHub does not apply the platform mask used by iOS and watchOS.
let source = try String(contentsOfFile: "docs/design/brand/avatar-front.svg", encoding: .utf8)
let background = "<rect x=\"-150\" y=\"-168\" width=\"300\" height=\"300\""
precondition(source.contains(background), "Avatar background geometry changed")
let rounded = source.replacingOccurrences(of: background, with: background + " rx=\"66\"")
guard let vector = NSImage(data: Data(rounded.utf8)),
      let context = CGContext(data: nil, width: 512, height: 512, bitsPerComponent: 8,
                              bytesPerRow: 512 * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { fatalError("Cannot render README icon") }
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
vector.draw(in: NSRect(x: 0, y: 0, width: 512, height: 512))
NSGraphicsContext.restoreGraphicsState()
let destination = URL(fileURLWithPath: "docs/assets/readme-icon-rounded.png")
guard let image = context.makeImage(),
      let output = CGImageDestinationCreateWithURL(destination as CFURL, UTType.png.identifier as CFString, 1, nil)
else { fatalError("Cannot save README icon") }
CGImageDestinationAddImage(output, image, nil)
precondition(CGImageDestinationFinalize(output))
let pixels = context.data!.assumingMemoryBound(to: UInt8.self)
precondition(pixels[3] == 0 && pixels[(256 * 512 + 256) * 4 + 3] == 255)
print(destination.path)
