// Generates AppIcon.icns with CoreGraphics - no design tools or Xcode needed.
// The mark: three lines of "text" on a blue tile, with a check badge.
// Usage: swift scripts/make-icon.swift <output-dir>
import AppKit
import CoreGraphics
import Foundation

let outputDir = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let iconsetDir = outputDir.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconsetDir)
try FileManager.default.createDirectory(at: iconsetDir, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func drawIcon(size: Int) -> CGImage {
    let s = CGFloat(size)
    let ctx = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // macOS icon grid: a rounded tile inside a 10% margin.
    let inset = s * 0.10
    let tile = CGRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    let radius = tile.width * 0.2237
    let tilePath = CGPath(roundedRect: tile, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // Soft drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.012), blur: s * 0.03, color: color(0.02, 0.10, 0.30, 0.45))
    ctx.addPath(tilePath)
    ctx.setFillColor(color(0.10, 0.40, 0.95))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath)
    ctx.clip()

    // Diagonal gradient: deep blue to bright azure.
    let base = CGGradient(colorsSpace: nil, colors: [
        color(0.07, 0.25, 0.85), color(0.10, 0.48, 0.98), color(0.22, 0.72, 1.00)
    ] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: tile.minX, y: tile.minY),
                           end: CGPoint(x: tile.maxX, y: tile.maxY), options: [])

    // Top sheen and bottom shade for depth.
    let sheen = CGGradient(colorsSpace: nil, colors: [
        color(1, 1, 1, 0.20), color(1, 1, 1, 0.0), color(0, 0, 0, 0.12)
    ] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: tile.midX, y: tile.maxY),
                           end: CGPoint(x: tile.midX, y: tile.minY), options: [])

    // Three "text" lines.
    let lineHeight = tile.height * 0.085
    let left = tile.minX + tile.width * 0.20
    let widths: [CGFloat] = [0.60, 0.48, 0.30]
    for (index, fraction) in widths.enumerated() {
        let y = tile.maxY - tile.height * (0.30 + CGFloat(index) * 0.17)
        let rect = CGRect(x: left, y: y, width: tile.width * fraction, height: lineHeight)
        let path = CGPath(roundedRect: rect, cornerWidth: lineHeight / 2, cornerHeight: lineHeight / 2, transform: nil)
        ctx.addPath(path)
        ctx.setFillColor(color(1, 1, 1, index == 2 ? 0.75 : 0.95))
        ctx.fillPath()
    }
    ctx.restoreGState()

    // Check badge, bottom right.
    let badgeDiameter = tile.width * 0.40
    let badge = CGRect(x: tile.maxX - badgeDiameter - tile.width * 0.09,
                       y: tile.minY + tile.height * 0.09,
                       width: badgeDiameter, height: badgeDiameter)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -s * 0.008), blur: s * 0.02, color: color(0, 0.1, 0.3, 0.35))
    ctx.addEllipse(in: badge)
    ctx.setFillColor(color(1, 1, 1))
    ctx.fillPath()
    ctx.restoreGState()

    let inner = badge.insetBy(dx: badgeDiameter * 0.09, dy: badgeDiameter * 0.09)
    ctx.addEllipse(in: inner)
    ctx.setFillColor(color(0.16, 0.78, 0.45))
    ctx.fillPath()

    ctx.setStrokeColor(color(1, 1, 1))
    ctx.setLineWidth(badgeDiameter * 0.11)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.move(to: CGPoint(x: inner.minX + inner.width * 0.27, y: inner.minY + inner.height * 0.50))
    ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.44, y: inner.minY + inner.height * 0.33))
    ctx.addLine(to: CGPoint(x: inner.minX + inner.width * 0.74, y: inner.minY + inner.height * 0.67))
    ctx.strokePath()

    return ctx.makeImage()!
}

func writePNG(_ image: CGImage, to url: URL) throws {
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "make-icon", code: 1)
    }
    try data.write(to: url)
}

let variants: [(name: String, size: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32), ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256), ("icon_256x256", 256),
    ("icon_256x256@2x", 512), ("icon_512x512", 512), ("icon_512x512@2x", 1024)
]
for variant in variants {
    try writePNG(drawIcon(size: variant.size), to: iconsetDir.appendingPathComponent("\(variant.name).png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconsetDir.path, "-o", outputDir.appendingPathComponent("AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
try? FileManager.default.removeItem(at: iconsetDir)
guard iconutil.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil failed\n".utf8))
    exit(1)
}
print("Wrote \(outputDir.appendingPathComponent("AppIcon.icns").path)")
