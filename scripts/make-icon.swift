#!/usr/bin/env swift
import AppKit
import Foundation

// Renders a 1024x1024 master icon for ClipSync.

let output = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "build/icon-1024.png"

let canvas = NSSize(width: 1024, height: 1024)
let image = NSImage(size: canvas)
image.lockFocus()

guard let context = NSGraphicsContext.current?.cgContext else {
    fatalError("No graphics context")
}
context.setShouldAntialias(true)

// Background squircle.
let backgroundRect = NSRect(x: 28, y: 28, width: 968, height: 968)
let background = NSBezierPath(roundedRect: backgroundRect, xRadius: 218, yRadius: 218)
let backgroundGradient = NSGradient(colors: [
    NSColor(srgbRed: 0.24, green: 0.50, blue: 1.00, alpha: 1.0),
    NSColor(srgbRed: 0.46, green: 0.27, blue: 0.96, alpha: 1.0),
])!
backgroundGradient.draw(in: background, angle: -62)

// Soft highlight at the top.
NSGraphicsContext.saveGraphicsState()
background.addClip()
let highlight = NSGradient(colors: [
    NSColor.white.withAlphaComponent(0.22),
    NSColor.white.withAlphaComponent(0.0),
])!
highlight.draw(
    from: NSPoint(x: 512, y: 1000),
    to: NSPoint(x: 512, y: 540),
    options: []
)
NSGraphicsContext.restoreGraphicsState()

// Two sheets of paper, the back one tilted.
func rounded(_ rect: NSRect, _ radius: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
}

NSGraphicsContext.saveGraphicsState()
let transform = NSAffineTransform()
transform.translateX(by: 512, yBy: 512)
transform.rotate(byDegrees: -11)
transform.translateX(by: -512, yBy: -512)
transform.concat()

let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.28)
shadow.shadowBlurRadius = 48
shadow.shadowOffset = NSSize(width: 0, height: -22)
shadow.set()

NSColor.white.withAlphaComponent(0.38).setFill()
rounded(NSRect(x: 232, y: 300, width: 388, height: 448), 44).fill()

NSGraphicsContext.restoreGraphicsState()

// Front sheet.
NSGraphicsContext.saveGraphicsState()
let cardShadow = NSShadow()
cardShadow.shadowColor = NSColor.black.withAlphaComponent(0.32)
cardShadow.shadowBlurRadius = 54
cardShadow.shadowOffset = NSSize(width: 0, height: -20)
cardShadow.set()

NSColor.white.setFill()
rounded(NSRect(x: 372, y: 208, width: 400, height: 476), 46).fill()
NSGraphicsContext.restoreGraphicsState()

// Clip at the top of the front sheet.
let clipRect = NSRect(x: 486, y: 610, width: 172, height: 78)
let clipPath = rounded(clipRect, 30)
backgroundGradient.draw(in: clipPath, angle: -62)

// Text lines.
let lineColor = NSColor(srgbRed: 0.40, green: 0.35, blue: 0.94, alpha: 0.34)
for (index, width) in [252.0, 196.0, 230.0].enumerated() {
    lineColor.setFill()
    let lineRect = NSRect(x: 426, y: 512 - CGFloat(index) * 88, width: width, height: 28)
    rounded(lineRect, 14).fill()
}

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let bitmap = NSBitmapImageRep(data: tiff),
      let png = bitmap.representation(using: .png, properties: [:])
else {
    fatalError("Could not render icon")
}

try png.write(to: URL(fileURLWithPath: output))
print("Wrote \(output)")
