import AppKit

// Original freetalk artwork, rendered into a standard macOS iconset.
let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        let transform = NSAffineTransform(); transform.scale(by: CGFloat(pixels) / 1024); transform.concat()
        let tile = NSBezierPath(roundedRect: NSRect(x: 56, y: 56, width: 912, height: 912), xRadius: 205, yRadius: 205)
        NSGradient(starting: NSColor(calibratedRed: 0.13, green: 0.22, blue: 0.20, alpha: 1),
                   ending: NSColor(calibratedRed: 0.05, green: 0.10, blue: 0.09, alpha: 1))!.draw(in: tile, angle: -90)
        NSColor(calibratedRed: 0.38, green: 0.82, blue: 0.67, alpha: 1).setFill()
        for (i, height) in [130.0, 240, 380, 490, 340, 220, 130].enumerated() {
            let bar = NSBezierPath(roundedRect: NSRect(x: 220 + Double(i) * 88, y: (1024-height)/2,
                                                      width: 56, height: height), xRadius: 28, yRadius: 28)
            bar.fill()
        }
        NSGraphicsContext.restoreGraphicsState()
        let filename = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(filename))
    }
}

