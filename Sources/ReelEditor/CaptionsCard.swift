// The Captions card and the text style controls (Sankalp, 2 Nov 2026), the app's side of Captions.swift: the card opens
// from the Captions layer on the timeline and sets the captions' look through set_caption_style, hides them over the
// selection or the clip under the playhead through hide_captions, and shows each hidden stretch to take away. A text
// layer's card (kind text, on the Animation layer) uses the same style controls through update_text_layer. Every change
// is applied at once, one undo step, and the preview shows it.
import AppKit
import ReelCore
import SwiftUI

// Every field of a text style as controls in inset cards: the font, the colours, the box and the place. `set` gets the
// fields to change, `caption` adds the caption only ones (words a line, the spoken word's highlight, how a line comes in).
struct StyleControls: View {
  let style: TextStyle
  let frame: CGSize // the export's frame, for the sliders of the place
  let caption: Bool
  let set: ([String: JSON]) -> Void
  static let weights: [(String, String)] = [("300", "Light"), ("400", "Regular"), ("500", "Medium"), ("600", "Semibold"), ("700", "Bold"), ("800", "Extra bold"), ("900", "Black")]

  var landscape: Bool { frame.width > frame.height }
  var frameW: Double { landscape ? 1920 : 1080 }
  var frameH: Double { landscape ? 1080 : 1920 }
  func px(_ v: Double) -> String { "\(Int(v.rounded())) px" }
  func colour(_ label: String, _ key: String, _ value: String?) -> some View {
    FieldRow(label) {
      ColorPicker("", selection: Binding(get: { Color(hex: value) ?? .white }, set: { c in if let h = c.hex { set([key: .string(h)]) } }), supportsOpacity: false).labelsHidden()
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      InsetCard(title: "Font", icon: "text-aa") {
        Field("Family") {
          Dropdown(options: Captions.families().map { ($0, $0) }, selection: Binding(get: { style.font ?? "Advercase" }, set: { set(["font": .string($0)]) }), icon: "text-t")
        }
        Field("Weight") {
          Dropdown(options: Self.weights, selection: Binding(get: { String(((style.weight ?? 700) / 100) * 100) }, set: { set(["weight": .number(Double($0) ?? 700)]) }))
        }
        ValueSlider(label: "Size", range: 24...240, format: px, value: style.size ?? 95) { set(["size": .number($0)]) }
        Field("Case and style") {
          HStack(spacing: 8) {
            SegmentTabs(items: [SegmentItem(value: "normal", label: "Aa"), SegmentItem(value: "upper", label: "AA")],
                        selection: Binding(get: { style.uppercase == true ? "upper" : "normal" }, set: { set(["uppercase": .bool($0 == "upper")]) }), fullWidth: true)
            SegmentTabs(items: [SegmentItem(value: "roman", label: "Upright"), SegmentItem(value: "italic", label: "Italic")],
                        selection: Binding(get: { style.italic == true ? "italic" : "roman" }, set: { set(["italic": .bool($0 == "italic")]) }), fullWidth: true)
          }
        }
        ValueSlider(label: "Letter spacing", range: -10...40, format: px, value: style.letterSpacing ?? 0) { set(["letterSpacing": .number($0)]) }
        if !caption {
          ValueSlider(label: "Line height", range: 0.8...2, step: 0.05, format: { String(format: "%.2f", $0) }, value: style.lineHeight ?? 1.1) { set(["lineHeight": .number($0)]) }
          Field("Align") {
            SegmentTabs(items: [SegmentItem(value: "left", label: "Left"), SegmentItem(value: "center", label: "Center"), SegmentItem(value: "right", label: "Right")],
                        selection: Binding(get: { style.align ?? "center" }, set: { set(["align": .string($0)]) }), fullWidth: true)
          }
        }
      }
      InsetCard(title: "Colours", icon: "palette") {
        colour("Text", "color", style.color)
        ValueSlider(label: "Outline", range: 0...24, format: px, value: style.strokeWidth ?? 0) { set(["strokeWidth": .number($0)]) }
        colour("Outline colour", "strokeColor", style.strokeColor)
        ValueSlider(label: "Shadow", range: 0...40, format: px, value: style.shadow ?? 0) { set(["shadow": .number($0)]) }
        colour("Shadow colour", "shadowColor", style.shadowColor)
        if caption {
          let on = style.highlight.map { $0 != "none" } ?? false
          FieldRow("Spoken word in its own colour") {
            Toggle("", isOn: Binding(get: { on }, set: { set(["highlight": .string($0 ? "#ffd400" : "none")]) })).toggleStyle(.pillSwitch).labelsHidden()
          }
          if on { colour("Spoken word", "highlight", style.highlight) }
        }
      }
      InsetCard(title: "Box", icon: "rectangle") {
        SegmentTabs(items: [SegmentItem(value: "none", label: "None"), SegmentItem(value: "line", label: caption ? "Whole line" : "Behind the text")] + (caption ? [SegmentItem(value: "word", label: "Spoken word")] : []),
                    selection: Binding(get: { style.box ?? "none" }, set: { set(["box": .string($0)]) }), fullWidth: true)
        if (style.box ?? "none") != "none" {
          colour("Colour", "boxColor", style.boxColor)
          ValueSlider(label: "Opacity", range: 0...1, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" }, value: style.boxOpacity ?? 1) { set(["boxOpacity": .number($0)]) }
          ValueSlider(label: "Padding across", range: 0...80, format: px, value: style.boxPadX ?? 16) { set(["boxPadX": .number($0)]) }
          ValueSlider(label: "Padding down", range: 0...80, format: px, value: style.boxPadY ?? 10) { set(["boxPadY": .number($0)]) }
          ValueSlider(label: "Corner", range: 0...80, format: px, value: style.boxRadius ?? 18) { set(["boxRadius": .number($0)]) }
        }
      }
      InsetCard(title: "Place", icon: "arrows-out-cardinal") {
        ValueSlider(label: "Up and down", range: 0...frameH, format: px, value: style.y ?? frameH / 2) { set(["y": .number($0)]) }
        ValueSlider(label: "Left and right", range: -frameW / 2...frameW / 2, format: px, value: style.x ?? 0) { set(["x": .number($0)]) }
        ValueSlider(label: "Widest line", range: 200...frameW, format: px, value: style.maxWidth ?? 900) { set(["maxWidth": .number($0)]) }
        if caption {
          ValueSlider(label: "Words a line", range: 1...8, format: { "\(Int($0))" }, value: Double(style.maxWords ?? 3)) { set(["maxWords": .number($0)]) }
          Field("Each line comes in") {
            SegmentTabs(items: [SegmentItem(value: "none", label: "At once"), SegmentItem(value: "pop", label: "Pop"), SegmentItem(value: "fade", label: "Fade"), SegmentItem(value: "rise", label: "Rise")],
                        selection: Binding(get: { style.animation ?? "none" }, set: { set(["animation": .string($0)]) }), fullWidth: true)
          }
        }
      }
    }
  }
}

// The Captions card: burned in or not, their look, and where they are hidden.
struct CaptionsCard: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let e = model.loaded.project.edits
    let burn = exportFlags(e, hasWords: model.loaded.hasAnyWords).captions
    VStack(alignment: .leading, spacing: 12) {
      FieldRow("Burned into the export") {
        Toggle("", isOn: Binding(get: { burn }, set: { model.run("set_captions", ["enabled": .bool($0)]) })).toggleStyle(.pillSwitch).labelsHidden()
      }
      InsetCard(title: "Hidden", icon: "eye-slash") {
        let hides = e.captionHides ?? []
        if hides.isEmpty { Note("Shown over the whole reel. Select words or a range, or put the playhead in a clip, to hide them there.") }
        ForEach(hides, id: \.id) { h in
          HStack(spacing: 8) {
            Text("\(timecode(h.start).components(separatedBy: ".")[0]) to \(timecode(h.end).components(separatedBy: ".")[0])").font(.inter(13)).foregroundStyle(Ink.text).monospacedDigit()
            Spacer()
            Button { model.seek(h.start) } label: { Icon("crosshair-simple", size: 12) }.pill(.ghost, .iconSm).help("Go there")
            Button { model.run("show_captions", ["id": .string(h.id)]) } label: { IconLabel("Show", icon: "eye", size: 12) }.pill(.ghost, .xs).fixedSize()
          }
        }
        HStack(spacing: 8) {
          Button { hideSelection() } label: { IconLabel(hideLabel, icon: "eye-slash", size: 12) }.pill(.outline, .xs).fixedSize()
          if !hides.isEmpty { Button { model.run("show_captions", ["all": true]) } label: { IconLabel("Show everywhere", icon: "eye", size: 12) }.pill(.ghost, .xs).fixedSize() }
        }
      }
      StyleControls(style: model.captionStyle, frame: model.exportSize, caption: true) { model.run("set_caption_style", $0) }
      HStack(spacing: 8) {
        Button { model.run("set_caption_style", ["reset": true]) } label: { IconLabel("Reset", icon: "arrow-counter-clockwise", size: 12) }.pill(.ghost, .xs).fixedSize()
          .help("Back to the look new projects start with")
        Spacer()
        Button { model.run("set_caption_style", ["saveAsDefault": true]) } label: { IconLabel("Use for new projects", icon: "bookmark-simple", size: 12) }.pill(.outline, .xs).fixedSize()
          .help("New projects start with this caption look")
      }
    }
  }

  // Hides the captions over the selected words or range, or else the clip under the playhead.
  var hideLabel: String { model.selection != nil || model.selectedWords != nil ? "Hide over the selection" : "Hide over this clip" }
  func hideSelection() {
    if let r = model.selection { model.run("hide_captions", ["start": .number(r.s), "end": .number(r.e)]) }
    else if let (a, b) = model.selectedWordRange { model.run("hide_captions", ["start": .number(a), "end": .number(b)]) }
    else if let c = locate(model.plan, model.clock.time)?.clip { model.run("hide_captions", ["clip": .string(c.id)]) }
  }
}

// A text layer's own fields in the animation card: its motions and its look, applied at once.
struct TextLayerControls: View {
  @ObservedObject var model: EditorModel
  let a: ReelAnimation
  static let enters: [(String, String)] = [("fade", "Fade in"), ("pop", "Pop"), ("rise", "Rise"), ("drop", "Drop"), ("slide-left", "Slide from the left"), ("slide-right", "Slide from the right"), ("typewriter", "Typewriter"), ("none", "At once")]
  static let exits: [(String, String)] = [("fade", "Fade out"), ("pop", "Pop"), ("rise", "Rise"), ("drop", "Drop"), ("slide-left", "Slide to the left"), ("slide-right", "Slide to the right"), ("none", "At once")]

  var body: some View {
    let size = model.exportSize
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Field("Comes in") { Dropdown(options: Self.enters, selection: Binding(get: { a.enter ?? "fade" }, set: { run(["enter": .string($0)]) })) }
        Field("Goes out") { Dropdown(options: Self.exits, selection: Binding(get: { a.exit ?? "fade" }, set: { run(["exit": .string($0)]) })) }
      }
      Button { run(["whole": true]) } label: { IconLabel("Over the whole reel", icon: "arrows-horizontal", size: 12) }.pill(.outline, .xs).fixedSize()
      StyleControls(style: Captions.textStyle(a, landscape: size.width > size.height), frame: size, caption: false) { run($0) }
    }
  }

  func run(_ args: [String: JSON]) { model.run("update_text_layer", args.merging(["id": .string(a.id)]) { x, _ in x }) }
}

// The Voice card, from the Audio layer's name (Sankalp, 2 Nov 2026), as the web editor's voice card: how loud all the
// voices are together, 0 to 1000 percent, with steps for the usual boosts, and their bass and treble. Above 100 percent
// the sound runs through the app's own gain and limiter (AudioFX.swift), so it really gets louder without clipping.
struct VoiceCard: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let e = model.loaded.project.edits
    let gain = e.voiceGain ?? 1
    VStack(alignment: .leading, spacing: 12) {
      InsetCard(title: "Volume", icon: "speaker-high") {
        ValueSlider(label: "All the voices", range: 0...10, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" }, value: gain) { set($0) }
        HStack(spacing: 8) {
          ForEach([1.0, 1.5, 2.0, 3.0, 5.0], id: \.self) { g in
            Button("\(Int(g * 100))%") { set(g) }.pill(abs(gain - g) < 0.001 ? .primary : .outline, .xs).fixedSize()
          }
        }
        Note("Above 100% a limiter holds the peaks, so the voice gets louder without crackling. The music and sound effects keep their own volume.")
      }
      InsetCard(title: "Tone", icon: "sliders-horizontal") {
        ValueSlider(label: "Bass", range: -12...12, format: { "\(Int($0)) dB" }, value: e.voiceEq?.bass ?? 0) { model.run("set_voice_eq", ["bass": .number($0.rounded())]) }
        ValueSlider(label: "Treble", range: -12...12, format: { "\(Int($0)) dB" }, value: e.voiceEq?.treble ?? 0) { model.run("set_voice_eq", ["treble": .number($0.rounded())]) }
      }
    }
  }

  func set(_ g: Double) { model.run("set_voice_gain", ["gain": .number((g * 100).rounded() / 100)]) }
}
