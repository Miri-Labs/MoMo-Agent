// Run from the repository root: swift Tools/Brand/export-wordmark.swift
import AppKit
import CoreText
let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? FileManager.default.currentDirectoryPath)
let source = root.appendingPathComponent("Apps/iPhoneApp/Resources/Assets.xcassets/MoMoWordmark.imageset/MoMoWordmark.svg")
let raw = try String(contentsOf: source, encoding: .utf8)
let start = raw.range(of: "<svg")!.lowerBound
let bodyStart = raw[start...].firstIndex(of: ">")!
let bodyEnd = raw.range(of: "</svg>")!.lowerBound
let body = String(raw[raw.index(after: bodyStart)..<bodyEnd])
let base = NSFont.systemFont(ofSize: 88, weight: .heavy)
let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded)!, size: 88)!
let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Agent", attributes: [.font: font]))
let outline = CGMutablePath()
for run in CTLineGetGlyphRuns(line) as! [CTRun] {
    let count = CTRunGetGlyphCount(run)
    var glyphs = [CGGlyph](repeating: 0, count: count)
    var positions = [CGPoint](repeating: .zero, count: count)
    CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
    CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
    let attributes = CTRunGetAttributes(run) as NSDictionary
    let runFont = attributes[kCTFontAttributeName] as! CTFont
    for i in 0..<count {
        if let path = CTFontCreatePathForGlyph(runFont, glyphs[i], nil) {
            outline.addPath(path, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
        }
    }
}
func number(_ value: CGFloat) -> String { String(format: "%.2f", locale: Locale(identifier: "en_US_POSIX"), Double(value)) }
func point(_ p: CGPoint) -> String { "\(number(p.x)) \(number(p.y))" }
var commands: [String] = []
outline.applyWithBlock { pointer in
    let e = pointer.pointee
    switch e.type {
    case .moveToPoint: commands.append("M" + point(e.points[0]))
    case .addLineToPoint: commands.append("L" + point(e.points[0]))
    case .addQuadCurveToPoint: commands.append("Q" + point(e.points[0]) + " " + point(e.points[1]))
    case .addCurveToPoint: commands.append("C" + point(e.points[0]) + " " + point(e.points[1]) + " " + point(e.points[2]))
    case .closeSubpath: commands.append("Z")
    @unknown default: fatalError("Unknown glyph element")
    }
}
let width = 274 + ceil(CTLineGetTypographicBounds(line, nil, nil, nil))
let height = ceil(67 - outline.boundingBox.minY)
let svg = """
<?xml version="1.0" encoding="UTF-8"?>
<!-- MoMo uses the approved Pebble outlines; Agent uses rounded system lettering, outlined for offline rendering. -->
<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 \(number(width)) \(number(height))" width="\(number(width))" height="\(number(height))">
\(body)
<path fill="#000000" transform="translate(274 67) scale(1 -1)" d="\(commands.joined(separator: " "))"/>
</svg>
"""
try svg.write(to: root.appendingPathComponent("Apps/iPhoneApp/Resources/Assets.xcassets/PhoneWordmark.imageset/PhoneWordmark.svg"), atomically: true, encoding: .utf8)
print("MoMo Agent vector wordmark \(width) × \(height)")
