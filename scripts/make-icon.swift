// Draws the app icon (1024x1024 PNG). Usage: swift scripts/make-icon.swift out.png
import AppKit

let out = CommandLine.arguments.dropFirst().first ?? "icon.png"
let size: CGFloat = 1024
let image = NSImage(size: NSSize(width: size, height: size))
image.lockFocus()

// macOS-style rounded background with a gradient
let inset: CGFloat = 100
let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
let path = NSBezierPath(roundedRect: rect, xRadius: 185, yRadius: 185)
NSGraphicsContext.current?.saveGraphicsState()
let shadow = NSShadow()
shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
shadow.shadowOffset = NSSize(width: 0, height: -12)
shadow.shadowBlurRadius = 30
shadow.set()
NSGradient(colors: [NSColor(calibratedRed: 0.13, green: 0.16, blue: 0.32, alpha: 1),
                    NSColor(calibratedRed: 0.05, green: 0.55, blue: 0.62, alpha: 1)])!
    .draw(in: path, angle: -60)
NSGraphicsContext.current?.restoreGraphicsState()

// Glyph: code brackets + sparkles
func drawSymbol(_ name: String, pointSize: CGFloat, at center: NSPoint, color: NSColor) {
    let config = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        .applying(.init(paletteColors: [color]))
    guard let sym = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config) else { return }
    let s = sym.size
    sym.draw(in: NSRect(x: center.x - s.width / 2, y: center.y - s.height / 2, width: s.width, height: s.height))
}
drawSymbol("chevron.left.forwardslash.chevron.right", pointSize: 250, at: NSPoint(x: 512, y: 470), color: .white)
drawSymbol("sparkles", pointSize: 170, at: NSPoint(x: 720, y: 720), color: NSColor(calibratedRed: 1, green: 0.85, blue: 0.35, alpha: 1))

image.unlockFocus()
guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else { exit(1) }
try! png.write(to: URL(fileURLWithPath: out))
