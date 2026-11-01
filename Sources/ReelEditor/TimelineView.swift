// The timeline, in edit time (the clips end to end, cuts shown where they are): a ruler, the video clips with their
// filmstrips, the waveform, the words, and the animation layer whose blocks can be moved and stretched. It is drawn in
// tiles, so a long video only draws what is on screen. Drag across it to select a range, click to move the playhead.
import AppKit
import ReelCore
import SwiftUI

// Where each lane sits, top to bottom, in the web timeline's order: the ruler, the animation layer, the video, its
// sound, the voice over and the words (the captions). A taller timeline (drag its divider up) gives the extra room to
// the filmstrip and the waveform, as the web editor does.
struct Lanes: Equatable {
  static let minHeight: Double = 260
  let ruler: ClosedRange<Double>, video: ClosedRange<Double>, audio: ClosedRange<Double>, words: ClosedRange<Double>, voice: ClosedRange<Double>, anim: ClosedRange<Double>
  let height: Double

  init(height h: Double = Lanes.minHeight) {
    let extra = max(0, h - Lanes.minHeight)
    let vh = 60 + extra * 0.6, ah = 38 + extra * 0.4
    ruler = 0...28
    anim = 32...68
    video = 76...(76 + vh)
    audio = (video.upperBound + 8)...(video.upperBound + 8 + ah)
    voice = (audio.upperBound + 8)...(audio.upperBound + 40) // the Voice over layer: audio overlays
    words = (voice.upperBound + 8)...(voice.upperBound + 32)
    height = words.upperBound + 8
  }
}

private struct LanesKey: EnvironmentKey { static let defaultValue = Lanes() }
extension EnvironmentValues { var lanes: Lanes { get { self[LanesKey.self] } set { self[LanesKey.self] = newValue } } }

private let TILE: Double = 640

func timecode(_ t: Double) -> String {
  let m = Int(t) / 60, s = t - Double(m * 60)
  return String(format: "%d:%05.2f", m, s)
}

struct TimelineView: View {
  @ObservedObject var model: EditorModel
  var height: Double = Lanes.minHeight + 14 // the panel's height, set by dragging its divider
  @State private var dragFrom: Double? = nil
  @State private var scrollX: Double = 0 // how far the lanes are scrolled, for zooming around the pointer
  @State private var pinchBase: Double? = nil
  @State private var position = ScrollPosition(edge: .leading)
  // The gap between the layer names and time zero, and after the end, as the web timeline has them (LABEL_GAP 48, PAD 24).
  static let pad: Double = 48
  static let endPad: Double = 24

  var body: some View {
    let lanes = Lanes(height: height - 14)
    let width = max(1, model.plan.editDuration) * model.zoom
    let tiles = Int(ceil(width / TILE))
    HStack(spacing: 0) {
    LaneNames(model: model)
    Hairline(vertical: true)
    ScrollViewReader { proxy in
      ScrollView(.horizontal) {
        ZStack(alignment: .topLeading) {
          LazyHStack(spacing: 0) {
            ForEach(0..<tiles, id: \.self) { i in
              TimelineTile(model: model, t0: Double(i) * TILE / model.zoom, t1: min(Double(i + 1) * TILE, width) / model.zoom)
                .frame(width: min(TILE, width - Double(i) * TILE), height: lanes.height)
                .id(i)
            }
          }
          ClipHitLane(model: model)
          SelectionBand(model: model)
          RangeMenu(model: model)
          VoiceOverLane(model: model)
          AnimationLane(model: model)
          Playhead(model: model, clock: model.clock, proxy: proxy)
        }
        .frame(width: width, height: lanes.height, alignment: .topLeading)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
          let a = g.startLocation.x / model.zoom, b = g.location.x / model.zoom
          if abs(g.translation.width) < 3 { return }
          dragFrom = a
          model.selectedWords = nil
          model.selection = ReelCore.Range(s: max(0, min(a, b)), e: min(model.plan.editDuration, max(a, b)))
        }.onEnded { g in
          if abs(g.translation.width) < 3 {
            model.selection = nil; model.selectedWords = nil; model.selectedAnimation = nil
            model.seek(g.location.x / model.zoom)
          }
          dragFrom = nil
        })
        .padding(.leading, Self.pad).padding(.trailing, Self.endPad)
      }
      .scrollPosition($position)
      .onScrollGeometryChange(for: Double.self, of: { $0.contentOffset.x }) { _, x in scrollX = x }
      // A trackpad pinch zooms the timeline, keeping the moment under the fingers where it is.
      .simultaneousGesture(MagnifyGesture()
        .onChanged { v in
          let base = pinchBase ?? model.zoom
          pinchBase = base
          let p = v.startLocation.x
          let t = (scrollX + p - Self.pad) / model.zoom
          let z = max(1, min(160, base * v.magnification))
          model.zoom = z
          position.scrollTo(x: max(0, t * z + Self.pad - p))
        }
        .onEnded { _ in pinchBase = nil })
    }
    }
    .frame(height: lanes.height + 14, alignment: .top)
    .environment(\.lanes, lanes)
    .background(Ink.page)
  }
}

// The column of layer names on the left of the timeline, each beside its lane, with Add layer at the top.
struct LaneNames: View {
  @Environment(\.lanes) private var lanes
  @ObservedObject var model: EditorModel
  @State private var adding = false

  var body: some View {
    ZStack(alignment: .topLeading) {
      Button { adding.toggle() } label: { name("Add layer", "plus") }
        .buttonStyle(.plain)
        .frame(height: lanes.ruler.upperBound - lanes.ruler.lowerBound)
        .popover(isPresented: $adding, arrowEdge: .trailing) {
          OptionList(options: [("clip", "Video clip at the end"), ("audio", "Audio at the playhead"), ("face", "Face video at the playhead")] + ANIMATION_KINDS.map { ("anim:" + $0.id, "Animation: " + $0.title) },
                     icons: ["clip": "film-strip", "audio": "waveform", "face": "user-square"].merging(Dictionary(uniqueKeysWithValues: ANIMATION_KINDS.map { ("anim:" + $0.id, "sparkle") })) { a, _ in a }) { id in
            adding = false
            if id == "clip" {
              let panel = NSOpenPanel()
              panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
              if panel.runModal() == .OK, let u = panel.url { model.run("add_clip", ["path": .string(u.path)]) }
            } else if id == "audio" { model.chooseOverlay(at: model.clock.time, muteClip: nil) }
            else if id == "face" { model.chooseFace() }
            else if let k = ANIMATION_KINDS.first(where: { "anim:" + $0.id == id }) { model.addAnimation(k) }
          }
        }
        .offset(y: lanes.ruler.lowerBound)
      row("Animation", "magic-wand", lanes.anim)
      row("Video", "film-strip", lanes.video)
      row("Audio", "waveform", lanes.audio)
      row("Voice and face", "microphone", lanes.voice)
      row("Captions", "closed-captioning", lanes.words)
    }
    .frame(width: 160, height: lanes.height, alignment: .topLeading)
    .padding(.top, 0)
  }

  func name(_ text: String, _ icon: String) -> some View {
    HStack(spacing: 8) { Icon(icon, size: 16).foregroundStyle(Ink.muted); Text(text).font(.inter(14)).foregroundStyle(Ink.text) }
      .padding(.leading, 16)
      .frame(width: 160, alignment: .leading)
      .contentShape(Rectangle())
  }

  func row(_ text: String, _ icon: String, _ r: ClosedRange<Double>) -> some View {
    name(text, icon).frame(height: r.upperBound - r.lowerBound).offset(y: r.lowerBound)
  }
}

// One tile of the timeline, drawn with Canvas. Redraws when the project changes, not with the playhead.
struct TimelineTile: View {
  @Environment(\.lanes) private var lanes
  @ObservedObject var model: EditorModel
  let t0: Double, t1: Double

  var body: some View {
    Canvas { ctx, size in
      let z = model.zoom
      let x = { (t: Double) in (t - t0) * z }
      let plan = model.plan

      // Ruler
      let major: Double = z > 60 ? 1 : z > 20 ? 5 : z > 6 ? 10 : z > 2 ? 30 : 60
      let minor = major / 5
      // The time labels first, then a dot at each minor tick that is clear of every label (with 6 points either side),
      // so no dot shows behind a time.
      var labels: [ClosedRange<Double>] = []
      var t = ((t0 - major) / major).rounded(.down) * major
      while t <= t1 + major {
        let label = ctx.resolve(Text(timecode(max(0, t)).replacingOccurrences(of: ".00", with: "")).font(.inter(12)).foregroundStyle(Ink.secondary))
        let w = label.measure(in: CGSize(width: 200, height: 20)).width
        if t >= 0 { ctx.draw(label, at: CGPoint(x: x(t), y: 14), anchor: .center); labels.append((x(t) - w / 2 - 6)...(x(t) + w / 2 + 6)) }
        t += major
      }
      t = (t0 / minor).rounded(.down) * minor
      while t <= t1 {
        let isMajor = abs((t / major).rounded() * major - t) < 1e-6
        let px = x(t)
        if !isMajor && !labels.contains(where: { $0.contains(px) }) {
          ctx.fill(Path(ellipseIn: CGRect(x: px - 1, y: 13, width: 2, height: 2)), with: .color(Ink.ghost))
        }
        t += minor
      }

      // Video clips with their filmstrips
      let vy = lanes.video.lowerBound, vh = lanes.video.upperBound - lanes.video.lowerBound
      for c in plan.clips where c.editEnd > t0 && c.editStart < t1 {
        let r = CGRect(x: x(c.editStart), y: vy, width: c.length * z, height: vh)
        ctx.fill(Path(roundedRect: r, cornerRadius: 8), with: .color(Ink.shell))
        if let strip = model.thumbs[c.source], let first = strip.images.first {
          let thumbW = vh * Double(first.width) / Double(max(1, first.height))
          var sx = max(r.minX, (r.minX + floor((max(0, -r.minX)) / thumbW) * thumbW))
          ctx.drawLayer { l in
            l.clip(to: Path(roundedRect: r, cornerRadius: 8))
            while sx < min(r.maxX, size.width) {
              let src = c.inn + (sx - r.minX) / z
              let idx = min(strip.images.count - 1, max(0, Int(src / strip.step)))
              l.draw(Image(decorative: strip.images[idx], scale: 1), in: CGRect(x: sx, y: vy, width: thumbW, height: vh))
              sx += thumbW
            }
          }
        }
        ctx.stroke(Path(roundedRect: r.insetBy(dx: 0.5, dy: 0.5), cornerRadius: 8), with: .color(Ink.border), lineWidth: 1)
        let label = "\(c.id). \(c.clip.label ?? (c.source == MAIN ? "main" : c.source))"
        if r.minX >= -1 {
          let tag = ctx.resolve(Text(label).font(.inter(12, .medium)).foregroundStyle(.white))
          let ts = tag.measure(in: CGSize(width: max(0, r.width - 16), height: 20))
          ctx.fill(Path(roundedRect: CGRect(x: r.minX + 4, y: vy + 4, width: min(ts.width + 12, max(0, r.width - 8)), height: ts.height + 4), cornerRadius: 4), with: .color(Color(nsColor: NSColor(hex: 0x333333, alpha: 0.85))))
          ctx.draw(tag, in: CGRect(x: r.minX + 10, y: vy + 6, width: max(0, min(ts.width, r.width - 20)), height: ts.height))
        }
      }

      // Waveform
      let ay = lanes.audio.lowerBound, ah = lanes.audio.upperBound - lanes.audio.lowerBound
      ctx.fill(Path(roundedRect: CGRect(x: 0, y: ay, width: size.width, height: ah), cornerRadius: 0), with: .color(Ink.sunken))
      var path = Path()
      var px = 0.0
      while px < size.width {
        let et = t0 + px / z
        if let hit = locate(plan, et), et < plan.editDuration, let p = model.peaks[hit.clip.source], !p.isEmpty {
          let v = Double(p[min(p.count - 1, max(0, Int(hit.sourceTime * 20)))])
          let h = max(1, v * ah * 0.95)
          path.addRect(CGRect(x: px, y: ay + (ah - h) / 2, width: 1.5, height: h))
        }
        px += 2
      }
      ctx.fill(path, with: .color(Ink.faint))

      // A clip whose own sound is muted: its waveform is greyed out and marked
      for c in plan.clips where c.clip.muteAudio == true && c.editEnd > t0 && c.editStart < t1 {
        let r = CGRect(x: x(c.editStart), y: ay, width: c.length * z, height: ah)
        ctx.fill(Path(r), with: .color(Ink.page.opacity(0.75)))
        ctx.draw(Text(PhosphorCodes.glyph("speaker-slash")).font(.custom("Phosphor-Fill", size: 14)).foregroundStyle(Ink.red), at: CGPoint(x: max(r.minX, 0) + 16, y: ay + ah / 2))
      }

      // Words
      let wy = lanes.words.lowerBound, wh = lanes.words.upperBound - lanes.words.lowerBound
      for w in model.words {
        guard let s = w.s, let e = w.e, e > t0, s < t1 else { continue }
        let r = CGRect(x: x(s), y: wy, width: max(1, (e - s) * z - 1), height: wh)
        ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(w.cut ? Ink.red.opacity(0.1) : Ink.shell))
        if r.width > 18 {
          ctx.draw(Text(w.text).font(.inter(11)).foregroundStyle(w.cut ? Ink.ghost : Ink.text).strikethrough(w.cut), in: r.insetBy(dx: 4, dy: 5))
        }
      }

      // The words of the added clips and of the voice overs, tinted so they read apart from the main video's
      for w in model.extraWords where w.e > t0 && w.s < t1 {
        let r = CGRect(x: x(w.s), y: wy, width: max(1, (w.e - w.s) * z - 1), height: wh)
        ctx.fill(Path(roundedRect: r, cornerRadius: 4), with: .color(Color.purple.opacity(0.12)))
        if r.width > 18 { ctx.draw(Text(w.w).font(.inter(11, italic: true)).foregroundStyle(Ink.text), in: r.insetBy(dx: 4, dy: 5)) }
      }

      // Cuts, laid over the picture, the sound and the words: red hatching between two red edges, as the web timeline
      // A cut made from the chat that waits for approval is amber instead of red: its range cut, or its words.
      let waiting = plan.rangeCuts.filter { $0.pending == true }.map { Range(s: $0.s, e: $0.e) }
        + model.words.filter { $0.pending }.compactMap { w in w.s.flatMap { s in w.e.map { Range(s: s, e: $0) } } }
      // Every cut in red first, then the waiting ones over them in amber.
      for (i, cut) in (plan.cuts + waiting).enumerated() where cut.e > t0 && cut.s < t1 {
        let tint = i >= plan.cuts.count ? Ink.amber : Ink.red
        let r = CGRect(x: x(cut.s), y: vy, width: (cut.e - cut.s) * z, height: lanes.words.upperBound - vy)
        ctx.fill(Path(r), with: .color(Ink.page.opacity(0.55)))
        ctx.fill(Path(r), with: .color(tint.opacity(0.08)))
        ctx.drawLayer { l in
          l.clip(to: Path(r))
          var hatch = Path()
          var hx = r.minX - r.height
          while hx < r.maxX { hatch.move(to: CGPoint(x: hx, y: r.maxY)); hatch.addLine(to: CGPoint(x: hx + r.height, y: r.minY)); hx += 8 }
          l.stroke(hatch, with: .color(tint.opacity(0.35)), lineWidth: 2)
        }
        ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)), with: .color(tint.opacity(0.8)))
        ctx.fill(Path(CGRect(x: r.maxX - 1, y: r.minY, width: 1, height: r.height)), with: .color(tint.opacity(0.8)))
      }

      // A hairline under each lane, as the web timeline's rows
      for y in [lanes.ruler.upperBound + 2, lanes.anim.upperBound + 4, lanes.video.upperBound + 4, lanes.audio.upperBound + 4, lanes.voice.upperBound + 4, lanes.words.upperBound + 4] {
        ctx.fill(Path(CGRect(x: 0, y: y, width: size.width, height: 1)), with: .color(Ink.hairline))
      }
    }
  }
}

struct SelectionBand: View {
  @Environment(\.lanes) private var lanes
  @ObservedObject var model: EditorModel
  var body: some View {
    let range: (Double, Double)? = model.selection.map { ($0.s, $0.e) } ?? model.selectedWordRange
    if let (a, b) = range {
      Rectangle().fill(Ink.select)
        .overlay(Rectangle().stroke(Ink.focus, lineWidth: 1))
        .frame(width: max(2, (b - a) * model.zoom), height: lanes.words.upperBound - lanes.video.lowerBound)
        .offset(x: a * model.zoom, y: lanes.video.lowerBound)
        .allowsHitTesting(false)
    }
  }
}

// The selection menu over a range dragged on the timeline: Cut, Uncut and Comment for Claude.
struct RangeMenu: View {
  @Environment(\.lanes) private var lanes
  @ObservedObject var model: EditorModel
  var body: some View {
    if let s = model.selection, s.e - s.s > 0.05 {
      SelectionMenu(canCut: true, canUncut: model.plan.cuts.contains { $0.e > s.s && $0.s < s.e },
        cut: { model.cutSelection() }, uncut: { model.restoreSelection() },
        comment: { t in model.run("add_comment", ["start": .number(round3(s.s)), "end": .number(round3(s.e)), "comment": .string(t)]) })
        .offset(x: max(0, s.s * model.zoom), y: lanes.anim.lowerBound)
        .id("\(s.s)-\(s.e)")
    }
  }
}

struct Playhead: View {
  @Environment(\.lanes) private var lanes
  @ObservedObject var model: EditorModel
  @ObservedObject var clock: Clock
  let proxy: ScrollViewProxy

  var body: some View {
    let x = clock.time * model.zoom
    ZStack(alignment: .top) {
      Rectangle().fill(Ink.text).frame(width: 2, height: lanes.height)
      RoundedRectangle(cornerRadius: 4).fill(Ink.text).frame(width: 12, height: 20).padding(.top, 4)
    }
    .offset(x: x - 1)
    .allowsHitTesting(false)
    .onChange(of: Int(x / TILE)) { _, tile in
      if clock.playing && model.follow { withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(tile, anchor: .leading) } }
    }
  }
}

struct Triangle: Shape {
  func path(in r: CGRect) -> Path { Path { p in p.move(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.midX, y: r.maxY)); p.closeSubpath() } }
}

// The animation layer: one block per animation, in edit time. Drag a block to move it, drag an edge to stretch it.
struct AnimationLane: View {
  @Environment(\.lanes) private var lanes
  @ObservedObject var model: EditorModel
  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(model.loaded.animations.animations, id: \.id) { a in AnimationBlock(model: model, a: a) }
    }
    .offset(y: lanes.anim.lowerBound + 2)
  }
}

struct AnimationBlock: View {
  @Environment(\.lanes) private var lanes
  @ObservedObject var model: EditorModel
  let a: ReelAnimation
  @State private var dx: Double = 0
  @State private var dStart: Double = 0
  @State private var dEnd: Double = 0
  @State private var hover = false

  // Each kind's colour, its border at full strength and its fill a light wash of it. Never red or pink: red is kept for
  // cuts on the timeline.
  static func tint(_ kind: String) -> Color {
    let hex: UInt32
    switch kind {
    case "text-pop": hex = 0xf59e0b // amber
    case "lower-third": hex = 0x3b82f6 // blue
    case "counter": hex = 0x8b5cf6 // violet
    case "emoji-burst": hex = 0x14b8a6 // teal
    case "progress-bar": hex = 0x22c55e // green
    case "callout": hex = 0x06b6d4 // cyan
    default: hex = 0x84cc16 // lime, the checklist and anything newer
    }
    return Color(nsColor: NSColor(hex: hex))
  }

  // Drags are measured in the window's space, so the block moving under the pointer never feeds back into the drag, and
  // they take priority over the timeline's own drag (seek and select), which starts as soon as the mouse goes down.
  var body: some View {
    let z = model.zoom
    let start = a.start * z + dx + dStart, end = a.end * z + dx + dEnd
    let selected = model.selectedAnimation == a.id
    let h = lanes.anim.upperBound - lanes.anim.lowerBound - 4
    let title = ANIMATION_KINDS.first { $0.id == a.kind }?.title ?? a.kind
    let showGrips = hover || selected || dStart != 0 || dEnd != 0
    HStack(spacing: 0) {
      handle(showGrips) { dStart = min($0, (a.end - a.start - 0.5) * z) } commit: {
        model.run("update_animation", ["id": .string(a.id), "start": .number(round3(max(0, a.start + dStart / z)))]); dStart = 0
      }
      Text("\(title)\(a.text.map { ", \($0.replacingOccurrences(of: "\n", with: " / "))" } ?? "")")
        .font(.inter(12, .medium)).lineLimit(1).foregroundStyle(Ink.text)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { dx = $0.translation.width }.onEnded { g in
          let s = max(0, a.start + g.translation.width / z)
          model.run("update_animation", ["id": .string(a.id), "start": .number(round3(s)), "end": .number(round3(s + a.end - a.start))])
          dx = 0
        })
        // A click opens its settings in a card floating above it.
        .onTapGesture(coordinateSpace: .named("editor")) { at in model.selectedAnimation = a.id; model.seek(a.start); model.show(.animation(a.id), at: at) }
        .onHover { inside in if inside { NSCursor.openHand.push() } else { NSCursor.pop() } }
      handle(showGrips) { dEnd = max($0, -(a.end - a.start - 0.5) * z) } commit: {
        model.run("update_animation", ["id": .string(a.id), "end": .number(round3(a.end + dEnd / z))]); dEnd = 0
      }
    }
    .frame(width: max(24, end - start), height: h)
    // The light wash of its colour over the page, so the fill shows (a second background would sit under the white one).
    .background {
      ZStack {
        RoundedRectangle(cornerRadius: 8).fill(Ink.page)
        RoundedRectangle(cornerRadius: 8).fill(Self.tint(a.kind).opacity(selected ? 0.24 : 0.14))
      }
    }
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(selected ? Ink.strong : Self.tint(a.kind).opacity(0.7), lineWidth: 1))
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .onHover { hover = $0 }
    .help("Drag to move it, drag an edge to make it longer or shorter, click for its settings")
    .offset(x: start)
  }

  // An edge to stretch it by: an 8 point grab area with the resize cursor, a small grip in it shown on hover.
  func handle(_ show: Bool, _ change: @escaping (Double) -> Void, commit: @escaping () -> Void) -> some View {
    Color.clear.frame(width: 8)
      .overlay { Capsule().fill(Ink.text.opacity(show ? 0.45 : 0)).frame(width: 2, height: 12) }
      .contentShape(Rectangle())
      .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
      .highPriorityGesture(DragGesture(minimumDistance: 1, coordinateSpace: .global).onChanged { change($0.translation.width) }.onEnded { _ in commit() })
  }
}

// Each clip of the video lane as a hit area: its name as a hover tip, and a right click menu of what can be done to it
// (as the web editor's clip menu): rename, mute or unmute its sound, lay a voice over on it, split at the playhead, delete.
struct ClipHitLane: View {
  @ObservedObject var model: EditorModel
  @Environment(\.lanes) private var lanes

  var body: some View {
    ZStack(alignment: .topLeading) {
      ForEach(model.plan.clips, id: \.id) { c in
        let label = c.clip.label ?? (c.source == MAIN ? model.loaded.project.main.label : c.source)
        Color.clear
          .frame(width: max(1, c.length * model.zoom), height: lanes.audio.upperBound - lanes.video.lowerBound)
          .contentShape(Rectangle())
          .help("\(c.id) · \(label)\(c.clip.muteAudio == true ? " · sound muted" : "") · \(timecode(c.length)). Click for its settings")
          // A click moves the playhead there and opens the clip's settings in a card floating above it.
          .simultaneousGesture(SpatialTapGesture(coordinateSpace: .local).onEnded { v in
            model.selection = nil; model.selectedWords = nil
            model.seek(c.editStart + v.location.x / model.zoom)
          })
          .simultaneousGesture(SpatialTapGesture(coordinateSpace: .named("editor")).onEnded { v in model.show(.clip(c.id), at: v.location) })
          .contextMenu {
            Text("\(c.id) · \(label)")
            Button { model.prompt = .renameClip(c.id, label) } label: { Label("Rename…", systemImage: "pencil") }
            Button { model.run("mute_clip_audio", ["clip": .string(c.id), "muted": .bool(c.clip.muteAudio != true)]) } label: {
              Label(c.clip.muteAudio == true ? "Unmute its sound" : "Mute its sound", systemImage: c.clip.muteAudio == true ? "speaker.wave.2" : "speaker.slash")
            }
            Button { model.chooseOverlay(at: c.editStart, muteClip: c.id) } label: { Label("Add a voice over on it…", systemImage: "waveform.badge.plus") }
            Divider()
            Button { model.run("set_clip_title", ["clip": .string(c.id), "visible": .bool(c.clip.hideTitle == true)]) } label: {
              Label(c.clip.hideTitle == true ? "Show the title over it" : "Hide the title over it", systemImage: c.clip.hideTitle == true ? "textformat" : "textformat.slash")
            }
            Menu("Look") {
              Button { model.run("set_clip_look", ["clip": .string(c.id), "reel_look": true]) } label: { Text("The reel's look") }
              Button { model.run("set_clip_look", ["clip": .string(c.id), "off": true]) } label: { Text("No look, as recorded") }
              let saved = Looks.list()
              if !saved.isEmpty { Divider() }
              ForEach(saved, id: \.slug) { t in Button(t.name) { model.run("set_clip_look", ["clip": .string(c.id), "look": .string(t.name)]) } }
            }
            Menu("Placement") {
              ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { zoom in
                Button("Zoom \(Int(zoom * 100))%") { model.run("set_clip_placement", ["clip": .string(c.id), "zoom": .number(zoom), "x": .number(c.clip.place?.x ?? 0), "y": .number(c.clip.place?.y ?? 0)]) }
              }
              Divider()
              Button("As recorded") { model.run("set_clip_placement", ["clip": .string(c.id), "reset": true]) }
            }
            Divider()
            Button { model.splitAtPlayhead() } label: { Label("Split at the playhead", systemImage: "square.split.2x1") }
            Button(role: .destructive) { model.run("delete_clip", ["clip": .string(c.id)]) } label: { Label("Delete clip", systemImage: "trash") }
              .disabled(model.plan.clips.count < 2)
          }
          .offset(x: c.editStart * model.zoom, y: lanes.video.lowerBound)
      }
    }
  }
}

// The Voice over layer: one block per audio overlay, its waveform inside it. Drag a block to move it; right click for its
// volume, a new name, its words, or to remove it. A right click on the empty layer lays a new one there.
struct VoiceOverLane: View {
  @ObservedObject var model: EditorModel
  @Environment(\.lanes) private var lanes
  @State private var hoverX: Double = 0

  var body: some View {
    let h = lanes.voice.upperBound - lanes.voice.lowerBound
    ZStack(alignment: .topLeading) {
      Color.clear
        .frame(width: max(1, model.plan.editDuration * model.zoom), height: h)
        .contentShape(Rectangle())
        .onContinuousHover { if case .active(let p) = $0 { hoverX = p.x } }
        .help("Voice over: right click to lay an audio file here")
        .contextMenu {
          Button { model.chooseOverlay(at: hoverX / model.zoom, muteClip: nil) } label: { Label("Add audio here…", systemImage: "waveform.badge.plus") }
        }
      ForEach(model.loaded.project.edits.audioOverlays ?? [], id: \.id) { o in OverlayBlock(model: model, o: o, height: h) }
    }
    .offset(y: lanes.voice.lowerBound)
  }
}

struct OverlayBlock: View {
  @ObservedObject var model: EditorModel
  let o: AudioOverlay
  let height: Double
  @State private var dx: Double = 0

  var body: some View {
    let z = model.zoom
    let w = max(12, (o.out - o.inn) * z)
    let peaks = model.overlayPeaks[o.file] ?? []
    ZStack(alignment: .leading) {
      RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: NSColor(hex: o.isFace ? 0xc9b8ec : o.isVoice ? 0x8fc79a : 0xf2c48d))) // face purple, voice green, sound effect orange
      Canvas { ctx, size in
        guard !peaks.isEmpty else { return }
        var path = Path()
        var px = 0.0
        while px < size.width {
          let t = o.inn + px / z
          let v = Double(peaks[min(peaks.count - 1, max(0, Int(t * 20)))]) * min(1.5, o.gain)
          let bh = max(1, min(size.height - 4, v * (size.height - 4)))
          path.addRect(CGRect(x: px, y: (size.height - bh) / 2, width: 1.5, height: bh))
          px += 2
        }
        ctx.fill(path, with: .color(Color(nsColor: NSColor(hex: 0x2f7d3b, alpha: 0.45))))
      }
      Text("\(o.isFace ? "Face, " : "")\(o.label)\(abs(o.gain - 1) > 0.01 ? String(format: ", %.0f%%", o.gain * 100) : "")")
        .font(.inter(12, .medium)).foregroundStyle(Ink.strong).lineLimit(1).padding(.horizontal, 8)
    }
    .frame(width: w, height: height)
    .clipShape(RoundedRectangle(cornerRadius: 8))
    .contentShape(Rectangle())
    .help("\(o.label) · \(timecode(o.start)) to \(timecode(o.start + o.out - o.inn)) · volume \(Int(o.gain * 100))%. Click for its settings")
    .onTapGesture(coordinateSpace: .named("editor")) { at in model.show(.overlay(o.id), at: at) }
    .highPriorityGesture(DragGesture(minimumDistance: 3, coordinateSpace: .global).onChanged { dx = $0.translation.width }.onEnded { g in
      model.run("update_audio_overlay", ["id": .string(o.id), "start": .number(round3(max(0, o.start + g.translation.width / z)))])
      dx = 0
    })
    .contextMenu {
      Text(o.label)
      Menu("Volume") {
        ForEach([0.25, 0.5, 0.75, 1, 1.5, 2], id: \.self) { g in
          Button { model.run("update_audio_overlay", ["id": .string(o.id), "gain": .number(g)]) } label: {
            if abs(o.gain - g) < 0.01 { Label("\(Int(g * 100))%", systemImage: "checkmark") } else { Text("\(Int(g * 100))%") }
          }
        }
      }
      Button { model.prompt = .renameOverlay(o.id, o.label) } label: { Label("Rename…", systemImage: "pencil") }
      Button { model.run("transcribe_source", ["overlay": .string(o.id)]) } label: { Label("Get its words", systemImage: "text.bubble") }
      Button { model.seek(o.start) } label: { Label("Go to its start", systemImage: "arrow.right.to.line") }
      Button { model.run("split_overlay", ["id": .string(o.id), "at": .number(round3(model.clock.time))]) } label: { Label("Split at the playhead", systemImage: "square.split.2x1") }
        .disabled(!(model.clock.time > o.start && model.clock.time < o.start + o.out - o.inn))
      Button { model.run("update_audio_overlay", ["id": .string(o.id), "sound": .bool(o.sound != true)]) } label: {
        Label(o.sound == true ? "Treat as a voice" : "Treat as a sound effect", systemImage: o.sound == true ? "person.wave.2" : "speaker.wave.2")
      }
      Divider()
      Button(role: .destructive) { model.run("delete_audio_overlay", ["id": .string(o.id)]) } label: { Label("Remove", systemImage: "trash") }
    }
    .offset(x: o.start * z + dx)
  }
}
