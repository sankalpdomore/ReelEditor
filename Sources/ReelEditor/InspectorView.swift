// The left panel, as the web editor's transcript column: a head with the TRANSCRIPT label, what the edit has saved so
// far, Approve for waiting cuts, and the Project and Chat buttons, which open their cards floating under the head, and
// Open folder; then the reel's title big and bold and the transcript. A layer's settings open from the timeline, in a
// card floating above the layer (Floating.swift).
import AppKit
import ReelCore
import SwiftUI

struct InspectorView: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(spacing: 0) {
      PanelHead(model: model)
      Hairline()
      ProjectTitle(model: model)
      TranscriptView(model: model)
    }
    .background(Ink.page)
  }
}

struct PanelHead: View {
  @ObservedObject var model: EditorModel
  @AppStorage("chatDock") private var dock = "floating"
  @AppStorage("chatSide") private var sideOpen = false

  var body: some View {
    let saved = max(0, model.plan.editDuration - model.plan.duration / model.speed)
    HStack(spacing: 12) {
      PanelLabel("Transcript", icon: "text-align-left").fixedSize()
      ViewThatFits(in: .horizontal) {
        MetaLabel("\(model.plan.cuts.count) \(model.plan.cuts.count == 1 ? "cut" : "cuts"), \(Int(saved.rounded())) s saved", icon: "scissors").fixedSize()
        Color.clear.frame(width: 0, height: 0)
      }
      Spacer(minLength: 8)
      if model.waitingCuts > 0 {
        Button { model.run("approve_cuts") } label: { IconLabel("Approve \(model.waitingCuts)", icon: "check", size: 12) }
          .pill(.primary, .xs)
          .help("Cuts Claude made from the chat wait for your approval, drawn in amber. They already play as cuts.")
      }
      Button { model.toggle(.project) } label: { IconLabel("Project", icon: "sliders-horizontal", size: 14) }
        .pill(.ghost, .xs, active: model.floating == .project)
        .help("The reel's status, caption, look, sound, comments, files and export")
      // Chat opens where it was left: the side panel on the right, or the floating card.
      Button { if dock == "side" { withAnimation(sideOpen ? .cardClose : .cardOpen) { sideOpen.toggle() } } else { model.toggle(.chat) } } label: { IconLabel("Chat", icon: "chat-circle-text", size: 14) }
        .pill(.ghost, .xs, active: model.floating == .chat || (dock == "side" && sideOpen))
        .help("Talk to the Claude connected over MCP")
      Button { NSWorkspace.shared.activateFileViewerSelecting([Store.document(model.name) ?? Store.root]) } label: { IconLabel("Open folder", icon: "folder-open", size: 14) }
        .pill(.gradient, .xs)
        .help("Show the project's file in Finder")
    }
    .padding(.leading, 32).padding(.trailing, 20)
    .frame(height: 52)
  }
}

// The project's title, big and bold at the top of the panel. Click it to edit; Return or a click anywhere else saves
// it, which renames the project and its folder too. Escape puts it back.
struct ProjectTitle: View {
  @ObservedObject var model: EditorModel
  @State private var text = ""
  @State private var monitor: Any?
  @State private var hover = false
  @State private var editing = false // plain text until clicked, so the field never takes the keyboard on its own
  @FocusState private var focused: Bool

  var body: some View {
    Group {
      if editing {
        TextField("Untitled", text: $text)
          .textFieldStyle(.plain)
          .focused($focused)
          .onSubmit { focused = false }
          .onExitCommand { text = model.title; editing = false }
          .onChange(of: focused) { _, f in if f { watchClicks() } else { stopWatching(); commit(); editing = false } }
          .onAppear { text = model.title; DispatchQueue.main.async { focused = true } }
      } else {
        Text(model.title).lineLimit(1).truncationMode(.tail)
          .frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle())
          .onTapGesture { editing = true }
      }
    }
    .font(.inter(28, .bold))
    .foregroundStyle(Ink.strong)
    .padding(.horizontal, 8).padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 8).fill(editing ? Ink.sunken : hover ? Ink.sunken.opacity(0.6) : .clear))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(editing ? Ink.border : .clear, lineWidth: 1))
    .onHover { hover = $0 }
    .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 8)
    .help("Click to rename the project")
  }

  func commit() {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, t != model.title else { text = model.title; return }
    AppModel.shared.rename(model.name, to: t)
  }

  // A click outside the field ends the edit, which saves it.
  func watchClicks() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
      if let w = e.window, !(w.contentView?.hitTest(e.locationInWindow) is NSTextView) {
        DispatchQueue.main.async { focused = false; w.makeFirstResponder(nil) }
      }
      return e
    }
  }
  func stopWatching() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
}

// A dropdown in the web DropdownOptions look: a field with the chosen option and a caret. Its options open in the
// window's own menu layer (MenuHost), right aligned under the field with an arrow at its top right pointing at the
// caret, so a menu never opens outside the window.
struct Dropdown: View {
  let options: [(id: String, label: String)]
  @Binding var selection: String
  @State private var frame: CGRect = .zero
  @ObservedObject private var host = MenuHost.shared

  var body: some View {
    let open = host.menu?.anchor == frame && host.menu != nil
    Button {
      if open { host.close() } else {
        host.open(MenuHost.Menu(anchor: frame, options: options, selected: selection) { selection = $0 })
      }
    } label: {
      HStack(spacing: 8) {
        Text(options.first { $0.id == selection }?.label ?? selection).lineLimit(1)
        Spacer(minLength: 8)
        Icon(open ? "caret-up" : "caret-down", size: 12).foregroundStyle(Ink.muted)
      }
      .font(.inter(14)).foregroundStyle(Ink.text)
      .padding(.horizontal, 12).frame(height: 32)
      .background(RoundedRectangle(cornerRadius: 8).fill(Ink.raised))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(open ? Ink.borderHover : Ink.border, lineWidth: 1))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("window")) }) { f in
      frame = f
      // REEL_EDITOR_OPEN_MENU=<value> opens the dropdown set to that value once at launch, for checking a menu in a snapshot.
      if ProcessInfo.processInfo.environment["REEL_EDITOR_OPEN_MENU"] == selection, host.menu == nil, f.width > 0 {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { host.open(MenuHost.Menu(anchor: frame, options: options, selected: selection) { selection = $0 }) }
      }
    }
  }
}

// The rows of a dropdown or a menu button: 8 rounded, a grey hover, a tick beside the chosen one.
struct OptionList: View {
  let options: [(id: String, label: String)]
  var selected: String? = nil
  var icons: [String: String] = [:]
  let pick: (String) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      ForEach(options, id: \.id) { o in OptionRow(label: o.label, icon: icons[o.id], on: o.id == selected) { pick(o.id) } }
    }
    .padding(4)
    .frame(minWidth: 200)
    .background(Ink.page)
  }
}

struct OptionRow: View {
  let label: String
  var icon: String? = nil
  var on = false
  let action: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: action) {
      HStack(spacing: 8) {
        if let icon { Icon(icon, size: 14).foregroundStyle(Ink.muted) }
        Text(label).font(.inter(14)).foregroundStyle(Ink.text)
        Spacer(minLength: 12)
        if on { Icon("check", size: 12).foregroundStyle(Ink.strong) }
      }
      .padding(.horizontal, 12).frame(height: 32)
      .background(RoundedRectangle(cornerRadius: 8).fill(hover ? Ink.hover : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Animations

struct AnimationEditor: View {
  @ObservedObject var model: EditorModel
  let original: ReelAnimation
  @State private var a: ReelAnimation
  @State private var colour: Color

  init(model: EditorModel, original: ReelAnimation) {
    self.model = model; self.original = original
    _a = State(initialValue: original)
    _colour = State(initialValue: Color(hex: original.color) ?? .yellow)
  }

  var fields: [String] { ANIMATION_KINDS.first { $0.id == a.kind }?.fields ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Field("Kind") { Dropdown(options: ANIMATION_KINDS.map { ($0.id, $0.title) }, selection: $a.kind) }
      HStack(spacing: 12) {
        Field("Start") {
          HStack(spacing: 8) {
            TextField("Start", value: $a.start, format: .number.precision(.fractionLength(0...3))).textFieldStyle(.field)
            Button("Playhead") { a.start = round3(model.clock.time) }.pill(.outline, .xs)
          }
        }
        Field("End") {
          HStack(spacing: 8) {
            TextField("End", value: $a.end, format: .number.precision(.fractionLength(0...3))).textFieldStyle(.field)
            Button("Playhead") { a.end = round3(model.clock.time) }.pill(.outline, .xs)
          }
        }
      }
      Field("Side") {
        SegmentTabs(items: [SegmentItem(value: "left", label: "Left"), SegmentItem(value: "center", label: "Center"), SegmentItem(value: "right", label: "Right")], selection: $a.side, fullWidth: true)
      }
      Field("Height") {
        SegmentTabs(items: [SegmentItem(value: "top", label: "Top"), SegmentItem(value: "middle", label: "Middle"), SegmentItem(value: "bottom", label: "Bottom")], selection: $a.position, fullWidth: true)
      }
      if fields.contains("text") {
        Field(a.kind == "checklist" ? "Items, one per line" : a.kind == "counter" ? "Label" : "Text") {
          TextEditor(text: Binding(get: { a.text ?? "" }, set: { a.text = $0 }))
            .font(.inter(14)).scrollContentBackground(.hidden)
            .padding(8).frame(height: 72)
            .background(RoundedRectangle(cornerRadius: 8).fill(Ink.raised))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.border, lineWidth: 1))
        }
      }
      if fields.contains("subtitle") { Field("Subtitle") { TextField("Subtitle", text: Binding(get: { a.subtitle ?? "" }, set: { a.subtitle = $0 })).textFieldStyle(.field) } }
      HStack(spacing: 12) {
        if fields.contains("from") { Field("From") { TextField("From", value: Binding(get: { a.from ?? 0 }, set: { a.from = $0 }), format: .number).textFieldStyle(.field) } }
        if fields.contains("to") { Field(a.kind == "progress-bar" ? "Percent" : "To") { TextField("To", value: Binding(get: { a.to ?? 100 }, set: { a.to = $0 }), format: .number).textFieldStyle(.field) } }
      }
      HStack(spacing: 12) {
        if fields.contains("prefix") { Field("Prefix") { TextField("Prefix", text: Binding(get: { a.prefix ?? "" }, set: { a.prefix = $0 })).textFieldStyle(.field) } }
        if fields.contains("suffix") { Field("Suffix") { TextField("Suffix", text: Binding(get: { a.suffix ?? "" }, set: { a.suffix = $0 })).textFieldStyle(.field) } }
      }
      if fields.contains("emoji") { Field("Emoji") { TextField("Emoji", text: Binding(get: { a.emoji ?? "🔥" }, set: { a.emoji = $0 })).textFieldStyle(.field) } }
      if fields.contains("color") {
        FieldRow("Colour") { ColorPicker("", selection: $colour, supportsOpacity: false).labelsHidden() }
      }
      HStack(spacing: 8) {
        Button { model.run("remove_animation", ["id": .string(a.id)]) } label: { IconLabel("Remove", icon: "trash", size: 14) }
          .pill(.outline, .sm)
        Spacer()
        Button("Apply") { apply() }.keyboardShortcut(.return, modifiers: .command).pill(.primary, .sm)
      }
    }
  }

  func apply() {
    var args: [String: JSON] = ["id": .string(a.id), "kind": .string(a.kind), "start": .number(a.start), "end": .number(a.end), "side": .string(a.side), "position": .string(a.position)]
    let f = fields
    if f.contains("text") { args["text"] = .string(a.text ?? "") }
    if f.contains("subtitle") { args["subtitle"] = .string(a.subtitle ?? "") }
    if f.contains("from") { args["from"] = .number(a.from ?? 0) }
    if f.contains("to") { args["to"] = .number(a.to ?? 100) }
    if f.contains("prefix") { args["prefix"] = .string(a.prefix ?? "") }
    if f.contains("suffix") { args["suffix"] = .string(a.suffix ?? "") }
    if f.contains("emoji") { args["emoji"] = .string(a.emoji ?? "🔥") }
    if f.contains("color"), let hex = colour.hex { args["color"] = .string(hex) }
    model.run("update_animation", args)
  }
}

extension Color {
  init?(hex: String?) {
    guard var s = hex else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    self = Color(red: Double((v >> 16) & 0xff) / 255, green: Double((v >> 8) & 0xff) / 255, blue: Double(v & 0xff) / 255)
  }
  var hex: String? {
    guard let c = NSColor(self).usingColorSpace(.sRGB) else { return nil }
    return String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Project

struct ProjectPanel: View {
  @ObservedObject var model: EditorModel
  @State private var title = ""
  @AppStorage(Theme.key) private var theme = Theme.light.rawValue

  // Adds another video as a clip at the end; its words are fetched in the background for the captions.
  func addClip() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
    panel.message = "Choose a video to add at the end. It is only read, never changed."
    if panel.runModal() == .OK, let u = panel.url { model.run("add_clip", ["path": .string(u.path)]) }
  }

  var body: some View {
    ScrollViewReader { proxy in
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        ReelCards(model: model).id("reel")
        LookCard(model: model).id("look")
        SoundCard(model: model).id("sound")
        CommentsCard(model: model).id("comments")
        SourcesCard(model: model).id("sources")
        InsetCard(title: "Source", icon: "film-strip") {
          FieldRow("Video") { Text(URL(fileURLWithPath: model.loaded.project.main.file).lastPathComponent).lineLimit(1).truncationMode(.middle) }
          FieldRow("Size") { Text("\(Int(model.loaded.project.main.width)) × \(Int(model.loaded.project.main.height))") }
          FieldRow("Length") { Text("\(timecode(model.plan.editDuration)) to \(timecode(model.plan.duration / model.speed))").monospacedDigit() }
          FieldRow("Project file") { Text((Store.document(model.name)?.path ?? "").replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle) }
          Note("The video is only ever read. Every edit lives in the project's one file, \(model.name)\(Store.DOC_EXT).")
          HStack(spacing: 8) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([Store.document(model.name) ?? Store.root]) } label: { IconLabel("Project file", icon: "folder-open", size: 12) }.pill(.outline, .xs)
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: model.loaded.project.main.file)]) } label: { IconLabel("Show video", icon: "file-video", size: 12) }.pill(.outline, .xs)
          }
        }
        InsetCard(title: "Clips and voice over", icon: "stack") {
          Note("Right click a clip on the timeline to rename it, mute its sound or lay a voice over on it.")
          HStack(spacing: 8) {
            Button { addClip() } label: { IconLabel("Add a video clip", icon: "film-strip", size: 12) }.pill(.outline, .xs)
            Button { model.chooseOverlay(at: model.clock.time, muteClip: nil) } label: { IconLabel("Add audio at the playhead", icon: "waveform", size: 12) }.pill(.outline, .xs)
          }
        }
        InsetCard(title: "Captions and title", icon: "closed-captioning") {
          Toggle("Burn in captions", isOn: Binding(get: { model.flags.captions }, set: { model.run("set_captions", ["enabled": .bool($0)]) }))
            .toggleStyle(.pillSwitch).disabled(model.loaded.words.isEmpty)
          Toggle("Show title", isOn: Binding(get: { model.flags.title }, set: { model.run("set_title", ["enabled": .bool($0), "text": .string(title)]) }))
            .toggleStyle(.pillSwitch)
          Field("Title text") {
            TextField("Title text", text: $title).textFieldStyle(.field).onSubmit { model.run("set_title", ["enabled": .bool(!title.isEmpty), "text": .string(title)]) }
          }
        }
        InsetCard(title: "Transcript", icon: "text-align-left") {
          FieldRow("Words") { Text("\(model.loaded.words.count)").monospacedDigit() }
          HStack(spacing: 8) {
            Button(model.loaded.words.isEmpty ? "Transcribe" : "Transcribe again") { model.transcribe() }.pill(.outline, .xs)
              .disabled(!model.loaded.project.main.hasAudio || model.status["state"]?.string == "transcribing")
            Button("Import words JSON") {
              let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]
              if panel.runModal() == .OK, let u = panel.url { model.run("import_transcript", ["path": .string(u.path)]) }
            }.pill(.outline, .xs)
          }
        }
        InsetCard(title: "Export", icon: "download-simple") {
          HStack(spacing: 8) {
            Button { model.chooseExport() } label: { IconLabel("Export MP4", icon: "download-simple", size: 14) }
              .pill(.primary, .sm).disabled(model.status["state"]?.string == "exporting")
            if model.status["kind"]?.string == "export", let f = model.status["result"]?["file"]?.string {
              Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) } label: { IconLabel("Show export", icon: "folder-open", size: 12) }.pill(.outline, .xs)
            }
          }
          if model.status["kind"]?.string == "export", let m = model.status["message"]?.string {
            if model.status["state"]?.string == "exporting" { ProgressBar(value: model.status["progress"]?.double ?? 0) }
            Note(m)
          }
        }
        InsetCard(title: "Appearance", icon: "paint-brush") {
          SegmentTabs(items: Theme.allCases.map { SegmentItem(value: $0.rawValue, label: $0.title) }, selection: $theme, fullWidth: true)
        }
        InsetCard(title: "Agents (MCP)", icon: "plugs-connected") {
          Note("Claude or any MCP client can edit this project's clips, cuts, words and animations. This window follows along live.")
          CommandBox(text: MCPDetails.command)
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    // REEL_EDITOR_CARD=look (or sound, comments, sources) scrolls to that card, for checking it in a snapshot.
    .onAppear { if let c = ProcessInfo.processInfo.environment["REEL_EDITOR_CARD"] { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { proxy.scrollTo(c, anchor: .top) } } }
    }
    .onAppear { title = model.loaded.project.edits.titleText ?? "" }
    .onChange(of: model.loaded.project.rev) { _, _ in title = model.loaded.project.edits.titleText ?? title }
  }
}

// A thin progress bar: a #eee track, a #111 fill.
struct ProgressBar: View {
  let value: Double
  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Ink.shell)
        Capsule().fill(Ink.strong).frame(width: g.size.width * max(0, min(1, value)))
      }
    }
    .frame(height: 4)
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// The cards for what the web editor added after 23 Oct 2026: the reel's status and post caption, its look, the voices
// and the music, comments, the source files, and the references and AI cost.

struct ReelCards: View {
  @ObservedObject var model: EditorModel
  @State private var caption = ""

  var body: some View {
    let e = model.loaded.project.edits
    InsetCard(title: "Reel", icon: "film-reel") {
      Field("Status") {
        SegmentTabs(items: [SegmentItem(value: "draft", label: "Draft", icon: "note-pencil"), SegmentItem(value: "live", label: "Live", icon: "check-circle")],
                    selection: Binding(get: { model.live ? "live" : "draft" }, set: { model.run("set_reel_status", ["status": .string($0)]) }), fullWidth: true)
      }
      Field("Caption to post with it") {
        TextEditor(text: $caption)
          .font(.inter(14)).scrollContentBackground(.hidden)
          .padding(8).frame(height: 88)
          .background(RoundedRectangle(cornerRadius: 8).fill(Ink.raised))
          .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.border, lineWidth: 1))
      }
      if caption != (e.caption ?? "") {
        HStack { Spacer(); Button("Save caption") { model.run("set_reel_caption", ["text": .string(caption)]) }.pill(.primary, .xs) }
      }
      HStack(spacing: 12) {
        Field("Caption x") { NumberBox(value: e.captionPos?.x ?? 0) { model.run("set_caption_position", ["x": .number($0), "y": .number(e.captionPos?.y ?? defaultCaptionY)]) } }
        Field("Caption y") { NumberBox(value: e.captionPos?.y ?? defaultCaptionY) { model.run("set_caption_position", ["x": .number(e.captionPos?.x ?? 0), "y": .number($0)]) } }
        if e.captionPos != nil { Button("Reset") { model.run("set_caption_position", ["reset": true]) }.pill(.outline, .xs).padding(.top, 16) }
      }
      Note("Where the burnt in captions sit, in pixels of the full frame: x from the centre, y down from the top.")
      if let refs = e.references, !refs.isEmpty {
        Field("References") {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(refs, id: \.path) { r in HStack(spacing: 8) { Icon(r.kind == "json" ? "brackets-curly" : "file-text", size: 12).foregroundStyle(Ink.muted); Text(r.title).font(.inter(13)) } }
          }
        }
      }
      if let c = e.cost {
        FieldRow("AI generations") { Text("\(c.total.generations), about ₹\(Int(c.total.inr.rounded()))").monospacedDigit() }
      }
    }
    .onAppear { caption = e.caption ?? "" }
    .onChange(of: model.loaded.project.rev) { _, _ in caption = model.loaded.project.edits.caption ?? caption }
  }

  var defaultCaptionY: Double {
    let s = model.exportSize
    return s.width > s.height ? 900 : 1400
  }
}

// A number field that saves on Return or when it loses focus.
struct NumberBox: View {
  let value: Double
  let commit: (Double) -> Void
  @State private var text = ""
  @FocusState private var focused: Bool
  var body: some View {
    TextField("", text: $text).textFieldStyle(.field).focused($focused)
      .onAppear { text = fmt(value) }
      .onChange(of: value) { _, v in if !focused { text = fmt(v) } }
      .onSubmit { save() }
      .onChange(of: focused) { _, f in if !f { save() } }
  }
  func fmt(_ v: Double) -> String { v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v) }
  func save() { if let v = Double(text.trimmingCharacters(in: .whitespaces)), abs(v - value) > 0.001 { commit(v) } }
}

struct LookCard: View {
  @ObservedObject var model: EditorModel
  static let keys: [(String, String, ClosedRange<Double>)] = [
    ("saturation", "Saturation", -100...100), ("brightness", "Brightness", -100...100), ("exposure", "Exposure", -100...100),
    ("contrast", "Contrast", -100...100), ("temperature", "Temperature", -100...100), ("sharpness", "Sharpness", 0...100), ("vignette", "Vignette", 0...100),
  ]

  var body: some View {
    let look = model.loaded.project.edits.look ?? ReelLook()
    let saved = Looks.list()
    InsetCard(title: "Look", icon: "palette") {
      if !saved.isEmpty {
        Field("Saved look") {
          Dropdown(options: [("", "Custom")] + saved.map { ($0.name, $0.name + ($0.default ? ", default" : "")) },
                   selection: Binding(get: { look.name ?? "" }, set: { if !$0.isEmpty { model.run("set_video_look", ["template": .string($0)]) } }))
        }
      }
      ForEach(Self.keys, id: \.0) { k in
        ValueSlider(label: k.1, range: k.2, value: value(look, k.0)) { v in model.run("set_video_look", [k.0: .number(v)]) }
      }
      HStack(spacing: 8) {
        Button("Reset") { model.run("set_video_look", ["reset": true]) }.pill(.outline, .xs)
        Spacer()
      }
      Note("The whole reel's look. A clip can carry its own: right click it on the timeline.")
    }
  }

  func value(_ l: ReelLook, _ k: String) -> Double {
    switch k {
    case "saturation": return l.saturation
    case "brightness": return l.brightness
    case "exposure": return l.exposure
    case "contrast": return l.contrast
    case "temperature": return l.temperature
    case "sharpness": return l.sharpness
    default: return l.vignette
    }
  }
}

struct SoundCard: View {
  @ObservedObject var model: EditorModel

  func chooseMusic() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
    panel.message = "Choose a music bed. It is only read, never changed."
    if panel.runModal() == .OK, let u = panel.url { model.run("set_music", ["track": .string(u.path)]) }
  }

  var body: some View {
    let e = model.loaded.project.edits
    InsetCard(title: "Sound", icon: "speaker-high") {
      ValueSlider(label: "Voice volume", range: 0...10, step: 0.1, format: { "\(Int(($0 * 100).rounded()))%" }, value: e.voiceGain ?? 1) { model.run("set_voice_gain", ["gain": .number($0)]) }
      ValueSlider(label: "Voice bass", range: -12...12, format: { String(format: "%+.0f dB", $0) }, value: e.voiceEq?.bass ?? 0) { model.run("set_voice_eq", ["bass": .number($0)]) }
      ValueSlider(label: "Voice treble", range: -12...12, format: { String(format: "%+.0f dB", $0) }, value: e.voiceEq?.treble ?? 0) { model.run("set_voice_eq", ["treble": .number($0)]) }
      Hairline()
      if let m = e.music, let track = m.track {
        FieldRow("Music") { Text(URL(fileURLWithPath: track).lastPathComponent).lineLimit(1).truncationMode(.middle) }
        ValueSlider(label: "Music volume", range: 0...1, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" }, value: m.gain) { model.run("set_music", ["gain": .number($0)]) }
        Toggle("Mute the music", isOn: Binding(get: { m.mute }, set: { model.run("set_music", ["mute": .bool($0)]) })).toggleStyle(.pillSwitch)
        HStack(spacing: 8) {
          Button { chooseMusic() } label: { IconLabel("Change track", icon: "music-notes", size: 12) }.pill(.outline, .xs)
          Button { model.run("set_music", ["none": true]) } label: { IconLabel("Remove", icon: "trash", size: 12) }.pill(.outline, .xs)
        }
      } else {
        Note("No music bed. It plays under the voices at its own speed, never sped up with the reel.")
        Button { chooseMusic() } label: { IconLabel("Add music", icon: "music-notes", size: 12) }.pill(.outline, .xs)
      }
    }
  }
}

// Comments left on words or on a range of the timeline, for Claude to act on (list_comments, add_comment).
struct CommentsCard: View {
  @ObservedObject var model: EditorModel
  @State private var draft = ""
  @State private var showResolved = false

  var body: some View {
    let all = Comments.read(model.name)
    let shown = all.filter { showResolved || $0.status != "resolved" }
    let _ = model.loaded.project.rev // read again whenever the project changes
    InsetCard(title: "Comments", icon: "chat-centered-text") {
      if shown.isEmpty { Note(all.isEmpty ? "No comments yet." : "Every comment is resolved.") }
      ForEach(shown, id: \.id) { c in
        VStack(alignment: .leading, spacing: 4) {
          HStack(alignment: .top, spacing: 8) {
            Text("\u{201C}\(c.words)\u{201D}").font(.inter(12, italic: true)).foregroundStyle(Ink.faint).lineLimit(2)
            Spacer(minLength: 4)
            if c.status == "resolved" {
              Button("Reopen") { model.run("reopen_comment", ["id": .string(c.id)]) }.pill(.ghost, .xs)
            } else {
              Button { model.run("resolve_comment", ["id": .string(c.id)]) } label: { IconLabel("Resolve", icon: "check", size: 12) }.pill(.outline, .xs)
            }
          }
          Text(c.comment).font(.inter(13)).foregroundStyle(c.status == "resolved" ? Ink.faint : Ink.text)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.sunken))
      }
      if all.contains(where: { $0.status == "resolved" }) {
        Toggle("Show resolved", isOn: $showResolved).toggleStyle(.pillSwitch)
      }
      Field(target.map { "Comment on \($0)" } ?? "Select words or a range to comment on it") {
        HStack(spacing: 8) {
          TextField("What should change", text: $draft).textFieldStyle(.field).onSubmit { add() }
          Button("Add") { add() }.pill(.primary, .xs).disabled(target == nil || draft.trimmingCharacters(in: .whitespaces).isEmpty)
        }
      }
    }
  }

  var target: String? {
    if let r = model.selectedWords { return r.count == 1 ? "1 word" : "\(r.count) words" }
    if let s = model.selection { return "\(timecode(s.s)) to \(timecode(s.e))" }
    return nil
  }

  func add() {
    let t = draft.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    if let r = model.selectedWords { model.run("add_comment", ["from": .number(Double(r.lowerBound)), "to": .number(Double(r.upperBound)), "comment": .string(t)]) }
    else if let s = model.selection { model.run("add_comment", ["start": .number(s.s), "end": .number(s.e), "comment": .string(t)]) }
    else { return }
    draft = ""
  }
}

// Every file the project reads, whether it is still there, and Relink for one that was moved (check_sources).
struct SourcesCard: View {
  @ObservedObject var model: EditorModel
  @State private var rows: [JSON] = []

  var body: some View {
    InsetCard(title: "Source files", icon: "files") {
      ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
        let found = r["found"]?.bool ?? true
        HStack(spacing: 8) {
          Icon(found ? "check-circle" : "warning-circle", size: 14, fill: true).foregroundStyle(found ? Ink.green : Ink.red)
          VStack(alignment: .leading, spacing: 2) {
            Text(r["label"]?.string ?? r["id"]?.string ?? "").font(.inter(13)).foregroundStyle(Ink.text).lineLimit(1)
            Text(URL(fileURLWithPath: r["url"]?.string ?? "").lastPathComponent).font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(1).truncationMode(.middle)
          }
          Spacer(minLength: 8)
          if !found, let id = r["id"]?.string {
            Button("Relink") { model.relink(id) }.pill(.primary, .xs)
          }
        }
      }
      if rows.isEmpty { Note("Checking the files.") }
    }
    .onAppear { check() }
    .onChange(of: model.loaded.project.rev) { _, _ in check() }
  }

  func check() {
    Task {
      if case .ok(let r) = await callTool("check_sources", ["project": .string(model.name)]) {
        rows = r["sources"]?.array ?? []
      }
    }
  }
}
