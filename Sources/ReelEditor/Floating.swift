// The cards that float over the editor (DESIGN.md's dropdown look and motion: a white card, a #ddd border, a soft
// shadow, growing out of the edge nearest what opened it and shrinking back into it). A layer clicked on the timeline
// (an animation, a clip, a voice or face overlay) shows its settings in a card just above it; the Project and Chat
// buttons open theirs under the transcript's head, right aligned to them. A click anywhere else, Escape or the close
// button puts the card away.
import AppKit
import ReelCore
import SwiftUI

struct FloatingLayer: View {
  @ObservedObject var model: EditorModel
  let size: CGSize
  let headAnchor: CGPoint // the right end of the transcript's head, where Project and Chat drop down from

  var body: some View {
    if let f = model.floating {
      let below = f == .project || f == .chat
      let width: CGFloat = f == .project ? 460 : f == .chat ? 420 : 380
      let at = below ? headAnchor : model.floatingAt
      let x = below ? max(16, at.x - width) : min(max(16, at.x - width / 2), size.width - width - 16)
      let room = below ? size.height - at.y - 24 : at.y - 24
      ZStack(alignment: below ? .topLeading : .bottomLeading) {
        Color.black.opacity(0.001).onTapGesture { model.closeFloating() }
        FloatingCard(title: title(f), maxHeight: max(160, room), fixedHeight: below ? min(room, f == .chat ? 520 : 640) : nil, close: model.closeFloating) {
          switch f {
          case .project: ProjectPanel(model: model)
          case .chat: ChatPanel(app: AppModel.shared, model: model)
          case .animation(let id):
            if let a = model.loaded.animations.animations.first(where: { $0.id == id }) {
              AnimationEditor(model: model, original: a).id("\(a.id)-\(model.loaded.animations.rev)")
            } else { Note("This animation is gone.") }
          case .clip(let id): ClipSettings(model: model, clipId: id)
          case .overlay(let id): OverlaySettings(model: model, overlayId: id)
          }
        }
        .frame(width: width)
        .padding(.leading, x)
        .padding(below ? .top : .bottom, below ? at.y + 4 : size.height - at.y + 12)
        .transition(.card(from: below ? .topTrailing : .bottom))
      }
      .frame(width: size.width, height: size.height, alignment: below ? .topLeading : .bottomLeading)
    }
  }

  func title(_ f: EditorModel.Floating) -> (String, String) {
    switch f {
    case .project: return ("Project", "sliders-horizontal")
    case .chat: return ("Chat with Claude", "chat-circle-text")
    case .animation(let id):
      let a = model.loaded.animations.animations.first { $0.id == id }
      return (a.map { k in ANIMATION_KINDS.first { $0.id == k.kind }?.title ?? k.kind } ?? "Animation", "magic-wand")
    case .clip(let id):
      let c = model.plan.clips.first { $0.id == id }
      return ("Clip \(id)\(c.map { ", " + ($0.clip.label ?? ($0.source == MAIN ? model.loaded.project.main.label : $0.source)) } ?? "")", "film-strip")
    case .overlay(let id):
      let o = model.loaded.project.edits.audioOverlays?.first { $0.id == id }
      return ((o?.isFace == true ? "Face, " : "Voice over, ") + (o?.label ?? id), o?.isFace == true ? "user-square" : "waveform")
    }
  }
}

// The card itself: its title with an icon and a close button, then the content, scrolling past its room.
struct FloatingCard<Content: View>: View {
  let title: (String, String)
  let maxHeight: CGFloat
  var fixedHeight: CGFloat? = nil
  let close: () -> Void
  @ViewBuilder var content: Content
  @State private var contentHeight: CGFloat = 200

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Icon(title.1, size: 16).foregroundStyle(Ink.muted)
        Text(title.0).font(.inter(14, .semibold)).foregroundStyle(Ink.strong).lineLimit(1)
        Spacer()
        Button(action: close) { Icon("x", size: 14) }.pill(.ghost, .iconSm).help("Close (Escape)")
      }
      .padding(.horizontal, 16).frame(height: 48)
      Hairline()
      Group {
        if let fixedHeight { content.frame(height: fixedHeight - 49) }
        else {
          ScrollView {
            content.padding(16)
              .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { contentHeight = $0 }
          }
          .frame(height: min(contentHeight, maxHeight - 49))
        }
      }
    }
    .cardChrome()
    .font(.inter())
    .foregroundStyle(Ink.text)
  }
}

// A clip's settings: its name, its sound, a voice over on it, the title over it, its own look and its placement, and
// splitting or deleting it. What the right click menu does, laid out.
struct ClipSettings: View {
  @ObservedObject var model: EditorModel
  let clipId: String
  @State private var name = ""

  var body: some View {
    if let c = model.plan.clips.first(where: { $0.id == clipId }) {
      let label = c.clip.label ?? (c.source == MAIN ? model.loaded.project.main.label : c.source)
      VStack(alignment: .leading, spacing: 16) {
        Note("\(timecode(c.editStart)) to \(timecode(c.editEnd)), \(timecode(c.length)) long")
        Field("Name") {
          HStack(spacing: 8) {
            TextField("Name", text: $name).textFieldStyle(.field).onSubmit { rename() }
            if name != label && !name.isEmpty { Button("Save") { rename() }.pill(.primary, .xs) }
          }
        }
        Toggle("Its own sound", isOn: Binding(get: { c.clip.muteAudio != true }, set: { model.run("mute_clip_audio", ["clip": .string(c.id), "muted": .bool(!$0)]) }))
          .toggleStyle(.pillSwitch)
        Toggle("The title over it", isOn: Binding(get: { c.clip.hideTitle != true }, set: { model.run("set_clip_title", ["clip": .string(c.id), "visible": .bool($0)]) }))
          .toggleStyle(.pillSwitch)
        Field("Look") {
          Dropdown(options: [("reel", "The reel's look"), ("off", "No look, as recorded")] + Looks.list().map { ("look:" + $0.name, $0.name) },
                   selection: Binding(get: { c.clip.hideLook == true ? "off" : c.clip.look?.name.map { "look:" + $0 } ?? "reel" }, set: { v in
                     if v == "reel" { model.run("set_clip_look", ["clip": .string(c.id), "reel_look": true]) }
                     else if v == "off" { model.run("set_clip_look", ["clip": .string(c.id), "off": true]) }
                     else { model.run("set_clip_look", ["clip": .string(c.id), "look": .string(String(v.dropFirst(5)))]) }
                   }))
        }
        Field("Placement") {
          SegmentTabs(items: [1.0, 1.25, 1.5, 2.0].map { SegmentItem(value: $0, label: "\(Int($0 * 100))%") },
                      selection: Binding(get: { c.clip.place?.zoom ?? 1 }, set: { z in
                        if z == 1 && (c.clip.place?.x ?? 0) == 0 && (c.clip.place?.y ?? 0) == 0 { model.run("set_clip_placement", ["clip": .string(c.id), "reset": true]) }
                        else { model.run("set_clip_placement", ["clip": .string(c.id), "zoom": .number(z), "x": .number(c.clip.place?.x ?? 0), "y": .number(c.clip.place?.y ?? 0)]) }
                      }), fullWidth: true)
        }
        HStack(spacing: 8) {
          Button { model.chooseOverlay(at: c.editStart, muteClip: c.id) } label: { IconLabel("Voice over", icon: "microphone", size: 12) }.pill(.outline, .xs)
          Button { model.splitAtPlayhead() } label: { IconLabel("Split", icon: "arrows-split", size: 12) }.pill(.outline, .xs)
            .help("Split the clip at the playhead")
            .disabled(!(model.clock.time > c.editStart && model.clock.time < c.editEnd))
          Spacer()
          Button { model.run("delete_clip", ["clip": .string(c.id)]); model.closeFloating() } label: { IconLabel("Delete", icon: "trash", size: 12) }.pill(.outline, .xs)
            .disabled(model.plan.clips.count < 2)
        }
      }
      .onAppear { name = label }
    } else { Note("This clip is gone.") }
  }

  func rename() {
    let t = name.trimmingCharacters(in: .whitespaces)
    if !t.isEmpty { model.run("rename_clip", ["clip": .string(clipId), "label": .string(t)]) }
  }
}

// A voice or face overlay's settings: its name, its volume, whether it is a voice or a sound effect, its words, and
// splitting or removing it.
struct OverlaySettings: View {
  @ObservedObject var model: EditorModel
  let overlayId: String
  @State private var name = ""

  var body: some View {
    if let o = model.loaded.project.edits.audioOverlays?.first(where: { $0.id == overlayId }) {
      let end = o.start + o.out - o.inn
      VStack(alignment: .leading, spacing: 16) {
        Note("\(timecode(o.start)) to \(timecode(end)), from \(URL(fileURLWithPath: o.file).lastPathComponent)")
        Field("Name") {
          HStack(spacing: 8) {
            TextField("Name", text: $name).textFieldStyle(.field).onSubmit { rename() }
            if name != o.label && !name.isEmpty { Button("Save") { rename() }.pill(.primary, .xs) }
          }
        }
        ValueSlider(label: "Volume", range: 0...2, step: 0.05, format: { "\(Int(($0 * 100).rounded()))%" }, value: o.gain) {
          model.run("update_audio_overlay", ["id": .string(o.id), "gain": .number($0)])
        }
        Toggle("A voice (raised with the voice volume)", isOn: Binding(get: { o.sound != true }, set: { model.run("update_audio_overlay", ["id": .string(o.id), "sound": .bool(!$0)]) }))
          .toggleStyle(.pillSwitch)
        HStack(spacing: 8) {
          Button { model.run("transcribe_source", ["overlay": .string(o.id)]) } label: { IconLabel("Its words", icon: "chat-text", size: 12) }.pill(.outline, .xs)
          Button { model.run("split_overlay", ["id": .string(o.id), "at": .number(round3(model.clock.time))]) } label: { IconLabel("Split", icon: "arrows-split", size: 12) }.pill(.outline, .xs)
            .help("Split it at the playhead")
            .disabled(!(model.clock.time > o.start && model.clock.time < end))
          Spacer()
          Button { model.run("delete_audio_overlay", ["id": .string(o.id)]); model.closeFloating() } label: { IconLabel("Remove", icon: "trash", size: 12) }.pill(.outline, .xs)
        }
      }
      .onAppear { name = o.label }
    } else { Note("This overlay is gone.") }
  }

  func rename() {
    let t = name.trimmingCharacters(in: .whitespaces)
    if !t.isEmpty { model.run("update_audio_overlay", ["id": .string(overlayId), "label": .string(t)]) }
  }
}
