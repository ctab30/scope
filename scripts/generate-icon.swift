#!/usr/bin/env swift
// Generates a minimal monochrome rocket ship app icon for Scope.
// Usage: swift generate-icon.swift [output-dir]

import AppKit

let outputDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

let size: CGFloat = 1024

let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(size),
    pixelsHigh: Int(size),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
)!

NSGraphicsContext.saveGraphicsState()
let ctx = NSGraphicsContext(bitmapImageRep: rep)!
NSGraphicsContext.current = ctx
let g = ctx.cgContext

// -- Background: dark charcoal gradient --
let darkTop = NSColor(red: 0.12, green: 0.12, blue: 0.14, alpha: 1.0).cgColor
let darkBot = NSColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1.0).cgColor
let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [darkBot, darkTop] as CFArray,
    locations: [0, 1]
)!
g.drawLinearGradient(bgGradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])

// -- Rocket ship (centered, bold, filled) --
// Coordinate system: origin bottom-left, we'll draw the rocket pointing up-right at ~45 degrees
// But simpler: draw it pointing straight up, centered

let cx: CGFloat = 512  // center x
let cy: CGFloat = 530  // center y (slightly above center)

// Rocket body - a bold rounded shape
let body = CGMutablePath()

// Nose cone (top)
body.move(to: CGPoint(x: cx, y: cy + 280))

// Right side curve down
body.addCurve(
    to: CGPoint(x: cx + 95, y: cy + 80),
    control1: CGPoint(x: cx + 20, y: cy + 240),
    control2: CGPoint(x: cx + 80, y: cy + 160)
)

// Right fin
body.addLine(to: CGPoint(x: cx + 95, y: cy - 40))
body.addLine(to: CGPoint(x: cx + 170, y: cy - 160))
body.addLine(to: CGPoint(x: cx + 110, y: cy - 140))
body.addLine(to: CGPoint(x: cx + 85, y: cy - 100))

// Bottom right
body.addLine(to: CGPoint(x: cx + 75, y: cy - 160))

// Exhaust nozzle bottom
body.addCurve(
    to: CGPoint(x: cx - 75, y: cy - 160),
    control1: CGPoint(x: cx + 40, y: cy - 190),
    control2: CGPoint(x: cx - 40, y: cy - 190)
)

// Bottom left
body.addLine(to: CGPoint(x: cx - 85, y: cy - 100))
body.addLine(to: CGPoint(x: cx - 110, y: cy - 140))
body.addLine(to: CGPoint(x: cx - 170, y: cy - 160))
body.addLine(to: CGPoint(x: cx - 95, y: cy - 40))

// Left side curve up
body.addLine(to: CGPoint(x: cx - 95, y: cy + 80))
body.addCurve(
    to: CGPoint(x: cx, y: cy + 280),
    control1: CGPoint(x: cx - 80, y: cy + 160),
    control2: CGPoint(x: cx - 20, y: cy + 240)
)

body.closeSubpath()

// Fill rocket body with a subtle light gradient
g.saveGState()
g.addPath(body)
g.clip()

let bodyBot = NSColor(white: 0.65, alpha: 1.0).cgColor
let bodyTop = NSColor(white: 0.90, alpha: 1.0).cgColor
let bodyGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [bodyBot, bodyTop] as CFArray,
    locations: [0, 1]
)!
g.drawLinearGradient(bodyGradient,
    start: CGPoint(x: cx, y: cy - 190),
    end: CGPoint(x: cx, y: cy + 280),
    options: [])
g.restoreGState()

// Rocket body outline
g.setStrokeColor(NSColor(white: 0.95, alpha: 0.3).cgColor)
g.setLineWidth(3)
g.addPath(body)
g.strokePath()

// -- Window/porthole (circle on the body) --
let portholeCY = cy + 80
let portholeR: CGFloat = 42
let portholeRect = CGRect(x: cx - portholeR, y: portholeCY - portholeR, width: portholeR * 2, height: portholeR * 2)

// Dark porthole
g.setFillColor(NSColor(red: 0.15, green: 0.18, blue: 0.25, alpha: 1.0).cgColor)
g.fillEllipse(in: portholeRect)

// Porthole ring
g.setStrokeColor(NSColor(white: 0.55, alpha: 0.8).cgColor)
g.setLineWidth(5)
g.strokeEllipse(in: portholeRect)

// Porthole highlight (small bright arc)
let highlightRect = CGRect(x: cx - portholeR + 10, y: portholeCY - portholeR + 14, width: 20, height: 20)
g.setFillColor(NSColor(white: 0.45, alpha: 0.5).cgColor)
g.fillEllipse(in: highlightRect)

// -- Exhaust flames --
let flameColor1 = NSColor(red: 0.95, green: 0.55, blue: 0.15, alpha: 0.7).cgColor
let flameColor2 = NSColor(red: 0.95, green: 0.30, blue: 0.10, alpha: 0.5).cgColor

// Center flame (large)
let flame1 = CGMutablePath()
flame1.move(to: CGPoint(x: cx - 45, y: cy - 160))
flame1.addCurve(
    to: CGPoint(x: cx, y: cy - 340),
    control1: CGPoint(x: cx - 30, y: cy - 240),
    control2: CGPoint(x: cx - 15, y: cy - 310)
)
flame1.addCurve(
    to: CGPoint(x: cx + 45, y: cy - 160),
    control1: CGPoint(x: cx + 15, y: cy - 310),
    control2: CGPoint(x: cx + 30, y: cy - 240)
)
flame1.closeSubpath()

g.saveGState()
g.addPath(flame1)
g.clip()
let flameGrad = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [flameColor1, flameColor2, NSColor(red: 0.9, green: 0.2, blue: 0.05, alpha: 0.0).cgColor] as CFArray,
    locations: [0, 0.5, 1.0]
)!
g.drawLinearGradient(flameGrad,
    start: CGPoint(x: cx, y: cy - 160),
    end: CGPoint(x: cx, y: cy - 340),
    options: [])
g.restoreGState()

// Inner bright flame core
let flame2 = CGMutablePath()
flame2.move(to: CGPoint(x: cx - 22, y: cy - 165))
flame2.addCurve(
    to: CGPoint(x: cx, y: cy - 280),
    control1: CGPoint(x: cx - 12, y: cy - 220),
    control2: CGPoint(x: cx - 5, y: cy - 260)
)
flame2.addCurve(
    to: CGPoint(x: cx + 22, y: cy - 165),
    control1: CGPoint(x: cx + 5, y: cy - 260),
    control2: CGPoint(x: cx + 12, y: cy - 220)
)
flame2.closeSubpath()

g.setFillColor(NSColor(red: 1.0, green: 0.75, blue: 0.3, alpha: 0.6).cgColor)
g.addPath(flame2)
g.fillPath()

// -- Small stars in background (subtle) --
let starPositions: [(CGFloat, CGFloat, CGFloat)] = [
    (180, 800, 3), (750, 850, 2.5), (850, 650, 2),
    (150, 400, 2.5), (820, 350, 3), (300, 900, 2),
    (700, 200, 2.5), (130, 200, 2), (900, 150, 3),
    (400, 170, 2), (650, 920, 2.5), (250, 650, 2),
]

for (sx, sy, sr) in starPositions {
    g.setFillColor(NSColor(white: 1.0, alpha: 0.25).cgColor)
    g.fillEllipse(in: CGRect(x: sx - sr, y: sy - sr, width: sr * 2, height: sr * 2))
}

NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
let outputPath = (outputDir as NSString).appendingPathComponent("icon_1024.png")
try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("Icon written to: \(outputPath)")
