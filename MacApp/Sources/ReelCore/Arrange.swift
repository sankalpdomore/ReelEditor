// A reel made of several videos, arranged in the transcript and by the agent (Sankalp, 2 Nov 2026). A project can start
// from many videos at once, laid out in the order they were recorded; the transcript reads as the reel plays, clip by
// clip, each with its own video's words; and the agent can move a part of the reel to another place or put in a part of
// any video between two places. Every one of these is a change to the project's JSON, one undo step each: the videos are
// only ever read.
import AVFoundation
import Foundation

// ---------------------------------------------------------------------------------------------------------------------
// The transcript as the reel plays

public struct LayoutWord: Sendable, Equatable {
  public var index: Int? // the main video's word index; nil for a word of another video
  public var source: String
  public var clip: String
  public var w: String
  public var s: Double, e: Double // edit seconds
  public var srcS: Double, srcE: Double // seconds of its video
  public var cut: Bool
  public var pending: Bool
}

public struct LayoutParagraph: Sendable {
  public var n: Int
  public var clip: String
  public var source: String
  public var label: String // the clip's name, its video's file name by default
  public var title: String? // the section that starts here
  public var clipStart: Bool // the first paragraph of its clip
  public var words: [LayoutWord]
}

// Every clip in the order it plays, each with the words its video speaks between its in and out, in paragraphs: a new
// one at every section, and after a sentence once a paragraph has 40 words (or at 90 words regardless).
public func transcriptLayout(_ l: Loaded) -> [LayoutParagraph] {
  let plan = l.plan, edl = l.project.edits
  let deleted = Set(edl.deleted), waiting = Set(edl.pendingWords ?? [])
  let waitingRanges = plan.rangeCuts.filter { $0.pending == true }
  let sections = Dictionary((edl.sections ?? []).map { ($0.from, $0.title) }, uniquingKeysWith: { a, _ in a })
  var out: [LayoutParagraph] = []
  for c in plan.clips {
    let label = c.clip.label ?? (c.source == MAIN ? l.project.main.label : edl.sources.first { $0.id == c.source }?.label ?? c.source)
    let source: [(Int?, Word)] = c.source == MAIN ? l.words.enumerated().map { ($0.offset, $0.element) } : (l.extra.sources[c.source] ?? []).map { (nil, $0) }
    var words: [LayoutWord] = []
    for (i, w) in source {
      let mid = (w.s + w.e) / 2
      guard mid >= c.inn, mid < c.out else { continue }
      let s = c.editStart + max(w.s, c.inn) - c.inn, e = c.editStart + min(w.e, c.out) - c.inn
      let m = (s + e) / 2
      let inRange = plan.cuts.contains { m >= $0.s && m < $0.e }
      let cut = (i.map(deleted.contains) ?? false) || inRange
      let pending = (i.map(waiting.contains) ?? false) || (inRange && waitingRanges.contains { m >= $0.s && m < $0.e })
      words.append(LayoutWord(index: i, source: c.source, clip: c.id, w: i.flatMap { edl.corrections[String($0)] } ?? w.w, s: s, e: e, srcS: w.s, srcE: w.e, cut: cut, pending: pending))
    }
    // A clip with no words (its video is still being transcribed, or has no speech) is one empty paragraph, so it still
    // shows and can be moved.
    if words.isEmpty { out.append(LayoutParagraph(n: out.count, clip: c.id, source: c.source, label: label, title: nil, clipStart: true, words: [])); continue }
    let local = words.enumerated().compactMap { k, w in w.index.flatMap { sections[$0] }.map { Section(id: "", title: $0, from: k) } }
    for (k, p) in transcriptParagraphs(words.map(\.w), local).enumerated() {
      out.append(LayoutParagraph(n: out.count, clip: c.id, source: c.source, label: label, title: p.title, clipStart: k == 0, words: Array(words[p.words])))
    }
  }
  return out
}

// ---------------------------------------------------------------------------------------------------------------------
// Moving and putting in

// Moves the part of the reel from start to end (edit seconds) to the point to, as it is before the move: the clips are
// split at the three points and the part's clips are put in their new place, with the cuts inside them. to cannot be
// inside the part. The voice overs stay where they are.
public func moveRange(_ edl: Edl, _ main: EdlMain, _ start: Double, _ end: Double, to: Double) throws -> OpResult {
  var e = materialize(edl, main)
  let total = buildPlan(e, main).editDuration
  let s = round3(max(0, start)), en = round3(min(total, end)), t = round3(max(0, min(total, to)))
  if en - s < MIN_CLIP { throw EdlError("invalid_range", "The part \(start) to \(end) is empty or outside the reel, which is \(round3(total)) s long before cuts") }
  if t > s + EPS && t < en - EPS { throw EdlError("invalid_range", "to \(to) is inside the part being moved; give a point before \(s) or after \(en)") }
  for x in [s, en, t] where x > EPS && x < total - EPS { e = try splitClip(e, main, x).edl }
  let plan = buildPlan(e, main)
  let block = plan.clips.filter { $0.editStart >= s - EPS && $0.editEnd <= en + EPS }.map(\.id)
  if block.isEmpty { throw EdlError("invalid_range", "No clip lies inside \(s) to \(en)") }
  var order = plan.clips.map(\.id).filter { !block.contains($0) }
  let at = order.firstIndex { id in (plan.clips.first { $0.id == id }?.editStart ?? 0) >= t - EPS } ?? order.count
  order.insert(contentsOf: block, at: at)
  e = try reorderClips(e, main, order).edl
  let moved = buildPlan(e, main).clips.filter { block.contains($0.id) }
  let ns = moved.first?.editStart ?? 0, ne = moved.last?.editEnd ?? 0
  return OpResult(edl: canonical(e, main), info: ["clips": .array(block.map { .string($0) }), "from": .number(s), "to": .number(round3(ns)), "end": .number(round3(ne)), "length": .number(round3(en - s))])
}

// Puts in a part of a video (source nil is the project's own video), from in to out of it, at the edit time at: the clip
// playing there is split and the new clip goes between the two halves. The clips after it move later.
public func insertClip(_ edl: Edl, _ main: EdlMain, _ source: Source?, _ inn: Double?, _ out: Double?, at: Double) throws -> OpResult {
  var e = materialize(edl, main)
  let total = buildPlan(e, main).editDuration
  let t = round3(max(0, min(total, at)))
  if t > EPS && t < total - EPS { e = try splitClip(e, main, t).edl }
  let plan = buildPlan(e, main)
  let index = plan.clips.firstIndex { $0.editStart >= t - EPS } ?? plan.clips.count
  var r = try addClip(e, main, source, inn, out, index)
  let placed = buildPlan(r.edl, main).clips.first { $0.id == r.info["created"]?.string }
  if let placed { r.info["start"] = .number(round3(placed.editStart)); r.info["end"] = .number(round3(placed.editEnd)) }
  return r
}

// ---------------------------------------------------------------------------------------------------------------------
// Many videos at once

public enum Arrange {
  // When a video was recorded: its own creation date, or the file's when it has none.
  public static func recordedAt(_ url: URL) async -> Date {
    let asset = AVURLAsset(url: url)
    if let item = try? await asset.load(.creationDate), let d = try? await item.load(.dateValue) { return d }
    let v = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
    return v?.creationDate ?? v?.contentModificationDate ?? .distantPast
  }

  // The videos in the order they were recorded, the earliest first.
  public static func byRecording(_ urls: [URL]) async -> [URL] {
    var dated: [(URL, Date)] = []
    for u in urls { dated.append((u, await recordedAt(u))) }
    return dated.sorted { $0.1 == $1.1 ? $0.0.lastPathComponent.localizedStandardCompare($1.0.lastPathComponent) == .orderedAscending : $0.1 < $1.1 }.map(\.0)
  }

  // A project from several videos: the first is the project's own video, the others follow it as clips, in one undo
  // step. Their words are fetched one video after another in the background when transcribe is true, every video with
  // sound, whether or not the first one has any.
  public static func createProject(videos: [URL], name: String?, folder: URL?, link: Bool = true, transcribe: Bool) async throws -> Loaded {
    guard let first = videos.first else { throw ToolError("invalid_input", "Give at least one video") }
    let l = try await Store.create(video: first, name: name, link: link, folder: folder)
    let n = l.project.name
    var sources: [Source] = []
    for u in videos.dropFirst() {
      let info = try await Media.probe(u)
      sources.append(Source(id: "", file: u.path, duration: info.duration, hasAudio: info.hasAudio, width: info.width, height: info.height, label: u.lastPathComponent))
    }
    if !sources.isEmpty {
      _ = try Store.mutate(n, "add_videos") { e, _, m in
        for s in sources { e = try addClip(e, m, s, nil, nil, nil).edl }
        return ["videos": .number(Double(sources.count + 1))]
      }
    }
    if transcribe, Jobs.whisperx() != nil, l.project.main.hasAudio || sources.contains(where: \.hasAudio) {
      Store.setStatus(n, ["state": "transcribing", "kind": "transcribe", "message": "Queued", "pid": .number(Double(getpid()))])
      Task.detached { _ = try? await Jobs.transcribeAll(n) }
    }
    return try Store.load(n)
  }
}
