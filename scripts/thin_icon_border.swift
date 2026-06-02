import AppKit
import Foundation

let path = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/Users/rick/Dropbox/Mac/Desktop/Magic Frame/MagicFrame/MagicFrame/Assets.xcassets/AppIcon.appiconset/AppIcon.png"

let paddingRatio = CommandLine.arguments.count > 2
    ? Double(CommandLine.arguments[2]) ?? 0.015
    : 0.015

guard let img = NSImage(contentsOfFile: path),
      let tiff = img.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let cg = rep.cgImage else {
    fputs("Failed to load image\n", stderr)
    exit(1)
}

let width = cg.width
let height = cg.height
let threshold: UInt8 = 25

func isContent(x: Int, y: Int) -> Bool {
    guard let data = cg.dataProvider?.data,
          let ptr = CFDataGetBytePtr(data) else {
        return false
    }
    let bytesPerRow = cg.bytesPerRow
    let bytesPerPixel = cg.bitsPerPixel / 8
    let index = y * bytesPerRow + x * bytesPerPixel
    let red = ptr[index]
    let green = ptr[index + 1]
    let blue = ptr[index + 2]
    return red > threshold || green > threshold || blue > threshold
}

var minX = width
var minY = height
var maxX = 0
var maxY = 0

for y in 0..<height {
    for x in 0..<width {
        if isContent(x: x, y: y) {
            minX = min(minX, x)
            minY = min(minY, y)
            maxX = max(maxX, x)
            maxY = max(maxY, y)
        }
    }
}

let pad = max(12, Int(Double(width) * paddingRatio))
minX = max(0, minX - pad)
minY = max(0, minY - pad)
maxX = min(width - 1, maxX + pad)
maxY = min(height - 1, maxY + pad)

let cropWidth = maxX - minX + 1
let cropHeight = maxY - minY + 1
let side = max(cropWidth, cropHeight)

guard let cropped = cg.cropping(to: CGRect(x: minX, y: minY, width: cropWidth, height: cropHeight)) else {
    fputs("Failed to crop image\n", stderr)
    exit(1)
}

guard let output = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: 1024,
    pixelsHigh: 1024,
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
) else {
    fputs("Failed to create output bitmap\n", stderr)
    exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: output)
NSColor.black.setFill()
NSRect(x: 0, y: 0, width: 1024, height: 1024).fill()

let scale = 1024.0 / Double(side)
let drawSide = Double(side) * scale
let offsetX = (1024.0 - drawSide) / 2.0
let offsetY = (1024.0 - drawSide) / 2.0

let context = NSGraphicsContext.current!.cgContext
context.interpolationQuality = .high
context.draw(
    cropped,
    in: CGRect(x: offsetX, y: offsetY, width: drawSide, height: drawSide)
)
NSGraphicsContext.restoreGraphicsState()

guard let png = output.representation(using: .png, properties: [:]) else {
    fputs("Failed to encode PNG\n", stderr)
    exit(1)
}

do {
    try png.write(to: URL(fileURLWithPath: path))
    print("Updated icon with ~\(pad)px border (\(Int(paddingRatio * 100))% padding)")
} catch {
    fputs("Failed to write PNG: \(error)\n", stderr)
    exit(1)
}
