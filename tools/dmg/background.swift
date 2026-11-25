import AppKit

let width = 640
let height = 350
let canvas = NSSize(width: width, height: height)
let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
    bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
    bytesPerRow: 0, bitsPerPixel: 0
)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)

let field = NSBezierPath(rect: NSRect(origin: .zero, size: canvas))
NSGradient(
    starting: NSColor(srgbRed: 0.93, green: 0.96, blue: 0.99, alpha: 1),
    ending: NSColor(srgbRed: 0.81, green: 0.89, blue: 0.96, alpha: 1)
)!.draw(in: field, angle: -90)

func drawCentered(_ value: String, baseline: CGFloat, size: CGFloat,
                  weight: NSFont.Weight, color: NSColor) {
    let text = NSAttributedString(string: value, attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight),
        .foregroundColor: color,
    ])
    text.draw(at: NSPoint(x: (CGFloat(width) - text.size().width) / 2, y: baseline))
}

let ink = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.32, alpha: 1)
drawCentered("将应用拖到右侧的应用程序文件夹", baseline: 280, size: 23, weight: .semibold, color: ink)
drawCentered("Drag the app to the Applications folder", baseline: 250, size: 15, weight: .medium, color: ink)

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 286, y: 168))
arrow.line(to: NSPoint(x: 352, y: 168))
arrow.move(to: NSPoint(x: 339, y: 181))
arrow.line(to: NSPoint(x: 352, y: 168))
arrow.line(to: NSPoint(x: 339, y: 155))
arrow.lineWidth = 5
arrow.lineCapStyle = .round
arrow.lineJoinStyle = .round
NSColor(srgbRed: 0.19, green: 0.40, blue: 0.67, alpha: 1).setStroke()
arrow.stroke()

let data = bitmap.representation(using: .png, properties: [:])!
try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
