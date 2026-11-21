// Draws the app icon from the same 100-unit geometry as the design canvas: the cat peeking over the refresh button.
// Usage: swift scripts/render-icon.swift <output directory>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct Style {
    var background: CGColor?
    var cat: CGColor
    var button: CGColor
    var lip: CGColor
    var ink: CGColor
    var eye: CGColor
}

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func render(_ style: Style, size: Int, to url: URL) {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!
    let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Work in the design's y-down, 100-unit space.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: CGFloat(size) / 100, y: -CGFloat(size) / 100)

    if let background = style.background {
        context.setFillColor(background)
        context.fill(CGRect(x: 0, y: 0, width: 100, height: 100))
    }

    // Head, drawn on its own 120 × 84 grid.
    context.saveGState()
    context.translateBy(x: 26.6, y: 6.1)
    context.scaleBy(x: 0.39, y: 0.39)
    let head = CGMutablePath()
    head.move(to: CGPoint(x: 25, y: 38)); head.addLine(to: CGPoint(x: 27.5, y: 9.5))
    head.addQuadCurve(to: CGPoint(x: 32.1, y: 7.5), control: CGPoint(x: 28.1, y: 4.9)); head.addLine(to: CGPoint(x: 52, y: 25)); head.closeSubpath()
    head.move(to: CGPoint(x: 95, y: 38)); head.addLine(to: CGPoint(x: 92.5, y: 9.5))
    head.addQuadCurve(to: CGPoint(x: 87.9, y: 7.5), control: CGPoint(x: 91.9, y: 4.9)); head.addLine(to: CGPoint(x: 68, y: 25)); head.closeSubpath()
    head.move(to: CGPoint(x: 22, y: 88)); head.addLine(to: CGPoint(x: 22, y: 52))
    head.addQuadCurve(to: CGPoint(x: 60, y: 22), control: CGPoint(x: 22, y: 24))
    head.addQuadCurve(to: CGPoint(x: 98, y: 52), control: CGPoint(x: 98, y: 24))
    head.addLine(to: CGPoint(x: 98, y: 88)); head.closeSubpath()
    context.setFillColor(style.cat)
    context.setStrokeColor(style.cat)
    context.setLineWidth(4)
    context.setLineJoin(.round)
    context.addPath(head); context.fillPath()
    context.addPath(head); context.strokePath()
    context.setFillColor(style.eye)
    context.fillEllipse(in: CGRect(x: 45 - 7.4, y: 45 - 8.4, width: 14.8, height: 16.8))
    context.fillEllipse(in: CGRect(x: 75 - 7.4, y: 45 - 8.4, width: 14.8, height: 16.8))
    context.setFillColor(style.ink)
    context.fillEllipse(in: CGRect(x: 45 - 2.6, y: 45 - 6.2, width: 5.2, height: 12.4))
    context.fillEllipse(in: CGRect(x: 75 - 2.6, y: 45 - 6.2, width: 5.2, height: 12.4))
    context.restoreGState()

    // The button: a darker lip, then the face.
    context.setFillColor(style.lip)
    context.fillEllipse(in: CGRect(x: 20, y: 33, width: 60, height: 60))
    context.setFillColor(style.button)
    context.fillEllipse(in: CGRect(x: 20, y: 30, width: 60, height: 60))

    // The refresh arrow on the 24-unit grid.
    context.saveGState()
    context.translateBy(x: 33.2, y: 43.2)
    context.scaleBy(x: 1.4, y: 1.4)
    context.setStrokeColor(style.ink)
    context.setLineWidth(2.6)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.addArc(center: CGPoint(x: 12, y: 12), radius: 8, startAngle: 0, endAngle: 7 * .pi / 4, clockwise: false)
    context.strokePath()
    context.move(to: CGPoint(x: 20, y: 4)); context.addLine(to: CGPoint(x: 20, y: 8)); context.addLine(to: CGPoint(x: 16, y: 8))
    context.strokePath()
    context.restoreGState()

    // Paws on the rim, outlined in the background colour so they read apart from the face.
    for (x, angle) in [(35.0, -14.0), (65.0, 14.0)] {
        context.saveGState()
        context.translateBy(x: x, y: 32.3)
        context.rotate(by: angle * .pi / 180)
        let paw = CGRect(x: -4.4, y: -3.1, width: 8.8, height: 6.2)
        context.setFillColor(style.cat)
        context.fillEllipse(in: paw)
        if let outline = style.background {
            context.setStrokeColor(outline)
            context.setLineWidth(1.4)
            context.strokeEllipse(in: paw)
        }
        context.restoreGState()
    }

    let image = context.makeImage()!
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
}

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ".")
let lemon = rgb(0xFFDD33)
render(Style(background: rgb(0xF4F4F1), cat: rgb(0x121210), button: lemon, lip: rgb(0x121210, 0.16), ink: rgb(0x121210), eye: lemon), size: 1024, to: output.appending(path: "AppIcon.png"))
render(Style(background: rgb(0x121210), cat: rgb(0x5A5A52), button: lemon, lip: rgb(0x000000, 0.55), ink: rgb(0x121210), eye: lemon), size: 1024, to: output.appending(path: "AppIcon-Dark.png"))
// Tinted icons are read as luminance on a dark backdrop: bright parts take the tint.
render(Style(background: nil, cat: rgb(0x5C5C5C), button: rgb(0xFFFFFF), lip: rgb(0xFFFFFF, 0.25), ink: rgb(0x000000), eye: rgb(0xFFFFFF)), size: 1024, to: output.appending(path: "AppIcon-Tinted.png"))
print("wrote icons to \(output.path)")
