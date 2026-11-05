// The non destructive edit decision list (EDL) and every piece of cut logic that works on it, ported one to one from the
// web editor's lib/reel-edl.ts and lib/reel-cuts.ts. Pure functions only, so the app's preview, the export and the MCP
// tools all call the same code and what is previewed is what is exported.
//
// THREE TIMES
//   source time: seconds inside one source video file.
//   edit time:   the clips laid end to end, before any cut is taken out. Every time a tool passes or reads is edit time.
//   output time: edit time with the cuts taken out, then divided by the speed. The export is as long as the output.
// A range cut is stored per clip in source seconds, so trimming, splitting or reordering clips never moves a cut off the
// picture it was made on. The source files are never written.
import Foundation

public let MAIN = "main"
public let EPS = 1e-3
public let MIN_CLIP = 0.05
public let MIN_KEEP = 0.02
public func round3(_ n: Double) -> Double { (n * 1000).rounded() / 1000 }

public struct Word: Codable, Equatable, Sendable { public var w: String; public var s: Double; public var e: Double
  public init(w: String, s: Double, e: Double) { self.w = w; self.s = s; self.e = e }
}
public struct Range: Codable, Equatable, Sendable { public var s: Double; public var e: Double
  public init(s: Double, e: Double) { self.s = s; self.e = e }
}

public struct Source: Codable, Equatable, Sendable {
  public var id: String
  public var file: String // absolute path, only ever read
  public var duration: Double
  public var hasAudio: Bool
  public var width: Double
  public var height: Double
  public var label: String
  public var origin: String? = nil // the path the file was added from, as relink_source records it
}

// muteAudio: the clip's own sound is silent in the preview and the export, an audio overlay laid on it is heard instead.
// hideTitle: the reel's title is not shown over this clip. hideLook: no look at all on this clip's own picture; look: its own
// look in place of the reel's (a face window over it keeps the reel's). place: where its own picture sits in the frame.
public struct Clip: Codable, Equatable, Sendable {
  public var id: String
  public var source: String
  public var inn: Double
  public var out: Double
  public var label: String? = nil
  public var muteAudio: Bool? = nil
  public var hideTitle: Bool? = nil
  public var hideLook: Bool? = nil
  public var look: ReelLook? = nil
  public var place: ReelPlace? = nil
  enum CodingKeys: String, CodingKey { case id, source, inn = "in", out, label, muteAudio, hideTitle, hideLook, look, place }
}

// An audio file laid over the reel on a layer of its own, Voice over (the web editor's EdlAudioOverlay): file is its path, only
// ever read, start the edit time where it begins, in and out the seconds of the file that play, gain 0 to 2, duration the
// whole file. It stays at its edit time and follows the cuts like the clips' own sound; a ripple (a clip deleted, trimmed or
// put in before it) moves it with the picture that follows.
// window makes it a video overlay (the web editor's Face layer): its file is a video, its sound is the overlay's sound and its
// picture is drawn in the window, on the Face layer, or on the Video layer when layer is "video". sound marks a sound effect
// or music, played at exactly its own gain outside the voice volume. eq is its own bass and treble.
public struct AudioOverlay: Codable, Equatable, Sendable {
  public var id: String
  public var file: String
  public var label: String
  public var start: Double
  public var inn: Double
  public var out: Double
  public var gain: Double
  public var duration: Double
  public var window: FaceWindow? = nil
  public var sound: Bool? = nil
  public var origin: String? = nil
  public var eq: AudioEq? = nil
  public var layer: String? = nil // "video" puts a window on the Video layer instead of Face
  enum CodingKeys: String, CodingKey { case id, file, label, start, inn = "in", out, gain, duration, window, sound, origin, eq, layer }
  public init(id: String, file: String, label: String, start: Double, inn: Double, out: Double, gain: Double, duration: Double) {
    self.id = id; self.file = file; self.label = label; self.start = start; self.inn = inn; self.out = out; self.gain = gain; self.duration = duration
  }
  public init(id: String, file: String, label: String, start: Double, inn: Double, out: Double, gain: Double, duration: Double, window: FaceWindow?, sound: Bool? = nil, origin: String? = nil, eq: AudioEq? = nil, layer: String? = nil) {
    self.init(id: id, file: file, label: label, start: start, inn: inn, out: out, gain: gain, duration: duration)
    self.window = window; self.sound = sound; self.origin = origin; self.eq = eq; self.layer = layer
  }
  public var isFace: Bool { window != nil }
  public var isVoice: Bool { sound != true } // a voice is raised with the voice volume, a sound effect is not
}

// pending marks a cut made from the chat (an agent through MCP), not in the app, until Sankalp approves it (approve_cuts): it
// plays and exports as a cut, and the app can draw it in yellow.
public struct Cut: Codable, Equatable, Sendable { public var id: String; public var clip: String; public var start: Double; public var end: Double; public var pending: Bool? = nil }
public struct Section: Codable, Equatable, Sendable { public var id: String; public var title: String; public var from: Int }

public struct ExportOptions: Codable, Equatable, Sendable {
  public var captions: Bool?
  public var title: Bool?
  public var speed: Double?
}

public struct Edl: Codable, Equatable, Sendable {
  public var deleted: [Int] = [] // word indexes cut
  public var corrections: [String: String] = [:]
  public var sections: [Section]? = nil
  public var clips: [Clip]? = nil // nil means one clip, the whole main video
  public var sources: [Source] = [] // videos added besides the main one
  public var cuts: [Cut] = []
  public var export = ExportOptions()
  public var titleText: String? = nil // the burned in title, shown when export.title is on
  public var audioOverlays: [AudioOverlay]? = nil // the Voice over and Face layers, part of undo
  // Ported from the web editor after 23 Oct 2026. Every one of these is a setting or a record, not an undo step.
  public var pendingWords: [Int]? = nil // the words of deleted cut from the chat and not approved yet
  public var look: ReelLook? = nil // the look of the reel's picture (set_video_look)
  public var music: MusicSettings? = nil // the music bed (set_music)
  public var voiceGain: Double? = nil // all the voices together, 0 to 10, 1 (nil) is as recorded
  public var voiceEq: AudioEq? = nil // the bass and treble of all the voices together
  public var captionPos: CaptionPos? = nil // where this reel's captions sat before caption styles; captionStyle's x and y now
  public var captionStyle: TextStyle? = nil // the captions' own look, laid over the default (Captions.swift); part of undo
  public var captionHides: [CaptionHide]? = nil // stretches with no captions, edit seconds; part of undo
  public var caption: String? = nil // the caption to post with the reel
  public var status: String? = nil // draft (nil) or live
  public var posts: [ReelPost]? = nil // where the reel was published: a link per post (add_post_link)
  public var references: [ReelReference]? = nil // the documents the reel is made from
  public var cost: ReelCost? = nil // what its AI generations cost
  public init() {}
}

public struct EdlMain: Sendable { public var duration: Double; public var words: [Word]
  public init(duration: Double, words: [Word]) { self.duration = duration; self.words = words }
}

public struct EdlError: Error, CustomStringConvertible { public let code: String; public let message: String
  public init(_ code: String, _ message: String) { self.code = code; self.message = message }
  public var description: String { message }
}

// ---------------------------------------------------------------------------------------------------------------------
// Keeping the EDL tidy

public func defaultClip(_ main: EdlMain) -> Clip { Clip(id: "c1", source: MAIN, inn: 0, out: main.duration) }
public func clipsOf(_ edl: Edl, _ main: EdlMain) -> [Clip] { edl.clips ?? [defaultClip(main)] }

// A single clip that is the whole main video is stored as no clips at all.
public func canonical(_ edl: Edl, _ main: EdlMain) -> Edl {
  var out = edl
  if let c = edl.clips, c.count == 1, c[0].id == "c1", c[0].source == MAIN, abs(c[0].inn) < EPS, abs(c[0].out - main.duration) < EPS, c[0].muteAudio != true,
     c[0].hideTitle != true, c[0].hideLook != true, c[0].look == nil, c[0].place == nil, c[0].label == nil { out.clips = nil } // a named lone clip is kept, or its name is lost
  let ids = Set(clipsOf(out, main).map(\.id))
  out.cuts = edl.cuts.filter { ids.contains($0.clip) && $0.end - $0.start >= EPS }
  // The words waiting for approval are only ever words that are cut.
  if let pw = edl.pendingWords { let del = Set(edl.deleted); let keep = Array(Set(pw.filter { del.contains($0) })).sorted(); out.pendingWords = keep.isEmpty ? nil : keep }
  return out
}

// ---------------------------------------------------------------------------------------------------------------------
// The plan: what the EDL means as clips, cuts, kept ranges and an output length

public struct PlanClip: Equatable, Sendable { public var clip: Clip; public var editStart: Double; public var editEnd: Double; public var length: Double
  public var id: String { clip.id }; public var source: String { clip.source }; public var inn: Double { clip.inn }; public var out: Double { clip.out }
}
// look: the clip's own look, lookOff: no look at all on it (nil both: the reel's look), place: where its picture sits.
public struct PlanSegment: Codable, Equatable, Sendable { public var clip: String; public var source: String; public var inn: Double; public var out: Double; public var outStart: Double; public var outEnd: Double; public var mute: Bool? = nil
  public var look: ReelLook? = nil; public var lookOff: Bool? = nil; public var place: ReelPlace? = nil
  enum CodingKeys: String, CodingKey { case clip, source, inn = "in", out, outStart, outEnd, mute, look, lookOff, place }
}
public struct PlanRangeCut: Codable, Equatable, Sendable { public var id: String; public var clip: String; public var start: Double; public var end: Double; public var s: Double; public var e: Double; public var pending: Bool? = nil }

public struct Plan: Sendable {
  public var clips: [PlanClip]
  public var editDuration: Double
  public var cuts: [Range]
  public var rangeCuts: [PlanRangeCut]
  public var wordCuts: [Range]
  public var keep: [Range]
  public var segments: [PlanSegment]
  public var duration: Double // output length before speed
}

// Runs of deleted words become one cut each, from the first word's start to the next kept word's start.
public func cutRanges(_ words: [Word], _ deleted: Set<Int>, _ duration: Double) -> [Range] {
  var cuts: [Range] = []
  var i = 0
  while i < words.count {
    if !deleted.contains(i) { i += 1; continue }
    var j = i
    while j + 1 < words.count && deleted.contains(j + 1) { j += 1 }
    cuts.append(Range(s: words[i].s, e: j + 1 < words.count ? words[j + 1].s : duration))
    i = j + 1
  }
  return cuts
}

public func mergeRanges(_ list: [Range]) -> [Range] {
  let sorted = list.filter { $0.e > $0.s }.sorted { $0.s < $1.s }
  var out: [Range] = []
  for r in sorted {
    if let last = out.last, r.s <= last.e + EPS { out[out.count - 1].e = max(last.e, r.e) } else { out.append(r) }
  }
  return out
}

public func buildPlan(_ edl: Edl, _ main: EdlMain) -> Plan {
  func srcDuration(_ id: String) -> Double { id == MAIN ? main.duration : edl.sources.first { $0.id == id }?.duration ?? 0 }
  var at = 0.0
  var clips: [PlanClip] = []
  for c in clipsOf(edl, main) {
    let d = srcDuration(c.source)
    let out = min(c.out, d > 0 ? d : c.out)
    let inn = min(c.inn, out)
    let length = max(0, out - inn)
    var cc = c; cc.inn = inn; cc.out = out
    if length > 0 { clips.append(PlanClip(clip: cc, editStart: at, editEnd: at + length, length: length)); at += length }
  }
  let editDuration = at

  var rangeCuts: [PlanRangeCut] = []
  for cut in edl.cuts {
    guard let c = clips.first(where: { $0.id == cut.clip }) else { continue }
    let a = max(cut.start, c.inn), b = min(cut.end, c.out)
    if b - a < EPS { continue }
    rangeCuts.append(PlanRangeCut(id: cut.id, clip: c.id, start: a, end: b, s: c.editStart + (a - c.inn), e: c.editStart + (b - c.inn), pending: cut.pending == true ? true : nil))
  }

  var wordCuts: [Range] = []
  if !edl.deleted.isEmpty && !main.words.isEmpty {
    for run in cutRanges(main.words, Set(edl.deleted), main.duration) {
      for c in clips where c.source == MAIN {
        let a = max(run.s, c.inn), b = min(run.e, c.out)
        if b - a > EPS { wordCuts.append(Range(s: c.editStart + (a - c.inn), e: c.editStart + (b - c.inn))) }
      }
    }
  }

  var cuts = mergeRanges(rangeCuts.map { Range(s: $0.s, e: $0.e) } + wordCuts)
  func keepOf(_ cs: [Range]) -> [Range] {
    var keep: [Range] = []
    var from = 0.0
    for c in cs { if c.s - from > EPS { keep.append(Range(s: from, e: c.s)) }; from = max(from, c.e) }
    if editDuration - from > EPS { keep.append(Range(s: from, e: editDuration)) }
    return keep
  }
  var keep = keepOf(cuts)
  let slivers = keep.filter { $0.e - $0.s < MIN_KEEP }
  if !slivers.isEmpty { cuts = mergeRanges(cuts + slivers); keep = keepOf(cuts) }

  var segments: [PlanSegment] = []
  var outAt = 0.0
  for k in keep {
    for c in clips {
      let a = max(k.s, c.editStart), b = min(k.e, c.editEnd)
      if b - a <= EPS { continue }
      let seg = PlanSegment(clip: c.id, source: c.source, inn: c.inn + (a - c.editStart), out: c.inn + (b - c.editStart), outStart: outAt, outEnd: outAt + (b - a), mute: c.clip.muteAudio == true ? true : nil,
                            look: c.clip.hideLook == true ? nil : c.clip.look, lookOff: c.clip.hideLook == true ? true : nil, place: c.clip.place)
      if let last = segments.last, last.source == seg.source, (last.mute == true) == (seg.mute == true), last.look == seg.look, last.lookOff == seg.lookOff, last.place == seg.place,
         abs(last.out - seg.inn) < EPS, abs(last.outEnd - seg.outStart) < EPS {
        segments[segments.count - 1].out = seg.out; segments[segments.count - 1].outEnd = seg.outEnd; segments[segments.count - 1].clip = seg.clip
      } else { segments.append(seg) }
      outAt += b - a
    }
  }
  return Plan(clips: clips, editDuration: editDuration, cuts: cuts, rangeCuts: rangeCuts, wordCuts: wordCuts, keep: keep, segments: segments, duration: outAt)
}

// An edit time as an output time (before speed): the cuts before it taken out.
public func outputOf(_ plan: Plan, _ t: Double) -> Double { t - plan.cuts.reduce(0) { $0 + max(0, min(t, $1.e) - $1.s) } }

// An output time (before speed) back to edit time, the first kept moment at or after it.
public func editOf(_ plan: Plan, _ o: Double) -> Double {
  var acc = 0.0
  for k in plan.keep {
    let len = k.e - k.s
    if o <= acc + len + EPS { return k.s + max(0, o - acc) }
    acc += len
  }
  return plan.editDuration
}

public func locate(_ plan: Plan, _ t: Double) -> (clip: PlanClip, sourceTime: Double)? {
  guard let first = plan.clips.first, let last = plan.clips.last else { return nil }
  let clip = plan.clips.first { t >= $0.editStart && t < $0.editEnd } ?? (t >= last.editEnd ? last : first)
  return (clip, max(clip.inn, min(clip.out, clip.inn + (t - clip.editStart))))
}

// Where each word of the main video sits in edit time, nil for a word no clip plays.
public func mapWords(_ plan: Plan, _ words: [Word]) -> [Range?] {
  words.map { w in
    let mid = (w.s + w.e) / 2
    guard let c = plan.clips.first(where: { $0.source == MAIN && mid >= $0.inn && mid < $0.out }) else { return nil }
    return Range(s: c.editStart + max(w.s, c.inn) - c.inn, e: c.editStart + min(w.e, c.out) - c.inn)
  }
}

public func wordsCut(_ plan: Plan, _ edl: Edl, _ words: [Word]) -> [Bool] {
  let mapped = mapWords(plan, words)
  let explicit = Set(edl.deleted)
  return words.indices.map { i in
    guard let m = mapped[i], !explicit.contains(i) else { return true }
    let mid = (m.s + m.e) / 2
    return plan.cuts.contains { mid >= $0.s && mid < $0.e }
  }
}

// The parts of an audio overlay that are heard: its span in edit time cut by the plan's cuts, each as the seconds of the file
// and where it starts in the output (before speed).
public func overlayPieces(_ plan: Plan, _ o: AudioOverlay) -> [(fileIn: Double, fileOut: Double, outStart: Double)] {
  let spanEnd = o.start + (o.out - o.inn)
  return plan.keep.compactMap { k in
    let a = max(k.s, o.start), b = min(k.e, spanEnd)
    return b - a > EPS ? (o.inn + (a - o.start), o.inn + (b - o.start), outputOf(plan, a)) : nil
  }
}

// The words of the project's added videos (by source id) and of its audio overlays (by file), each in seconds of its own
// file, so a project made of several clips has the spoken words of every one in its captions.
public struct ExtraWords: Sendable { public var sources: [String: [Word]] = [:]; public var overlays: [String: [Word]] = [:]
  public init(sources: [String: [Word]] = [:], overlays: [String: [Word]] = [:]) { self.sources = sources; self.overlays = overlays }
  public var isEmpty: Bool { sources.values.allSatisfy(\.isEmpty) && overlays.values.allSatisfy(\.isEmpty) }
}
public struct ExtraEditWord: Sendable { public var w: String; public var s: Double; public var e: Double; public var from: String }

// Whether a word of the main video is spoken in a clip whose own sound is muted: then it is not in the captions.
public func inMutedClip(_ plan: Plan, _ w: Word) -> Bool {
  let mid = (w.s + w.e) / 2
  return plan.clips.first { $0.source == MAIN && mid >= $0.inn && mid < $0.out }?.clip.muteAudio == true
}

// The extra words in edit time, in play order. A word of an added video belongs to the first clip of it that it falls in
// by its middle, and is left out when that clip is muted. An overlay's words sit from its start.
public func extraEditWords(_ plan: Plan, _ edl: Edl, _ extra: ExtraWords) -> [ExtraEditWord] {
  var out: [ExtraEditWord] = []
  for (id, words) in extra.sources where id != MAIN {
    for w in words {
      let mid = (w.s + w.e) / 2
      guard let c = plan.clips.first(where: { $0.source == id && mid >= $0.inn && mid < $0.out }), c.clip.muteAudio != true else { continue }
      out.append(ExtraEditWord(w: w.w, s: c.editStart + max(w.s, c.inn) - c.inn, e: c.editStart + min(w.e, c.out) - c.inn, from: id))
    }
  }
  for o in edl.audioOverlays ?? [] {
    for w in extra.overlays[o.file] ?? [] {
      let mid = (w.s + w.e) / 2
      if mid < o.inn || mid >= o.out { continue }
      out.append(ExtraEditWord(w: w.w, s: o.start + max(w.s, o.inn) - o.inn, e: o.start + min(w.e, o.out) - o.inn, from: o.id))
    }
  }
  return out.sorted { $0.s < $1.s }
}

// The words that stay, corrected and in output time (before speed), what the captions are drawn from: the main video's
// words and the extra ones, the words of a muted clip and everything inside a cut left out.
public func outputWords(_ plan: Plan, _ edl: Edl, _ words: [Word], _ extra: ExtraWords = ExtraWords()) -> [Word] {
  let mapped = mapWords(plan, words)
  let cut = wordsCut(plan, edl, words)
  var out: [Word] = []
  for (i, w) in words.enumerated() {
    guard !cut[i], let m = mapped[i], !inMutedClip(plan, w) else { continue }
    out.append(Word(w: edl.corrections[String(i)] ?? w.w, s: outputOf(plan, m.s), e: outputOf(plan, m.e)))
  }
  if !extra.isEmpty {
    for ew in extraEditWords(plan, edl, extra) {
      let mid = (ew.s + ew.e) / 2
      if plan.cuts.contains(where: { mid >= $0.s && mid < $0.e }) { continue }
      out.append(Word(w: ew.w, s: outputOf(plan, ew.s), e: outputOf(plan, ew.e)))
    }
    out.sort { $0.s < $1.s }
  }
  return out
}

// A readable default label for a clip added by its file path: the base name without its extension, build tokens at the end
// dropped (voiced, v2, pip, 1.1x, captioned, original, heygen), dashes and underscores made spaces, "part2" split to
// "part 2", the first letter capital. part2-login-and-city-voiced-v4.mp4 is "Part 2 login and city".
public func humanClipLabel(_ fileName: String) -> String {
  let last = (fileName as NSString).lastPathComponent
  let base = last.replacingOccurrences(of: "\\.[A-Za-z0-9]{2,4}$", with: "", options: .regularExpression)
  var tokens = base.split(whereSeparator: { $0 == "-" || $0 == "_" || $0 == " " }).map(String.init)
  let build = try! NSRegularExpression(pattern: "^(voiced|v\\d+|pip|captioned|original|heygen|\\d+(\\.\\d+)?x)$", options: .caseInsensitive)
  while tokens.count > 1, let t = tokens.last, build.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil { tokens.removeLast() }
  let split = try! NSRegularExpression(pattern: "^([A-Za-z]+)(\\d+)$")
  let words = tokens.flatMap { t -> [String] in
    if let m = split.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let a = Swift.Range(m.range(at: 1), in: t), let b = Swift.Range(m.range(at: 2), in: t) { return [String(t[a]), String(t[b])] }
    return [t]
  }
  let text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
  return text.isEmpty ? last : text.prefix(1).uppercased() + text.dropFirst()
}

// The audio overlays cleaned: a file, a start of 0 or more, a part at least MIN_CLIP long, a gain of 0 to 2, sorted by
// start, each with an id (o1, o2 and so on).
public func normalizeOverlays(_ list: [AudioOverlay]) -> [AudioOverlay] {
  var clean = list.filter { !$0.file.isEmpty && $0.duration > MIN_CLIP && $0.start >= 0 }.map { x -> AudioOverlay in
    var o = x
    o.duration = round3(x.duration)
    o.inn = round3(max(0, min(x.inn, o.duration - MIN_CLIP)))
    o.out = max(x.out > o.inn + MIN_CLIP / 2 ? round3(min(x.out, o.duration)) : o.duration, round3(o.inn + MIN_CLIP))
    o.start = round3(x.start)
    o.gain = round3(max(0, min(2, x.gain)))
    let label = x.label.trimmingCharacters(in: .whitespaces)
    o.label = label.isEmpty ? (x.file as NSString).lastPathComponent : String(label.prefix(80))
    o.window = normalizeWindow(x.window)
    o.sound = x.sound == true && o.window == nil ? true : nil
    o.eq = normalizeEq(x.eq)
    o.layer = x.layer == "video" && o.window != nil ? "video" : nil
    return o
  }.sorted { $0.start < $1.start }
  var taken = Set(clean.map(\.id).filter { !$0.isEmpty })
  for i in clean.indices where clean[i].id.isEmpty {
    var n = 1
    while taken.contains("o\(n)") { n += 1 }
    clean[i].id = "o\(n)"; taken.insert("o\(n)")
  }
  return clean
}

public func exportFlags(_ edl: Edl, hasWords: Bool) -> (captions: Bool, title: Bool) {
  (edl.export.captions ?? hasWords, edl.export.title ?? !(edl.titleText ?? "").isEmpty)
}

// ---------------------------------------------------------------------------------------------------------------------
// Edits. Each takes an EDL and returns a new one. All times are seconds.

public struct OpResult { public var edl: Edl; public var info: [String: JSON] = [:] }

func materialize(_ edl: Edl, _ main: EdlMain) -> Edl { var e = edl; if e.clips == nil { e.clips = [defaultClip(main)] }; return e }
func nextId(_ prefix: String, _ taken: [String]) -> String { var n = 1; while taken.contains("\(prefix)\(n)") { n += 1 }; return "\(prefix)\(n)" }
func sourceDuration(_ edl: Edl, _ main: EdlMain, _ id: String) -> Double { id == MAIN ? main.duration : edl.sources.first { $0.id == id }?.duration ?? 0 }
func findClip(_ edl: Edl, _ id: String) throws -> Clip {
  guard let c = edl.clips?.first(where: { $0.id == id }) else { throw EdlError("no_such_clip", "No clip with id \(id). Clips: \((edl.clips ?? []).map(\.id).joined(separator: ", "))") }
  return c
}

// When clips ripple (one is deleted, trimmed or put in before others) the audio overlays that start at or after edit time `at`
// move by `delta` with the picture that follows. One that started inside a removed span moves to its start. Splitting and
// reordering move nothing.
func rippleOverlays(_ edl: Edl, at: Double, delta: Double, removedTo: Double? = nil) -> (overlays: [AudioOverlay]?, moved: [JSON]) {
  guard let list = edl.audioOverlays, !list.isEmpty else { return (edl.audioOverlays, []) }
  var moved: [JSON] = []
  let next = list.map { o -> AudioOverlay in
    var to = o.start
    if o.start >= (removedTo ?? at) - EPS { to = max(0, round3(o.start + delta)) }
    else if removedTo != nil && o.start > at + EPS { to = round3(at) }
    if abs(to - o.start) < EPS { return o }
    moved.append(["id": .string(o.id), "from": .number(o.start), "to": .number(to)])
    var x = o; x.start = to; return x
  }.sorted { $0.start < $1.start }
  return (next, moved)
}

private func pieces(_ plan: Plan, _ s: Double, _ e: Double) -> [(clip: String, start: Double, end: Double)] {
  plan.clips.compactMap { c in
    let a = max(s, c.editStart), b = min(e, c.editEnd)
    return b - a > EPS ? (c.id, round3(c.inn + (a - c.editStart)), round3(c.inn + (b - c.editStart))) : nil
  }
}

private func checkRange(_ plan: Plan, _ start: Double, _ end: Double) throws -> (Double, Double) {
  let s = round3(max(0, start)), e = round3(min(plan.editDuration, end))
  if e - s < EPS { throw EdlError("invalid_range", "The range \(start) to \(end) is empty or outside the reel, which is \(round3(plan.editDuration)) s long before cuts") }
  return (s, e)
}

public func cutRange(_ edl: Edl, _ main: EdlMain, _ start: Double, _ end: Double, pending: Bool = false) throws -> OpResult {
  let base = materialize(edl, main)
  let plan = buildPlan(base, main)
  let (s, e) = try checkRange(plan, start, end)
  var cuts = base.cuts
  var made: [String] = []
  for p in pieces(plan, s, e) {
    // A cut from the chat joins only other cuts waiting for approval, and an approved cut only approved ones, so each keeps its colour.
    let touching = cuts.filter { $0.clip == p.clip && ($0.pending == true) == pending && $0.start <= p.end + EPS && $0.end >= p.start - EPS }
    let a = ([p.start] + touching.map(\.start)).min()!, b = ([p.end] + touching.map(\.end)).max()!
    let id = touching.first?.id ?? nextId("x", cuts.map(\.id))
    cuts.removeAll { c in touching.contains { $0.id == c.id } }
    cuts.append(Cut(id: id, clip: p.clip, start: round3(a), end: round3(b), pending: pending ? true : nil))
    made.append(id)
  }
  var b2 = base; b2.cuts = cuts
  return OpResult(edl: canonical(b2, main), info: ["cuts": .array(made.map { .string($0) })])
}

public func restoreRange(_ edl: Edl, _ main: EdlMain, _ start: Double, _ end: Double) throws -> OpResult {
  let base = materialize(edl, main)
  let plan = buildPlan(base, main)
  let (s, e) = try checkRange(plan, start, end)
  var cuts = base.cuts
  for p in pieces(plan, s, e) {
    var next: [Cut] = []
    for c in cuts {
      if c.clip != p.clip || c.end <= p.start + EPS || c.start >= p.end - EPS { next.append(c); continue }
      if c.start < p.start - EPS { var x = c; x.end = p.start; next.append(x) }
      if c.end > p.end + EPS { next.append(Cut(id: c.start < p.start - EPS ? nextId("x", (cuts + next).map(\.id)) : c.id, clip: c.clip, start: p.end, end: c.end, pending: c.pending)) }
    }
    cuts = next
  }
  var b2 = base; b2.cuts = cuts
  return OpResult(edl: canonical(b2, main))
}

// Moves the edges of the cut at edit time at to start and end (Sankalp, 4 Nov 2026): the timeline's handles on a cut, and
// resize_cut. The cut there, a range cut or a run of cut words or both joined, is restored, its words with it, and the new
// span is cut as one range, waiting for approval when any part of the old cut was. One undo step.
public func resizeCut(_ edl: Edl, _ main: EdlMain, at: Double, start: Double, end: Double) throws -> OpResult {
  let base = materialize(edl, main)
  let plan = buildPlan(base, main)
  guard let old = plan.cuts.first(where: { at >= $0.s - EPS && at <= $0.e + EPS }) else {
    throw EdlError("not_found", "No cut at \(round3(at)) s. The cuts are at \(plan.cuts.prefix(12).map { "\(round3($0.s)) to \(round3($0.e))" }.joined(separator: ", "))")
  }
  let mid = { (i: Int) -> Double? in
    guard i < main.words.count else { return nil }
    let w = main.words[i]
    return plan.clips.first { $0.source == MAIN && (w.s + w.e) / 2 >= $0.inn && (w.s + w.e) / 2 < $0.out }.map { $0.editStart + (w.s + w.e) / 2 - $0.inn }
  }
  let words = base.deleted.filter { i in mid(i).map { $0 >= old.s - EPS && $0 <= old.e + EPS } ?? false }
  let pendingWords = Set(base.pendingWords ?? [])
  let pending = plan.rangeCuts.contains { $0.pending == true && $0.e > old.s + EPS && $0.s < old.e - EPS } || words.contains { pendingWords.contains($0) }
  var e = try restoreRange(base, main, old.s, old.e).edl
  if !words.isEmpty { e = try restoreWords(e, main, words).edl }
  let r = try cutRange(e, main, start, end, pending: pending)
  var info = r.info
  info["from"] = ["start": .number(round3(old.s)), "end": .number(round3(old.e))]
  info["start"] = .number(round3(max(0, start))); info["end"] = .number(round3(min(plan.editDuration, end)))
  info["pending"] = .bool(pending)
  return OpResult(edl: r.edl, info: info)
}

private func checkWords(_ main: EdlMain, _ indexes: [Int]) throws {
  for i in indexes where i < 0 || i >= main.words.count { throw EdlError("invalid_word", "No word with index \(i). The reel has \(main.words.count) words") }
}

public func deleteWords(_ edl: Edl, _ main: EdlMain, _ indexes: [Int], pending: Bool = false) throws -> OpResult {
  try checkWords(main, indexes)
  let was = Set(edl.deleted)
  var e = edl; e.deleted = Array(Set(edl.deleted + indexes)).sorted()
  if pending { let pw = Array(Set((edl.pendingWords ?? []) + indexes.filter { !was.contains($0) })).sorted(); e.pendingWords = pw.isEmpty ? nil : pw }
  return OpResult(edl: e)
}

public func restoreWords(_ edl: Edl, _ main: EdlMain, _ indexes: [Int]) throws -> OpResult {
  try checkWords(main, indexes)
  let drop = Set(indexes)
  var e = edl; e.deleted = edl.deleted.filter { !drop.contains($0) }
  let pw = (edl.pendingWords ?? []).filter { !drop.contains($0) }
  e.pendingWords = pw.isEmpty ? nil : pw
  return OpResult(edl: e)
}

// Approves cuts made from the chat: the range cuts by id and the cut words by index, or every waiting one when neither is given.
// An approved cut stays cut and is drawn like any other.
public func approveCuts(_ edl: Edl, ids: [String]?, words: [Int]?) -> OpResult {
  let all = (ids ?? []).isEmpty && (words ?? []).isEmpty
  let idSet = Set(ids ?? []), wordSet = Set(words ?? [])
  var e = edl
  e.cuts = edl.cuts.map { c in c.pending == true && (all || idSet.contains(c.id)) ? Cut(id: c.id, clip: c.clip, start: c.start, end: c.end) : c }
  let left = all ? [] : (edl.pendingWords ?? []).filter { !wordSet.contains($0) }
  e.pendingWords = left.isEmpty ? nil : left
  return OpResult(edl: e, info: ["waiting": .number(Double(e.cuts.filter { $0.pending == true }.count + left.count))])
}

public func correctWord(_ edl: Edl, _ main: EdlMain, _ index: Int, _ text: String?) throws -> OpResult {
  try checkWords(main, [index])
  var e = edl
  if let t = text, !t.isEmpty, t != main.words[index].w { e.corrections[String(index)] = t } else { e.corrections.removeValue(forKey: String(index)) }
  return OpResult(edl: e)
}

public func trimClip(_ edl: Edl, _ main: EdlMain, _ clipId: String, _ inn: Double?, _ out: Double?) throws -> OpResult {
  var base = materialize(edl, main)
  let c = try findClip(base, clipId)
  let dur = sourceDuration(base, main, c.source)
  let nIn = round3(inn ?? c.inn), nOut = round3(out.map { min($0, dur) } ?? c.out)
  if nIn < 0 { throw EdlError("invalid_range", "in must be 0 or more") }
  if nOut - nIn < MIN_CLIP { throw EdlError("invalid_range", "A clip has to be at least \(MIN_CLIP) s long, the source is \(round3(dur)) s") }
  if nIn > dur - MIN_CLIP { throw EdlError("invalid_range", "in \(nIn) is past the end of the source, \(round3(dur)) s") }
  let old = buildPlan(base, main).clips.first { $0.id == clipId }
  base.clips = base.clips!.map { $0.id == clipId ? { var x = $0; x.inn = nIn; x.out = nOut; return x }($0) : $0 }
  base.cuts = base.cuts.compactMap { x in
    if x.clip != clipId { return x }
    let a = max(x.start, nIn), b = min(x.end, nOut)
    return b - a >= EPS ? Cut(id: x.id, clip: x.clip, start: round3(a), end: round3(b)) : nil
  }
  var moved: [JSON] = []
  if let old { let r = rippleOverlays(base, at: old.editEnd, delta: (nOut - nIn) - old.length); base.audioOverlays = r.overlays; moved = r.moved }
  return OpResult(edl: canonical(base, main), info: moved.isEmpty ? [:] : ["overlaysMoved": .array(moved)])
}

public func splitClip(_ edl: Edl, _ main: EdlMain, _ at: Double) throws -> OpResult {
  var base = materialize(edl, main)
  let plan = buildPlan(base, main)
  if at < -EPS || at > plan.editDuration + EPS { throw EdlError("invalid_time", "at \(at) is outside the reel, which is \(round3(plan.editDuration)) s long before cuts") }
  guard let hit = locate(plan, at) else { throw EdlError("no_clips", "The reel has no clips") }
  let clip = hit.clip
  if at - clip.editStart < MIN_CLIP || clip.editEnd - at < MIN_CLIP { return OpResult(edl: canonical(base, main), info: ["split": .bool(false), "reason": .string("at a clip boundary")]) }
  let t = round3(hit.sourceTime)
  let id = nextId("c", base.clips!.map(\.id))
  var clips: [Clip] = []
  for c in base.clips! {
    if c.id != clip.id { clips.append(c); continue }
    var a = c; a.out = t
    clips.append(a)
    clips.append(Clip(id: id, source: c.source, inn: t, out: c.out, label: c.label, muteAudio: c.muteAudio, hideTitle: c.hideTitle, hideLook: c.hideLook, look: c.look, place: c.place))
  }
  var cuts: [Cut] = []
  for x in base.cuts {
    if x.clip != clip.id { cuts.append(x); continue }
    if x.start < t - EPS { var y = x; y.end = min(x.end, t); cuts.append(y) }
    if x.end > t + EPS { cuts.append(Cut(id: x.start < t - EPS ? nextId("x", (base.cuts + cuts).map(\.id)) : x.id, clip: id, start: max(x.start, t), end: x.end, pending: x.pending)) }
  }
  base.clips = clips; base.cuts = cuts
  return OpResult(edl: canonical(base, main), info: ["split": .bool(true), "created": .string(id)])
}

public func deleteClip(_ edl: Edl, _ main: EdlMain, _ clipId: String) throws -> OpResult {
  var base = materialize(edl, main)
  _ = try findClip(base, clipId)
  if base.clips!.count == 1 { throw EdlError("last_clip", "The reel needs at least one clip, trim it or cut a range instead") }
  var moved: [JSON] = []
  if let gone = buildPlan(base, main).clips.first(where: { $0.id == clipId }) {
    let r = rippleOverlays(base, at: gone.editStart, delta: -gone.length, removedTo: gone.editEnd); base.audioOverlays = r.overlays; moved = r.moved
  }
  base.clips = base.clips!.filter { $0.id != clipId }
  base.cuts = base.cuts.filter { $0.clip != clipId }
  return OpResult(edl: canonical(base, main), info: moved.isEmpty ? [:] : ["overlaysMoved": .array(moved)])
}

public func reorderClips(_ edl: Edl, _ main: EdlMain, _ order: [String]) throws -> OpResult {
  var base = materialize(edl, main)
  let ids = base.clips!.map(\.id)
  if order.count != ids.count || Set(order).count != ids.count || !order.allSatisfy(ids.contains) {
    throw EdlError("invalid_order", "order has to list every clip id exactly once: \(ids.joined(separator: ", "))")
  }
  base.clips = order.map { id in base.clips!.first { $0.id == id }! }
  return OpResult(edl: canonical(base, main))
}

// Adds a clip of a video (a new source, or one already used, or the main video when source is nil).
public func addClip(_ edl: Edl, _ main: EdlMain, _ source: Source?, _ inn: Double?, _ out: Double?, _ index: Int?) throws -> OpResult {
  var base = materialize(edl, main)
  var sourceId = MAIN, dur = main.duration
  if let src = source {
    if let known = base.sources.first(where: { $0.file == src.file }) { sourceId = known.id; dur = known.duration }
    else { sourceId = nextId("s", base.sources.map(\.id)); dur = src.duration; var s = src; s.id = sourceId; base.sources.append(s) }
  }
  let nIn = round3(inn ?? 0), nOut = round3(min(out ?? dur, dur))
  if nOut - nIn < MIN_CLIP || nIn < 0 { throw EdlError("invalid_range", "in and out have to be inside the video, which is \(round3(dur)) s long, and at least \(MIN_CLIP) s apart") }
  let id = nextId("c", base.clips!.map(\.id))
  let clip = Clip(id: id, source: sourceId, inn: nIn, out: nOut, label: source?.label)
  var clips = base.clips!
  let at = index.map { max(0, min(clips.count, $0)) } ?? clips.count
  // A clip put in before others moves them later, and the audio overlays that start after that point move with them.
  var moved: [JSON] = []
  if at < clips.count {
    let insertAt = buildPlan(base, main).clips.prefix(at).reduce(0) { $0 + $1.length }
    let r = rippleOverlays(base, at: insertAt, delta: nOut - nIn); base.audioOverlays = r.overlays; moved = r.moved
  }
  clips.insert(clip, at: at)
  base.clips = clips
  var info: [String: JSON] = ["created": .string(id), "source": .string(sourceId)]
  if !moved.isEmpty { info["overlaysMoved"] = .array(moved) }
  return OpResult(edl: canonical(base, main), info: info)
}

// ---------------------------------------------------------------------------------------------------------------------
// Audio overlays, muted clips and clip names

public func muteClipAudio(_ edl: Edl, _ main: EdlMain, _ clipId: String, _ muted: Bool) throws -> OpResult {
  var base = materialize(edl, main)
  _ = try findClip(base, clipId)
  base.clips = base.clips!.map { c in var x = c; if c.id == clipId { x.muteAudio = muted ? true : nil }; return x }
  return OpResult(edl: canonical(base, main), info: ["clip": .string(clipId), "muted": .bool(muted)])
}

private func findOverlay(_ edl: Edl, _ id: String) throws -> AudioOverlay {
  guard let o = edl.audioOverlays?.first(where: { $0.id == id }) else { throw EdlError("no_such_overlay", "No audio overlay with id \(id). Overlays: \((edl.audioOverlays ?? []).map(\.id).joined(separator: ", ").isEmpty ? "none" : (edl.audioOverlays ?? []).map(\.id).joined(separator: ", "))") }
  return o
}

private func checkOverlay(_ o: AudioOverlay) throws {
  if o.start < 0 { throw EdlError("invalid_range", "start has to be a number of seconds from 0, in edit time") }
  if o.inn < 0 || o.out - o.inn < MIN_CLIP || o.out > o.duration + EPS { throw EdlError("invalid_range", "in and out have to be inside the file, which is \(round3(o.duration)) s long, and at least \(MIN_CLIP) s apart") }
  if o.gain < 0 || o.gain > 2 { throw EdlError("invalid_gain", "gain is 0 to 2, 1 is the file as it is") }
}

// Lays an audio file over the reel from an edit time.
public func addAudioOverlay(_ edl: Edl, _ main: EdlMain, file: String, duration: Double, label: String, start: Double, inn: Double?, out: Double?, gain: Double?, window: FaceWindow? = nil, sound: Bool = false, layer: String? = nil) throws -> OpResult {
  let plan = buildPlan(edl, main)
  let win = normalizeWindow(window)
  var o = AudioOverlay(id: nextId("o", (edl.audioOverlays ?? []).map(\.id)), file: file, label: label.trimmingCharacters(in: .whitespaces).isEmpty ? (win != nil ? "Face" : "Voice over") : String(label.prefix(80)),
                       start: round3(start), inn: round3(inn ?? 0), out: round3(min(out ?? duration, duration)), gain: round3(gain ?? 1), duration: round3(duration),
                       window: win, sound: sound && win == nil ? true : nil, origin: file, layer: win != nil && layer == "video" ? "video" : nil)
  try checkOverlay(o)
  if plan.editDuration > 0 && o.start >= plan.editDuration - EPS { throw EdlError("invalid_range", "start \(o.start) is at or after the end of the reel, which is \(round3(plan.editDuration)) s long before cuts") }
  o.label = o.label.trimmingCharacters(in: .whitespaces)
  var e = edl
  e.audioOverlays = ((edl.audioOverlays ?? []) + [o]).sorted { $0.start < $1.start }
  return OpResult(edl: e, info: ["created": .string(o.id)])
}

public func updateAudioOverlay(_ edl: Edl, _ main: EdlMain, _ id: String, start: Double?, inn: Double?, out: Double?, gain: Double?, label: String?,
                               sound: Bool? = nil, bass: Double? = nil, treble: Double? = nil, window: FaceWindow? = nil) throws -> OpResult {
  var o = try findOverlay(edl, id)
  if let v = start { o.start = round3(v) }
  if let v = inn { o.inn = round3(v) }
  if let v = out { o.out = round3(min(v, o.duration)) }
  if let v = gain { o.gain = round3(v) }
  if let v = label { let t = v.trimmingCharacters(in: .whitespaces); if !t.isEmpty { o.label = String(t.prefix(80)) } }
  if let w = normalizeWindow(window) { o.window = w }
  // sound on a voice overlay only, a face window's sound is always the voice
  if let s = sound, o.window == nil { o.sound = s ? true : nil }
  if bass != nil || treble != nil {
    for v in [bass, treble].compactMap({ $0 }) where !v.isFinite || v < EQ_MIN || v > EQ_MAX { throw EdlError("invalid_eq", "bass and treble are \(Int(EQ_MIN)) to \(Int(EQ_MAX)) dB, 0 is as recorded") }
    o.eq = normalizeEq(bass: bass ?? o.eq?.bass ?? 0, treble: treble ?? o.eq?.treble ?? 0)
  }
  try checkOverlay(o)
  var e = edl
  e.audioOverlays = edl.audioOverlays!.map { $0.id == id ? o : $0 }.sorted { $0.start < $1.start }
  return OpResult(edl: e)
}

public func deleteAudioOverlay(_ edl: Edl, _ main: EdlMain, _ id: String) throws -> OpResult {
  _ = try findOverlay(edl, id)
  var e = edl
  let rest = edl.audioOverlays!.filter { $0.id != id }
  e.audioOverlays = rest.isEmpty ? nil : rest
  return OpResult(edl: e)
}

// Splits an overlay at an edit time into two that play on from each other, the window of a face overlay carried over: the
// second begins where the window is at that moment, with the moves still to come.
public func splitAudioOverlay(_ edl: Edl, _ main: EdlMain, _ id: String, _ at: Double) throws -> OpResult {
  let cur = try findOverlay(edl, id)
  let local = round3(at - cur.start)
  if local < MIN_CLIP || cur.out - cur.inn - local < MIN_CLIP { throw EdlError("invalid_range", "at has to be inside the overlay, at least \(MIN_CLIP) s from either end. It plays from \(cur.start) to \(round3(cur.start + (cur.out - cur.inn))) in edit time") }
  let newId = nextId("o", (edl.audioOverlays ?? []).map(\.id))
  var first = cur; first.out = round3(cur.inn + local)
  var second = cur; second.id = newId; second.start = round3(at); second.inn = round3(cur.inn + local)
  if let w = cur.window {
    let here = windowAt(w, local)
    let before = (w.moves ?? []).filter { $0.at < local - EPS }
    let after = (w.moves ?? []).filter { $0.at >= local - EPS }.map { m -> WindowMove in var x = m; x.at = round3(max(0, m.at - local)); return x }
    var fw = w; fw.moves = before.isEmpty ? nil : before
    first.window = fw
    second.window = FaceWindow(x: round3(here.x), y: round3(here.y), w: w.w, ratio: w.ratio, radius: w.radius, place: w.place, moves: after.isEmpty ? nil : after)
  }
  var e = edl
  e.audioOverlays = ((edl.audioOverlays ?? []).filter { $0.id != id } + [first, second]).sorted { $0.start < $1.start }
  return OpResult(edl: e, info: ["created": .string(newId)])
}

// Sets the window of a face overlay (where it is and how it moves), replacing the old one.
public func setFaceWindow(_ edl: Edl, _ main: EdlMain, _ id: String, _ window: FaceWindow) throws -> OpResult {
  guard let cur = edl.audioOverlays?.first(where: { $0.id == id }), cur.window != nil else {
    let faces = (edl.audioOverlays ?? []).filter { $0.window != nil }.map(\.id)
    throw EdlError("not_found", "\(id) is not a face overlay. Face overlays: \(faces.isEmpty ? "none" : faces.joined(separator: ", "))")
  }
  guard let w = normalizeWindow(window) else { throw EdlError("invalid_input", "window needs x, y and w as numbers") }
  var e = edl
  e.audioOverlays = edl.audioOverlays!.map { o in var x = o; if o.id == id { x.window = w }; return x }
  return OpResult(edl: e, info: ["id": .string(id)])
}

// Renames a clip: the label on its tag on the timeline. An empty label puts the default back.
public func renameClip(_ edl: Edl, _ main: EdlMain, _ clipId: String, _ label: String) throws -> OpResult {
  var base = materialize(edl, main)
  _ = try findClip(base, clipId)
  let text = String(label.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(120))
  base.clips = base.clips!.map { c in var x = c; if c.id == clipId { x.label = text.isEmpty ? nil : text }; return x }
  return OpResult(edl: canonical(base, main), info: ["clip": .string(clipId), "label": .string(text)])
}

// Hides the reel's title over a clip (visible false) or shows it again (true). The picture and the sound are untouched.
public func setClipTitle(_ edl: Edl, _ main: EdlMain, _ clipId: String, _ visible: Bool) throws -> OpResult {
  var base = materialize(edl, main)
  _ = try findClip(base, clipId)
  base.clips = base.clips!.map { c in var x = c; if c.id == clipId { x.hideTitle = visible ? nil : true }; return x }
  return OpResult(edl: canonical(base, main), info: ["clip": .string(clipId), "titleVisible": .bool(visible)])
}

// What a clip's own picture looks like: no look at all (off), its own look, or the reel's look (reel).
public enum ClipLookMode: Equatable, Sendable { case off, own(ReelLook), reel }

// Sets the look of a clip's own picture. The sound and any face window over it are untouched.
public func setClipLook(_ edl: Edl, _ main: EdlMain, _ clipId: String, _ mode: ClipLookMode) throws -> OpResult {
  var base = materialize(edl, main)
  _ = try findClip(base, clipId)
  base.clips = base.clips!.map { c in
    guard c.id == clipId else { return c }
    var x = c; x.hideLook = nil; x.look = nil
    switch mode { case .off: x.hideLook = true; case .own(let l): x.look = l; case .reel: break }
    return x
  }
  let what: String
  switch mode { case .off: what = "off"; case .own(let l): what = l.name ?? "custom"; case .reel: what = "reel" }
  return OpResult(edl: canonical(base, main), info: ["clip": .string(clipId), "look": .string(what)])
}

// Sets where a clip's own picture sits in the frame, a zoom and a move, or back as recorded with nil.
public func setClipPlace(_ edl: Edl, _ main: EdlMain, _ clipId: String, _ place: ReelPlace?) throws -> OpResult {
  var base = materialize(edl, main)
  _ = try findClip(base, clipId)
  let normal = normalizePlace(place)
  base.clips = base.clips!.map { c in var x = c; if c.id == clipId { x.place = normal }; return x }
  return OpResult(edl: canonical(base, main), info: ["clip": .string(clipId), "place": normal.map { JSON.from($0) } ?? "as recorded"])
}

// The stretches of the reel (edit time) where the title is hidden because the clip under it has hideTitle, merged, in play order.
public func clipTitleHides(_ plan: Plan) -> [Range] { mergeRanges(plan.clips.filter { $0.clip.hideTitle == true }.map { Range(s: $0.editStart, e: $0.editEnd) }) }

// The stretches of the reel (edit time) where the colour look is off because the clip under it has hideLook.
public func clipLookOffs(_ plan: Plan) -> [Range] { mergeRanges(plan.clips.filter { $0.clip.hideLook == true }.map { Range(s: $0.editStart, e: $0.editEnd) }) }
