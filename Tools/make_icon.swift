import AppKit
import Foundation

let args = CommandLine.arguments
let output = args.count > 1 ? args[1] : "/tmp/AppIcon.iconset"
let fm = FileManager.default
try? fm.removeItem(atPath: output)
try fm.createDirectory(atPath: output, withIntermediateDirectories: true)

let specs: [(String, CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024)
]

func render(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    guard let ctx = NSGraphicsContext.current?.cgContext else { return image }
    ctx.saveGState()
    let scale = size / 1024.0
    ctx.scaleBy(x: scale, y: scale)

    let outer = NSBezierPath(roundedRect: NSRect(x: 52, y: 52, width: 920, height: 920), xRadius: 220, yRadius: 220)
    let gradient = NSGradient(colors: [
        NSColor(calibratedRed: 0.07, green: 0.42, blue: 0.95, alpha: 1),
        NSColor(calibratedRed: 0.08, green: 0.80, blue: 0.76, alpha: 1)
    ])!
    gradient.draw(in: outer, angle: -35)

    ctx.setShadow(offset: CGSize(width: 0, height: -22), blur: 36, color: NSColor.black.withAlphaComponent(0.24).cgColor)

    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 820))
    shield.curve(to: NSPoint(x: 760, y: 720), controlPoint1: NSPoint(x: 610, y: 790), controlPoint2: NSPoint(x: 700, y: 760))
    shield.line(to: NSPoint(x: 760, y: 505))
    shield.curve(to: NSPoint(x: 512, y: 240), controlPoint1: NSPoint(x: 760, y: 380), controlPoint2: NSPoint(x: 670, y: 285))
    shield.curve(to: NSPoint(x: 264, y: 505), controlPoint1: NSPoint(x: 354, y: 285), controlPoint2: NSPoint(x: 264, y: 380))
    shield.line(to: NSPoint(x: 264, y: 720))
    shield.curve(to: NSPoint(x: 512, y: 820), controlPoint1: NSPoint(x: 324, y: 760), controlPoint2: NSPoint(x: 414, y: 790))
    shield.close()
    NSColor.white.withAlphaComponent(0.97).setFill()
    shield.fill()

    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Lock body
    let lockBody = NSBezierPath(roundedRect: NSRect(x: 382, y: 390, width: 260, height: 205), xRadius: 54, yRadius: 54)
    NSColor(calibratedRed: 0.08, green: 0.48, blue: 0.88, alpha: 1).setFill()
    lockBody.fill()

    // Lock shackle
    let shackle = NSBezierPath()
    shackle.appendArc(withCenter: NSPoint(x: 512, y: 585), radius: 92, startAngle: 0, endAngle: 180)
    shackle.lineWidth = 46
    shackle.lineCapStyle = .round
    NSColor(calibratedRed: 0.08, green: 0.48, blue: 0.88, alpha: 1).setStroke()
    shackle.stroke()

    // Three small routing nodes
    let nodeColor = NSColor(calibratedRed: 0.06, green: 0.33, blue: 0.72, alpha: 0.95)
    nodeColor.setFill()
    for point in [NSPoint(x: 420, y: 676), NSPoint(x: 512, y: 710), NSPoint(x: 604, y: 676)] {
        NSBezierPath(ovalIn: NSRect(x: point.x - 15, y: point.y - 15, width: 30, height: 30)).fill()
    }

    ctx.restoreGState()
    return image
}

for (name, size) in specs {
    let image = render(size: size)
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
        throw NSError(domain: "icon", code: 1)
    }
    try png.write(to: URL(fileURLWithPath: output).appendingPathComponent(name))
}

print("Generated iconset at \(output)")