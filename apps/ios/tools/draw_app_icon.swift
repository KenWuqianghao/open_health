// Draws the app icon: the three daily scores as concentric rings (Readiness teal,
// Sleep indigo, Activity orange) on a dark gradient, matching the Summary screen.
// Run: swift apps/ios/tools/draw_app_icon.swift <output.png>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let space = CGColorSpace(name: CGColorSpace.displayP3)!
guard let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                          space: space, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { exit(1) }

func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(colorSpace: space, components: [r / 255, g / 255, b / 255, a])!
}

let s = CGFloat(size)
let center = CGPoint(x: s / 2, y: s / 2)

// background: deep night gradient, lighter at the top
let bg = CGGradient(colorsSpace: space,
                    colors: [rgb(30, 32, 52), rgb(12, 13, 22), rgb(6, 7, 11)] as CFArray,
                    locations: [0, 0.55, 1])!
ctx.drawLinearGradient(bg, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

// a soft indigo bloom behind the rings
let bloom = CGGradient(colorsSpace: space,
                       colors: [rgb(94, 92, 230, 0.30), rgb(94, 92, 230, 0)] as CFArray,
                       locations: [0, 1])!
ctx.drawRadialGradient(bloom, startCenter: center, startRadius: 0, endCenter: center, endRadius: s * 0.46, options: [])

// rings: outer to inner. (radius, fill fraction, colour)
let lineWidth: CGFloat = 62
let rings: [(CGFloat, CGFloat, CGColor)] = [
    (318, 0.86, rgb(64, 214, 222)),   // readiness, teal
    (238, 0.74, rgb(110, 108, 245)),  // sleep, indigo
    (158, 0.62, rgb(255, 159, 10)),   // activity, orange
]
ctx.setLineCap(.round)
ctx.setLineWidth(lineWidth)
for (radius, fraction, colour) in rings {
    // track
    ctx.setShadow(offset: .zero, blur: 0, color: nil)
    ctx.setStrokeColor(colour.copy(alpha: 0.16)!)
    ctx.addArc(center: center, radius: radius, startAngle: 0, endAngle: .pi * 2, clockwise: false)
    ctx.strokePath()
    // progress: from 12 o'clock, clockwise (CG's y axis points up, so clockwise = true)
    let start = CGFloat.pi / 2
    let end = start - .pi * 2 * fraction
    ctx.setShadow(offset: .zero, blur: 38, color: colour.copy(alpha: 0.75))
    ctx.setStrokeColor(colour)
    ctx.addArc(center: center, radius: radius, startAngle: start, endAngle: end, clockwise: true)
    ctx.strokePath()
}

guard let image = ctx.makeImage(),
      let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: out) as CFURL,
                                                 UTType.png.identifier as CFString, 1, nil) else { exit(1) }
CGImageDestinationAddImage(dest, image, nil)
exit(CGImageDestinationFinalize(dest) ? 0 : 1)
