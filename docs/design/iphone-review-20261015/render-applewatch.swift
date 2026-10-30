import AppKit

let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
let config = NSImage.SymbolConfiguration(pointSize: 34, weight: .light)
guard let symbol = NSImage(systemSymbolName: "applewatch", accessibilityDescription: nil)?.withSymbolConfiguration(config) else {
    fatalError("Missing native applewatch symbol")
}
for (name, color) in [("applewatch-light.png", NSColor.white), ("applewatch-dark.png", NSColor.black)] {
    let scale: CGFloat = 4
    let size = symbol.size
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = size
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let colored = symbol.withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [color]))!
    colored.draw(in: NSRect(origin: .zero, size: size))
    NSGraphicsContext.restoreGraphicsState()
    try rep.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name))
}
