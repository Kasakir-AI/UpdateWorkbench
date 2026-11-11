// Generates the Update Workbench app icon (original design) with Core Graphics.
// Usage: xcrun swift Resources/AppIcon/make-icon.swift <output.iconset> [<preview-1024.png>]
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let indigo = CGColor(srgbRed: 0.36, green: 0.42, blue: 1.00, alpha: 1)
let violet = CGColor(srgbRed: 0.62, green: 0.36, blue: 0.98, alpha: 1)
let pink = CGColor(srgbRed: 0.98, green: 0.38, blue: 0.62, alpha: 1)
let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)

/// Draws on a 1024-unit canvas scaled to `pixels`. Small sizes use a simplified, heavier glyph.
func render(pixels: Int) -> CGImage {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: pixels, height: pixels, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    ctx.interpolationQuality = .high
    let small = pixels <= 32
    // Body: macOS-style rounded square inside the standard 1024 grid (824 pt body, small sizes fill more).
    let inset: CGFloat = small ? 40 : 100
    let body = CGRect(x: inset, y: inset, width: 1024 - 2 * inset, height: 1024 - 2 * inset)
    let radius = body.width * 0.225
    let bodyPath = CGPath(roundedRect: body, cornerWidth: radius, cornerHeight: radius, transform: nil)
    if !small {
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.35))
        ctx.addPath(bodyPath); ctx.setFillColor(indigo); ctx.fillPath()
        ctx.restoreGState()
    }
    ctx.saveGState()
    ctx.addPath(bodyPath); ctx.clip()
    let gradient = CGGradient(colorsSpace: space, colors: [indigo, violet, pink] as CFArray, locations: [0, 0.55, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: body.minX, y: body.maxY), end: CGPoint(x: body.maxX, y: body.minY), options: [])
    // Soft highlight at the top for depth.
    let gloss = CGGradient(colorsSpace: space, colors: [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.28), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(gloss, startCenter: CGPoint(x: 400, y: 900), startRadius: 0, endCenter: CGPoint(x: 400, y: 900), endRadius: 620, options: [])
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 512)
    ctx.saveGState()
    if !small { ctx.setShadow(offset: CGSize(width: 0, height: -8), blur: 16, color: CGColor(srgbRed: 0.15, green: 0.05, blue: 0.35, alpha: 0.35)) }
    ctx.setFillColor(white); ctx.setStrokeColor(white)
    ctx.beginTransparencyLayer(auxiliaryInfo: nil)
    if small {
        // Simplified: heavy ring with a bold down arrow, legible at 16 px.
        ctx.setLineWidth(110)
        ctx.addEllipse(in: CGRect(x: c.x - 320, y: c.y - 320, width: 640, height: 640)); ctx.strokePath()
        downArrow(ctx, center: c, shaft: 120, head: 340, top: 230, bottom: -230, headBase: -10)
    } else {
        // Two circular refresh arrows around a down arrow.
        let r: CGFloat = 268, line: CGFloat = 66
        ctx.setLineWidth(line); ctx.setLineCap(.round)
        for (start, end) in [(CGFloat(28), CGFloat(146)), (CGFloat(208), CGFloat(326))] {
            ctx.addArc(center: c, radius: r, startAngle: start * .pi / 180, endAngle: end * .pi / 180, clockwise: false)
            ctx.strokePath()
            arrowHead(ctx, center: c, radius: r, angle: end * .pi / 180, length: 130, width: 170)
        }
        downArrow(ctx, center: c, shaft: 74, head: 230, top: 150, bottom: -150, headBase: -30)
    }
    ctx.endTransparencyLayer()
    ctx.restoreGState()
    return ctx.makeImage()!
}

/// Triangle at angle on the circle, pointing counter-clockwise along the tangent.
func arrowHead(_ ctx: CGContext, center: CGPoint, radius: CGFloat, angle: CGFloat, length: CGFloat, width: CGFloat) {
    let base = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
    let tangent = CGPoint(x: -sin(angle), y: cos(angle))
    let normal = CGPoint(x: cos(angle), y: sin(angle))
    let tip = CGPoint(x: base.x + tangent.x * length, y: base.y + tangent.y * length)
    ctx.move(to: tip)
    ctx.addLine(to: CGPoint(x: base.x + normal.x * width / 2, y: base.y + normal.y * width / 2))
    ctx.addLine(to: CGPoint(x: base.x - normal.x * width / 2, y: base.y - normal.y * width / 2))
    ctx.closePath(); ctx.fillPath()
}

func downArrow(_ ctx: CGContext, center c: CGPoint, shaft: CGFloat, head: CGFloat, top: CGFloat, bottom: CGFloat, headBase: CGFloat) {
    let shaftRect = CGRect(x: c.x - shaft / 2, y: c.y + headBase - 2, width: shaft, height: top - headBase + 2)
    ctx.addPath(CGPath(roundedRect: shaftRect, cornerWidth: shaft / 2.5, cornerHeight: shaft / 2.5, transform: nil)); ctx.fillPath()
    ctx.move(to: CGPoint(x: c.x, y: c.y + bottom))
    ctx.addLine(to: CGPoint(x: c.x + head / 2, y: c.y + headBase))
    ctx.addLine(to: CGPoint(x: c.x - head / 2, y: c.y + headBase))
    ctx.closePath(); ctx.fillPath()
}

func write(_ image: CGImage, to url: URL) {
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { fatalError("Could not write \(url.path)") }
}

let args = CommandLine.arguments
guard args.count >= 2 else { print("usage: make-icon.swift <output.iconset> [<preview.png>]"); exit(64) }
let iconset = URL(fileURLWithPath: args[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    write(render(pixels: points), to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    write(render(pixels: points * 2), to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}
if args.count >= 3 { write(render(pixels: 1024), to: URL(fileURLWithPath: args[2])) }
print("Wrote \(iconset.path)")
