// What is drawn over the picture: the captions, the title and the coded animations, as one Core Animation layer tree
// timed in output seconds. The preview hangs it on an AVSynchronizedLayer and the export hands it to
// AVVideoCompositionCoreAnimationTool, so both draw the same frames. Layers use the bottom left origin of macOS.
import AppKit
import AVFoundation
import QuartzCore

// A time on the layer timeline. Zero has to be AVCoreAnimationBeginTimeAtZero, Core Animation reads 0 as "now".
func bt(_ t: Double) -> CFTimeInterval { t <= 0.0001 ? AVCoreAnimationBeginTimeAtZero : t }

func color(_ hex: String?, _ fallback: String) -> CGColor {
  var s = (hex ?? fallback).trimmingCharacters(in: .whitespaces)
  if s.hasPrefix("#") { s.removeFirst() }
  guard s.count == 6, let v = UInt32(s, radix: 16) else { return color(fallback, "#ffffff") }
  return CGColor(red: CGFloat((v >> 16) & 0xff) / 255, green: CGFloat((v >> 8) & 0xff) / 255, blue: CGFloat(v & 0xff) / 255, alpha: 1)
}

// Shown from `start` for `length` seconds (fillMode removed: outside that it is back to its model opacity of 0).
func showBetween(_ layer: CALayer, _ start: Double, _ length: Double, fadeIn: Double = 0, fadeOut: Double = 0) {
  layer.opacity = 0
  let a = CAKeyframeAnimation(keyPath: "opacity")
  let fi = min(fadeIn, length / 3), fo = min(fadeOut, length / 2)
  a.values = [fi > 0 ? 0 : 1, 1, 1, fo > 0 ? 0 : 1]
  a.keyTimes = [0, NSNumber(value: fi / length), NSNumber(value: max(fi, length - fo) / length), 1]
  a.beginTime = bt(start); a.duration = length
  a.fillMode = .removed; a.isRemovedOnCompletion = false
  layer.add(a, forKey: "show")
}

// A keyframe animation on the layer timeline, times in seconds from `start`, held before and after.
func keyframes(_ layer: CALayer, _ keyPath: String, start: Double, _ frames: [(Double, Any)], timing: CAMediaTimingFunctionName = .easeOut) {
  guard let last = frames.last?.0, last > 0 else { return }
  let a = CAKeyframeAnimation(keyPath: keyPath)
  a.values = frames.map(\.1)
  a.keyTimes = frames.map { NSNumber(value: $0.0 / last) }
  a.timingFunctions = Array(repeating: CAMediaTimingFunction(name: timing), count: max(1, frames.count - 1))
  a.beginTime = bt(start); a.duration = last
  a.fillMode = .both; a.isRemovedOnCompletion = false
  layer.add(a, forKey: "\(keyPath)-\(layer.animationKeys()?.count ?? 0)")
}

func measure(_ text: String, _ font: NSFont, _ maxWidth: CGFloat) -> CGSize {
  let r = NSAttributedString(string: text, attributes: [.font: font]).boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading])
  return CGSize(width: ceil(r.width) + 2, height: ceil(r.height) + 2)
}

// Text as a layer whose contents are the text already drawn into a bitmap. CATextLayer draws nothing when the export
// renders offscreen, a picture draws the same everywhere.
func textLayer(_ text: String, _ font: NSFont, _ fill: CGColor, maxWidth: CGFloat, align: NSTextAlignment = .center, scale: CGFloat) -> CALayer {
  let para = NSMutableParagraphStyle()
  para.alignment = align
  let attr = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(cgColor: fill) ?? .white, .paragraphStyle: para])
  let size = measure(text, font, maxWidth)
  let l = CALayer()
  l.bounds = CGRect(origin: .zero, size: size)
  l.contentsScale = scale
  let w = max(1, Int(ceil(size.width * scale))), h = max(1, Int(ceil(size.height * scale)))
  if let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
    ctx.scaleBy(x: scale, y: scale)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attr.draw(with: CGRect(origin: .zero, size: size), options: [.usesLineFragmentOrigin, .usesFontLeading])
    NSGraphicsContext.restoreGraphicsState()
    l.contents = ctx.makeImage()
  }
  return l
}

public enum Overlay {
  public struct CaptionGroup: Sendable { public var s: Double; public var e: Double; public var text: String }

  // The words that stay, in groups of up to three, broken at a pause or the end of a sentence. Output seconds after speed.
  public static func captionGroups(_ l: Loaded, _ plan: Plan, speed: Double) -> [CaptionGroup] {
    let words = outputWords(plan, l.project.edits, l.words, l.extra)
    var groups: [CaptionGroup] = []
    var cur: [Word] = []
    func flush() { if let f = cur.first, let z = cur.last { groups.append(CaptionGroup(s: f.s / speed, e: z.e / speed, text: cur.map(\.w).joined(separator: " "))) }; cur = [] }
    for w in words {
      if let last = cur.last, w.s - last.e > 0.5 { flush() }
      cur.append(w)
      if cur.count >= 3 || w.w.last.map({ ".?!,".contains($0) }) == true { flush() }
    }
    flush()
    // Each group stays up until the next one starts, when the gap is short.
    for i in groups.indices.dropLast() where groups[i + 1].s - groups[i].e < 0.4 { groups[i].e = groups[i + 1].s }
    return groups
  }

  // Where the middle of the captions sits in a frame of `size`, in the layer's bottom left space: the project's own position
  // (set_caption_position, px of the 1080 by 1920 or 1920 by 1080 frame, x from the centre, y down from the top) or the
  // fixed reel look's.
  public static func captionCenter(_ edl: Edl, size: CGSize) -> CGPoint {
    let landscape = size.width > size.height
    if let p = edl.captionPos {
      let s = size.width / (landscape ? 1920 : 1080)
      return CGPoint(x: size.width / 2 + p.x * s, y: size.height - p.y * s)
    }
    return CGPoint(x: size.width / 2, y: size.height * (landscape ? 1 - 900.0 / 1080 : 1 - 1400.0 / 1920))
  }

  // The stretches of the output (seconds, after the speed) where the title is hidden because the clip under it hides it.
  public static func titleHides(_ plan: Plan, speed: Double) -> [Range] {
    clipTitleHides(plan).map { Range(s: outputOf(plan, $0.s) / speed, e: outputOf(plan, $0.e) / speed) }.filter { $0.e > $0.s + 0.001 }
  }

  public static func layer(_ l: Loaded, _ rc: ReelComposition, contentsScale: CGFloat, captions drawCaptions: Bool = true) -> CALayer {
    layer(l, rc, contentsScale: contentsScale, captions: drawCaptions, captionsOn: nil, titleOn: nil)
  }

  // captionsOn and titleOn override the project's settings for one export (export's captions and title).
  public static func layer(_ l: Loaded, _ rc: ReelComposition, contentsScale: CGFloat, captions drawCaptions: Bool, captionsOn: Bool?, titleOn: Bool?) -> CALayer {
    let size = rc.renderSize
    let root = CALayer()
    root.frame = CGRect(origin: .zero, size: size)
    root.masksToBounds = true
    let plan = rc.plan, speed = rc.speed
    var flags = exportFlags(l.project.edits, hasWords: l.hasAnyWords)
    if let c = captionsOn { flags.captions = c }
    if let t = titleOn { flags.title = t }
    let u = min(size.width, size.height) / 1080
    let landscape = size.width > size.height

    // The coded animations, under the captions so a caption is never covered.
    for a in l.animations.animations {
      let s = outputOf(plan, a.start) / speed, e = outputOf(plan, a.end) / speed
      if e - s < 0.3 || s >= rc.duration { continue }
      if let layer = AnimationLayers.build(a, frame: size, start: s, length: min(e, rc.duration) - s, scale: contentsScale) { root.addSublayer(layer) }
    }

    if flags.title, let title = l.project.edits.titleText, !title.isEmpty {
      let font = NSFont.systemFont(ofSize: (landscape ? 64 : 80) * u, weight: .black)
      let t = textLayer(title, font, color("#ffff00", "#ffff00"), maxWidth: size.width * 0.9, scale: contentsScale)
      t.shadowOpacity = 0.9; t.shadowRadius = 6 * u; t.shadowOffset = .zero; t.shadowColor = .black
      t.position = CGPoint(x: size.width / 2, y: size.height - (landscape ? 120 : 232) * (size.height / (landscape ? 1080 : 1920)))
      // Hidden over the clips that hide it (set_clip_title): an opacity that steps to 0 and back at their edges.
      let hides = titleHides(plan, speed: speed).filter { $0.s < rc.duration }
      if !hides.isEmpty && rc.duration > 0 {
        var values: [NSNumber] = [1], times: [NSNumber] = [0]
        for h in hides { values += [0, 1]; times += [NSNumber(value: max(0, h.s) / rc.duration), NSNumber(value: min(rc.duration, h.e) / rc.duration)] }
        times.append(1) // a discrete animation has one key time more than it has values
        let a = CAKeyframeAnimation(keyPath: "opacity")
        a.calculationMode = .discrete
        a.values = values; a.keyTimes = times
        a.beginTime = AVCoreAnimationBeginTimeAtZero; a.duration = rc.duration
        a.fillMode = .both; a.isRemovedOnCompletion = false
        t.add(a, forKey: "hide")
      }
      root.addSublayer(t)
    }

    // The captions in the project's caption style, outside its hidden stretches (Captions.swift).
    if flags.captions && drawCaptions {
      for c in Captions.layers(l, plan, speed: speed, duration: rc.duration, frame: size, scale: contentsScale) { root.addSublayer(c) }
    }
    return root
  }
}

