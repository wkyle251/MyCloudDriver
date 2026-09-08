#!/usr/bin/env swift

import AppKit
import Foundation

guard CommandLine.arguments.count == 3 else {
    fputs("usage: prepare-app-icon.swift INPUT.png OUTPUT.png\n", stderr)
    exit(2)
}

let inputPath = CommandLine.arguments[1]
let outputPath = CommandLine.arguments[2]

guard let source = NSImage(contentsOfFile: inputPath) else {
    fputs("could not open input image\n", stderr)
    exit(1)
}

let canvasSize = NSSize(width: 1024, height: 1024)
let output = NSImage(size: canvasSize)
output.lockFocus()
guard let context = NSGraphicsContext.current else {
    fputs("could not create graphics context\n", stderr)
    exit(1)
}

context.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(origin: .zero, size: canvasSize).fill()

// Image generation supplied the finished artwork on a checkerboard preview.
// Clip just inside its blue tile so the packaged icon has real alpha outside
// the macOS-style rounded square, without altering the generated artwork.
let iconBounds = NSRect(x: 80, y: 72, width: 864, height: 890)
let iconClip = NSBezierPath(roundedRect: iconBounds, xRadius: 230, yRadius: 230)
iconClip.addClip()
source.draw(
    in: NSRect(origin: .zero, size: canvasSize),
    from: NSRect(origin: .zero, size: source.size),
    operation: .copy,
    fraction: 1
)
output.unlockFocus()

guard
    let tiff = output.tiffRepresentation,
    let bitmap = NSBitmapImageRep(data: tiff),
    let png = bitmap.representation(using: .png, properties: [:])
else {
    fputs("could not encode output image\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
    fputs("could not write output image: \(error.localizedDescription)\n", stderr)
    exit(1)
}
