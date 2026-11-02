// Captions and text layers (Sankalp, 2 Nov 2026), brought over from the ContentApp reel editor's captions and title
// style (lib/reel-style.ts) and made agentic. One text style, TextStyle, dresses both: the font (any family on this Mac,
// Advercase and Inter bundled), its weight, italic, size, letter spacing, line height and case; the fill, an outline and a
// shadow; a box behind the line or behind the word being spoken; where it sits and how wide a line may run. Sizes and
// places are px of the 1080 by 1920 frame (1920 by 1080 for a landscape video), x from the frame's centre and y the middle
// of the text down from the top, as on the web.
//
// The captions take the project's own style (captionStyle in its file) over the default for new projects (settings.json)
// over the built in look, the web editor's: Advercase Bold 95 px in white with a black outline, the spoken word in a black
// box, three words a line at 1490 px down. They can be hidden over stretches of the reel (captionHides, edit seconds).
// A text layer is an animation of kind text on the Animation layer: its own words in the same style, at its own place,
// for a part of the reel or all of it, coming in and going out with a motion of its own.
//
// Each caption line is drawn as one picture per state (the line, or the line with word k spoken), and the export shows
// them in turn; the preview draws the picture for the playhead from the same function, so both look the same.
import AppKit
import CoreText
import QuartzCore

public struct TextStyle: Codable, Equatable, Sendable {
  public var font: String? = nil // a font family on this Mac, Advercase or Inter for example
  public var weight: Int? = nil // 100 to 900, 400 regular and 700 bold
  public var italic: Bool? = nil
  public var size: Double? = nil // px of the frame
  public var letterSpacing: Double? = nil // px added between letters, below 0 tighter
  public var lineHeight: Double? = nil // times the size, for text on more than one line
  public var uppercase: Bool? = nil
  public var color: String? = nil // #rrggbb
  public var strokeWidth: Double? = nil // the outline, px, 0 for none
  public var strokeColor: String? = nil
  public var shadow: Double? = nil // the shadow's blur, px, 0 for none
  public var shadowColor: String? = nil
  public var box: String? = nil // none, line (behind the whole line) or word (behind the word being spoken)
  public var boxColor: String? = nil
  public var boxOpacity: Double? = nil // 0 to 1
  public var boxPadX: Double? = nil
  public var boxPadY: Double? = nil
  public var boxRadius: Double? = nil
  public var x: Double? = nil // the middle, px from the frame's centre, minus is left
  public var y: Double? = nil // the middle, px down from the top
  public var maxWidth: Double? = nil // a line breaks before it runs wider
  public var align: String? = nil // left, center or right, for text on more than one line
  // Captions only.
  public var maxWords: Int? = nil // and before it holds more words
  public var highlight: String? = nil // the colour of the word being spoken; none keeps it the text's colour
  public var animation: String? = nil // how each line comes in: none, pop, fade or rise
  public init() {}

  public static let KEYS = ["font", "weight", "italic", "size", "letterSpacing", "lineHeight", "uppercase", "color", "strokeWidth", "strokeColor",
                            "shadow", "shadowColor", "box", "boxColor", "boxOpacity", "boxPadX", "boxPadY", "boxRadius", "x", "y", "maxWidth",
                            "align", "maxWords", "highlight", "animation"]

  // This style with every field `over` sets laid on top.
  public func merged(_ over: TextStyle?) -> TextStyle {
    guard let over, let a = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any],
          let b = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(over)) as? [String: Any],
          let d = try? JSONSerialization.data(withJSONObject: a.merging(b) { _, n in n }) else { return self }
    return (try? JSONDecoder().decode(TextStyle.self, from: d)) ?? self
  }

  // The fields a tool call gives, laid on this style: a value sets a field, null clears it back to the default.
  public mutating func apply(_ i: JSON) throws {
    guard var o = try? JSONSerialization.jsonObject(with: JSONEncoder().encode(self)) as? [String: Any] else { return }
    for k in Self.KEYS {
      guard let v = i[k] else { continue }
      if case .null = v { o[k] = nil; continue }
      switch v {
      case .string(let s): o[k] = s
      case .number(let n): o[k] = ["weight", "maxWords"].contains(k) ? Int(n.rounded()) : n
      case .bool(let b): o[k] = b
      default: break
      }
    }
    for k in ["color", "strokeColor", "shadowColor", "boxColor", "highlight"] {
      if let s = o[k] as? String, k != "highlight" || s != "none" { o[k] = try Captions.hex(s, k) }
    }
    let d = try JSONSerialization.data(withJSONObject: o)
    self = try JSONDecoder().decode(TextStyle.self, from: d)
  }
}

// A stretch of the reel where the captions do not show, in edit seconds.
public struct CaptionHide: Codable, Equatable, Sendable {
  public var id: String
  public var start: Double
  public var end: Double
  public init(id: String, start: Double, end: Double) { self.id = id; self.start = start; self.end = end }
}

public enum Captions {
  // ------------------------------------------------------------------------------------------------------------------
  // The looks

  // The web editor's caption look (DEFAULT_STYLE in lib/reel-style.ts), on a portrait or a landscape frame.
  public static func builtIn(landscape: Bool) -> TextStyle {
    var s = TextStyle()
    s.font = "Advercase"; s.weight = 700; s.italic = false; s.size = landscape ? 72 : 95; s.letterSpacing = 0; s.lineHeight = 1.1
    s.uppercase = false; s.color = "#ffffff"; s.strokeWidth = 7; s.strokeColor = "#000000"; s.shadow = 0; s.shadowColor = "#000000"
    s.box = "word"; s.boxColor = "#000000"; s.boxOpacity = 1; s.boxPadX = 16; s.boxPadY = 10; s.boxRadius = 18
    s.x = 0; s.y = landscape ? 900 : 1490; s.maxWidth = landscape ? 1200 : 900; s.align = "center"
    s.maxWords = 3; s.highlight = "none"; s.animation = "none"
    return s
  }

  // A text layer's look before its own: the caption font, larger, in the middle of the frame, with no box.
  public static func textBuiltIn(landscape: Bool) -> TextStyle {
    var s = builtIn(landscape: landscape)
    s.size = landscape ? 80 : 90; s.strokeWidth = 6; s.box = "none"; s.boxColor = "#000000"; s.boxOpacity = 0.8
    s.y = landscape ? 540 : 960; s.maxWidth = landscape ? 1600 : 900; s.maxWords = nil; s.highlight = nil; s.animation = nil
    return s
  }

  static var settingsURL: URL { Store.root.appendingPathComponent("settings.json") }
  static func settings() -> [String: Any] { (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]) ?? [:] }
  static func key(_ landscape: Bool) -> String { landscape ? "captionStyleLandscape" : "captionStyle" }

  // The caption style saved for new projects, the fields set on it only.
  public static func savedDefault(landscape: Bool) -> TextStyle? {
    guard let o = settings()[key(landscape)], let d = try? JSONSerialization.data(withJSONObject: o) else { return nil }
    return try? JSONDecoder().decode(TextStyle.self, from: d)
  }

  // Saves a project's caption style as the one new projects start from (nil clears it). The other settings are kept.
  public static func saveDefault(_ style: TextStyle?, landscape: Bool) throws {
    var s = settings()
    if let style, let o = try JSONSerialization.jsonObject(with: JSONEncoder().encode(style)) as? [String: Any], !o.isEmpty { s[key(landscape)] = o } else { s[key(landscape)] = nil }
    try FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
    try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: settingsURL, options: .atomic)
  }

  // The style the project's captions are drawn in: the built in look, the saved default, then the project's own; a
  // position set with set_caption_position before styles existed counts as the project's own place.
  public static func style(_ edl: Edl, landscape: Bool) -> TextStyle {
    var s = builtIn(landscape: landscape).merged(savedDefault(landscape: landscape))
    if let p = edl.captionPos { s.x = p.x; s.y = p.y }
    return s.merged(edl.captionStyle)
  }

  public static func textStyle(_ a: ReelAnimation, landscape: Bool) -> TextStyle { textBuiltIn(landscape: landscape).merged(a.style) }

  static func hex(_ s: String, _ field: String) throws -> String {
    var h = s.trimmingCharacters(in: .whitespaces).lowercased()
    if !h.hasPrefix("#") { h = "#" + h }
    if h.count == 4 { h = "#" + h.dropFirst().map { "\($0)\($0)" }.joined() }
    guard h.count == 7, UInt32(h.dropFirst(), radix: 16) != nil else { throw ToolError("invalid_input", "\(field) has to be a colour like #ffcc00") }
    return h
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Fonts

  // Advercase and Inter ship in Resources/Fonts; the app and reel-mcp both register them once, so an export from either
  // draws the same letters.
  nonisolated(unsafe) static var registered = false
  static let fontLock = NSLock()
  public static func registerFonts() {
    fontLock.lock(); defer { fontLock.unlock() }
    guard !registered else { return }
    registered = true
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let dirs = [Bundle.main.resourceURL?.appendingPathComponent("Fonts"), exe.appendingPathComponent("../Resources/Fonts").standardized,
                URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts").standardized]
    guard let dir = dirs.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0.path) }),
          let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for f in files where ["otf", "ttf"].contains(f.pathExtension) && !f.lastPathComponent.hasPrefix("Phosphor") {
      CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil)
    }
  }

  // Every font family that can be used, the bundled ones first.
  public static func families() -> [String] {
    registerFonts()
    let all = NSFontManager.shared.availableFontFamilies.filter { !$0.hasPrefix(".") && !$0.hasPrefix("Phosphor") }
    return ["Advercase", "Inter"].filter(all.contains) + all.filter { $0 != "Advercase" && $0 != "Inter" }.sorted()
  }

  // The font of a style at a size in points: its family at the nearest weight and italic, else the system font.
  public static func font(_ s: TextStyle, size: CGFloat) -> NSFont {
    registerFonts()
    let w = s.weight ?? 700
    let manager = [100: 2, 200: 3, 300: 4, 400: 5, 500: 6, 600: 8, 700: 9, 800: 10, 900: 11][(min(900, max(100, w)) / 100) * 100] ?? 5
    let family = s.font ?? "Advercase"
    if let f = NSFontManager.shared.font(withFamily: family, traits: s.italic == true ? .italicFontMask : [], weight: manager, size: size) { return f }
    if let f = NSFontManager.shared.font(withFamily: family, traits: [], weight: manager, size: size) { return f }
    if let f = NSFont(name: family, size: size) { return f }
    let sys: NSFont.Weight = w >= 900 ? .black : w >= 800 ? .heavy : w >= 700 ? .bold : w >= 600 ? .semibold : w >= 500 ? .medium : w >= 300 ? .regular : .light
    return NSFont.systemFont(ofSize: size, weight: sys)
  }

  // ------------------------------------------------------------------------------------------------------------------
  // The caption lines

  public struct LineWord: Sendable, Equatable { public var w: String; public var s: Double; public var e: Double }
  public struct Line: Sendable, Equatable {
    public var s: Double // output seconds, after the speed
    public var e: Double
    public var words: [LineWord]
    public var text: String { words.map(\.w).joined(separator: " ") }
  }

  // The frame's px in points of a render of `size`.
  public static func unit(_ size: CGSize) -> CGFloat { size.width / (size.width > size.height ? 1920 : 1080) }

  // The hidden stretches in output seconds after the speed.
  public static func hiddenOutput(_ edl: Edl, _ plan: Plan, speed: Double) -> [Range] {
    (edl.captionHides ?? []).map { Range(s: outputOf(plan, $0.start) / speed, e: outputOf(plan, $0.end) / speed) }.filter { $0.e > $0.s + 0.001 }
  }

  // The words that stay, outside the hidden stretches, in lines: a line ends after a pause of half a second, at the end
  // of a sentence or a comma, at the style's word limit, or before it would run wider than its widest line. A line stays
  // up until the next one when the gap is short. Output seconds after speed.
  public static func lines(_ l: Loaded, _ plan: Plan, speed: Double, style s: TextStyle, frame: CGSize) -> [Line] {
    let k = unit(frame)
    let font = font(s, size: CGFloat(s.size ?? 95) * k)
    let maxW = CGFloat(s.maxWidth ?? 900) * k, maxWords = max(1, s.maxWords ?? 3)
    let hides = hiddenOutput(l.project.edits, plan, speed: speed)
    let space = wordWidth(" ", font, s, k)
    var out: [Line] = []
    var cur: [LineWord] = [], width: CGFloat = 0, segment = -1
    func flush() { if let f = cur.first, let z = cur.last { out.append(Line(s: f.s, e: z.e, words: cur)) }; cur = []; width = 0 }
    for w in outputWords(plan, l.project.edits, l.words, l.extra) {
      let ws = w.s / speed, we = w.e / speed, mid = (ws + we) / 2
      if hides.contains(where: { mid >= $0.s && mid < $0.e }) { continue }
      let seg = hides.filter { $0.e <= mid }.count
      let text = s.uppercase == true ? w.w.uppercased() : w.w
      let ww = wordWidth(text, font, s, k)
      if let last = cur.last, ws - last.e > 0.5 / speed || seg != segment || width + space + ww > maxW { flush() }
      segment = seg
      width = cur.isEmpty ? ww : width + space + ww
      cur.append(LineWord(w: text, s: ws, e: we))
      if cur.count >= maxWords || w.w.last.map({ ".?!,".contains($0) }) == true { flush() }
    }
    flush()
    for i in out.indices.dropLast() where out[i + 1].s - out[i].e < 0.4 {
      let gap = Range(s: out[i].e, e: out[i + 1].s)
      if !hides.contains(where: { $0.s < gap.e && $0.e > gap.s }) { out[i].e = out[i + 1].s }
    }
    return out
  }

  static func attributes(_ font: NSFont, _ s: TextStyle, _ k: CGFloat, fill: NSColor) -> [NSAttributedString.Key: Any] {
    [.font: font, .foregroundColor: fill, .kern: CGFloat(s.letterSpacing ?? 0) * k]
  }

  static func wordWidth(_ text: String, _ font: NSFont, _ s: TextStyle, _ k: CGFloat) -> CGFloat {
    ceil(NSAttributedString(string: text, attributes: attributes(font, s, k, fill: .white)).size().width)
  }

  static func ns(_ hex: String?, _ fallback: String, alpha: Double = 1) -> NSColor {
    (NSColor(cgColor: color(hex, fallback)) ?? .white).withAlphaComponent(CGFloat(alpha))
  }

  // Where the middle of the text sits, in the layer's bottom left space of a frame of `size`.
  public static func center(_ s: TextStyle, frame size: CGSize) -> CGPoint {
    let k = unit(size)
    return CGPoint(x: size.width / 2 + CGFloat(s.x ?? 0) * k, y: size.height - CGFloat(s.y ?? 960) * k)
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Drawing

  // Draws a run of text at a point (its baseline origin) with the style's outline, shadow and fill.
  static func drawText(_ text: String, at p: CGPoint, _ font: NSFont, _ s: TextStyle, _ k: CGFloat, fill: NSColor, in ctx: CGContext) {
    let stroke = CGFloat(s.strokeWidth ?? 0) * k
    let shadow = CGFloat(s.shadow ?? 0) * k
    var attr = attributes(font, s, k, fill: fill)
    ctx.saveGState()
    if shadow > 0 { ctx.setShadow(offset: .zero, blur: shadow, color: ns(s.shadowColor, "#000000", alpha: 0.9).cgColor) }
    if stroke > 0 {
      // The outline is drawn first at twice its width, then the fill over it, so the outline shows outside the letters only.
      var o = attr
      o[.strokeColor] = ns(s.strokeColor, "#000000")
      o[.strokeWidth] = stroke * 2 / font.pointSize * 100
      NSAttributedString(string: text, attributes: o).draw(at: p)
      ctx.setShadow(offset: .zero, blur: 0, color: nil)
    }
    attr[.foregroundColor] = fill
    NSAttributedString(string: text, attributes: attr).draw(at: p)
    ctx.restoreGState()
  }

  static func bitmap(_ size: CGSize, scale: CGFloat, _ draw: (CGContext) -> Void) -> CGImage? {
    let w = max(1, Int(ceil(size.width * scale))), h = max(1, Int(ceil(size.height * scale)))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    draw(ctx)
    NSGraphicsContext.restoreGraphicsState()
    return ctx.makeImage()
  }

  // A caption line as a picture, with word `active` spoken (its box or its highlight) or none: the picture and its size in
  // points of a frame of `frame`, drawn at `scale` pixels a point. Its middle goes at center(style).
  public static func lineImage(_ line: Line, active: Int?, style s: TextStyle, frame: CGSize, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
    let k = unit(frame)
    let font = font(s, size: CGFloat(s.size ?? 95) * k)
    let widths = line.words.map { wordWidth($0.w, font, s, k) }
    let space = wordWidth(" ", font, s, k)
    let textW = widths.reduce(0, +) + space * CGFloat(max(0, widths.count - 1))
    // Where the letters really sit, measured from the font's own ink (Sankalp, 2 Nov 2026: the tops of Advercase were cut
    // off and the word box sat below the word, as a font's ascender and leading do not say where its letters are).
    let ink = inkExtent(font, s, k)
    let textH = ink.top - ink.bottom
    let box = s.box ?? "none"
    let padX = CGFloat(s.boxPadX ?? 16) * k, padY = CGFloat(s.boxPadY ?? 10) * k
    let stroke = CGFloat(s.strokeWidth ?? 0) * k, shadow = CGFloat(s.shadow ?? 0) * k
    let mx = max(box == "none" ? 0 : padX, stroke) + shadow + 2, my = max(box == "none" ? 0 : padY, stroke) + shadow + 2
    let size = CGSize(width: ceil(textW + mx * 2), height: ceil(textH + my * 2))
    let baseline = my - ink.bottom // the point the text is drawn at, so its ink starts at my
    let boxFill = ns(s.boxColor, "#000000", alpha: s.boxOpacity ?? 1).cgColor
    let radius = CGFloat(s.boxRadius ?? 18) * k
    let highlight = s.highlight.flatMap { $0 == "none" ? nil : $0 }
    guard let img = bitmap(size, scale: scale, { ctx in
      if box == "line" {
        ctx.setFillColor(boxFill)
        ctx.addPath(CGPath(roundedRect: CGRect(x: mx - padX, y: my - padY, width: textW + padX * 2, height: textH + padY * 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
      }
      var x = mx
      for (i, w) in line.words.enumerated() {
        if box == "word", i == active {
          ctx.setFillColor(boxFill)
          ctx.addPath(CGPath(roundedRect: CGRect(x: x - padX, y: my - padY, width: widths[i] + padX * 2, height: textH + padY * 2), cornerWidth: min(radius, (textH + padY * 2) / 2), cornerHeight: min(radius, (textH + padY * 2) / 2), transform: nil))
          ctx.fillPath()
        }
        let fill = i == active && highlight != nil ? ns(highlight, "#ffff00") : ns(s.color, "#ffffff")
        drawText(w.w, at: CGPoint(x: x, y: baseline), font, s, k, fill: fill, in: ctx)
        x += widths[i] + space
      }
    }) else { return nil }
    return (img, size)
  }

  // How far below and above the point a run of text is drawn at its letters reach, for this font: measured once by drawing
  // tall and deep letters and finding their first and last inked rows.
  nonisolated(unsafe) static var inks: [String: (bottom: CGFloat, top: CGFloat)] = [:]
  static let inkLock = NSLock()
  static func inkExtent(_ font: NSFont, _ s: TextStyle, _ k: CGFloat) -> (bottom: CGFloat, top: CGFloat) {
    let key = "\(font.fontName)-\(font.pointSize)-\(s.uppercase == true)"
    inkLock.lock(); defer { inkLock.unlock() }
    if let v = inks[key] { return v }
    let sample = s.uppercase == true ? "HÉQJ" : "HÉfghjklpqy"
    let attr = NSAttributedString(string: sample, attributes: attributes(font, s, k, fill: .black))
    let sz = attr.size()
    let pad = ceil(font.pointSize)
    let w = Int(ceil(sz.width + pad * 2)), h = Int(ceil(sz.height + pad * 2))
    var result = (bottom: font.descender, top: font.ascender)
    if let ctx = CGContext(data: nil, width: max(1, w), height: max(1, h), bitsPerComponent: 8, bytesPerRow: max(1, w), space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) {
      ctx.setFillColor(gray: 1, alpha: 1); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
      attr.draw(at: CGPoint(x: pad, y: pad))
      NSGraphicsContext.restoreGraphicsState()
      if let data = ctx.data {
        let px = data.bindMemory(to: UInt8.self, capacity: w * h)
        // Rows in memory run from the top of the picture down.
        let inked = (0..<h).filter { r in (0..<w).contains { px[r * w + $0] < 128 } }
        if let first = inked.first, let last = inked.last {
          result = (bottom: CGFloat(h - 1 - last) - pad, top: CGFloat(h - first) - pad)
        }
      }
    }
    inks[key] = result
    return result
  }

  // Whether a line has a picture for each spoken word, or one for all of it.
  public static func perWord(_ s: TextStyle) -> Bool { s.box == "word" || (s.highlight.map { $0 != "none" } ?? false) }

  // The word being spoken at output time t: the last one that has started.
  public static func activeWord(_ line: Line, at t: Double) -> Int? { line.words.lastIndex { $0.s <= t } }

  // How a line looks `t` seconds after it came in: its opacity, its scale and how far it has still to rise (points).
  public static func entrance(_ kind: String?, t: Double, unit k: CGFloat) -> (opacity: Double, scale: Double, rise: CGFloat) {
    let d = 0.18
    guard t < d * 1.6 else { return (1, 1, 0) }
    let p = max(0, min(1, t / d))
    switch kind ?? "none" {
    case "fade": return (p, 1, 0)
    case "pop": return (min(1, p * 2), t < d ? 0.6 + 0.5 * p : 1.1 - 0.1 * min(1, (t - d) / (d * 0.6)), 0)
    case "rise": return (p, 1, (1 - p) * 30 * k)
    default: return (1, 1, 0)
    }
  }

  // The captions as layers on the layer timeline, one per line, or one per spoken word for a word box or highlight.
  public static func layers(_ l: Loaded, _ plan: Plan, speed: Double, duration: Double, frame: CGSize, scale: CGFloat) -> [CALayer] {
    let s = style(l.project.edits, landscape: frame.width > frame.height)
    let at = center(s, frame: frame)
    let k = unit(frame)
    return lines(l, plan, speed: speed, style: s, frame: frame).filter { $0.e > $0.s && $0.s < duration }.compactMap { line in
      let holder = CALayer()
      let states: [(Int?, Double, Double)] = perWord(s)
        ? line.words.indices.map { i in (i, i == 0 ? line.s : line.words[i].s, i == line.words.count - 1 ? line.e : line.words[i + 1].s) }
        : [(nil, line.s, line.e)]
      var box = CGSize.zero
      for (i, a, b) in states where b > a {
        guard let pic = lineImage(line, active: i, style: s, frame: frame, scale: scale) else { continue }
        box = pic.size
        let p = CALayer()
        p.bounds = CGRect(origin: .zero, size: pic.size); p.contents = pic.image; p.contentsScale = scale
        p.position = CGPoint(x: pic.size.width / 2, y: pic.size.height / 2)
        showBetween(p, a, b - a)
        holder.addSublayer(p)
      }
      guard box != .zero else { return nil }
      holder.bounds = CGRect(origin: .zero, size: box)
      holder.position = at
      switch s.animation ?? "none" {
      case "fade": keyframes(holder, "opacity", start: line.s, [(0, 0.0), (0.18, 1.0)])
      case "pop": keyframes(holder, "transform.scale", start: line.s, [(0, 0.6), (0.18, 1.1), (0.29, 1.0)])
      case "rise":
        keyframes(holder, "opacity", start: line.s, [(0, 0.0), (0.18, 1.0)])
        keyframes(holder, "position.y", start: line.s, [(0, at.y - 30 * k), (0.18, at.y)])
      default: break
      }
      return holder
    }
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Text layers

  // A block of text, broken into lines at its widest line, aligned, as a picture: the picture and its size in points.
  public static func blockImage(_ text: String, style s: TextStyle, frame: CGSize, scale: CGFloat) -> (image: CGImage, size: CGSize)? {
    let k = unit(frame)
    let font = font(s, size: CGFloat(s.size ?? 90) * k)
    let para = NSMutableParagraphStyle()
    para.alignment = s.align == "left" ? .left : s.align == "right" ? .right : .center
    para.lineHeightMultiple = CGFloat(s.lineHeight ?? 1.1)
    let body = s.uppercase == true ? text.uppercased() : text
    var attr = attributes(font, s, k, fill: ns(s.color, "#ffffff"))
    attr[.paragraphStyle] = para
    let maxW = CGFloat(s.maxWidth ?? 900) * k
    let r = NSAttributedString(string: body, attributes: attr).boundingRect(with: CGSize(width: maxW, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
    let textW = ceil(r.width), textH = ceil(r.height)
    let box = s.box ?? "none"
    let padX = CGFloat(s.boxPadX ?? 16) * k, padY = CGFloat(s.boxPadY ?? 10) * k
    let stroke = CGFloat(s.strokeWidth ?? 0) * k, shadow = CGFloat(s.shadow ?? 0) * k
    let mx = max(box == "none" ? 0 : padX, stroke) + shadow + 2, my = max(box == "none" ? 0 : padY, stroke) + shadow + 2
    let size = CGSize(width: textW + mx * 2, height: textH + my * 2)
    let radius = CGFloat(s.boxRadius ?? 18) * k
    guard let img = bitmap(size, scale: scale, { ctx in
      if box != "none" {
        ctx.setFillColor(ns(s.boxColor, "#000000", alpha: s.boxOpacity ?? 0.8).cgColor)
        ctx.addPath(CGPath(roundedRect: CGRect(x: mx - padX, y: my - padY, width: textW + padX * 2, height: textH + padY * 2), cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.fillPath()
      }
      let rect = CGRect(x: mx, y: my, width: textW, height: textH)
      let shadowBlur = shadow
      ctx.saveGState()
      if shadowBlur > 0 { ctx.setShadow(offset: .zero, blur: shadowBlur, color: ns(s.shadowColor, "#000000", alpha: 0.9).cgColor) }
      if stroke > 0 {
        var o = attr
        o[.strokeColor] = ns(s.strokeColor, "#000000")
        o[.strokeWidth] = stroke * 2 / font.pointSize * 100
        NSAttributedString(string: body, attributes: o).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
        ctx.setShadow(offset: .zero, blur: 0, color: nil)
      }
      NSAttributedString(string: body, attributes: attr).draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
      ctx.restoreGState()
    }) else { return nil }
    return (img, size)
  }

  public static let ENTERS = ["fade", "pop", "rise", "drop", "slide-left", "slide-right", "typewriter", "none"]
  public static let EXITS = ["fade", "pop", "rise", "drop", "slide-left", "slide-right", "none"]

  // A text layer on the layer timeline: its picture at its place, coming in with its enter motion and going out with its
  // exit one. The exit moves a wrapper and the enter the picture inside it, so the two never fight over one property.
  static func textLayer(_ a: ReelAnimation, frame: CGSize, start: Double, length: Double, scale: CGFloat) -> CALayer? {
    let s = textStyle(a, landscape: frame.width > frame.height)
    let text = (a.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !text.isEmpty, let pic = blockImage(text, style: s, frame: frame, scale: scale) else { return nil }
    let k = unit(frame), at = center(s, frame: frame)
    let enter = a.enter ?? "fade", exit = a.exit ?? "fade"
    let inDur = min(0.45, length / 3), outDur = min(0.4, length / 3)
    let holder = CALayer(); holder.frame = CGRect(origin: .zero, size: frame)
    let w = pic.size.width, h = pic.size.height
    // The wrapper sits on the text's own box, so its moves and scale are about the text; the picture fills it.
    let wrap = CALayer(); wrap.bounds = CGRect(origin: .zero, size: pic.size); wrap.position = at
    let content = CALayer()
    content.bounds = CGRect(origin: .zero, size: pic.size); content.position = CGPoint(x: w / 2, y: h / 2); content.contentsScale = scale
    if enter == "typewriter" {
      // The letters come in one after another over the first part of the span, each step its own picture.
      let chars = Array(text)
      let steps = min(chars.count, 40), over = min(1.5, length * 0.4)
      for i in 1...max(1, steps) {
        let n = Int((Double(chars.count) * Double(i) / Double(max(1, steps))).rounded(.up))
        guard let p = blockImage(String(chars.prefix(n)), style: s, frame: frame, scale: scale) else { continue }
        let l = CALayer()
        l.bounds = CGRect(origin: .zero, size: p.size); l.contents = p.image; l.contentsScale = scale
        // Each step keeps the full text's top, and its side by the alignment, so the text grows from where it ends up.
        let left = s.align == "left" ? 0 : s.align == "right" ? w - p.size.width : (w - p.size.width) / 2
        l.position = CGPoint(x: left + p.size.width / 2, y: h - p.size.height / 2)
        let from = start + over * Double(i - 1) / Double(max(1, steps)), until = i == steps ? start + length : start + over * Double(i) / Double(max(1, steps))
        showBetween(l, from, max(0.01, until - from))
        content.addSublayer(l)
      }
    } else {
      content.contents = pic.image
      switch enter {
      case "fade": keyframes(content, "opacity", start: start, [(0, 0.0), (inDur, 1.0)])
      case "pop": keyframes(content, "transform.scale", start: start, [(0, 0.4), (inDur * 0.6, 1.1), (inDur, 1.0)])
      case "rise":
        keyframes(content, "opacity", start: start, [(0, 0.0), (inDur, 1.0)])
        keyframes(content, "position.y", start: start, [(0, h / 2 - 60 * k), (inDur, h / 2)])
      case "drop":
        keyframes(content, "opacity", start: start, [(0, 0.0), (inDur, 1.0)])
        keyframes(content, "position.y", start: start, [(0, h / 2 + 60 * k), (inDur, h / 2)])
      case "slide-left": keyframes(content, "position.x", start: start, [(0, -at.x), (inDur, w / 2)]) // in from the left edge
      case "slide-right": keyframes(content, "position.x", start: start, [(0, w + frame.width - at.x), (inDur, w / 2)])
      default: break
      }
    }
    let outAt = start + length - outDur
    let fadeOut: [(Double, Any)] = [(0, 1.0), (outDur, 0.0)]
    switch exit {
    case "fade": keyframes(wrap, "opacity", start: outAt, fadeOut)
    case "pop": keyframes(wrap, "opacity", start: outAt, fadeOut); keyframes(wrap, "transform.scale", start: outAt, [(0, 1.0), (outDur * 0.4, 1.08), (outDur, 0.3)])
    case "rise": keyframes(wrap, "opacity", start: outAt, fadeOut); keyframes(wrap, "position.y", start: outAt, [(0, at.y), (outDur, at.y + 60 * k)])
    case "drop": keyframes(wrap, "opacity", start: outAt, fadeOut); keyframes(wrap, "position.y", start: outAt, [(0, at.y), (outDur, at.y - 60 * k)])
    case "slide-left": keyframes(wrap, "position.x", start: outAt, [(0, at.x), (outDur, -w / 2)])
    case "slide-right": keyframes(wrap, "position.x", start: outAt, [(0, at.x), (outDur, frame.width + w / 2)])
    default: break
    }
    wrap.addSublayer(content)
    holder.addSublayer(wrap)
    showBetween(holder, start, length)
    return holder
  }
}
