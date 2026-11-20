// The coded animations drawn as Core Animation layers. Each kind is a function of its span alone, so the preview can
// scrub it with the video and the export draws the same frames. Sizes are in units of the short side over 1080, so a
// 1080 by 1920 reel and a 1920 by 1080 video get the same look scaled. Nothing random: every "random" offset comes
// from the item's index.
import AppKit
import QuartzCore

enum AnimationLayers {
  struct Ctx { var a: ReelAnimation; var frame: CGSize; var start: Double; var length: Double; var u: CGFloat; var width: CGFloat; var scale: CGFloat }

  static func build(_ a: ReelAnimation, frame: CGSize, start: Double, length: Double, scale: CGFloat) -> CALayer? {
    // A text layer is placed by its own style and moves by its own enter and exit (Captions.swift).
    if a.kind == "text" { return Captions.textLayer(a, frame: frame, start: start, length: length, scale: scale) }
    let u = min(frame.width, frame.height) / 1080
    let landscape = frame.width > frame.height
    let width = a.side == "center" ? frame.width * (landscape ? 0.6 : 0.82) : frame.width * (landscape ? 0.34 : 0.8)
    let c = Ctx(a: a, frame: frame, start: start, length: length, u: u, width: width, scale: scale)
    let content: CALayer
    switch a.kind {
    case "text-pop": content = textPop(c)
    case "lower-third": content = lowerThird(c)
    case "counter": content = counter(c)
    case "emoji-burst": content = emojiBurst(c)
    case "progress-bar": content = progressBar(c)
    case "callout": content = callout(c)
    case "checklist": content = checklist(c)
    default: return nil
    }
    // Placed on its side, its middle at the chosen height, kept inside the frame.
    let b = content.bounds.size
    let margin = frame.width * 0.06
    let x: CGFloat = a.side == "left" ? margin + b.width / 2 : a.side == "right" ? frame.width - margin - b.width / 2 : frame.width / 2
    let fromTop: CGFloat = a.position == "top" ? 0.2 : a.position == "bottom" ? 0.66 : 0.45
    let y = min(frame.height - b.height / 2 - 20 * u, max(b.height / 2 + 20 * u, frame.height * (1 - fromTop)))
    content.position = CGPoint(x: x, y: y)
    let holder = CALayer()
    holder.frame = CGRect(origin: .zero, size: frame)
    holder.addSublayer(content)
    showBetween(holder, start, length, fadeIn: 0.12, fadeOut: ANIMATION_EXIT)
    return holder
  }

  static func card(_ size: CGSize, _ bg: CGColor, radius: CGFloat) -> CALayer {
    let l = CALayer()
    l.bounds = CGRect(origin: .zero, size: size)
    l.backgroundColor = bg
    l.cornerRadius = radius
    l.shadowColor = .black; l.shadowOpacity = 0.35; l.shadowRadius = radius * 0.6; l.shadowOffset = CGSize(width: 0, height: -radius * 0.2)
    return l
  }

  static func pop(_ l: CALayer, _ start: Double, overshoot: CGFloat = 1.12) {
    keyframes(l, "transform.scale", start: start, [(0, 0.4), (0.18, overshoot), (0.3, 0.95), (0.42, 1.02), (0.55, 1.0)])
  }

  static func fmt(_ v: Double, _ decimals: Bool) -> String {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.maximumFractionDigits = decimals ? 1 : 0
    f.minimumFractionDigits = decimals ? 1 : 0
    return f.string(from: NSNumber(value: v)) ?? String(v)
  }

  // A number that counts from `from` to `to` in `steps` frames over `over` seconds from `start`, each step its own text
  // layer shown in turn (a text layer's string cannot be animated).
  static func countingText(_ from: Double, _ to: Double, prefix: String, suffix: String, font: NSFont, fill: CGColor, start: Double, over: Double, total: Double, scale: CGFloat, maxWidth: CGFloat) -> CALayer {
    let holder = CALayer()
    let decimals = from.rounded() != from || to.rounded() != to
    let steps = 30
    let widest = measure("\(prefix)\(fmt(max(abs(from), abs(to)), decimals))\(suffix)", font, 100_000)
    holder.bounds = CGRect(origin: .zero, size: widest)
    if widest.width > maxWidth { holder.setAffineTransform(CGAffineTransform(scaleX: maxWidth / widest.width, y: maxWidth / widest.width)) }
    for i in 0..<steps {
      let k = Double(i) / Double(steps - 1)
      let eased = 1 - pow(1 - k, 3)
      let t = textLayer("\(prefix)\(fmt(from + (to - from) * eased, decimals))\(suffix)", font, fill, maxWidth: 100_000, scale: scale)
      t.position = CGPoint(x: widest.width / 2, y: widest.height / 2)
      let at = start + over * k
      let until = i == steps - 1 ? start + total : start + over * Double(i + 1) / Double(steps - 1)
      showBetween(t, at, max(0.01, until - at))
      holder.addSublayer(t)
    }
    return holder
  }

  // ------------------------------------------------------------------------------------------------------------------
  // The kinds

  static func textPop(_ c: Ctx) -> CALayer {
    let u = c.u, pad = 30 * u
    let font = NSFont.systemFont(ofSize: 64 * u, weight: .black)
    let text = textLayer(c.a.text ?? "Text", font, color("#111111", "#111111"), maxWidth: c.width - pad * 2, scale: c.scale)
    let box = card(CGSize(width: text.bounds.width + pad * 2, height: text.bounds.height + pad * 1.4), color(c.a.color, "#FFE600"), radius: 24 * u)
    text.position = CGPoint(x: box.bounds.midX, y: box.bounds.midY)
    box.addSublayer(text)
    pop(box, c.start)
    keyframes(box, "transform.rotation.z", start: c.start, [(0, -0.08), (0.3, 0.02), (0.5, -0.02)])
    return box
  }

  static func lowerThird(_ c: Ctx) -> CALayer {
    let u = c.u, pad = 26 * u, bar = 12 * u
    let title = textLayer(c.a.text ?? "Name", NSFont.systemFont(ofSize: 50 * u, weight: .heavy), .white, maxWidth: c.width - pad * 2 - bar, align: .left, scale: c.scale)
    let sub = c.a.subtitle.flatMap { $0.isEmpty ? nil : $0 }.map { textLayer($0, NSFont.systemFont(ofSize: 32 * u, weight: .medium), color("#dddddd", "#dddddd"), maxWidth: c.width - pad * 2 - bar, align: .left, scale: c.scale) }
    let h = title.bounds.height + (sub?.bounds.height ?? 0) + pad * 1.3
    let w = max(title.bounds.width, sub?.bounds.width ?? 0) + pad * 2 + bar
    let box = card(CGSize(width: w, height: h), CGColor(gray: 0.07, alpha: 0.9), radius: 16 * u)
    let accent = CALayer()
    accent.frame = CGRect(x: 0, y: 0, width: bar, height: h)
    accent.backgroundColor = color(c.a.color, "#FFE600")
    box.masksToBounds = false
    let clip = CALayer(); clip.frame = box.bounds; clip.cornerRadius = 16 * u; clip.masksToBounds = true
    clip.addSublayer(accent); box.addSublayer(clip)
    title.frame.origin = CGPoint(x: bar + pad, y: h - pad * 0.65 - title.bounds.height)
    box.addSublayer(title)
    if let sub { sub.frame.origin = CGPoint(x: bar + pad, y: pad * 0.65); box.addSublayer(sub) }
    let dx: CGFloat = c.a.side == "left" ? -w * 1.3 : c.a.side == "right" ? w * 1.3 : 0
    let dy: CGFloat = c.a.side == "center" ? -h * 1.5 : 0
    keyframes(box, "transform.translation.x", start: c.start, [(0, dx), (0.5, 0)])
    keyframes(box, "transform.translation.y", start: c.start, [(0, dy), (0.5, 0)])
    return box
  }

  static func counter(_ c: Ctx) -> CALayer {
    let u = c.u, pad = 30 * u
    let numFont = NSFont.monospacedDigitSystemFont(ofSize: 120 * u, weight: .black)
    let over = min(1.6, c.length * 0.6)
    let num = countingText(c.a.from ?? 0, c.a.to ?? 100, prefix: c.a.prefix ?? "", suffix: c.a.suffix ?? "", font: numFont, fill: color(c.a.color, "#FFE600"), start: c.start, over: over, total: c.length, scale: c.scale, maxWidth: c.width - pad * 2)
    let label = c.a.text.flatMap { $0.isEmpty ? nil : $0 }.map { textLayer($0, NSFont.systemFont(ofSize: 36 * u, weight: .bold), .white, maxWidth: c.width - pad * 2, scale: c.scale) }
    let w = max(num.frame.width, label?.bounds.width ?? 0) + pad * 2
    let h = num.frame.height + (label.map { $0.bounds.height + 8 * u } ?? 0) + pad * 1.2
    let box = card(CGSize(width: w, height: h), CGColor(gray: 0.07, alpha: 0.88), radius: 28 * u)
    num.position = CGPoint(x: w / 2, y: h - pad * 0.6 - num.frame.height / 2)
    box.addSublayer(num)
    if let label { label.position = CGPoint(x: w / 2, y: pad * 0.6 + label.bounds.height / 2); box.addSublayer(label) }
    pop(box, c.start, overshoot: 1.08)
    return box
  }

  static func emojiBurst(_ c: Ctx) -> CALayer {
    let u = c.u
    let box = CALayer()
    let w = c.width, h = c.frame.height * 0.45
    box.bounds = CGRect(x: 0, y: 0, width: w, height: h)
    let n = 10
    for i in 0..<n {
      let e = textLayer(c.a.emoji ?? "🔥", NSFont.systemFont(ofSize: (70 + CGFloat((i * 37) % 40)) * u), .white, maxWidth: 400 * u, scale: c.scale)
      let x0 = w * (0.1 + 0.8 * CGFloat((i * 53) % 100) / 100)
      let drift = CGFloat(sin(Double(i) * 2.1)) * 60 * u
      e.position = CGPoint(x: x0, y: e.bounds.height / 2)
      let at = c.start + Double(i) * min(0.12, c.length / Double(n * 2))
      let life = min(1.3, c.length)
      e.opacity = 0
      let fade = CAKeyframeAnimation(keyPath: "opacity")
      fade.values = [0, 1, 1, 0]; fade.keyTimes = [0, 0.15, 0.7, 1]
      fade.beginTime = bt(at); fade.duration = life; fade.fillMode = .removed; fade.isRemovedOnCompletion = false
      e.add(fade, forKey: "fade")
      keyframes(e, "transform.translation.y", start: at, [(0, 0), (life, h - e.bounds.height)], timing: .easeOut)
      keyframes(e, "transform.translation.x", start: at, [(0, 0), (life, drift)], timing: .easeInEaseOut)
      keyframes(e, "transform.scale", start: at, [(0, 0.5), (0.25, 1.15), (life, 0.9)])
      box.addSublayer(e)
    }
    return box
  }

  static func progressBar(_ c: Ctx) -> CALayer {
    let u = c.u, pad = 28 * u
    let w = c.width
    let label = textLayer(c.a.text ?? "Progress", NSFont.systemFont(ofSize: 38 * u, weight: .heavy), .white, maxWidth: w - pad * 2 - 160 * u, align: .left, scale: c.scale)
    let barH = 30 * u
    let h = label.bounds.height + barH + pad * 2 + 14 * u
    let box = card(CGSize(width: w, height: h), CGColor(gray: 0.07, alpha: 0.88), radius: 24 * u)
    label.frame.origin = CGPoint(x: pad, y: h - pad - label.bounds.height)
    box.addSublayer(label)
    let pct = max(0, min(100, c.a.to ?? 100))
    let over = c.length * 0.8
    let num = countingText(0, pct, prefix: "", suffix: "%", font: NSFont.monospacedDigitSystemFont(ofSize: 38 * u, weight: .heavy), fill: color(c.a.color, "#22C55E"), start: c.start, over: over, total: c.length, scale: c.scale, maxWidth: 200 * u)
    num.position = CGPoint(x: w - pad - num.bounds.width / 2, y: label.frame.midY)
    box.addSublayer(num)
    let track = CALayer()
    track.frame = CGRect(x: pad, y: pad, width: w - pad * 2, height: barH)
    track.backgroundColor = CGColor(gray: 1, alpha: 0.18)
    track.cornerRadius = barH / 2
    box.addSublayer(track)
    let fill = CALayer()
    fill.anchorPoint = CGPoint(x: 0, y: 0.5)
    fill.bounds = CGRect(x: 0, y: 0, width: track.bounds.width * CGFloat(pct / 100), height: barH)
    fill.position = CGPoint(x: 0, y: barH / 2)
    fill.backgroundColor = color(c.a.color, "#22C55E")
    fill.cornerRadius = barH / 2
    track.addSublayer(fill)
    keyframes(fill, "transform.scale.x", start: c.start, [(0, 0.001), (over, 1)], timing: .easeInEaseOut)
    pop(box, c.start, overshoot: 1.05)
    return box
  }

  static func callout(_ c: Ctx) -> CALayer {
    let u = c.u, pad = 30 * u, tail = 34 * u
    let text = textLayer(c.a.text ?? "Callout", NSFont.systemFont(ofSize: 46 * u, weight: .bold), color("#111111", "#111111"), maxWidth: c.width - pad * 2 - tail, scale: c.scale)
    let bw = text.bounds.width + pad * 2, bh = text.bounds.height + pad * 1.4
    let side = c.a.side
    let holder = CALayer()
    holder.bounds = CGRect(x: 0, y: 0, width: bw + (side == "center" ? 0 : tail), height: bh + (side == "center" ? tail : 0))
    let bubble = card(CGSize(width: bw, height: bh), color(c.a.color, "#ffffff"), radius: 30 * u)
    // The tail points toward the speaker: right of a bubble on the left, left of one on the right, down from one in the centre.
    let tri = CAShapeLayer()
    let path = CGMutablePath()
    switch side {
    case "left":
      bubble.frame.origin = .zero
      path.move(to: CGPoint(x: bw - 2, y: bh * 0.3)); path.addLine(to: CGPoint(x: bw + tail, y: bh * 0.18)); path.addLine(to: CGPoint(x: bw - 2, y: bh * 0.55))
    case "right":
      bubble.frame.origin = CGPoint(x: tail, y: 0)
      path.move(to: CGPoint(x: tail + 2, y: bh * 0.3)); path.addLine(to: CGPoint(x: 0, y: bh * 0.18)); path.addLine(to: CGPoint(x: tail + 2, y: bh * 0.55))
    default:
      bubble.frame.origin = CGPoint(x: 0, y: tail)
      path.move(to: CGPoint(x: bw * 0.42, y: tail + 2)); path.addLine(to: CGPoint(x: bw * 0.5, y: 0)); path.addLine(to: CGPoint(x: bw * 0.6, y: tail + 2))
    }
    path.closeSubpath()
    tri.path = path
    tri.fillColor = color(c.a.color, "#ffffff")
    holder.addSublayer(tri)
    holder.addSublayer(bubble)
    text.position = CGPoint(x: bw / 2, y: bh / 2)
    bubble.addSublayer(text)
    pop(holder, c.start)
    return holder
  }

  static func checklist(_ c: Ctx) -> CALayer {
    let u = c.u, pad = 30 * u, gap = 18 * u, dot = 46 * u
    let items = (c.a.text ?? "First\nSecond\nThird").split(whereSeparator: \.isNewline).map { String($0).trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    let font = NSFont.systemFont(ofSize: 42 * u, weight: .bold)
    let rows = items.map { textLayer($0, font, .white, maxWidth: c.width - pad * 2 - dot - gap, align: .left, scale: c.scale) }
    let rowH = rows.map { max($0.bounds.height, dot) }
    let h = rowH.reduce(0, +) + gap * CGFloat(max(0, rows.count - 1)) + pad * 2
    let w = (rows.map(\.bounds.width).max() ?? 0) + dot + gap + pad * 2
    let box = card(CGSize(width: w, height: h), CGColor(gray: 0.07, alpha: 0.88), radius: 26 * u)
    let span = c.length * 0.66
    var y = h - pad
    for (i, row) in rows.enumerated() {
      let at = c.start + 0.2 + span * Double(i) / Double(max(1, rows.count))
      y -= rowH[i]
      let line = CALayer()
      line.frame = CGRect(x: pad, y: y, width: w - pad * 2, height: rowH[i])
      let circle = CALayer()
      circle.frame = CGRect(x: 0, y: (rowH[i] - dot) / 2, width: dot, height: dot)
      circle.cornerRadius = dot / 2
      circle.backgroundColor = color(c.a.color, "#22C55E")
      let tick = textLayer("✓", NSFont.systemFont(ofSize: 30 * u, weight: .black), .white, maxWidth: dot, scale: c.scale)
      tick.position = CGPoint(x: dot / 2, y: dot / 2)
      circle.addSublayer(tick)
      row.frame.origin = CGPoint(x: dot + gap, y: (rowH[i] - row.bounds.height) / 2)
      line.addSublayer(circle); line.addSublayer(row)
      showBetween(line, at, max(0.05, c.start + c.length - at), fadeIn: 0.15)
      keyframes(line, "transform.translation.x", start: at, [(0, 24 * u), (0.3, 0)])
      keyframes(circle, "transform.scale", start: at, [(0, 0.3), (0.2, 1.2), (0.35, 1)])
      box.addSublayer(line)
      y -= gap
    }
    pop(box, c.start, overshoot: 1.05)
    return box
  }
}
