// Draws Resources/AppIcon.icns: the web reel editor's brand mark (the Phosphor Bold film strip, white, on a black tile)
// as a Mac app icon. The tile is the macOS icon shape, a rounded square 824 of 1024 with a soft shadow, filled with the
// web app's primary button gradient, #333 at the top to #111 at the bottom.
//   swift make-icon.swift
import AppKit
import CoreText

let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
CTFontManagerRegisterFontsForURL(root.appendingPathComponent("Resources/Fonts/Phosphor-Bold.ttf") as CFURL, .process, nil)

func draw(_ px: Int) -> NSBitmapImageRep {
  let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
  let k = CGFloat(px) / 1024
  let tile = NSRect(x: 100 * k, y: 100 * k, width: 824 * k, height: 824 * k)
  let path = NSBezierPath(roundedRect: tile, xRadius: 185 * k, yRadius: 185 * k)
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
  shadow.shadowBlurRadius = 20 * k
  shadow.shadowOffset = NSSize(width: 0, height: -8 * k)
  NSGraphicsContext.saveGraphicsState()
  shadow.set()
  NSColor(srgbRed: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0, alpha: 1).setFill()
  path.fill()
  NSGraphicsContext.restoreGraphicsState()
  NSGradient(starting: NSColor(srgbRed: 0x33 / 255.0, green: 0x33 / 255.0, blue: 0x33 / 255.0, alpha: 1),
             ending: NSColor(srgbRed: 0x11 / 255.0, green: 0x11 / 255.0, blue: 0x11 / 255.0, alpha: 1))!.draw(in: path, angle: -90)
  // A hairline of light along the top edge, as the button's border catches it.
  NSColor.white.withAlphaComponent(0.08).setStroke()
  let edge = NSBezierPath(roundedRect: tile.insetBy(dx: 1.5 * k, dy: 1.5 * k), xRadius: 184 * k, yRadius: 184 * k)
  edge.lineWidth = 3 * k
  edge.stroke()
  // The film strip, Phosphor Bold U+E792, centred.
  let glyph = String(Character(UnicodeScalar(0xe792)!))
  let font = NSFont(name: "Phosphor-Bold", size: 600 * k)!
  let text = NSAttributedString(string: glyph, attributes: [.font: font, .foregroundColor: NSColor.white])
  let line = CTLineCreateWithAttributedString(text)
  let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
  let ctx = NSGraphicsContext.current!.cgContext
  ctx.textPosition = CGPoint(x: tile.midX - bounds.midX, y: tile.midY - bounds.midY)
  CTLineDraw(line, ctx)
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

let set = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: set)
try FileManager.default.createDirectory(at: set, withIntermediateDirectories: true)
for (size, scale) in [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)] {
  let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
  try draw(size * scale).representation(using: .png, properties: [:])!.write(to: set.appendingPathComponent(name))
}
try draw(1024).representation(using: .png, properties: [:])!.write(to: FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon-preview.png"))
let p = Process()
p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
p.arguments = ["-c", "icns", set.path, "-o", root.appendingPathComponent("Resources/AppIcon.icns").path]
try p.run(); p.waitUntilExit()
print(p.terminationStatus == 0 ? "Wrote Resources/AppIcon.icns" : "iconutil failed")
