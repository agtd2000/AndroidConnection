import AppKit
import Foundation

let outputDirectory = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    : URL(fileURLWithPath: "build/AppIcon.iconset", isDirectory: true)

try? FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawArtwork(in context: CGContext) {
    let canvas: CGFloat = 1024
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    // Background card with a soft diagonal gradient.
    let card = CGRect(x: 56, y: 56, width: 912, height: 912)
    let cardPath = CGPath(roundedRect: card, cornerWidth: 208, cornerHeight: 208, transform: nil)
    context.saveGState()
    context.addPath(cardPath)
    context.clip()
    let gradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.05, 0.36, 0.55), color(0.16, 0.74, 0.62)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 56, y: 968),
        end: CGPoint(x: 968, y: 40),
        options: []
    )

    // Subtle highlight.
    context.setFillColor(color(1, 1, 1, 0.08))
    context.fillEllipse(in: CGRect(x: 560, y: 600, width: 520, height: 520))
    context.restoreGState()

    // Phone body.
    let phoneRect = CGRect(x: 352, y: 206, width: 320, height: 612)
    let phone = CGPath(roundedRect: phoneRect, cornerWidth: 78, cornerHeight: 78, transform: nil)
    context.setFillColor(color(1, 1, 1, 0.96))
    context.addPath(phone)
    context.fillPath()

    // Screen.
    let screenRect = CGRect(x: 376, y: 240, width: 272, height: 544)
    let screen = CGPath(roundedRect: screenRect, cornerWidth: 52, cornerHeight: 52, transform: nil)
    context.saveGState()
    context.addPath(screen)
    context.clip()
    let screenGradient = CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: [color(0.03, 0.22, 0.34), color(0.05, 0.42, 0.46)] as CFArray,
        locations: [0, 1]
    )!
    context.drawLinearGradient(
        screenGradient,
        start: CGPoint(x: 376, y: 784),
        end: CGPoint(x: 648, y: 240),
        options: []
    )

    // Cast / mirror arcs.
    let origin = CGPoint(x: 430, y: 640)
    context.setStrokeColor(color(1, 1, 1, 0.95))
    context.setFillColor(color(1, 1, 1, 0.95))
    context.setLineCap(.round)
    for (index, radius) in [52.0, 96.0, 140.0].enumerated() {
        context.setLineWidth(index == 0 ? 26 : 24)
        context.addArc(center: origin, radius: radius, startAngle: -.pi / 2, endAngle: 0, clockwise: false)
        context.strokePath()
    }
    context.fillEllipse(in: CGRect(x: origin.x - 17, y: origin.y - 17, width: 34, height: 34))
    context.restoreGState()

    // Speaker notch.
    context.setFillColor(color(0.08, 0.26, 0.34))
    let notch = CGPath(
        roundedRect: CGRect(x: 462, y: 752, width: 100, height: 16),
        cornerWidth: 8,
        cornerHeight: 8,
        transform: nil
    )
    context.addPath(notch)
    context.fillPath()

    // Tiny base shadow ellipse.
    context.setFillColor(color(0, 0, 0, 0.10))
    context.fillEllipse(in: CGRect(x: 320, y: 150, width: 384, height: 34))
}

func render(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    let context = graphics.cgContext
    context.scaleBy(x: CGFloat(size) / 1024.0, y: CGFloat(size) / 1024.0)
    drawArtwork(in: context)
    NSGraphicsContext.restoreGraphicsState()
    return bitmap.representation(using: .png, properties: [:])
}

let variants: [(String, Int)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

for (name, size) in variants {
    guard let data = render(size: size) else {
        FileHandle.standardError.write(Data("Failed to render \(name)\n".utf8))
        exit(1)
    }
    try data.write(to: outputDirectory.appendingPathComponent(name))
}
print("Iconset written to \(outputDirectory.path)")
