// The editor window for one project, in one of three layouts, as in the web editor:
//   Wide: the transcript and the video side by side, the timeline across the bottom (a landscape video opens in it).
//   Tall: the video full height on the right, the timeline under the transcript (a portrait video opens in it).
//   Distraction free: only the video, centred. Escape or the close button brings the layout back.
// The divider between the transcript and the video, and the one above the timeline, can be dragged; a double click
// puts it back. The layout each kind of video opens in, the timeline's height and the video's width are kept.
// Keys (when no text field is being typed in): Space plays, Delete cuts the selection, Shift Delete restores it, S
// splits at the playhead, the arrows step a frame (with Shift, a second), = and - zoom the timeline in and out, Escape
// leaves distraction free. Cmd plus and Cmd minus zoom the whole window instead (UIZoom, in ReelEditorApp.swift).
import AppKit
import ReelCore
import SwiftUI

enum EditorLayout: String, CaseIterable { case wide, tall }

struct EditorView: View {
  @ObservedObject var model: EditorModel
  @State private var monitor: Any?
  @AppStorage("layoutLandscape") private var layoutLandscape = EditorLayout.wide.rawValue
  @AppStorage("layoutPortrait") private var layoutPortrait = EditorLayout.tall.rawValue
  @AppStorage("playerWidthLandscape") private var playerWidthLandscape = 0.0
  @AppStorage("playerWidthPortrait") private var playerWidthPortrait = 0.0
  @State private var dragStart: Double? = nil
  @AppStorage("chatDock") private var dock = "floating"
  @AppStorage("chatSide") private var sideOpen = false
  // The side chat's width, dragged on its divider and saved (Sankalp, 2 Nov 2026); a double click puts it back to 400.
  @AppStorage("chatWidth") private var chatWidth = 400.0
  @AppStorage("timelineHeight") private var timelineHeight = 0.0 // 0 fits the timeline to its layers
  @State private var chatDragStart: Double? = nil

  var landscape: Bool { model.exportSize.width >= model.exportSize.height }
  var layout: EditorLayout { EditorLayout(rawValue: landscape ? layoutLandscape : layoutPortrait) ?? (landscape ? .wide : .tall) }

  static let defaultTimeline = Lanes.minHeight + 14 // every layer, and the scroll bar under them
  static let minSide: Double = 320 // the narrowest the transcript or the video column gets

  // The editor, with the chat docked as a column on its right when it is set to the side panel and open.
  var body: some View {
    HStack(spacing: 0) {
      editor
      if dock == "side" && sideOpen {
        SplitHandle(axis: .vertical,
          onChange: { dx in
            let start = chatDragStart ?? chatWidth
            chatDragStart = start
            chatWidth = max(320, min(start - dx, 900))
          },
          onEnd: { chatDragStart = nil },
          onReset: { chatWidth = 400 })
        VStack(spacing: 0) {
          HStack(spacing: 8) {
            Icon("chat-circle-text", size: 16).foregroundStyle(Ink.muted)
            Text("Chat with Claude").font(.inter(14, .semibold)).foregroundStyle(Ink.strong)
            Spacer()
            Button { withAnimation(.cardClose) { sideOpen = false } } label: { Icon("x", size: 14) }.pill(.ghost, .iconSm).help("Close the chat")
          }
          .padding(.horizontal, 16).frame(height: 52)
          Hairline()
          ChatPanel(app: AppModel.shared, model: model)
        }
        .frame(width: max(320, min(chatWidth, 900)))
        .background(Ink.page)
        .transition(.move(edge: .trailing).combined(with: .opacity))
      }
    }
  }

  var editor: some View {
    GeometryReader { geo in
      let size = geo.size
      Group {
      if model.focus {
        ZStack(alignment: .topTrailing) {
          PreviewPane(model: model)
          Button { model.focus = false } label: { Icon("x", size: 16) }
            .pill(.outline, .icon).padding(16).help("Leave distraction free (Escape)")
        }
      } else {
        let th = clampTimeline(size.height)
        let pw = playerWidth(in: size)
        switch layout {
        case .wide:
          VStack(spacing: 0) {
            HStack(spacing: 0) {
              InspectorView(model: model).frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped()
              widthHandle(size)
              PreviewPane(model: model).frame(width: pw)
            }
            .frame(maxHeight: .infinity)
            heightHandle(size)
            TimelinePanel(model: model, height: th)
          }
        case .tall:
          HStack(spacing: 0) {
            VStack(spacing: 0) {
              InspectorView(model: model).frame(maxHeight: .infinity)
              heightHandle(size)
              TimelinePanel(model: model, height: th)
            }
            // The column never grows past its share: what is too wide inside it shrinks or is cut at its own edge,
            // never under the video (Sankalp, 19 Nov 2026).
            .frame(minWidth: 0, maxWidth: .infinity)
            .clipped()
            widthHandle(size)
            PreviewPane(model: model).frame(width: pw)
          }
        }
      }
      }
      // A layer's settings float above it, Project and Chat under the transcript's head (its right end: the transcript
      // column's width less the head's padding).
      .overlay { FloatingLayer(model: model, size: size, headAnchor: CGPoint(x: size.width - playerWidth(in: size) - 8 - 20, y: 52)) }
    }
    .coordinateSpace(.named("editor"))
    .background(Ink.page)
    .onAppear { installKeys() }
    .onDisappear { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    .sheet(item: $model.prompt) { p in NameSheet(model: model, prompt: p) }
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Sizes

  // The timeline's height under its toolbar, dragged with its divider (Sankalp, 2 Nov 2026): its layers keep their own
  // heights, room past them is left empty at the bottom, and a shorter timeline scrolls up and down to show them all.
  static let minTimeline: Double = 96
  func clampTimeline(_ total: Double) -> Double {
    let h = timelineHeight > 0 ? timelineHeight : Self.defaultTimeline
    return max(Self.minTimeline, min(h, total - 260))
  }

  // The video column: what was dragged to, or by default about half the window for a landscape video and the width a
  // portrait video needs at the window's height.
  func playerWidth(in size: CGSize) -> Double {
    let saved = landscape ? playerWidthLandscape : playerWidthPortrait
    let aspect = model.exportSize.width / max(1, model.exportSize.height)
    let fallback = landscape ? size.width * 0.5 : min(size.width * 0.45, (size.height - 120) * aspect + 48)
    return max(Self.minSide, min(saved > 0 ? saved : fallback, size.width - Self.minSide))
  }

  func setPlayerWidth(_ w: Double) { if landscape { playerWidthLandscape = w } else { playerWidthPortrait = w } }

  // The divider between the transcript and the video. Dragging it left widens the video.
  func widthHandle(_ size: CGSize) -> some View {
    SplitHandle(axis: .vertical,
      onChange: { dx in
        let start = dragStart ?? playerWidth(in: size)
        dragStart = start
        setPlayerWidth(max(Self.minSide, min(start - dx, size.width - Self.minSide)))
      },
      onEnd: { dragStart = nil },
      onReset: { setPlayerWidth(0) })
  }

  // The divider above the timeline. Dragging it up makes the timeline taller; a double click fits it to its layers.
  func heightHandle(_ size: CGSize) -> some View {
    SplitHandle(axis: .horizontal,
      onChange: { dy in
        let start = dragStart ?? clampTimeline(size.height)
        dragStart = start
        timelineHeight = max(Self.minTimeline, min(start - dy, size.height - 260))
      },
      onEnd: { dragStart = nil },
      onReset: { timelineHeight = 0 })
  }

  func installKeys() {
    monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak model] e in
      // While the rule books are open, Escape closes them and the up and down arrows move between them.
      if AppModel.shared.rulesOpen, e.modifierFlags.intersection([.command, .option, .control]).isEmpty {
        switch e.keyCode {
        case 53: AppModel.shared.closeRules(); return nil
        case 126: AppModel.shared.stepRuleBook(-1); return nil
        case 125: AppModel.shared.stepRuleBook(1); return nil
        default: break
        }
      }
      // The export modal takes the keyboard: Escape or Return closes it once the export is over, nothing reaches the editor.
      if let model, model.exportOpen {
        if [53, 36].contains(e.keyCode), model.status["state"]?.string != "exporting" { model.closeExport() }
        return e.modifierFlags.contains(.command) && e.keyCode == 12 ? e : nil // Cmd Q still quits
      }
      guard let model, e.window?.firstResponder as? NSTextView == nil else { return e }
      let mods = e.modifierFlags.intersection([.command, .option, .control])
      if !mods.isEmpty { return e }
      let shift = e.modifierFlags.contains(.shift)
      switch e.keyCode {
      case 53: // Escape closes a menu, the MCP details or a floating card, leaves distraction free, or lets go of a selection
        if MenuHost.shared.menu != nil { MenuHost.shared.close() }
        else if AppModel.shared.mcpOpen { withAnimation(.cardClose) { AppModel.shared.mcpOpen = false } }
        else if AppModel.shared.settingsOpen { withAnimation(.cardClose) { AppModel.shared.settingsOpen = false } }
        else if model.floating != nil { model.closeFloating() }
        else if model.focus { model.focus = false }
        else if model.selection != nil || model.selectedWords != nil { model.selection = nil; model.selectedWords = nil }
        else { return e }
      case 49: model.togglePlay()
      case 51, 117: shift ? model.restoreSelection() : model.cutSelection()
      case 123: model.step(shift ? -1 : -1.0 / 30)
      case 124: model.step(shift ? 1 : 1.0 / 30)
      case 1: model.splitAtPlayhead()
      case 24: model.zoom = min(160, model.zoom * 1.25) // = (and +, the same key): zoom the timeline in
      case 27: model.zoom = max(1, model.zoom / 1.25) // -: zoom the timeline out
      default: return e
      }
      return nil
    }
  }
}

// A divider that can be dragged: vertical between two columns, horizontal between two rows. An 8 point grip with a #eee
// hairline down its middle that darkens under the pointer, the resize cursor over it, and a double click puts the size
// back to the default. The sizes it sets are saved (EditorView's AppStorage), so the app opens as it was left.
// A divider that drags. It takes only its 1 point line in the layout, so the lines meeting it run right up to it with no
// white gap (Sankalp, 2 Nov 2026); the 8 point area that takes the pointer and the darker 2 point line shown on hover lie
// over it without taking room.
struct SplitHandle: View {
  enum Axis { case vertical, horizontal }
  let axis: Axis
  let onChange: (Double) -> Void
  let onEnd: () -> Void
  let onReset: () -> Void
  @State private var hover = false
  @State private var dragging = false

  var body: some View {
    let vertical = axis == .vertical
    let on = hover || dragging
    Rectangle().fill(Ink.hairline)
      .frame(width: vertical ? 1 : nil, height: vertical ? nil : 1)
      .frame(maxWidth: vertical ? nil : .infinity, maxHeight: vertical ? .infinity : nil)
      .overlay {
        Rectangle().fill(on ? Ink.borderHover : Color.clear)
          .frame(width: vertical ? 2 : nil, height: vertical ? nil : 2)
          .frame(width: vertical ? 8 : nil, height: vertical ? nil : 8)
          .contentShape(Rectangle())
          .onHover { inside in
            hover = inside
            if inside { (vertical ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push() } else { NSCursor.pop() }
          }
          .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
            .onChanged { g in dragging = true; onChange(vertical ? g.translation.width : g.translation.height) }
            .onEnded { _ in dragging = false; onEnd() })
          .onTapGesture(count: 2) { onReset() }
          .help("Drag to resize, double click to reset")
      }
      .zIndex(1)
  }
}

// The timeline panel, as in the web editor: a toolbar of edit buttons, the time, speed and zoom on the right, then the
// layers with their names in a column on the left.
struct TimelinePanel: View {
  @ObservedObject var model: EditorModel
  let height: Double
  var body: some View {
    VStack(spacing: 0) {
      TimelineToolbar(model: model, clock: model.clock)
      Hairline()
      TimelineView(model: model, height: height)
    }
    .background(Ink.page)
  }
}

// The timeline's toolbar: cut, restore, split and delete as ghost icon buttons, play, any running job or error, then
// the times, Follow, the speed and the zoom.
struct TimelineToolbar: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var clock: Clock

  // The bar as wide as it can be, then narrower in steps when the column is narrow, so nothing is ever cut off at its
  // edge (Sankalp, 19 Nov 2026): the times lose their words, then stack, then go; Follow and the Claude note lose their
  // words; the steppers lose their icons; last, the bar takes two rows, editing above, the times, speed and zoom below.
  var body: some View {
    ViewThatFits(in: .horizontal) {
      ForEach(0..<5) { bar($0) }
      twoRows
    }
    .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
    .clipped()
  }

  func bar(_ k: Int) -> some View {
    HStack(spacing: 4) {
      editing(k)
      Spacer(minLength: 12)
      if k == 0 { times(full: true) } else if k == 1 { times(full: false) } else if k <= 3 { stackedTimes }
      steppers(icons: k <= 3)
      follow(label: k <= 2)
    }
    .padding(.horizontal, 12)
    .frame(height: 52)
  }

  var twoRows: some View {
    VStack(spacing: 0) {
      HStack(spacing: 4) { editing(4); Spacer(minLength: 8); follow(label: false) }.frame(height: 44)
      HStack(spacing: 4) { stackedTimes; Spacer(minLength: 8); steppers(icons: false) }.frame(height: 44)
    }
    .padding(.horizontal, 12).padding(.vertical, 4)
  }

  func steppers(icons: Bool) -> some View {
    HStack(spacing: 4) {
      StepperPill(icon: "gauge", value: String(format: "%.1fx", model.speed), help: "Playback and export speed",
        minus: { setSpeed(model.speed - 0.1) }, plus: { setSpeed(model.speed + 0.1) }, showsIcon: icons)
      StepperPill(icon: "magnifying-glass", value: "\(Int((model.zoom / 24 * 100).rounded()))%", help: "Zoom the timeline (pinch, Cmd or Ctrl with the scroll wheel, or = and -)",
        minus: { model.zoom = max(1, model.zoom / 1.25) }, plus: { model.zoom = min(160, model.zoom * 1.25) }, showsIcon: icons)
    }
  }

  // Follow, its own setting in a pill of its own beside the zoom.
  func follow(label: Bool) -> some View {
    PillBox {
      InlineToggle(label: "Follow", icon: "navigation-arrow", on: $model.follow,
        help: "Follow: while playing, the timeline and the transcript keep the playhead in view", showsLabel: label)
    }
  }

  // The editing buttons, play, and any note: Claude editing, an error, a job running.
  @ViewBuilder func editing(_ k: Int) -> some View {
    HStack(spacing: 4) {
      let hasSelection = model.selection != nil || model.selectedWords != nil
      let locked = model.claudeEditing // Claude is editing: the editing buttons wait (Sankalp, 2 Nov 2026)
      Button { model.cutSelection() } label: { Icon("scissors", size: 16) }.pill(.ghost, .icon)
        .disabled(!hasSelection || locked).help("Cut the selected range or words (Delete)")
      Button { model.restoreSelection() } label: { Icon("arrow-u-up-left", size: 16) }.pill(.ghost, .icon)
        .disabled(!hasSelection || locked).help("Bring the selection back (Shift Delete)")
      Button { model.splitAtPlayhead() } label: { Icon("arrows-split", size: 16) }.pill(.ghost, .icon)
        .disabled(locked).help("Split the clip at the playhead (S)")
      Button { model.deleteClipAtPlayhead() } label: { Icon("trash", size: 16) }.pill(.ghost, .icon)
        .disabled(model.plan.clips.count < 2 || locked).help("Take out the clip under the playhead")
      Button { model.togglePlay() } label: { Icon(clock.playing ? "pause" : "play", size: 16, fill: true) }.pill(.ghost, .icon)
        .help("Play or pause (Space)")
      if model.busy { Spinner(size: 14).padding(.leading, 8) }
      if locked {
        HStack(spacing: 8) {
          Icon("lock-simple", size: 12)
          if k <= 1 { Text("Claude is editing, your edits wait").font(.inter(12)).lineLimit(1).fixedSize() }
          else if k == 2 { Text("Claude is editing").font(.inter(12)).lineLimit(1).fixedSize() }
          if DirectChat.shared.isWorking(model.name) {
            Button("Stop") { DirectChat.shared.interrupt() }.buttonStyle(.plain).font(.inter(12, .semibold)).foregroundStyle(Ink.text)
          }
        }
        .foregroundStyle(Ink.secondary)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(Ink.select))
        .overlay(Capsule().strokeBorder(Ink.focus.opacity(0.4), lineWidth: 1))
        .padding(.leading, 8)
        .help("While Claude edits this reel your own edits are held, so neither undoes the other. Play, read, select and comment as you like.")
      }
      if let e = model.error, e != EditorModel.lockedNote, model.rc != nil { // without a composition the error already fills the video pane
        HStack(spacing: 8) {
          Icon("warning-circle", size: 14)
          Text(e).font(.inter(12)).lineLimit(1).truncationMode(.tail).frame(maxWidth: k <= 1 ? 320 : k == 2 ? 180 : 96, alignment: .leading)
          Button { model.error = nil } label: { Icon("x", size: 12) }.buttonStyle(.plain)
        }
        .foregroundStyle(Ink.red)
        .padding(.horizontal, 12).frame(height: 28)
        .background(Capsule().fill(Ink.red.opacity(0.08)))
        .overlay(Capsule().strokeBorder(Ink.red.opacity(0.3), lineWidth: 1))
        .padding(.leading, 8)
        .help(e)
      }
      if let m = model.status["message"]?.string, ["transcribing", "exporting"].contains(model.status["state"]?.string ?? "") {
        HStack(spacing: 8) { Spinner(size: 12); Text(m).font(.inter(12)).lineLimit(1).frame(maxWidth: k <= 1 ? 280 : k == 2 ? 160 : 80, alignment: .leading) }
          .foregroundStyle(Ink.secondary)
          .padding(.horizontal, 12).frame(height: 28)
          .background(Capsule().fill(Ink.sunken))
          .overlay(Capsule().strokeBorder(Ink.border, lineWidth: 1))
          .padding(.leading, 8)
          .help(m)
      }
    }
  }

  func setSpeed(_ s: Double) { model.run("set_speed", ["speed": .number((min(2, max(0.5, s)) * 10).rounded() / 10)]) }

  // Current, Trimmed and Original, as the web editor's time row reads them.
  func times(full: Bool) -> some View {
    HStack(spacing: 8) {
      MetaLabel("\(full ? "Current: " : "")\(timecode(clock.time))", icon: "play-circle")
      Text("/").foregroundStyle(Ink.ghost)
      MetaLabel("\(full ? "Trimmed: " : "")\(timecode(model.plan.duration / model.speed))", icon: "scissors")
      if full {
        Text("/").foregroundStyle(Ink.ghost)
        MetaLabel("Original \(timecode(model.plan.editDuration))", icon: "film-strip")
      }
    }
    .font(.inter(12))
    .monospacedDigit()
    .fixedSize()
    .padding(.trailing, 8)
  }

  // Current over Trimmed, for a narrow bar.
  var stackedTimes: some View {
    VStack(alignment: .trailing, spacing: 2) {
      MetaLabel(timecode(clock.time), icon: "play-circle").help("Current")
      MetaLabel(timecode(model.plan.duration / model.speed), icon: "scissors").help("Trimmed")
    }
    .monospacedDigit()
    .fixedSize()
    .padding(.trailing, 8)
  }
}

// Renaming a clip or an audio overlay, from the timeline's right click menus.
struct NameSheet: View {
  @ObservedObject var model: EditorModel
  let prompt: NamePrompt
  @State private var text = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    let (title, current): (String, String) = {
      switch prompt { case .renameClip(let c, let l): return ("Rename clip \(c)", l); case .renameOverlay(_, let l): return ("Rename the voice over", l) }
    }()
    VStack(alignment: .leading, spacing: 16) {
      Text(title).font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
      TextField("Name", text: $text).textFieldStyle(.field).frame(width: 320).onSubmit { save() }
      HStack(spacing: 8) {
        Spacer()
        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction).pill(.outline, .sm)
        Button("Rename") { save() }.keyboardShortcut(.defaultAction).pill(.primary, .sm)
      }
    }
    .padding(20)
    .background(Ink.page)
    .onAppear { text = current }
  }

  func save() {
    switch prompt {
    case .renameClip(let c, _): model.run("rename_clip", ["clip": .string(c), "label": .string(text)])
    case .renameOverlay(let o, _): model.run("update_audio_overlay", ["id": .string(o), "label": .string(text)])
    }
    dismiss()
  }
}
