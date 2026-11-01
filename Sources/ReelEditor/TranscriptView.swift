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
    if model.words.isEmpty {
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
            ForEach(model.paragraphs) { p in
              let part = titled.firstIndex(of: p.id)
              TranscriptParagraph(model: model, p: p, part: part, last: p.id == model.paragraphs.last?.id && model.extraWords.isEmpty, frames: frames)
                .id(p.id)
            }
            ExtraTranscript(model: model)
          }
          .coordinateSpace(.named("words"))
          // Drag across words to select them, as in the web editor; the menu then floats above the first one.
          .simultaneousGesture(DragGesture(minimumDistance: 4, coordinateSpace: .named("words")).onChanged { g in
            guard let a = wordAt(g.startLocation), let b = wordAt(g.location) else { return }
            model.selection = nil
            model.selectedWords = min(a, b)...max(a, b)
          })
          .overlay(alignment: .topLeading) { menu }
          .padding(.leading, 16).padding(.trailing, 32).padding(.top, 8).padding(.bottom, 48)
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
    if let r = model.selectedWords, let first = frames.rects[r.lowerBound] {
      let sel = model.words[r]
      let below = first.minY < 56
      let y = below ? (frames.rects[r.upperBound]?.maxY ?? first.maxY) + 8 : first.minY - 52
      SelectionMenu(canCut: sel.contains { !$0.cut }, canUncut: sel.contains { $0.cut }, words: sel.map(\.text).joined(separator: " "),
        cut: { model.cutSelection() }, uncut: { model.restoreSelection() },
        correct: { text in correct(r, text) },
        comment: { t in model.run("add_comment", ["from": .number(Double(r.lowerBound)), "to": .number(Double(r.upperBound)), "comment": .string(t)]) })
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

  var body: some View {
    let color = part.map { PART_COLORS[$0 % PART_COLORS.count] } ?? Ink.ghost
    let start = model.words[p.words].first { $0.s != nil }?.s ?? 0
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
        FlowLayout(spacing: TRANSCRIPT_WORD_GAP, lineSpacing: TRANSCRIPT_LINE_GAP) {
          ForEach(model.words[p.words]) { w in WordChip(model: model, w: w, frames: frames) }
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
    let current = model.currentWord == w.id
    Text(w.text)
      .font(.inter(TRANSCRIPT_SIZE))
      .strikethrough(w.cut, color: w.pending ? Ink.amber : Ink.red)
      .foregroundStyle(w.pending ? Ink.amber : w.cut ? Ink.ghost : current ? Ink.strong : Ink.text)
      .padding(.horizontal, TRANSCRIPT_WORD_PAD)
      .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Ink.select : w.pending ? Ink.amber.opacity(0.1) : current ? Ink.shell : hover ? Ink.sunken : .clear))
      .help(w.pending ? "Cut from the chat, waiting for your approval" : "")
      .onHover { hover = $0 }
      .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named("words")) }) { [frames, id = w.id] r in frames.rects[id] = r }
      .onTapGesture {
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
    let groups = Dictionary(grouping: model.extraWords, by: \.from).sorted { ($0.value.first?.s ?? 0) < ($1.value.first?.s ?? 0) }
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
