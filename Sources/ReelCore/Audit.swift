// Reading a long transcript and auditing it against the sound, so the app's chat can make a full trim pass on its own
// (Sankalp, 2 Nov 2026). The chat's Claude has only the editor's tools, no shell and no file reader, and a tool answer
// past the client's limit is saved to a file it cannot open: get_project on a 23 minute reel is 175,000 characters.
// get_words returns the words a page at a time as short lines, with the pauses between them, and audit_audio runs the
// web editor's audio audit (tools/reel-tools/audit-audio.py) on the project's own files and returns what it found.
import Foundation

enum Audit {
  // The audit script beside the transcriber: in the app's Resources, or the repo's Resources for a debug build.
  static func script() -> String? {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    return Jobs.firstFile([ProcessInfo.processInfo.environment["REEL_AUDIT_SCRIPT"],
                           Bundle.main.resourceURL?.appendingPathComponent("audit_audio.py").path,
                           exe.appendingPathComponent("../Resources/audit_audio.py").standardized.path,
                           exe.appendingPathComponent("../../Resources/audit_audio.py").standardized.path])
  }

  // The sound of a file at 16 kHz mono, kept in the project's cache and made again when the file is newer.
  static func wav(_ name: String, _ file: String) async throws -> URL {
    var h: UInt64 = 1469598103934665603
    for b in file.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    let url = Store.dir(name).appendingPathComponent("media/audit-\(String(h, radix: 16)).wav")
    let fm = FileManager.default
    let made = (try? fm.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
    let changed = (try? fm.attributesOfItem(atPath: file)[.modificationDate] as? Date) ?? nil
    if let made, let changed, made >= changed { return url }
    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try await Media.writeWav(URL(fileURLWithPath: file), to: url)
    return url
  }

  // Runs a command and hands each line it writes to stderr to onLine as it comes; returns the exit code and the last of it.
  static func runReporting(_ exe: String, _ args: [String], onLine: @escaping @Sendable (String) -> Void) async throws -> (Int32, String) {
    try await withCheckedThrowingContinuation { cont in
      let p = Process()
      p.executableURL = URL(fileURLWithPath: exe)
      p.arguments = args
      let err = Pipe()
      p.standardError = err
      p.standardOutput = FileHandle.nullDevice
      final class Buf: @unchecked Sendable { var pending = Data(); var tail = ""; let lock = NSLock() }
      let buf = Buf()
      err.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        buf.lock.lock(); defer { buf.lock.unlock() }
        buf.pending.append(d)
        while let nl = buf.pending.firstIndex(of: 0x0A) {
          let line = String(decoding: buf.pending[buf.pending.startIndex..<nl], as: UTF8.self)
          buf.pending.removeSubrange(buf.pending.startIndex...nl)
          buf.tail = String((buf.tail + line + "\n").suffix(600))
          onLine(line)
        }
      }
      p.terminationHandler = { proc in
        err.fileHandleForReading.readabilityHandler = nil
        let rest = err.fileHandleForReading.readDataToEndOfFile()
        buf.lock.lock(); let tail = String((buf.tail + String(decoding: buf.pending + rest, as: UTF8.self)).suffix(600)); buf.lock.unlock()
        cont.resume(returning: (proc.terminationStatus, tail))
      }
      do { try p.run() } catch { cont.resume(throwing: ToolError("audit_failed", "Could not start \(exe): \(error.localizedDescription)")) }
    }
  }

  static func run(_ name: String, from: Double?, to: Double?) async throws -> [JSON] {
    guard let wx = Jobs.whisperx() else { throw ToolError("no_transcriber", "WhisperX was not found. Set whisperxPython in \(Store.root.path)/settings.json") }
    guard let script = script() else { throw ToolError("no_audit", "audit_audio.py was not found in the app's Resources") }
    let l = try Store.load(name)
    let plan = l.plan
    Store.setStatus(name, ["state": "auditing", "kind": "audit", "message": "Reading the sound for the audit"])
    do {
      var clips: [JSON] = []
      var wavs: [String: URL] = [:]
      for c in plan.clips {
        if let from, c.editEnd <= from { continue }
        if let to, c.editStart >= to { continue }
        let file = c.source == MAIN ? l.project.main.file : (l.project.edits.sources.first { $0.id == c.source }?.file ?? "")
        let words = c.source == MAIN ? l.words : (l.extra.sources[c.source] ?? [])
        guard !file.isEmpty, !words.isEmpty, FileManager.default.fileExists(atPath: file) else { continue }
        if wavs[file] == nil { wavs[file] = try await wav(name, file) }
        clips.append(["clip": .string(c.id), "label": .string(c.clip.label ?? ""), "wav": .string(wavs[file]!.path),
                      "in": .number(c.inn), "out": .number(c.out), "editStart": .number(c.editStart),
                      "words": .array(words.map { ["w": .string($0.w), "s": .number($0.s), "e": .number($0.e)] })])
      }
      if clips.isEmpty { throw ToolError("no_words", "No clip in that range has a video and words to audit. Transcribe first.") }
      let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reel-audit-\(UUID().uuidString.prefix(8))")
      try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: tmp) }
      let spec = tmp.appendingPathComponent("spec.json"), out = tmp.appendingPathComponent("report.json")
      var s: [String: JSON] = ["asr": .string(wx.script), "clips": .array(clips)]
      if let from { s["from"] = .number(from) }
      if let to { s["to"] = .number(to) }
      try JSON.object(s).text().write(to: spec, atomically: true, encoding: .utf8)
      Store.setStatus(name, ["state": "auditing", "kind": "audit", "message": "Listening again where the words and the sound disagree"])
      // The audit says where it listens again as it goes; each spot lights up its paragraph in the app.
      let (code, stderr) = try await runReporting(wx.python, [script, spec.path, out.path]) { line in
        let p = line.split(separator: " ")
        if p.count == 3, p[0] == "checking", let a = Double(p[1]), let b = Double(p[2]) { Focus.set(name, "Listening again to a spot the transcript may have missed", a, b) }
      }
      guard code == 0 else { throw ToolError("audit_failed", "The audit stopped with code \(code): \(stderr)") }
      let found = try JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [[String: Any]] ?? []
      let report: [JSON] = found.map { f in
        .object(["clip": .string(f["clip"] as? String ?? ""), "start": .number((f["edit_start"] as? NSNumber)?.doubleValue ?? 0), "end": .number((f["edit_end"] as? NSNumber)?.doubleValue ?? 0),
                 "sourceStart": .number((f["source_start"] as? NSNumber)?.doubleValue ?? 0), "sourceEnd": .number((f["source_end"] as? NSNumber)?.doubleValue ?? 0),
                 "why": .string(f["why"] as? String ?? ""), "heard": .string(f["heard"] as? String ?? "")])
      }
      Store.setStatus(name, ["state": "ready", "kind": "audit", "message": .string("Audit found \(report.count)")])
      return report
    } catch {
      Store.setStatus(name, ["state": "error", "kind": "audit", "message": .string(String(describing: error).prefix(400).description)])
      throw error
    }
  }
}

// The words as short lines, one per word, in the order the reel plays: its index, its start and end in edit time and the
// word, marked when it is cut or its cut waits for approval, with a line for every pause at least `pause` long. A word of
// another video than the project's own has no index and is marked with its video; a voice over's with its layer.
func wordLines(_ l: Loaded, from: Double, to: Double?, start: Int?, limit: Int, pause: Double) -> JSON {
  let plan = l.plan, edl = l.project.edits
  struct Row { var i: Int?; var s: Double; var e: Double; var w: String; var mark: String }
  var rows: [Row] = []
  for p in transcriptLayout(l) {
    for w in p.words {
      rows.append(Row(i: w.index, s: w.s, e: w.e, w: w.w, mark: (w.source == MAIN ? "" : " [\(p.label)]") + (w.pending ? " [cut, waiting]" : w.cut ? " [cut]" : "")))
    }
  }
  let overlays = Set((edl.audioOverlays ?? []).map(\.id))
  for x in extraEditWords(plan, edl, l.extra) where overlays.contains(x.from) {
    let inCut = plan.cuts.contains { (x.s + x.e) / 2 >= $0.s && (x.s + x.e) / 2 < $0.e }
    rows.append(Row(i: nil, s: x.s, e: x.e, w: x.w, mark: " [\(x.from)]" + (inCut ? " [cut]" : "")))
  }
  rows.sort { $0.s < $1.s }
  let first = start.flatMap { s in rows.firstIndex { ($0.i ?? -1) >= s } } ?? rows.firstIndex { $0.e > from } ?? rows.count
  var lines: [String] = []
  var k = first, taken = 0
  var prevEnd: Double? = first > 0 ? rows[first - 1].e : nil
  let f = { (x: Double) in String(format: "%.2f", x) }
  while k < rows.count, taken < limit {
    let r = rows[k]
    if let to, r.s >= to { break }
    if let p = prevEnd, r.s - p >= pause - 0.0005 { lines.append("pause \(f(r.s - p)) s, \(f(p)) to \(f(r.s))") }
    lines.append("\(r.i.map(String.init) ?? "-") \(f(r.s)) \(f(r.e)) \(r.w)\(r.mark)")
    prevEnd = r.e; k += 1; taken += 1
  }
  var out: [String: JSON] = ["project": .string(l.project.name), "totalWords": .number(Double(l.words.count)), "editDuration": .number(round3(plan.editDuration)),
                             "shown": .number(Double(taken)), "format": "index start end word, edit seconds; pause lines give the silence between words",
                             "text": .string(lines.joined(separator: "\n"))]
  if taken > 0 { out["from"] = .number(round3(rows[first].s)); out["to"] = .number(round3(rows[k - 1].e)) }
  if k < rows.count, to.map({ rows[k].s < $0 }) ?? true {
    out["nextFrom"] = .number(round3(rows[k].s))
    if let i = rows[k...].first(where: { $0.i != nil })?.i { out["nextStart"] = .number(Double(i)) }
  }
  return .object(out)
}

// A video's own words in its own seconds, whether the reel plays them or not, so a part left out can be found and put
// back in: each line is start and end in the video, the word, and where the reel plays it or that it does not.
func videoLines(_ l: Loaded, video: String, from: Double, to: Double?, limit: Int) throws -> JSON {
  let plan = l.plan, edl = l.project.edits
  let words: [Word]
  let label: String
  if video == MAIN { words = l.words; label = l.project.main.label }
  else if let s = edl.sources.first(where: { $0.id == video }) { words = l.extra.sources[video] ?? []; label = s.label }
  else { throw ToolError("not_found", "No video \(video). The project's videos are main\(edl.sources.map { ", \($0.id) (\($0.label))" }.joined())") }
  let f = { (x: Double) in String(format: "%.2f", x) }
  var lines: [String] = [], shown = 0, next: Double? = nil
  for (k, w) in words.enumerated() where w.e > from {
    if let to, w.s >= to { break }
    if shown >= limit { next = w.s; break }
    let mid = (w.s + w.e) / 2
    let at = plan.clips.first { $0.source == video && mid >= $0.inn && mid < $0.out }.map { $0.editStart + mid - $0.inn }
    let idx = video == MAIN ? "\(k) " : ""
    lines.append("\(idx)\(f(w.s)) \(f(w.e)) \(w.w)\(at.map { " [in the reel at \(f($0))]" } ?? " [not in the reel]")")
    shown += 1
  }
  var out: [String: JSON] = ["project": .string(l.project.name), "video": .string(video), "file": .string(label), "shown": .number(Double(shown)),
                             "format": .string((video == MAIN ? "index " : "") + "start end word, in seconds of this video; insert_clip with this video and in and out puts a part in the reel"),
                             "text": .string(lines.joined(separator: "\n"))]
  if let next { out["nextFrom"] = .number(round3(next)) }
  return .object(out)
}

func videoSource(_ l: Loaded, _ v: String) async throws -> (source: Source?, label: String, newFile: Bool) {
  if v == MAIN { return (nil, l.project.main.label, false) }
  if let s = l.project.edits.sources.first(where: { $0.id == v }) { return (s, s.label, false) }
  let url = try Store.videoURL(v)
  if let s = l.project.edits.sources.first(where: { $0.file == url.path }) { return (s, s.label, false) }
  let info = try await Media.probe(url)
  return (Source(id: "", file: url.path, duration: info.duration, hasAudio: info.hasAudio, width: info.width, height: info.height, label: url.lastPathComponent), url.lastPathComponent, true)
}

// 83.4 as 1:23, for what the app shows.
func clockTime(_ t: Double) -> String { let s = Int(max(0, t)); return "\(s / 60):" + String(format: "%02d", s % 60) }

let auditTools: [ReelTool] = [
  ReelTool(name: "move_range", description: "Moves a part of the reel to another place: the picture and sound from start to end (edit seconds) are taken out and put in at to (an edit time as the reel is before the move, not inside the part), with the cuts inside them. The clips are split at the three points; nothing in the videos changes, it is all in the project's JSON, one undo step. The app lights up where the part lands. Returns the new start (to) and end of the part. Voice overs stay where they are.", inputSchema: obj([
    "project": projectArg, "start": sec("Start of the part to move, edit seconds."), "end": sec("End of the part, edit seconds."), "to": sec("Where to put it, an edit time outside the part, as the reel is now."),
  ], ["project", "start", "end", "to"])) { i in
    let r = try edit(i, "move_range") { e, _, m in let r = try moveRange(e, m, i["start"]!.double!, i["end"]!.double!, to: i["to"]!.double!); e = r.edl; return r.info }
    if let n = try? name(i), let a = r["to"]?.double, let b = r["end"]?.double {
      let tc = { (x: Double) in clockTime(x) }
      Focus.set(n, "Moving \(tc(i["start"]!.double!)) to \(tc(i["end"]!.double!)) here", a, b)
    }
    return r
  },
  ReelTool(name: "insert_clip", description: "Puts a part of a video in the reel between two places: the clip playing at at (edit seconds) is split there and the part goes between its halves; the clips after it move later. video is main (the project's own video), a source id such as s1 from get_project, or the path of another video, which is added to the project. in and out are seconds of that video (get_words with video lists its words in its own seconds, including the parts not in the reel). The video is only read; it is all in the project's JSON, one undo step. The app lights up the part where it lands, naming the video.", inputSchema: obj([
    "project": projectArg,
    "video": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "main, a source id such as s1, or the absolute path of a video."],
    "in": sec("Start of the part, seconds of that video."), "out": sec("End of the part, seconds of that video."),
    "at": sec("Where to put it, edit seconds."),
  ], ["project", "video", "in", "out", "at"])) { i in
    let n = try name(i)
    let src = try await videoSource(try Store.load(n), i["video"]!.string!)
    let r = try edit(i, "insert_clip") { e, _, m in let r = try insertClip(e, m, src.source, i["in"]?.double, i["out"]?.double, at: i["at"]!.double!); e = r.edl; return r.info }
    if let a = r["start"]?.double, let b = r["end"]?.double {
      let tc = { (x: Double) in clockTime(x) }
      Focus.set(n, "Placing \(tc(i["in"]!.double!)) to \(tc(i["out"]!.double!)) of \(src.label) here", a, b)
    }
    if src.newFile, let s = src.source, s.hasAudio, Jobs.whisperx() != nil, (try? Store.read(Transcript.self, Store.wordsFile(n, s.file))) == nil {
      Task.detached { _ = try? await Jobs.transcribeFile(n, file: s.file, script: nil, what: s.label) }
    }
    return r
  },
  ReelTool(name: "get_words", description: "The transcript a page at a time, for a reel too long to read whole: one line per word, \"index start end word\" in edit seconds, marked [cut] or [cut, waiting], with a \"pause\" line for every silence at least pause seconds long. Words of added clips and voice overs have - for an index and the layer they come from. Read from from (edit seconds) or from the word index start; nextFrom and nextStart give where the next page begins. Use the indexes with delete_words and the times with cut_range.", inputSchema: obj([
    "project": projectArg,
    "from": sec("Edit time to start reading at. Default 0."),
    "to": sec("Edit time to stop at. Default the end, or as far as limit allows."),
    "start": ["type": "integer", "minimum": 0, "description": "The word index to start at, instead of from."],
    "paragraph": ["type": "integer", "minimum": 0, "description": "Read one paragraph, by its n from get_paragraphs, instead of from or start."],
    "video": ["type": "string", "minLength": 1, "maxLength": 40, "description": "Read one video's own words instead, main or a source id such as s1, in its own seconds (from and to are then seconds of that video), each marked with where the reel plays it or not in the reel."],
    "limit": ["type": "integer", "minimum": 1, "maximum": 3000, "default": 1500, "description": "Most words in one page."],
    "pause": ["type": "number", "minimum": 0.05, "default": 0.5, "description": "Shortest silence between words that gets a pause line, seconds."],
  ], ["project"])) { i in
    let l = try Store.load(try name(i))
    guard !l.words.isEmpty || !l.extra.isEmpty else { throw ToolError("no_words", "This project has no transcript yet. Run transcribe first.") }
    if let v = i["video"]?.string {
      let page = try videoLines(l, video: v, from: i["from"]?.double ?? 0, to: i["to"]?.double, limit: i["limit"]?.int ?? 1500)
      if let c = l.plan.clips.first(where: { $0.source == v }) { Focus.set(l.project.name, "Reading \(page["file"]?.string ?? v)", c.editStart, c.editEnd) }
      return page
    }
    let start = i["start"]?.int, limit = i["limit"]?.int ?? 1500
    var from = i["from"]?.double ?? 0, to = i["to"]?.double
    var label = "Reading"
    let multi = l.plan.clips.contains { $0.source != MAIN }
    if let p = i["paragraph"]?.int {
      let paras = transcriptLayout(l)
      guard p < paras.count else { throw ToolError("not_found", "There are \(paras.count) paragraphs, 0 to \(paras.count - 1)") }
      guard let s = spanOf(paras[p]) else { throw ToolError("no_words", "Paragraph \(p) is clip \(paras[p].clip) of \(paras[p].label), which has no words yet: it is being transcribed or has no speech") }
      from = s.s - 0.0005; to = s.e + 0.0005
      label = "Reading paragraph \(p + 1) of \(paras.count)" + (multi ? ", from \(paras[p].label)" : "")
    }
    let page = wordLines(l, from: from, to: to, start: i["paragraph"] == nil ? start : nil, limit: i["paragraph"] == nil ? limit : 100_000, pause: i["pause"]?.double ?? 0.5)
    if let a = page["from"]?.double, let b = page["to"]?.double { Focus.set(l.project.name, label, a, b) }
    return page
  },
  ReelTool(name: "audit_audio", description: "The audio audit of the rule books (audit-audio.py in the web editor), run on this project's own files: finds where the transcript does not match the sound, a word the aligner stretched over a hidden retake or false start (longer than 0.8 s with more than 0.5 s of speech inside) and speech no word covers, and transcribes each spot again so the report says what is really said there. Each finding has the clip, start and end in edit seconds, sourceStart and sourceEnd, why and heard. Give from and to to audit a part. Takes from a few seconds to a few minutes; nothing in the reel changes. Run it before planning the cuts and again after making them.", inputSchema: obj([
    "project": projectArg,
    "from": sec("Edit time to start the audit at. Default 0."),
    "to": sec("Edit time to end it at. Default the end."),
  ], ["project"])) { i in
    let n = try name(i)
    let whole = try Store.load(n).plan.editDuration
    Focus.set(n, "Auditing the sound", i["from"]?.double ?? 0, i["to"]?.double ?? whole)
    let found = try await Audit.run(n, from: i["from"]?.double, to: i["to"]?.double)
    return ["project": .string(n), "found": .number(Double(found.count)), "findings": .array(found),
            "note": .string(found.isEmpty ? "Nothing found: every stretch of speech is covered by a word of normal length." : "Act on every finding: cut a hidden retake or false start, move a cut edge off a leftover word, correct a misheard word.")]
  },
]
