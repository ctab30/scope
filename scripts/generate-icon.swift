#!/usr/bin/env swift
// Generates a minimal monochrome "W" lettermark app icon for Workspace.
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

// -- Background: dark charcoal gradient (matches app theme) --
let darkTop = NSColor(red: 0.11, green: 0.11, blue: 0.13, alpha: 1.0).cgColor
let darkBot = NSColor(red: 0.06, green: 0.06, blue: 0.08, alpha: 1.0).cgColor
let bgGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [darkBot, darkTop] as CFArray,
    locations: [0, 1]
)!
g.drawLinearGradient(bgGradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])

// -- Rounded rectangle background (macOS icon shape) --
let inset: CGFloat = 12
let iconRect = CGRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let cornerRadius: CGFloat = size * 0.22 // macOS standard ~22%
let bgPath = CGPath(roundedRect: iconRect, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)
g.addPath(bgPath)
g.clip()

// Redraw gradient inside clipped shape
g.drawLinearGradient(bgGradient, start: .zero, end: CGPoint(x: 0, y: size), options: [])

// -- "W" letterform --
// Clean, geometric, slightly bold "W" centered in the icon
let cx: CGFloat = 512
let cy: CGFloat = 512

// W dimensions
let wTop: CGFloat = cy + 210    // top of W
let wBot: CGFloat = cy - 210    // bottom of W
let wLeft: CGFloat = cx - 260   // left extent
let wRight: CGFloat = cx + 260  // right extent
let strokeWidth: CGFloat = 52   // stroke thickness

// Draw the W as a bold path
let w = CGMutablePath()

// Outer shape of W
// Start at top-left
w.move(to: CGPoint(x: wLeft, y: wTop))
// Down-left to bottom-left valley
w.addLine(to: CGPoint(x: wLeft + 120, y: wBot))
// Up to center peak
w.addLine(to: CGPoint(x: cx, y: wBot + 180))
// Down to bottom-right valley
w.addLine(to: CGPoint(x: wRight - 120, y: wBot))
// Up to top-right
w.addLine(to: CGPoint(x: wRight, y: wTop))

// Now trace the inner shape back (creating the stroke effect)
w.addLine(to: CGPoint(x: wRight - strokeWidth, y: wTop))
w.addLine(to: CGPoint(x: wRight - 120, y: wBot + strokeWidth + 10))
w.addLine(to: CGPoint(x: cx, y: wBot + 180 + strokeWidth - 10))
w.addLine(to: CGPoint(x: wLeft + 120, y: wBot + strokeWidth + 10))
w.addLine(to: CGPoint(x: wLeft + strokeWidth, y: wTop))

w.closeSubpath()

// Fill with white gradient (subtle top-to-bottom)
g.saveGState()
g.addPath(w)
g.clip()

let wGradBot = NSColor(white: 0.75, alpha: 1.0).cgColor
let wGradTop = NSColor(white: 1.0, alpha: 1.0).cgColor
let wGradient = CGGradient(
    colorsSpace: CGColorSpaceCreateDeviceRGB(),
    colors: [wGradBot, wGradTop] as CFArray,
    locations: [0, 1]
)!
g.drawLinearGradient(wGradient,
    start: CGPoint(x: cx, y: wBot),
    end: CGPoint(x: cx, y: wTop),
    options: [])
g.restoreGState()

// -- Subtle glow behind the W --
g.saveGState()
g.setShadow(offset: .zero, blur: 40, color: NSColor(white: 1.0, alpha: 0.15).cgColor)
g.addPath(w)
g.setFillColor(NSColor(white: 1.0, alpha: 0.9).cgColor)
g.fillPath()
g.restoreGState()

NSGraphicsContext.restoreGraphicsState()

let pngData = rep.representation(using: .png, properties: [:])!
let outputPath = (outputDir as NSString).appendingPathComponent("icon_1024.png")
try! pngData.write(to: URL(fileURLWithPath: outputPath))
print("Icon written to: \(outputPath)")
