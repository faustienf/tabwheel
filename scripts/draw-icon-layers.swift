#!/usr/bin/env swift
// Draws the artwork layers of the app icon into Support/AppIcon.icon/Assets/.
// The icon itself (background and layer styling) is described in Support/AppIcon.icon/icon.json
// and can be tweaked in Icon Composer (Xcode → Open Developer Tool → Icon Composer).
// The next build picks changes up: scripts/setup.sh compiles the icon with actool.
//
//   swift scripts/draw-icon-layers.swift
//
// Layers are 1024×1024 points: warm neutral artwork and one coral orbital accent.
//   ring.png     – a continuous open orbit
//   selected.png – the coral selection arc at 1:30
//   command.png  – an ivory ⌘ in the hub
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let size = 1024
let center = CGPoint(x: 512, y: 512)

// A quiet orbit replaces the chunky segmented wheel.
let ringRadius: CGFloat = 340
let ringStroke: CGFloat = 24
let selectedStroke: CGFloat = 36
let selectedAngle: CGFloat = .pi / 4
let selectedHalfAngle: CGFloat = 0.34
let selectionGap: CGFloat = 0.13

// ⌘: a square with a loop at each corner. `half` = half the square's side, loops are as big.
let commandHalf: CGFloat = 54
let commandStroke: CGFloat = 26

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
    context.setStrokeColor(CGColor(red: 0.72, green: 0.7, blue: 0.66, alpha: 1))
    context.setLineWidth(ringStroke)
    context.setLineCap(.round)
    context.addArc(center: center, radius: ringRadius,
                   startAngle: selectedAngle + selectedHalfAngle + selectionGap,
                   endAngle: selectedAngle - selectedHalfAngle - selectionGap + 2 * .pi,
                   clockwise: false)
    context.strokePath()
}

try render("selected.png") { context in
    context.setStrokeColor(CGColor(red: 0.97, green: 0.5, blue: 0.4, alpha: 1))
    context.setLineWidth(selectedStroke)
    context.setLineCap(.round)
    context.addArc(center: center, radius: ringRadius,
                   startAngle: selectedAngle - selectedHalfAngle,
                   endAngle: selectedAngle + selectedHalfAngle, clockwise: false)
    context.strokePath()
}

try render("command.png") { context in
    context.setStrokeColor(CGColor(red: 0.95, green: 0.93, blue: 0.87, alpha: 1))
    context.addPath(commandPath())
    context.setLineWidth(commandStroke)
    context.setLineJoin(.round)
    context.setLineCap(.round)
    context.strokePath()
}
