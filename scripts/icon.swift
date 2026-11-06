// Draws the application icon and writes a full .iconset.
//
// The icon is code rather than a binary asset so it stays editable: the mark
// is a trefoil — the simplest knot there is — drawn as one rope that passes
// over and under itself, which is what a vault of notes tied together by
// links actually is.
//
// Usage: swift scripts/icon.swift <output directory>

import AppKit
import Foundation

/// Apple's icon grid: the body fills 824 of the 1024 canvas, and the rest is
/// the margin every other application in the Dock also leaves.
let canvas = 1024.0
let body = 824.0

func color(_ hex: UInt32, _ alpha: Double = 1) -> NSColor {
    NSColor(
        srgbRed: Double((hex >> 16) & 0xFF) / 255,
        green: Double((hex >> 8) & 0xFF) / 255,
        blue: Double(hex & 0xFF) / 255,
        alpha: alpha
    )
}

func gradient(_ stops: [(Double, NSColor)]) -> CGGradient {
    CGGradient(
        colorsSpace: CGColorSpaceCreateDeviceRGB(),
        colors: stops.map { $0.1.usingColorSpace(.sRGB)!.cgColor } as CFArray,
        locations: stops.map { CGFloat($0.0) }
    )!
}

func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
}

/// The rounded square macOS draws every application in — a superellipse, not a
/// rounded rectangle, which is why the corners have no flat spot where the
/// straight edge meets the curve.
func superellipse(center: CGPoint, half: Double, exponent: Double = 5) -> CGPath {
    let path = CGMutablePath()
    let steps = 720
    for step in 0...steps {
        let angle = Double(step) / Double(steps) * 2 * .pi
        let cosine = cos(angle), sine = sin(angle)
        let x = pow(abs(cosine), 2 / exponent) * half * (cosine < 0 ? -1 : 1)
        let y = pow(abs(sine), 2 / exponent) * half * (sine < 0 ? -1 : 1)
        let point = CGPoint(x: center.x + x, y: center.y + y)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    path.closeSubpath()
    return path
}

/// The standard trefoil: one closed curve that crosses itself three times.
/// Its depth at `t` is `-sin(3t)` — where the rope passes over, and where under.
func knotCurve(_ t: Double) -> CGPoint {
    CGPoint(x: sin(t) + 2 * sin(2 * t), y: cos(t) - 2 * cos(2 * t))
}

/// The curve is not centred on its own origin, so it is measured once and
/// moved onto the middle of the canvas rather than eyeballed into place.
let knotBounds: (center: CGPoint, halfExtent: Double) = {
    var minX = Double.infinity, maxX = -Double.infinity
    var minY = Double.infinity, maxY = -Double.infinity
    for step in 0...2000 {
        let point = knotCurve(Double(step) / 2000 * 2 * .pi)
        minX = min(minX, point.x); maxX = max(maxX, point.x)
        minY = min(minY, point.y); maxY = max(maxY, point.y)
    }
    return (
        CGPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
        max(maxX - minX, maxY - minY) / 2
    )
}()

func knotPoint(_ t: Double, center: CGPoint, scale: Double) -> CGPoint {
    let raw = knotCurve(t)
    return CGPoint(
        x: center.x + (raw.x - knotBounds.center.x) * scale,
        y: center.y + (raw.y - knotBounds.center.y) * scale
    )
}

/// The curve cut at every `sin(3t) == 0`, which is where the rope is furthest
/// from a crossing — so the six arcs meet mid-strand, and each arc keeps one
/// sign of depth for its whole length.
///
/// `overlap` extends an arc past its ends. The casing is drawn without it, so
/// the dark border still stops dead at the seam; the core is drawn with it, so
/// the two halves of a strand meet with no antialiased hairline between them.
func knotArc(_ index: Int, center: CGPoint, scale: Double, overlap: Double = 0) -> CGPath {
    let from = Double(index) * .pi / 3 - overlap, to = Double(index + 1) * .pi / 3 + overlap
    let path = CGMutablePath()
    let samples = 240
    for step in 0...samples {
        let t = from + (to - from) * Double(step) / Double(samples)
        let point = knotPoint(t, center: center, scale: scale)
        if step == 0 { path.move(to: point) } else { path.addLine(to: point) }
    }
    return path
}

func draw(into context: CGContext, size: Double) {
    context.scaleBy(x: size / canvas, y: size / canvas)
    let center = CGPoint(x: canvas / 2, y: canvas / 2)
    let shape = superellipse(center: center, half: body / 2)

    // The body, on the soft shadow every Dock icon casts.
    context.saveGState()
    context.setShadow(
        offset: CGSize(width: 0, height: -16),
        blur: 36,
        color: color(0x000000, 0.45).cgColor
    )
    context.addPath(shape)
    context.setFillColor(color(0x000000).cgColor)
    context.fillPath()
    context.restoreGState()

    context.saveGState()
    context.addPath(shape)
    context.clip()

    // Black, but not a flat black: lit from the top left and falling away.
    context.drawLinearGradient(
        gradient([(0, color(0x23252E)), (0.45, color(0x101218)), (1, color(0x000000))]),
        start: CGPoint(x: canvas * 0.12, y: canvas * 0.98),
        end: CGPoint(x: canvas * 0.88, y: canvas * 0.04),
        options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
    )
    context.drawRadialGradient(
        gradient([(0, color(0x9B7BFF, 0.20)), (1, color(0x9B7BFF, 0))]),
        startCenter: CGPoint(x: canvas * 0.30, y: canvas * 0.76), startRadius: 0,
        endCenter: CGPoint(x: canvas * 0.30, y: canvas * 0.76), endRadius: body * 0.70,
        options: []
    )

    // The rope: a core of hemp, a dark casing around it. The casing is what
    // makes a crossing read as over rather than merely touching.
    let coreWidth = body * 0.105
    let casingWidth = coreWidth + body * 0.034
    // Fit the knot, casing and all, to a little over three quarters of the body.
    let scale = (body * 0.78 / 2 - casingWidth / 2) / knotBounds.halfExtent

    func strand(_ index: Int) {
        context.saveGState()
        context.setLineCap(.butt)
        context.setLineJoin(.round)

        context.addPath(knotArc(index, center: center, scale: scale))
        context.setLineWidth(casingWidth)
        context.setStrokeColor(color(0x000000, 0.94).cgColor)
        context.strokePath()

        context.addPath(knotArc(index, center: center, scale: scale, overlap: 0.02))
        context.setLineWidth(coreWidth)
        context.replacePathWithStrokedPath()
        context.clip()
        context.drawLinearGradient(
            gradient([(0, color(0xF6E4C4)), (0.5, color(0xE3C295)), (1, color(0xB98E5F))]),
            start: CGPoint(x: canvas * 0.22, y: canvas * 0.82),
            end: CGPoint(x: canvas * 0.80, y: canvas * 0.16),
            options: [.drawsBeforeStartLocation, .drawsAfterEndLocation]
        )
        context.restoreGState()
    }

    // Everything that passes under, then everything that passes over.
    for index in [0, 2, 4] { strand(index) }
    for index in [1, 3, 5] { strand(index) }

    // The rim light that keeps the body from dissolving into a dark Dock.
    context.addPath(superellipse(center: center, half: body / 2 - 1.5))
    context.setStrokeColor(color(0xFFFFFF, 0.14).cgColor)
    context.setLineWidth(3)
    context.strokePath()
    context.restoreGState()
}

func render(size: Double) -> Data {
    let pixels = Int(size.rounded())
    let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    draw(into: context, size: size)
    let image = context.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: icon.swift <output directory>\n".utf8))
    exit(1)
}

let iconset = URL(fileURLWithPath: arguments[1]).appendingPathComponent("Om.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

for point in [16.0, 32, 128, 256, 512] {
    for scale in [1.0, 2.0] {
        let name = scale == 1
            ? "icon_\(Int(point))x\(Int(point)).png"
            : "icon_\(Int(point))x\(Int(point))@2x.png"
        try render(size: point * scale).write(to: iconset.appendingPathComponent(name))
    }
}
print(iconset.path)
