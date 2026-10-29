import AppKit

/// Renders the disk image's simple instruction background at Retina resolution.
@main
struct DMGBackground {
    /// Writes the background PNG to the path supplied by the release builder.
    static func main() throws {
        let size = NSSize(width: 660, height: 400)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1320, pixelsHigh: 800,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        bitmap.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
        NSRect(origin: .zero, size: size).fill()
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        NSAttributedString(string: "Trimsmith", attributes: [.font: NSFont.systemFont(ofSize: 32, weight: .semibold),
            .foregroundColor: NSColor.white, .paragraphStyle: centered])
            .draw(in: NSRect(x: 0, y: 315, width: 660, height: 45))
        NSAttributedString(string: "Drag Trimsmith to Applications", attributes: [.font: NSFont.systemFont(ofSize: 16),
            .foregroundColor: NSColor(calibratedWhite: 0.72, alpha: 1), .paragraphStyle: centered])
            .draw(in: NSRect(x: 0, y: 70, width: 660, height: 26))
        NSColor(calibratedRed: 0.67, green: 0.91, blue: 0.48, alpha: 1).setStroke()
        let arrow = NSBezierPath()
        arrow.move(to: NSPoint(x: 287, y: 205)); arrow.line(to: NSPoint(x: 373, y: 205))
        arrow.move(to: NSPoint(x: 357, y: 220)); arrow.line(to: NSPoint(x: 373, y: 205))
        arrow.line(to: NSPoint(x: 357, y: 190))
        arrow.lineWidth = 3; arrow.lineCapStyle = .round; arrow.lineJoinStyle = .round; arrow.stroke()
        NSGraphicsContext.restoreGraphicsState()
        try bitmap.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
    }
}
