import AppKit

@MainActor func makeIcons(directory: URL) {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for base in [16, 32, 128, 256, 512] {
        for factor in [1, 2] {
            let size = base * factor
            guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                let context = NSGraphicsContext(bitmapImageRep: bitmap) else { continue }
            NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = context
            context.cgContext.clear(CGRect(x: 0, y: 0, width: size, height: size))
            context.cgContext.scaleBy(x: CGFloat(size) / 512, y: CGFloat(size) / 512)
            NSColor(red: 0.28, green: 0.59, blue: 0.88, alpha: 1).setFill()
            NSBezierPath(roundedRect: NSRect(x: 8, y: 8, width: 496, height: 496), xRadius: 108, yRadius: 108).fill()
            NSColor.white.setFill()
            NSBezierPath(ovalIn: NSRect(x: 88, y: 150, width: 300, height: 218)).fill()
            let tail = NSBezierPath(); tail.move(to: NSPoint(x: 350, y: 258))
            tail.curve(to: NSPoint(x: 448, y: 328), controlPoint1: NSPoint(x: 399, y: 262), controlPoint2: NSPoint(x: 414, y: 311))
            tail.curve(to: NSPoint(x: 448, y: 186), controlPoint1: NSPoint(x: 438, y: 281), controlPoint2: NSPoint(x: 438, y: 232))
            tail.curve(to: NSPoint(x: 350, y: 258), controlPoint1: NSPoint(x: 403, y: 201), controlPoint2: NSPoint(x: 393, y: 241)); tail.fill()
            NSColor(red: 0.12, green: 0.25, blue: 0.41, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 166, y: 274, width: 28, height: 34)).fill()
            NSColor.white.setFill(); NSBezierPath(ovalIn: NSRect(x: 171, y: 294, width: 9, height: 9)).fill()
            NSColor(red: 0.28, green: 0.59, blue: 0.88, alpha: 1).setStroke()
            let smile = NSBezierPath(); smile.move(to: NSPoint(x: 132, y: 244))
            smile.curve(to: NSPoint(x: 205, y: 231), controlPoint1: NSPoint(x: 158, y: 223), controlPoint2: NSPoint(x: 184, y: 221)); smile.lineWidth = 9; smile.lineCapStyle = .round; smile.stroke()
            NSGraphicsContext.restoreGraphicsState()
            let filename = "icon_\(base)x\(base)\(factor == 2 ? "@2x" : "").png"
            if let data = bitmap.representation(using: .png, properties: [:]) { try? data.write(to: directory.appendingPathComponent(filename)) }
        }
    }
}
