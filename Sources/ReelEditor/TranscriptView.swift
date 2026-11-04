// The transcript: every word, cut words struck through, the word being spoken lit up. Click a word to jump to it,
// shift click to select a run, then Delete cuts it (or Restore brings it back). Sections are headings.
import AppKit
import ReelCore
import SwiftUI

struct FlowLayout: Layout {
  var spacing: CGFloat = 2
  var lineSpacing: CGFloat = 4

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 600
    var x: CGFloat = 0, y: CGFloat = 0, line: CGFloat = 0
    for v in subviews {
      let s = v.sizeThatFits(.unspecified)
      if x > 0 && x + s.width > width { x = 0; y += line + lineSpacing; line = 0 }
      x += s.width + spacing; line = max(line, s.height)
    }
    return CGSize(width: width, height: y + line)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    var x = bounds.minX, y = bounds.minY, line: CGFloat = 0
    for v in subviews {
      let s = v.sizeThatFits(.unspecified)
      if x > bounds.minX && x + s.width > bounds.maxX { x = bounds.minX; y += line + lineSpacing; line = 0 }
      v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
      x += s.width + spacing; line = max(line, s.height)
    }
  }
}

// The colours a part's marker and heading take, in turn, as in the web transcript.
let PART_COLORS: [Color] = [0x2f7d3b, 0x2563eb, 0x7c3aed, 0xc2410c, 0x0f766e, 0xbe185d].map { Color(nsColor: NSColor(hex: $0)) }

// Where each word sits inside the transcript, kept outside SwiftUI's state so scrolling and laying out never redraw the
// transcript; read when a drag selects words and to place the selection menu.
final class WordFrames { var rects: [Int: CGRect] = [:] }

// The transcript's line height, 1.16 times its 16 point type (Sankalp, 31 Oct 2026): the gap between lines is what is
// left of 1.16 x 16 after Inter's own line height, a little below zero, so the lines sit close.
let TRANSCRIPT_SIZE: CGFloat = 16
let TRANSCRIPT_LINE_GAP: CGFloat = {
  guard let f = NSFont(name: "Inter-Regular", size: TRANSCRIPT_SIZE) else { return 0 }
  return TRANSCRIPT_SIZE * 1.16 - (f.ascender - f.descender + f.leading)
}()

// Each word is its own block, 2 points of padding on its left and right (room for its highlight) and 2 points between one
// block and the next, so the words are 6 points apart (Sankalp, 31 Oct 2026).
let TRANSCRIPT_WORD_PAD: CGFloat = 2
let TRANSCRIPT_WORD_GAP: CGFloat = 2

struct TranscriptView: View {
  @ObservedObject var model: EditorModel
  @State private var frames = WordFrames()

  var body: some View {
    // With no words at all, the clips are still listed in the order they play, each with its video's name and place in
    // the reel, so the pane is never blank (Sankalp, 4 Nov 2026); only a project with no clips shows the empty state.
    if model.paragraphs.isEmpty {
      VStack(spacing: 12) {
        Icon("chat-text", size: 32).foregroundStyle(Ink.muted)
        Text(model.loaded.project.main.hasAudio ? "No transcript yet" : "This video has no sound").font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
        Text("Transcribe the speech to cut by words. The video can still be cut on the timeline.").font(.inter(14)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
        if model.loaded.project.main.hasAudio {
          Button { model.transcribe() } label: { IconLabel("Transcribe with WhisperX", icon: "microphone", size: 14) }
            .pill(.primary, .md).disabled(model.status["state"]?.string == "transcribing")
        }
        if let m = model.status["message"]?.string, model.status["kind"]?.string == "transcribe" { Note(m) }
      }
      .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 0) {
            let titled = model.paragraphs.filter { $0.title != nil }.map(\.id)
            let lit = focusedParagraphs
            // Every paragraph in what Claude works on shimmers, the whole reel when it reads all of it (Sankalp, 2 Nov 2026).
            let working = Set(model.agentFocus.map(model.paragraphIds) ?? [])
            let clips = Set(model.paragraphs.map(\.clip)).count
            if model.words.isEmpty { TranscribeBar(model: model).padding(.leading, 72).padding(.bottom, 16) }
            ForEach(model.paragraphs) { p in
              let part = titled.firstIndex(of: p.id)
              // With more than one clip, each clip starts with its video's name, dragged to put the clips in a new order.
              let head = p.clipStart && (clips > 1 || model.words.isEmpty), lit1 = lit.contains(p.id)
              // A clip's first paragraph that Claude works on has its blue box round the clip's head too, from the head's
              // top to the paragraph's last line (Sankalp, 4 Nov 2026).
              VStack(alignment: .leading, spacing: 0) {
                if head { ClipHeadRow(model: model, p: p, first: p.id == model.paragraphs.first?.id) }
                TranscriptParagraph(model: model, p: p, part: part, last: p.id == model.paragraphs.last?.id, frames: frames,
                                    focus: lit1, glow: !head, focusLabel: p.id == lit.first ? model.agentFocus.map(Self.tag) : nil, shimmer: working.contains(p.id))
                  .id(p.id)
              }
              .background(alignment: .topLeading) {
                // The head starts 72 points in and the paragraph's words end 24 points above its bottom: the box reaches
                // 8 points past both, as a paragraph's own box does.
                if head && lit1 { FocusGlow().padding(EdgeInsets(top: -8, leading: 64, bottom: 16, trailing: -8)).transition(.opacity) }
              }
            }
            ExtraTranscript(model: model)
          }
          .coordinateSpace(.named("words"))
          // Drag across words to select them, as in the web editor; the menu then floats above the first one.
          .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("words")).onChanged { g in
            guard !model.claudeEditing else { return } // nothing is selected while Claude edits (Sankalp, 2 Nov 2026)
            guard let a = wordAt(g.startLocation), var b = wordAt(g.location) else { return }
            // A selection stays among one kind of word: the project's own video's, or another video's.
            if (a >= model.mainWordCount) != (b >= model.mainWordCount) { b = a }
            model.selection = nil
            model.selectedWords = min(a, b)...max(a, b)
          })
          .overlay(alignment: .topLeading) { menu }
          .padding(.leading, 16).padding(.trailing, 32).padding(.top, 8).padding(.bottom, 48)
        }
        // Work over much of the reel at once (the audit of the whole reel) is one line at the top, not every paragraph lit.
        .overlay(alignment: .top) {
          if let f = model.agentFocus, focusedParagraphs.isEmpty, !focused.isEmpty {
            FocusTag(text: Self.label(f) + ", " + Self.span(f)).padding(.top, 8).transition(.opacity.combined(with: .move(edge: .top)))
          }
        }
        // Follows Claude through the reel: the paragraph it works on comes into view, unless the video is playing.
        .onChange(of: focusedParagraphs.first) { _, p in
          guard let p, !model.clock.playing else { return }
          withAnimation(.easeInOut(duration: 0.4)) { proxy.scrollTo(p, anchor: .top) }
        }
        .onChange(of: model.currentWord) { _, w in
          guard model.follow, model.clock.playing, let w, let p = model.paragraphs.first(where: { $0.words.contains(w) }) else { return }
          withAnimation { proxy.scrollTo(p.id, anchor: .top) }
        }
      }
    }
  }
}

extension TranscriptView {
  // The paragraphs Claude is working on: every one with a word inside the span its tools last touched.
  var focused: [Int] { model.agentFocus.map { model.paragraphIds($0) } ?? [] }

  // The paragraphs lit up as being worked on: every one of the span that still has a kept or waiting word, however many
  // Claude reads at once, so Sankalp always sees which part it is on (Sankalp, 2 Nov 2026). Only work over nearly the
  // whole reel, such as the audit of all of it, is one line at the top instead.
  var focusedParagraphs: [Int] {
    let live = focused.filter { id in model.wordsOf(model.paragraphs[id]).contains { !$0.cut || $0.pending } }
    return model.isWide(focused) ? [] : live
  }

  static func span(_ f: AgentFocus) -> String {
    let t = { (x: Double) in timecode(x).components(separatedBy: ".")[0] }
    return "\(t(f.start)) to \(t(f.end))"
  }

  // "Claude is reading paragraph 3 of 40", from the action its tool reported; with the times when it names no paragraph.
  static func label(_ f: AgentFocus) -> String {
    let a = f.action.prefix(1).lowercased() + f.action.dropFirst()
    return "Claude is \(a)"
  }
  static func tag(_ f: AgentFocus) -> String { f.action.contains("paragraph") ? label(f) : label(f) + ", " + span(f) }

  // The word under a point of the transcript, or the nearest one on that line.
  func wordAt(_ p: CGPoint) -> Int? {
    var best: (Int, Double)? = nil
    for (i, r) in frames.rects {
      let dx = p.x < r.minX ? r.minX - p.x : p.x > r.maxX ? p.x - r.maxX : 0
      let dy = p.y < r.minY ? r.minY - p.y : p.y > r.maxY ? p.y - r.maxY : 0
      let d = dx + dy * 4
      if d == 0 { return i }
      if best == nil || d < best!.1 { best = (i, d) }
    }
    return best.flatMap { $0.1 < 120 ? $0.0 : nil }
  }

  // The selection menu, above the first selected word, or below the last when there is no room above.
  @ViewBuilder var menu: some View {
    if !model.claudeEditing, let r = model.selectedWords, let first = frames.rects[r.lowerBound] {
      let sel = model.words[r]
      let below = first.minY < 56
      let y = below ? (frames.rects[r.upperBound]?.maxY ?? first.maxY) + 8 : first.minY - 52
      let extra = model.selectionHasExtra
      SelectionMenu(canCut: sel.contains { !$0.cut }, canUncut: sel.contains { $0.cut }, words: extra ? nil : sel.map(\.text).joined(separator: " "),
        cut: { model.cutSelection() }, uncut: { model.restoreSelection() },
        correct: { text in correct(r, text) },
        comment: { t in
          // Saved on the reel, and sent to the chat's Claude at once (Sankalp, 2 Nov 2026).
          let on = "\"\(sel.map(\.text).joined(separator: " "))\" (words \(r.lowerBound) to \(r.upperBound), at \(timecode(sel.first?.s ?? 0).components(separatedBy: ".")[0]))"
          let span = model.selectedWordRange ?? (0, 0)
          let args: [String: JSON] = extra ? ["start": .number(round3(span.0)), "end": .number(round3(span.1)), "comment": .string(t)]
            : ["from": .number(Double(r.lowerBound)), "to": .number(Double(r.upperBound)), "comment": .string(t)]
          model.run("add_comment", args) { res in
            DirectChat.shared.sendComment(t, on: on, id: res["comment"]?["id"]?.string)
          }
        })
        .offset(x: max(0, first.minX - 8), y: y)
        .id("\(r.lowerBound)-\(r.upperBound)")
    }
  }

  // One word typed for each word selected, as the web editor asks; each changed word goes through correct_word.
  func correct(_ r: ClosedRange<Int>, _ text: String) -> String? {
    let next = text.split(whereSeparator: \.isWhitespace).map(String.init)
    guard next.count == r.count else { return "Type \(r.count) \(r.count == 1 ? "word" : "words"), one for each word selected" }
    for (k, i) in r.enumerated() where next[k] != model.words[i].text {
      model.run("correct_word", ["index": .number(Double(i)), "text": .string(next[k])])
    }
    return nil
  }
}

// One paragraph: its start time in a grey gutter, a ring and a line down the side tying the parts together, the part's
// heading in its colour when a section starts here, then the words.
struct TranscriptParagraph: View {
  @ObservedObject var model: EditorModel
  let p: Paragraph
  let part: Int?
  let last: Bool
  let frames: WordFrames
  var focus = false // Claude is working on this paragraph
  var glow = true // its own blue box; false when the box is drawn round its clip's head and it together
  var focusLabel: String? = nil // what it is doing, on the first such paragraph
  var shimmer = false // inside what Claude works on now

  var body: some View {
    let color = part.map { PART_COLORS[$0 % PART_COLORS.count] } ?? Ink.ghost
    // Not reached yet by Claude in the pass it is making, and with something left to review.
    let waiting = model.awaitsClaude(p.id) && model.wordsOf(p).contains { !$0.cut }
    let start = model.wordsOf(p).first { $0.s != nil }?.s ?? model.plan.clips.first { $0.id == p.clip }?.editStart ?? 0
    HStack(alignment: .top, spacing: 0) {
      Text(timecode(start).components(separatedBy: ".").first ?? "")
        .font(.inter(12)).foregroundStyle(Ink.faint).monospacedDigit()
        .frame(width: 48, alignment: .leading).padding(.top, 4)
      ZStack(alignment: .top) {
        if !last { Rectangle().fill(Ink.hairline).frame(width: 2).padding(.top, part != nil ? 20 : 0) }
        if part != nil { Circle().strokeBorder(color, lineWidth: 2).background(Circle().fill(Ink.page)).frame(width: 16, height: 16).padding(.top, 4) }
      }
      .frame(width: 16).frame(maxHeight: .infinity, alignment: .top)
      VStack(alignment: .leading, spacing: 8) {
        if let t = p.title { Text(t).font(.inter(16, .medium)).foregroundStyle(color) }
        if let focusLabel { FocusTag(text: focusLabel).transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .topLeading))) }
        if p.words.isEmpty {
          Text(model.status["state"]?.string == "transcribing" ? "No words yet, its video is being transcribed" : "No words in this clip: its video has no speech, or no transcript yet")
            .font(.inter(14)).foregroundStyle(Ink.faint)
        } else {
          FlowLayout(spacing: TRANSCRIPT_WORD_GAP, lineSpacing: TRANSCRIPT_LINE_GAP) {
            ForEach(model.wordsOf(p)) { w in WordChip(model: model, w: w, frames: frames) }
          }
          .shimmer(shimmer)
        }
      }
      // Blue while Claude works on it; a pale yellow wash while it waits for Claude to reach it, plain once Claude has been
      // through it (Sankalp, 2 Nov 2026). A paragraph whose cuts wait for approval has no box of its own: its cut words
      // show it, and Approve at the top (Sankalp, 2 Nov 2026).
      .background {
        if focus { if glow { FocusGlow().padding(-8).transition(.opacity) } }
        else if waiting {
          RoundedRectangle(cornerRadius: 12).fill(Ink.yellow.opacity(0.12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.yellow.opacity(0.4), lineWidth: 1))
            .padding(-8).transition(.opacity)
        }
      }
      .padding(.leading, 24).padding(.bottom, 24)
    }
  }
}

struct WordChip: View {
  @ObservedObject var model: EditorModel
  let w: WordView
  let frames: WordFrames
  @State private var hover = false

  var body: some View {
    let selected = model.selectedWords?.contains(w.id) == true
    // The word at the playhead in white on black, so it stands out as the video plays (Sankalp, 2 Nov 2026).
    let current = model.currentWord == w.id && !selected
    Text(w.text)
      .font(.inter(TRANSCRIPT_SIZE))
      .strikethrough(w.cut, color: w.pending ? Ink.amber : Ink.red)
      .foregroundStyle(current ? Ink.onPrimary : w.pending ? Ink.amber : w.cut ? Ink.ghost : Ink.text)
      .padding(.horizontal, TRANSCRIPT_WORD_PAD)
      .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Ink.select : current ? Ink.strong : w.pending ? Ink.amber.opacity(0.1) : hover ? Ink.sunken : .clear))
      .help(w.pending ? "Cut from the chat, waiting for your approval" : "")
      .onHover { hover = $0 }
      .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("words")) }) { [frames, id = w.id] r in frames.rects[id] = r }
      .onTapGesture {
        // While Claude edits a click only moves the playhead: no selection, so no Cut or Comment (Sankalp, 2 Nov 2026).
        if model.claudeEditing { if let s = w.s { model.seek(s) }; return }
        if NSEvent.modifierFlags.contains(.shift), let r = model.selectedWords {
          model.selectedWords = min(r.lowerBound, w.id)...max(r.upperBound, w.id)
        } else {
          model.selectedWords = w.id...w.id
          if let s = w.s { model.seek(s) }
        }
        model.selection = nil
      }
  }
}

// The words of the added clips and of the voice overs, under the main transcript, one part per clip or overlay, in
// italics. Clicking a word goes to it; they are cut with the timeline (their clips are trimmed, cut or muted there).
struct ExtraTranscript: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    // The voice overs only: the other videos' words are in the transcript above, in their clips.
    let overlays = Set((model.loaded.project.edits.audioOverlays ?? []).map(\.id))
    let groups = Dictionary(grouping: model.extraWords.filter { overlays.contains($0.from) }, by: \.from).sorted { ($0.value.first?.s ?? 0) < ($1.value.first?.s ?? 0) }
    ForEach(groups, id: \.key) { from, words in
      HStack(alignment: .top, spacing: 0) {
        Text(timecode(words.first?.s ?? 0).components(separatedBy: ".").first ?? "")
          .font(.inter(12)).foregroundStyle(Ink.faint).monospacedDigit()
          .frame(width: 48, alignment: .leading).padding(.top, 4)
        Circle().strokeBorder(Ink.muted, lineWidth: 2).frame(width: 16, height: 16).padding(.top, 4)
        VStack(alignment: .leading, spacing: 8) {
          Text(title(from)).font(.inter(16, .medium)).foregroundStyle(Ink.muted)
          FlowLayout(spacing: TRANSCRIPT_WORD_GAP, lineSpacing: TRANSCRIPT_LINE_GAP) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, w in
              Text(w.w).font(.inter(TRANSCRIPT_SIZE, italic: true)).foregroundStyle(Ink.secondary).padding(.horizontal, TRANSCRIPT_WORD_PAD)
                .onTapGesture { model.seek(w.s) }
            }
          }
        }
        .padding(.leading, 24).padding(.bottom, 24)
      }
    }
  }

  func title(_ from: String) -> String {
    if let o = model.loaded.project.edits.audioOverlays?.first(where: { $0.id == from }) { return "Voice over, \(o.label)" }
    if let s = model.loaded.project.edits.sources.first(where: { $0.id == from }) { return s.label }
    return from
  }
}

// The light on a paragraph Claude is working on: a blue wash and border that breathe while it works.
struct FocusGlow: View {
  @State private var on = false
  var body: some View {
    RoundedRectangle(cornerRadius: 12)
      .fill(Ink.focus.opacity(on ? 0.10 : 0.04))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.focus.opacity(on ? 0.45 : 0.2), lineWidth: 1))
      .onAppear { withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true } }
  }
}

// What Claude is doing, in a pill above the paragraph it works on: "Claude is reading paragraph 3 of 40".
struct FocusTag: View {
  let text: String
  var body: some View {
    HStack(spacing: 8) {
      Spinner(size: 12)
      BrandMark(name: "claude", size: 12)
      Text(text).font(.inter(12, .medium)).foregroundStyle(Ink.text).lineLimit(1)
    }
    .padding(.horizontal, 12).frame(height: 28)
    .background(Capsule().fill(Ink.page))
    .overlay(Capsule().strokeBorder(Ink.focus.opacity(0.45), lineWidth: 1))
    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
    .fixedSize()
  }
}

// The head of a clip in the transcript, when the reel has more than one: a grip, the clip's video and which part of it,
// and its length. Drag it onto another clip's head to put it before that clip (reorder_clips, one undo step). While
// Claude reads or places this clip's video, the head says so.
// A clip's head with a dot on the paragraphs' line beside it, so the clips and their paragraphs read as one timeline
// joined by that line, as the chat's rows are (Sankalp, 2 Nov 2026). The line runs on through the head into the
// paragraphs under it; above the first head there is none.
// Above the clips of a reel with no words yet: why there are none, the button that transcribes every video, and how
// the last transcription went.
struct TranscribeBar: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let busy = model.status["state"]?.string == "transcribing"
    let sound = model.loaded.project.main.hasAudio || model.loaded.project.edits.sources.contains(where: \.hasAudio)
    InsetCard(title: busy ? "Transcribing" : sound ? "No transcript yet" : "These videos have no sound", icon: "chat-text") {
      Text("Transcribe the speech to cut by words and show captions. The clips can still be cut and moved on the timeline.")
        .font(.inter(14)).foregroundStyle(Ink.secondary).fixedSize(horizontal: false, vertical: true)
      if sound {
        Button { model.transcribe() } label: { IconLabel(busy ? "Transcribing" : "Transcribe with WhisperX", icon: "microphone", size: 14) }
          .pill(.primary, .md).disabled(busy)
      }
      if let m = model.status["message"]?.string, model.status["kind"]?.string == "transcribe" { Note(m) }
    }
  }
}

struct ClipHeadRow: View {
  @ObservedObject var model: EditorModel
  let p: Paragraph
  let first: Bool

  var body: some View {
    HStack(alignment: .top, spacing: 0) {
      Color.clear.frame(width: 48, height: 1)
      ZStack(alignment: .top) {
        Rectangle().fill(Ink.hairline).frame(width: 2).padding(.top, first ? 16 : 0)
        Circle().fill(Ink.muted).frame(width: 8, height: 8).padding(3).background(Circle().fill(Ink.page)).padding(.top, 9)
      }
      .frame(width: 16).frame(maxHeight: .infinity, alignment: .top)
      ClipHeader(model: model, p: p).padding(.leading, 8).padding(.bottom, 12)
        .allowsHitTesting(!model.claudeEditing) // no reordering while Claude edits
    }
  }
}

struct ClipHeader: View {
  @ObservedObject var model: EditorModel
  let p: Paragraph
  @State private var target = false

  var body: some View {
    let c = model.plan.clips.first { $0.id == p.clip }
    HStack(spacing: 8) {
      Icon("dots-six-vertical", size: 14).foregroundStyle(Ink.faint)
      Icon(p.source == MAIN ? "film-strip" : "film-slate", size: 14).foregroundStyle(Ink.muted)
      Text(p.label).font(.inter(13, .semibold)).foregroundStyle(Ink.strong).lineLimit(1).truncationMode(.middle)
      if let c {
        Text("\(clipName(p.clip)), \(Self.time(c.inn)) to \(Self.time(c.out)) of the video, \(Self.time(c.length)) long")
          .font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(1)
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 12).frame(height: 32)
    .background(RoundedRectangle(cornerRadius: 8).fill(target ? Ink.select : Ink.sunken))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(target ? Ink.focus : Ink.border, lineWidth: 1))
    .contentShape(Rectangle())
    .draggable(p.clip) {
      Text(p.label).font(.inter(13, .semibold)).padding(.horizontal, 12).frame(height: 32)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.page)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.border, lineWidth: 1))
    }
    .dropDestination(for: String.self) { items, _ in
      guard let moved = items.first, moved != p.clip else { return false }
      var order = model.plan.clips.map(\.id).filter { $0 != moved }
      guard let at = order.firstIndex(of: p.clip) else { return false }
      order.insert(moved, at: at)
      model.run("reorder_clips", ["order": .array(order.map { .string($0) })])
      return true
    } isTargeted: { target = $0 }
    .help("Drag onto another clip's head to put this clip before it")
  }

  // Under a minute in tenths of a second, 4.5 s; longer as minutes and seconds, 2:05.
  static func time(_ t: Double) -> String { t < 60 ? String(format: "%.1f s", t) : timecode(t).components(separatedBy: ".")[0] }
}

// A clip as people read it (Sankalp, 2 Nov 2026): Clip 5 for the clip the tools call c5. The number is the clip's own and
// stays with it when clips are moved, so what is on screen always matches what Claude and the tools mean.
func clipName(_ id: String) -> String { id.hasPrefix("c") && Int(id.dropFirst()) != nil ? "Clip \(id.dropFirst())" : id }
