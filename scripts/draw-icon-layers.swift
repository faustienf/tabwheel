#!/usr/bin/env swift
// Draws the artwork layers of the app icon into Support/AppIcon.icon/Assets/.
// The icon itself (background, glass, shadows) is described in Support/AppIcon.icon/icon.json
// and can be tweaked in Icon Composer (Xcode → Open Developer Tool → Icon Composer).
// The next build picks changes up: scripts/bundle-app.sh compiles the icon with actool.
//
//   swift scripts/draw-icon-layers.swift
//
// Layers are 1024×1024 points, white on transparent; the icon colors them via the glass.
//   ring.png     – the wheel's sectors, minus the selected one
//   selected.png – the selected sector at 12 o'clock (the quick-switch slot)
//   command.png  – a ⌘ in the hub
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let center = CGPoint(x: 512, y: 512)

// Wheel geometry, in points of the 1024 canvas.
let outerRadius: CGFloat = 384
let innerRadius: CGFloat = 238
let sectorCount = 8
let gap: CGFloat = 26         // between sectors, same width all the way out
let cornerRadius: CGFloat = 22

// ⌘: a square with a loop at each corner. `half` = half the square's side, loops are as big.
let commandHalf: CGFloat = 46
let commandStroke: CGFloat = 30

let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "Support/AppIcon.icon/Assets", isDirectory: true)

func render(_ name: String, draw: (CGContext) -> Void) throws {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.setStrokeColor(CGColor(gray: 1, alpha: 1))
    draw(context)
    let url = outputDirectory.appendingPathComponent(name)
    let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    guard CGImageDestinationFinalize(destination) else { throw CocoaError(.fileWriteUnknown) }
    print("✓ \(url.path)")
}

/// One sector of the ring, centered on `angle` (radians, CG coordinates: y up, 0 = 3 o'clock).
/// Drawn shrunk by the corner radius, then filled and stroked with round joins — that rounds
/// the corners without changing the outline.
func sectorPath(at angle: CGFloat) -> CGPath {
    let half = CGFloat.pi / CGFloat(sectorCount)
    let outer = outerRadius - cornerRadius
    let inner = innerRadius + cornerRadius
    let edgeOffset = gap / 2 + cornerRadius
    // Straight edges parallel to the sector boundary: the angular inset grows towards the hub.
    let outerInset = asin(edgeOffset / outer)
    let innerInset = asin(edgeOffset / inner)
    let path = CGMutablePath()
    path.addArc(center: center, radius: outer, startAngle: angle - half + outerInset,
                endAngle: angle + half - outerInset, clockwise: false)
    path.addArc(center: center, radius: inner, startAngle: angle + half - innerInset,
                endAngle: angle - half + innerInset, clockwise: true)
    path.closeSubpath()
    return path
}

func fillRounded(_ path: CGPath, in context: CGContext) {
    context.addPath(path)
    context.fillPath()
    context.addPath(path)
    context.setLineWidth(cornerRadius * 2)
    context.setLineJoin(.round)
    context.strokePath()
}

/// Slot 0 sits at 12 o'clock, the rest go clockwise — same as the wheel.
func slotAngle(_ slot: Int) -> CGFloat {
    .pi / 2 - CGFloat(slot) * 2 * .pi / CGFloat(sectorCount)
}

/// ⌘ as one closed line: four straight sides of the square, each running on into a 270° loop.
func commandPath() -> CGPath {
    let a = commandHalf
    let r = commandHalf
    let c = a + r // loop centers sit diagonally off the square's corners
    let path = CGMutablePath()
    path.move(to: CGPoint(x: center.x - a, y: center.y + c))
    // Bottom-left, bottom-right, top-right, top-left loops; addArc draws the side leading into each.
    let loops: [(dx: CGFloat, dy: CGFloat, start: CGFloat)] = [
        (-c, -c, 0), (c, -c, .pi / 2), (c, c, .pi), (-c, c, 3 * .pi / 2),
    ]
    for loop in loops {
        path.addArc(center: CGPoint(x: center.x + loop.dx, y: center.y + loop.dy), radius: r,
                    startAngle: loop.start, endAngle: loop.start + .pi / 2, clockwise: true)
    }
    path.closeSubpath()
    return path
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

try render("ring.png") { context in
    for slot in 1..<sectorCount {
        fillRounded(sectorPath(at: slotAngle(slot)), in: context)
    }
}

try render("selected.png") { context in
    fillRounded(sectorPath(at: slotAngle(0)), in: context)
}

try render("command.png") { context in
    context.addPath(commandPath())
    context.setLineWidth(commandStroke)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
}
