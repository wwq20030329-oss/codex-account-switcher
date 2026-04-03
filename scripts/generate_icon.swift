import AppKit
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else {
    fputs("Usage: generate_icon.swift <iconset-dir> <icns-output>\n", stderr)
    exit(1)
}

let iconsetURL = URL(fileURLWithPath: args[1], isDirectory: true)
let icnsURL = URL(fileURLWithPath: args[2])
let fileManager = FileManager.default

try? fileManager.removeItem(at: iconsetURL)
try fileManager.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

let specs: [(name: String, size: CGFloat)] = [
    ("icon_16x16.png", 16),
    ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32),
    ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128),
    ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512),
    ("icon_512x512@2x.png", 1024),
]

extension NSColor {
    convenience init(hex: Int, alpha: CGFloat = 1.0) {
        self.init(
            calibratedRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255,
            alpha: alpha
        )
    }
}

func savePNG(_ image: NSImage, to url: URL) throws {
    guard
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff),
        let png = bitmap.representation(using: .png, properties: [:])
    else {
        throw NSError(domain: "IconGen", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to encode PNG"])
    }
    try png.write(to: url)
}

func makeImage(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()
    defer { image.unlockFocus() }

    NSGraphicsContext.current?.imageInterpolation = .high

    let bounds = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = size * 0.04
    let cardRect = bounds.insetBy(dx: inset, dy: inset)
    let cornerRadius = size * 0.23

    let backgroundPath = NSBezierPath(roundedRect: cardRect, xRadius: cornerRadius, yRadius: cornerRadius)
    let backgroundGradient = NSGradient(
        colors: [
            NSColor(hex: 0x132033),
            NSColor(hex: 0x1d3557),
            NSColor(hex: 0x275d8c),
        ]
    )!
    backgroundGradient.draw(in: backgroundPath, angle: 90)

    NSColor.white.withAlphaComponent(0.10).setStroke()
    backgroundPath.lineWidth = max(1, size * 0.012)
    backgroundPath.stroke()

    let glowCenter = NSPoint(x: size * 0.33, y: size * 0.74)
    let glowRadius = size * 0.5
    let glowPath = NSBezierPath(ovalIn: NSRect(
        x: glowCenter.x - glowRadius * 0.5,
        y: glowCenter.y - glowRadius * 0.5,
        width: glowRadius,
        height: glowRadius
    ))
    NSColor.white.withAlphaComponent(0.10).setFill()
    glowPath.fill()

    let innerRect = cardRect.insetBy(dx: size * 0.12, dy: size * 0.12)
    let cString = NSAttributedString(
        string: "C",
        attributes: [
            .font: NSFont.systemFont(ofSize: size * 0.56, weight: .black),
            .foregroundColor: NSColor.white.withAlphaComponent(0.95),
        ]
    )
    let cSize = cString.size()
    let cPoint = NSPoint(
        x: innerRect.midX - cSize.width * 0.60,
        y: innerRect.midY - cSize.height * 0.48
    )
    cString.draw(at: cPoint)

    let badgeSize = size * 0.36
    let badgeRect = NSRect(
        x: cardRect.maxX - badgeSize - size * 0.10,
        y: cardRect.minY + size * 0.10,
        width: badgeSize,
        height: badgeSize
    )
    let badgePath = NSBezierPath(roundedRect: badgeRect, xRadius: badgeSize * 0.34, yRadius: badgeSize * 0.34)
    let badgeGradient = NSGradient(
        colors: [
            NSColor(hex: 0x1fe2a6),
            NSColor(hex: 0x0fb8ff),
        ]
    )!
    badgeGradient.draw(in: badgePath, angle: 315)

    NSColor.black.withAlphaComponent(0.12).setStroke()
    badgePath.lineWidth = max(1, size * 0.01)
    badgePath.stroke()

    let arrowInsetX = badgeSize * 0.22
    let arrowTopY = badgeRect.midY + badgeSize * 0.10
    let arrowBottomY = badgeRect.midY - badgeSize * 0.10
    let arrowWidth = badgeSize * 0.42
    let arrowHead = badgeSize * 0.12

    let arrow1 = NSBezierPath()
    arrow1.lineWidth = max(1.6, size * 0.03)
    arrow1.lineCapStyle = .round
    arrow1.lineJoinStyle = .round
    arrow1.move(to: NSPoint(x: badgeRect.minX + arrowInsetX, y: arrowTopY))
    arrow1.line(to: NSPoint(x: badgeRect.minX + arrowInsetX + arrowWidth, y: arrowTopY))
    arrow1.move(to: NSPoint(x: badgeRect.minX + arrowInsetX + arrowWidth - arrowHead, y: arrowTopY + arrowHead))
    arrow1.line(to: NSPoint(x: badgeRect.minX + arrowInsetX + arrowWidth, y: arrowTopY))
    arrow1.line(to: NSPoint(x: badgeRect.minX + arrowInsetX + arrowWidth - arrowHead, y: arrowTopY - arrowHead))

    let arrow2 = NSBezierPath()
    arrow2.lineWidth = max(1.6, size * 0.03)
    arrow2.lineCapStyle = .round
    arrow2.lineJoinStyle = .round
    arrow2.move(to: NSPoint(x: badgeRect.maxX - arrowInsetX, y: arrowBottomY))
    arrow2.line(to: NSPoint(x: badgeRect.maxX - arrowInsetX - arrowWidth, y: arrowBottomY))
    arrow2.move(to: NSPoint(x: badgeRect.maxX - arrowInsetX - arrowWidth + arrowHead, y: arrowBottomY + arrowHead))
    arrow2.line(to: NSPoint(x: badgeRect.maxX - arrowInsetX - arrowWidth, y: arrowBottomY))
    arrow2.line(to: NSPoint(x: badgeRect.maxX - arrowInsetX - arrowWidth + arrowHead, y: arrowBottomY - arrowHead))

    NSColor.white.withAlphaComponent(0.96).setStroke()
    arrow1.stroke()
    arrow2.stroke()

    let sparkRect = NSRect(
        x: cardRect.minX + size * 0.13,
        y: cardRect.maxY - size * 0.23,
        width: size * 0.10,
        height: size * 0.10
    )
    let sparkPath = NSBezierPath(ovalIn: sparkRect)
    NSColor(hex: 0x8dd4ff, alpha: 0.85).setFill()
    sparkPath.fill()

    return image
}

for spec in specs {
    let image = makeImage(size: spec.size)
    try savePNG(image, to: iconsetURL.appendingPathComponent(spec.name))
}

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconsetURL.path, "-o", icnsURL.path]
try process.run()
process.waitUntilExit()

guard process.terminationStatus == 0 else {
    throw NSError(domain: "IconGen", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: "iconutil failed"])
}
