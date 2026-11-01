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
  var icon: String? = nil // an icon before the value, saying what the field is (the account, the model)
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
        if let icon { Icon(icon, size: 14).foregroundStyle(Ink.muted) }
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

// The Project card holds only what the project is (Sankalp, 1 Nov 2026): when it was started, when it was last edited,
// who edited it, where its file is saved and what it reads. Nothing here changes the reel: each layer's settings open in
// its own card from the timeline, and the app's own settings (appearance, agents) are under App settings in the top bar.
struct ProjectPanel: View {
  @ObservedObject var model: EditorModel
  @State private var editors: [ProjectEditor] = []
  @State private var edited: Date?

  static let when: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM yyyy, h:mm a"; return f }()
  static func date(_ iso: String) -> Date? {
    let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.date(from: iso) ?? ISO8601DateFormatter().date(from: iso)
  }
  func home(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

  var body: some View {
    let p = model.loaded.project
    let file = Store.document(model.name)?.path ?? ""
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        InsetCard(title: "Details", icon: "info") {
          FieldRow("Started") { Text(Self.date(p.createdAt).map { Self.when.string(from: $0) } ?? p.createdAt) }
          FieldRow("Last edited") { Text(edited.map { Self.when.string(from: $0) } ?? "Not yet") }
          FieldRow("Saved at") { Text(home(file)).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(file) }
          FieldRow("Video") { Text(home(p.main.file)).lineLimit(2).truncationMode(.middle).textSelection(.enabled).help(p.main.file) }
          FieldRow("Length") { Text("\(timecode(model.plan.editDuration)) to \(timecode(model.plan.duration / model.speed))").monospacedDigit() }
          FieldRow("Size") { Text("\(Int(p.main.width)) × \(Int(p.main.height))") }
        }
        InsetCard(title: "Edited by", icon: "users") {
          if editors.isEmpty { Note("No edits recorded yet. Edits are recorded from 1 Nov 2026 on.") }
          ForEach(editors) { e in
            VStack(alignment: .leading, spacing: 2) {
              Text(e.who).font(.inter(14, .medium)).foregroundStyle(Ink.text).lineLimit(1)
              Text([e.account, "\(e.edits) \(e.edits == 1 ? "edit" : "edits")", "last \(Self.when.string(from: Date(timeIntervalSince1970: e.last)))"].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
      }
      .padding(.horizontal, 16).padding(.bottom, 16)
    }
    .onAppear(perform: reload)
    .onChange(of: model.loaded.project.rev) { _, _ in reload() }
    .onChange(of: model.loaded.animations.rev) { _, _ in reload() }
  }

  func reload() {
    editors = Editors.list(model.name)
    edited = Store.document(model.name).flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
  }
}
