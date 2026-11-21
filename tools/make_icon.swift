import AppKit

func draw(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    let context = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = context
    let cg = context.cgContext
    let s = CGFloat(pixels) / 1024
    cg.scaleBy(x: s, y: s)

    let plate = CGRect(x: 100, y: 100, width: 824, height: 824)
    let platePath = CGPath(roundedRect: plate, cornerWidth: 185, cornerHeight: 185, transform: nil)
    cg.saveGState()
    cg.addPath(platePath)
    cg.clip()
    let space = CGColorSpaceCreateDeviceRGB()
    let background = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.16, green: 0.22, blue: 0.42, alpha: 1),
        CGColor(red: 0.07, green: 0.09, blue: 0.18, alpha: 1),
    ] as CFArray, locations: [0, 1])!
    cg.drawLinearGradient(background, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    cg.restoreGState()

    let center = CGPoint(x: 512, y: 560)
    func circle(_ radius: CGFloat) -> CGRect {
        CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: CGColor(gray: 0, alpha: 0.5))
    cg.setFillColor(CGColor(gray: 0.86, alpha: 1))
    cg.fillEllipse(in: circle(300))
    cg.restoreGState()

    cg.saveGState()
    cg.addEllipse(in: circle(300))
    cg.clip()
    let sheen = CGGradient(colorsSpace: space, colors: [
        CGColor(red: 0.95, green: 0.96, blue: 0.99, alpha: 1),
        CGColor(red: 0.62, green: 0.80, blue: 0.98, alpha: 1),
        CGColor(red: 0.86, green: 0.72, blue: 0.96, alpha: 1),
        CGColor(red: 0.93, green: 0.94, blue: 0.97, alpha: 1),
    ] as CFArray, locations: [0, 0.4, 0.7, 1])!
    cg.drawLinearGradient(sheen, start: CGPoint(x: 250, y: 840), end: CGPoint(x: 780, y: 280), options: [])
    cg.restoreGState()

    cg.setStrokeColor(CGColor(gray: 1, alpha: 0.55))
    cg.setLineWidth(6)
    cg.strokeEllipse(in: circle(297))
    cg.setFillColor(CGColor(gray: 0.97, alpha: 1))
    cg.fillEllipse(in: circle(112))
    cg.setStrokeColor(CGColor(gray: 0.55, alpha: 0.5))
    cg.setLineWidth(5)
    cg.strokeEllipse(in: circle(112))
    cg.setFillColor(CGColor(red: 0.10, green: 0.13, blue: 0.26, alpha: 1))
    cg.fillEllipse(in: circle(46))

    let badge = CGRect(x: 292, y: 150, width: 440, height: 170)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -8), blur: 20, color: CGColor(gray: 0, alpha: 0.45))
    cg.addPath(CGPath(roundedRect: badge, cornerWidth: 46, cornerHeight: 46, transform: nil))
    cg.setFillColor(CGColor(red: 0.20, green: 0.52, blue: 0.98, alpha: 1))
    cg.fillPath()
    cg.restoreGState()
    let text = NSAttributedString(string: "ISO", attributes: [
        .font: NSFont.systemFont(ofSize: 128, weight: .heavy),
        .foregroundColor: NSColor.white,
        .kern: 8,
    ])
    let size = text.size()
    text.draw(at: CGPoint(x: badge.midX - size.width / 2 + 4, y: badge.midY - size.height / 2))

    context.flushGraphics()
    return rep.representation(using: .png, properties: [:])!
}

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
for (points, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
    let name = "icon_\(points)x\(points)" + (scale == 2 ? "@2x" : "") + ".png"
    try draw(points * scale).write(to: out.appendingPathComponent(name))
}
