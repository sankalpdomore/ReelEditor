// The editor's tools: every edit the app makes and every edit an agent makes through MCP is one of these, so a cut from
// the screen and a cut from a tool call are the same operation on the same files. Each tool has a name, a description
// and a JSON schema for its input, which the MCP server publishes as is. Results are flat JSON. Times are seconds, in
// edit time (the clips end to end, before the cuts) unless a field says output.
import Foundation

// Who is calling, set by the MCP server once its client introduces itself (Claude Code, Codex and so on).
public enum ToolContext {
  nonisolated(unsafe) public static var client = "Agent"
  // The Claude Code session the server runs under, by its name, and its account, for the project's list of editors.
  nonisolated(unsafe) public static var session: String? = nil
  nonisolated(unsafe) public static var account: String? = nil
  // A cut made through MCP (from the chat) waits for Sankalp's approval unless the call says approved; a cut made in the app
  // is his own and is approved at once.
  public static var cutsWaitForApproval: Bool { Log.source == "mcp" }
  // REEL_EDITOR_NO_OPEN=1 keeps the tools that open Finder or the app from opening anything (for tests).
  public static var mayOpen: Bool { ProcessInfo.processInfo.environment["REEL_EDITOR_NO_OPEN"] != "1" }
}

public struct ReelTool: Sendable {
  public let name: String
  public let description: String
  public let inputSchema: JSON
  public let run: @Sendable (JSON) async throws -> JSON
}

// ---------------------------------------------------------------------------------------------------------------------
// A small JSON Schema checker, so each tool's schema is both what MCP publishes and the check every call goes through.

public func validate(_ schema: JSON, _ value: JSON, at: String = "input") -> [String] {
  func typeOf(_ v: JSON) -> String {
    switch v { case .null: return "null"; case .bool: return "boolean"; case .string: return "string"; case .array: return "array"; case .object: return "object"
    case .number(let n): return n.rounded() == n ? "integer" : "number" }
  }
  var errors: [String] = []
  let types: [String] = schema["type"].flatMap { $0.string.map { [$0] } ?? $0.array?.compactMap(\.string) } ?? []
  if !types.isEmpty {
    let t = typeOf(value)
    if !types.contains(where: { $0 == t || ($0 == "number" && t == "integer") }) { return ["\(at) must be \(types.joined(separator: " or ")), got \(t)"] }
  }
  if let e = schema["enum"]?.array, !e.contains(value) { errors.append("\(at) must be one of \(e.map { $0.text() }.joined(separator: ", "))") }
  if let n = value.double {
    if let m = schema["minimum"]?.double, n < m { errors.append("\(at) must be at least \(m)") }
    if let m = schema["maximum"]?.double, n > m { errors.append("\(at) must be at most \(m)") }
  }
  if let s = value.string {
    if let m = schema["minLength"]?.int, s.count < m { errors.append("\(at) must be at least \(m) characters") }
    if let m = schema["maxLength"]?.int, s.count > m { errors.append("\(at) must be at most \(m) characters") }
    if let p = schema["pattern"]?.string, s.range(of: p, options: .regularExpression) == nil { errors.append("\(at) does not match \(p)") }
  }
  if let a = value.array {
    if let m = schema["minItems"]?.int, a.count < m { errors.append("\(at) needs at least \(m) items") }
    if let m = schema["maxItems"]?.int, a.count > m { errors.append("\(at) takes at most \(m) items") }
    if let items = schema["items"] { for (i, v) in a.enumerated() { errors += validate(items, v, at: "\(at)[\(i)]") } }
  }
  if let o = value.object {
    for key in schema["required"]?.array?.compactMap(\.string) ?? [] where o[key] == nil { errors.append("\(at).\(key) is required") }
    for (key, v) in o {
      if let sub = schema["properties"]?[key] { errors += validate(sub, v, at: "\(at).\(key)") }
      else if schema["additionalProperties"]?.bool == false { errors.append("\(at).\(key) is not a known field") }
    }
  }
  return errors
}

// ---------------------------------------------------------------------------------------------------------------------
// The state of a project as the tools return it

public enum ReelState {
  public static func of(_ l: Loaded, words: Bool = true) -> JSON {
    let plan = l.plan, edl = l.project.edits
    let speed = Compose.speedOf(edl)
    let flags = exportFlags(edl, hasWords: l.hasAnyWords)
    let r = { (x: Range) -> JSON in ["s": .number(round3(x.s)), "e": .number(round3(x.e))] }
    func fileOf(_ id: String) -> String { id == MAIN ? l.project.main.file : edl.sources.first { $0.id == id }?.file ?? "" }
    var out: [String: JSON] = [
      "project": .string(l.project.name), "projectTitle": .string(l.project.title ?? l.project.name), "rev": .number(Double(l.project.rev)), "animationsRev": .number(Double(l.animations.rev)),
      "video": .string(l.project.main.file), "size": [.number(l.project.main.width), .number(l.project.main.height)],
      "editDuration": .number(round3(plan.editDuration)), "cutDuration": .number(round3(plan.duration)), "duration": .number(round3(plan.duration / speed)), "speed": .number(speed),
      "hasWords": .bool(!l.words.isEmpty),
      "clips": .array(plan.clips.map { c in
        var o: [String: JSON] = ["id": .string(c.id), "source": .string(c.source), "in": .number(round3(c.inn)), "out": .number(round3(c.out)), "editStart": .number(round3(c.editStart)), "editEnd": .number(round3(c.editEnd)), "length": .number(round3(c.length)), "label": .string(c.clip.label ?? (c.source == MAIN ? l.project.main.label : c.source)), "file": .string(fileOf(c.source)), "muteAudio": .bool(c.clip.muteAudio == true),
                                 "hideTitle": .bool(c.clip.hideTitle == true), "hideLook": .bool(c.clip.hideLook == true)]
        if let lk = c.clip.look { o["look"] = JSON.from(lk) }
        if let pl = c.clip.place { o["place"] = JSON.from(pl) }
        return .object(o)
      }),
      "audioOverlays": .array((edl.audioOverlays ?? []).map { o in
        var j = JSON.from(o).object ?? [:]
        j["pieces"] = .array(overlayPieces(plan, o).map { ["fileIn": .number(round3($0.fileIn)), "fileOut": .number(round3($0.fileOut)), "outStart": .number(round3($0.outStart / speed))] })
        j["words"] = .number(Double(l.extra.overlays[o.file]?.count ?? 0))
        return .object(j)
      }),
      "extraWords": .array(extraEditWords(plan, edl, l.extra).map { ["w": .string($0.w), "s": .number(round3($0.s)), "e": .number(round3($0.e)), "from": .string($0.from)] }),
      "sources": .array(([l.project.main] + edl.sources).map { JSON.from($0) }),
      "cuts": .array(plan.cuts.map(r)), "keep": .array(plan.keep.map(r)),
      "rangeCuts": JSON.from(plan.rangeCuts), "deletedWords": JSON.from(edl.deleted), "corrections": JSON.from(edl.corrections),
      "segments": JSON.from(plan.segments),
      "captions": .bool(flags.captions), "title": .bool(flags.title), "titleText": .string(edl.titleText ?? ""),
      "sections": JSON.from(edl.sections ?? []),
      "pendingWords": JSON.from(edl.pendingWords ?? []), "waitingCuts": .number(Double(edl.cuts.filter { $0.pending == true }.count + (edl.pendingWords?.count ?? 0))),
      "look": edl.look.map { JSON.from($0) } ?? .null, "music": edl.music.map { JSON.from($0) } ?? .null, "musicFile": Compose.musicFile(edl).map { .string($0.path) } ?? .null,
      "voiceGain": .number(edl.voiceGain ?? 1), "voiceEq": edl.voiceEq.map { JSON.from($0) } ?? .null, "captionPos": edl.captionPos.map { JSON.from($0) } ?? .null,
      "caption": edl.caption.map { .string($0) } ?? .null, "status": .string(edl.status ?? "draft"), "references": JSON.from(edl.references ?? []), "cost": edl.cost.map { JSON.from($0) } ?? .null,
      "titleHides": .array(clipTitleHides(plan).map(r)), "comments": .number(Double(Comments.read(l.project.name).filter { $0.status == "unresolved" }.count)),
      "draft": .bool(Drafts.read(l.project.name) != nil),
      "animations": .array(l.animations.animations.map { a in
        var o = JSON.from(a).object ?? [:]
        o["outStart"] = .number(round3(outputOf(plan, a.start) / speed)); o["outEnd"] = .number(round3(outputOf(plan, a.end) / speed))
        return .object(o)
      }),
      "canUndo": .bool(!l.history.past.isEmpty), "canRedo": .bool(!l.history.future.isEmpty),
      "files": ["project": .string(Store.document(l.project.name)?.path ?? ""), "exports": .string(Store.exportsDir(l.project.name).path)],
    ]
    if words {
      let mapped = mapWords(plan, l.words), cut = wordsCut(plan, edl, l.words)
      let waiting = Set(edl.pendingWords ?? [])
      out["words"] = .array(l.words.enumerated().map { i, w in
        var o: [String: JSON] = ["i": .number(Double(i)), "w": .string(edl.corrections[String(i)] ?? w.w), "s": mapped[i].map { .number(round3($0.s)) } ?? .null, "e": mapped[i].map { .number(round3($0.e)) } ?? .null, "cut": .bool(cut[i])]
        if waiting.contains(i) { o["pending"] = true }
        return .object(o)
      })
    }
    return .object(out)
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// The tools

func obj(_ properties: [String: JSON], _ required: [String] = []) -> JSON {
  ["type": "object", "properties": .object(properties), "required": .array(required.map { .string($0) }), "additionalProperties": false]
}
let projectArg: JSON = ["type": "string", "pattern": "^[a-z0-9-]{1,120}$", "description": "The project's name, as list_projects shows it. reel is taken as another name for it, as the web editor calls it."]
func sec(_ d: String) -> JSON { ["type": "number", "minimum": 0, "description": .string(d)] }
let wordsArg: JSON = ["type": "array", "items": ["type": "integer", "minimum": 0], "minItems": 1, "maxItems": 5000, "description": "Word indexes, the i of each word in get_project."]
let clipArg: JSON = ["type": "string", "minLength": 1, "maxLength": 40, "description": "A clip id from get_project, for example c1."]
private let animFields: [String: JSON] = [
  "kind": ["type": "string", "enum": .array(ANIMATION_KIND_IDS.map { .string($0) }), "description": "One of the kinds list_animation_kinds describes."],
  "start": sec("Edit time it appears, seconds."),
  "end": sec("Edit time it is gone, seconds, at least 0.5 s after start."),
  "side": ["type": "string", "enum": ["left", "right", "center"], "description": "Which side of the frame, the one with room beside the speaker. Default right."],
  "position": ["type": "string", "enum": ["top", "middle", "bottom"], "description": "Height in the frame. Default middle."],
  "text": ["type": "string", "maxLength": 400, "description": "The main text (for checklist, one item per line)."],
  "subtitle": ["type": "string", "maxLength": 200],
  "color": ["type": "string", "pattern": "^#[0-9a-fA-F]{6}$", "description": "Accent colour, #rrggbb."],
  "emoji": ["type": "string", "maxLength": 8],
  "from": ["type": "number"], "to": ["type": "number"],
  "prefix": ["type": "string", "maxLength": 12], "suffix": ["type": "string", "maxLength": 12],
]

func name(_ i: JSON) throws -> String { try Store.checkName(i["project"]?.string ?? "") }
func result(_ m: Store.Mutation, _ extra: [String: JSON] = [:]) -> JSON {
  let state = ReelState.of(m.loaded, words: false)
  var o: [String: JSON] = ["project": .string(m.loaded.project.name), "changed": .bool(m.changed), "duration": state["duration"] ?? .null, "keep": state["keep"] ?? .null]
  for (k, v) in m.info { o[k] = v }
  for (k, v) in extra { o[k] = v }
  o["state"] = state
  return .object(o)
}
func edit(_ i: JSON, _ label: String, _ fn: @escaping (inout Edl, inout [ReelAnimation], EdlMain) throws -> [String: JSON]) throws -> JSON {
  result(try Store.mutate(try name(i), label, fn))
}
private func ints(_ i: JSON) throws -> [Int] {
  if let a = i["indexes"]?.array, !a.isEmpty { return a.compactMap(\.int) }
  if let f = i["from"]?.int, let t = i["to"]?.int, t >= f { return Array(f...t) }
  throw ToolError("invalid_input", "Give indexes, or from and to (the first and last word index)")
}
private func applyFields(_ a: inout ReelAnimation, _ i: JSON) {
  if let v = i["kind"]?.string { a.kind = v }
  if let v = i["start"]?.double { a.start = v }
  if let v = i["end"]?.double { a.end = v }
  if let v = i["side"]?.string { a.side = v }
  if let v = i["position"]?.string { a.position = v }
  if let v = i["text"] { a.text = v.string }
  if let v = i["subtitle"] { a.subtitle = v.string }
  if let v = i["color"] { a.color = v.string }
  if let v = i["emoji"] { a.emoji = v.string }
  if let v = i["from"] { a.from = v.double }
  if let v = i["to"] { a.to = v.double }
  if let v = i["prefix"] { a.prefix = v.string }
  if let v = i["suffix"] { a.suffix = v.string }
}
private func checkAnimation(_ a: ReelAnimation) throws {
  if !ANIMATION_KIND_IDS.contains(a.kind) { throw ToolError("invalid_animation", "kind has to be one of \(ANIMATION_KIND_IDS.joined(separator: ", "))") }
  if a.end - a.start < 0.5 { throw ToolError("invalid_animation", "An animation runs at least 0.5 s: end has to be 0.5 s or more after start") }
}

let coreTools: [ReelTool] = [
  ReelTool(name: "list_projects", description: "Lists the projects with their source video, length before cuts (editDuration), the length of the export (duration), how many clips, cuts and animations, whether there is a transcript, what is running and whether the reel is draft or live. A draft reel with no video yet (create_draft_reel) is listed with draft true and no video.", inputSchema: obj([:])) { _ in
    .object(["root": .string(Store.root.path), "projects": .array(Store.names().compactMap { n in
      guard let l = try? Store.load(n) else { return nil }
      let s = ReelState.of(l, words: false)
      return ["name": .string(n), "title": .string(l.project.title ?? n), "file": .string(Store.document(n)?.path ?? ""), "video": .string(l.project.main.file), "editDuration": s["editDuration"]!, "duration": s["duration"]!, "clips": .number(Double(l.plan.clips.count)), "cuts": .number(Double(l.plan.cuts.count)), "animations": .number(Double(l.animations.animations.count)), "hasWords": .bool(!l.words.isEmpty), "status": Store.status(n)["state"] ?? "ready", "reelStatus": .string(l.project.edits.status ?? "draft"), "draft": .bool(Drafts.read(n) != nil)]
    } + Drafts.names().map { n in ["name": .string(n), "title": .string(Drafts.read(n)?.title ?? n), "video": .null, "editDuration": .null, "duration": .null, "clips": 0, "cuts": 0, "animations": 0, "hasWords": false, "status": "draft", "reelStatus": "draft", "draft": true] })])
  },
  ReelTool(name: "create_project", description: "Opens a video file as a new project. The video stays where it is and is only ever read (link false copies it beside the project file instead). The project is one JSON file, <name>.reel.json, holding everything: the edits, the animations, the transcript, the undo history, comments and the draft; it is saved in folder (an absolute path) or, by default, in the Reel Editor folder, and put on the list the app and list_projects read. Transcribes the speech with WhisperX unless transcribe is false", inputSchema: obj([
    "path": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "Absolute path of a video (mp4, mov, m4v)."],
    "videos": ["type": "array", "items": ["type": "string", "minLength": 1, "maxLength": 2048], "minItems": 1, "maxItems": 100, "description": "Several videos for one project, instead of path: laid out one after another in the order they were recorded (order given keeps this order), the first as the project's own video and each of the others as a clip, every one transcribed in turn."],
    "order": ["type": "string", "enum": ["recorded", "given"], "default": "recorded", "description": "With videos: by when each was recorded, or as listed."],
    "name": ["type": "string", "pattern": "^[a-z0-9-]{1,120}$", "description": "Name for the project. Default today's date, the file name and -v1 (the next free version)."],
    "transcribe": ["type": "boolean", "default": true, "description": "Transcribe the speech for word timings."],
    "wait": ["type": "boolean", "default": false, "description": "Wait until the transcription is done instead of returning at once."],
    "link": ["type": "boolean", "default": true, "description": "Read the video where it is (true), or copy it beside the project file (false)."],
    "folder": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "Absolute path of the folder to save the project file in. Default the Reel Editor folder."],
  ], [])) { i in
    let folder = i["folder"]?.string.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true) }
    if let vs = i["videos"]?.array?.compactMap(\.string) {
      let urls = try vs.map { try Store.videoURL($0) }
      let ordered = i["order"]?.string == "given" ? urls : await Arrange.byRecording(urls)
      let l = try await Arrange.createProject(videos: ordered, name: i["name"]?.string, folder: folder, link: i["link"]?.bool ?? true, transcribe: i["transcribe"]?.bool ?? true)
      return ["project": .string(l.project.name), "videos": .array(ordered.map { .string($0.path) }), "transcribing": .bool((i["transcribe"]?.bool ?? true) && Jobs.whisperx() != nil), "state": ReelState.of(l, words: false)]
    }
    guard i["path"]?.string != nil else { throw ToolError("invalid_input", "Give path, or videos for a project of several videos") }
    let l = try await Store.create(video: try Store.videoURL(i["path"]!.string!), name: i["name"]?.string, link: i["link"]?.bool ?? true, folder: folder)
    let n = l.project.name
    let transcribe = (i["transcribe"]?.bool ?? true) && l.project.main.hasAudio
    if transcribe && i["wait"]?.bool == true {
      let words = try await Jobs.transcribe(n)
      return ["project": .string(n), "transcribing": false, "words": .number(Double(words)), "state": ReelState.of(try Store.load(n), words: false)]
    }
    if transcribe { Store.setStatus(n, ["state": "transcribing", "kind": "transcribe", "message": "Queued"]); Task.detached { _ = try? await Jobs.transcribe(n) } }
    return ["project": .string(n), "transcribing": .bool(transcribe), "state": ReelState.of(l, words: false)]
  },
  ReelTool(name: "add_project", description: "Puts a project file saved anywhere (<name>.reel.json) on the list, so the app and these tools can open it by its name. The file stays where it is. Refused when another project of the same name is already on the list.", inputSchema: obj([
    "path": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "Absolute path of the project file."],
  ], ["path"])) { i in
    let n = try Store.register(file: URL(fileURLWithPath: (i["path"]!.string! as NSString).expandingTildeInPath))
    return ["project": .string(n), "file": .string(Store.document(n)?.path ?? "")]
  },
  ReelTool(name: "remove_project", description: "Takes a project off the list. Its file is left where it is and can be added again with add_project.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let n = try name(i)
    let f = Store.document(n)?.path ?? ""
    try Store.forget(n)
    return ["project": .string(n), "removed": true, "file": .string(f)]
  },
  ReelTool(name: "move_project", description: "Moves a project's file (<name>.reel.json) into another folder, keeping its name, and points the list at its new place. Only the project file moves: the video and every other source stay where they are, and exports made earlier stay where they were. Refused when the folder already holds a file of that name.", inputSchema: obj([
    "project": projectArg,
    "folder": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "Absolute path of the folder to move the project file into. Made if it does not exist."],
  ], ["project", "folder"])) { i in
    let n = try name(i)
    let r = try Store.relocate(n, to: URL(fileURLWithPath: (i["folder"]!.string! as NSString).expandingTildeInPath, isDirectory: true))
    return ["project": .string(n), "file": .string(r.to.path), "previous": .string(r.from.path)]
  },
  ReelTool(name: "get_project", description: "The whole state of a project: its clips (in and out in source seconds, editStart and editEnd in edit time), the cuts, the kept ranges, the length of the export (duration, after cuts and speed), the words with their indexes and edit times (empty without a transcript), the sections, the export options and the animation layer (each animation also has outStart and outEnd, its place in the export). Read this before editing and after, to check what an edit did. A transcript of more than 1,500 words is left out unless words is true (wordsOmitted says how many); read it a page at a time with get_words.", inputSchema: obj(["project": projectArg, "words": ["type": "boolean", "description": "Include the words. Left out, they are included up to 1,500 words. False for a shorter answer."]], ["project"])) { i in
    let l = try Store.load(try name(i))
    let long = l.words.count > 1500
    var state = ReelState.of(l, words: i["words"]?.bool ?? !long)
    if long, i["words"] == nil, var o = state.object {
      o["wordsOmitted"] = .number(Double(l.words.count)); o["extraWords"] = nil
      o["readWordsWith"] = "get_words, a page at a time"
      state = .object(o)
    }
    return state
  },
  ReelTool(name: "cut_range", description: "Cuts a range out: the picture and sound between start and end (edit time, seconds) are skipped by playback and left out of the export. Nothing is deleted; restore_range or undo brings it back. A range touching an earlier cut joins it. A cut made through MCP waits for Sankalp's approval (pending, see approve_cuts) unless approved is true; it plays and exports as a cut either way.", inputSchema: obj(["project": projectArg, "start": sec("Where the cut starts."), "end": sec("Where the cut ends."), "approved": ["type": "boolean", "description": "True only for a cut Sankalp made himself. Left out from an agent, the cut waits for his approval (approve_cuts)."]], ["project", "start", "end"])) { i in
    let pending = !(i["approved"]?.bool ?? !ToolContext.cutsWaitForApproval)
    if let n = try? name(i) { Focus.set(n, "Applying trims", i["start"]!.double!, i["end"]!.double!) }
    return try edit(i, "cut_range") { e, _, m in let r = try cutRange(e, m, i["start"]!.double!, i["end"]!.double!, pending: pending); e = r.edl; return r.info }
  },
  ReelTool(name: "restore_range", description: "Brings back a range cut_range took out: cuts inside start to end are removed, a cut that crosses an end is shortened. Cut words come back with restore_words.", inputSchema: obj(["project": projectArg, "start": sec("Start of the range to bring back."), "end": sec("End of the range.")], ["project", "start", "end"])) { i in
    try edit(i, "restore_range") { e, _, m in let r = try restoreRange(e, m, i["start"]!.double!, i["end"]!.double!); e = r.edl; return r.info }
  },
  ReelTool(name: "delete_words", description: "Cuts words out of the video by index (get_project words). A run of cut words and the pause after it are skipped. Give indexes, or from and to for a run. Words cut through MCP wait for Sankalp's approval (pendingWords, see approve_cuts) unless approved is true.", inputSchema: obj(["project": projectArg, "indexes": wordsArg, "from": ["type": "integer", "minimum": 0], "to": ["type": "integer", "minimum": 0], "approved": ["type": "boolean", "description": "True only for words Sankalp cut himself."]], ["project"])) { i in
    let idx = try ints(i)
    let pending = !(i["approved"]?.bool ?? !ToolContext.cutsWaitForApproval)
    if let n = try? name(i), let l = try? Store.load(n), let lo = idx.min(), let hi = idx.max(), hi < l.words.count, let r = span(l.plan, l.words, lo..<(hi + 1)) {
      Focus.set(n, "Applying trims", r.s, r.e)
    }
    return try edit(i, "delete_words") { e, _, m in e = try deleteWords(e, m, idx, pending: pending).edl; return [:] }
  },
  ReelTool(name: "restore_words", description: "Brings cut words back, by indexes or by from and to.", inputSchema: obj(["project": projectArg, "indexes": wordsArg, "from": ["type": "integer", "minimum": 0], "to": ["type": "integer", "minimum": 0]], ["project"])) { i in
    let idx = try ints(i)
    return try edit(i, "restore_words") { e, _, m in e = try restoreWords(e, m, idx).edl; return [:] }
  },
  ReelTool(name: "correct_word", description: "Corrects how a word is spelled in the captions (the sound is untouched). text null or empty puts the heard word back.", inputSchema: obj(["project": projectArg, "index": ["type": "integer", "minimum": 0], "text": ["type": ["string", "null"], "maxLength": 100]], ["project", "index"])) { i in
    try edit(i, "correct_word") { e, _, m in e = try correctWord(e, m, i["index"]!.int!, i["text"]?.string).edl; return [:] }
  },
  ReelTool(name: "trim_clip", description: "Sets where a clip starts (in) and ends (out) inside its source video, source seconds. Give either or both. The clips after it move up or back.", inputSchema: obj(["project": projectArg, "clip": clipArg, "in": sec("Seconds into the source where the clip starts."), "out": sec("Seconds into the source where it ends.")], ["project", "clip"])) { i in
    try edit(i, "trim_clip") { e, _, m in let r = try trimClip(e, m, i["clip"]!.string!, i["in"]?.double, i["out"]?.double); e = r.edl; return r.info }
  },
  ReelTool(name: "split_clip", description: "Splits the clip playing at an edit time into two, so each part can be trimmed, moved or deleted. At a clip's edge nothing changes. The second part's id is returned as created.", inputSchema: obj(["project": projectArg, "at": sec("Edit time to split at.")], ["project", "at"])) { i in
    try edit(i, "split_clip") { e, _, m in let r = try splitClip(e, m, i["at"]!.double!); e = r.edl; return r.info }
  },
  ReelTool(name: "delete_clip", description: "Takes a clip out, with the cuts made inside it. The last clip cannot be deleted. Undo brings it back.", inputSchema: obj(["project": projectArg, "clip": clipArg], ["project", "clip"])) { i in
    try edit(i, "delete_clip") { e, _, m in let r = try deleteClip(e, m, i["clip"]!.string!); e = r.edl; return r.info }
  },
  ReelTool(name: "reorder_clips", description: "Puts the clips in a new order. order lists every clip id exactly once, first to play first.", inputSchema: obj(["project": projectArg, "order": ["type": "array", "items": clipArg, "minItems": 1, "maxItems": 500]], ["project", "order"])) { i in
    try edit(i, "reorder_clips") { e, _, m in e = try reorderClips(e, m, i["order"]!.array!.compactMap(\.string)).edl; return [:] }
  },
  ReelTool(name: "add_clip", description: "Adds a clip of another video (path) or of the project's own video (no path), at the end or at index. in and out pick the part of it, source seconds, default all of it. The added video is only read; a different size is fitted into the frame.", inputSchema: obj(["project": projectArg, "path": ["type": "string", "minLength": 1, "maxLength": 2048], "in": sec("Start in the added video."), "out": sec("End in the added video."), "index": ["type": "integer", "minimum": 0], "transcribe": ["type": "boolean", "default": true, "description": "Get the added video's words in the background (WhisperX), for the captions."]], ["project"])) { i in
    var src: Source? = nil
    if let p = i["path"]?.string {
      let url = try Store.videoURL(p)
      let info = try await Media.probe(url)
      src = Source(id: "", file: url.path, duration: info.duration, hasAudio: info.hasAudio, width: info.width, height: info.height, label: humanClipLabel(url.path))
    }
    let out = try edit(i, "add_clip") { e, _, m in let r = try addClip(e, m, src, i["in"]?.double, i["out"]?.double, i["index"]?.int); e = r.edl; return r.info }
    // The added video's words, in the background, so the captions read the whole script.
    if let src, src.hasAudio, i["transcribe"]?.bool ?? true, Jobs.whisperx() != nil {
      let n = try name(i)
      if (try? Store.read(Transcript.self, Store.wordsFile(n, src.file))) == nil { Task.detached { _ = try? await Jobs.transcribeFile(n, file: src.file, script: nil, what: src.label) } }
    }
    return out
  },
  ReelTool(name: "rename_clip", description: "Renames a clip: the label on its tag on the timeline, for example Part 4, Leap Finance. Up to 120 characters; an empty label brings the default back. Undoable.", inputSchema: obj(["project": projectArg, "clip": clipArg, "label": ["type": "string", "maxLength": 120]], ["project", "clip", "label"])) { i in
    try edit(i, "rename_clip") { e, _, m in let r = try renameClip(e, m, i["clip"]!.string!, i["label"]!.string!); e = r.edl; return r.info }
  },
  ReelTool(name: "add_audio_overlay", description: "Lays an audio file over the project on its own layer, Voice over, from an edit time: a voice over for a clip, with mute_clip silencing that clip's own sound so the two never have to be merged. The preview and the export play it at its start with its gain and follow the cuts like the clip's own sound. The picture is not stretched to it; it stays at its edit time, and moves with the picture when clips before it are trimmed, deleted or put in. The file is only read. Undoable. Returns the new overlay's id (created).", inputSchema: obj([
    "project": projectArg,
    "path": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "An audio file (mp3, wav, m4a, aac, aiff) or a video whose sound to use."],
    "start": sec("Edit time where it begins. Default 0."),
    "in": sec("Where in the file it starts playing. Default 0."), "out": sec("Where in the file it stops. Default its end."),
    "sound": ["type": "boolean", "description": "A sound effect or music, not a voice: it plays at exactly its own gain, outside the voice volume (set_voice_gain) and its bass and treble. Default true when transcribe is false."],
    "gain": ["type": "number", "minimum": 0, "maximum": 2, "description": "Volume, 1 is the file as it is."],
    "label": ["type": "string", "maxLength": 80],
    "mute_clip": ["type": "string", "minLength": 1, "maxLength": 40, "description": "A clip id whose own sound is muted at the same time."],
    "transcribe": ["type": "boolean", "default": true, "description": "Get its words (WhisperX in the background) for the captions. False for music or sound with no speech."],
    "script": ["type": "string", "maxLength": 6000, "description": "The exact words spoken, placed on the audio instead of transcribing."],
  ], ["project", "path"])) { i in
    let url = URL(fileURLWithPath: (i["path"]!.string! as NSString).expandingTildeInPath).resolvingSymlinksInPath()
    guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("not_found", "No file at \(url.path)") }
    guard Media.AUDIO_EXTENSIONS.contains(url.pathExtension.lowercased()) else { throw ToolError("invalid_path", "Not an audio file (\(Media.AUDIO_EXTENSIONS.joined(separator: ", ")))") }
    let duration = try await Media.probeAudio(url)
    let label = i["label"]?.string ?? humanClipLabel(url.path)
    let out = try edit(i, "add_audio_overlay") { e, _, m in
      var r = try addAudioOverlay(e, m, file: url.path, duration: duration, label: label, start: i["start"]?.double ?? 0, inn: i["in"]?.double, out: i["out"]?.double, gain: i["gain"]?.double,
                                  sound: i["sound"]?.bool ?? (i["transcribe"]?.bool == false))
      if let c = i["mute_clip"]?.string { r.edl = try muteClipAudio(r.edl, m, c, true).edl; r.info["muted"] = .string(c) }
      e = r.edl; return r.info
    }
    let n = try name(i)
    let script = i["script"]?.string
    if (i["transcribe"]?.bool ?? true) || script != nil, Jobs.whisperx() != nil {
      Task.detached { _ = try? await Jobs.transcribeFile(n, file: url.path, script: script, what: label) }
    }
    return out
  },
  ReelTool(name: "update_audio_overlay", description: "Changes an audio or face overlay: where it starts (start, edit time), the part of the file that plays (in, out), its gain (0 to 2, above 1 louder than the file, limited so it does not clip), its label, whether it is a sound effect (sound true, played at its own gain outside the voice volume) or a voice (false), or its bass and treble (dB, -12 to 12, 0 as recorded, a low shelf at 120 Hz and a high shelf at 6 kHz, saved as eq on the overlay). Only the fields given change. The preview and the export play them. Undoable.", inputSchema: obj(["project": projectArg, "id": ["type": "string", "pattern": "^o[0-9]{1,3}$"], "start": sec("Edit time where it begins."), "in": sec("Start in the file."), "out": sec("End in the file."), "gain": ["type": "number", "minimum": 0, "maximum": 2], "label": ["type": "string", "maxLength": 80],
    "sound": ["type": "boolean"], "bass": ["type": "integer", "minimum": -12, "maximum": 12], "treble": ["type": "integer", "minimum": -12, "maximum": 12]], ["project", "id"])) { i in
    try edit(i, "update_audio_overlay") { e, _, m in e = try updateAudioOverlay(e, m, i["id"]!.string!, start: i["start"]?.double, inn: i["in"]?.double, out: i["out"]?.double, gain: i["gain"]?.double, label: i["label"]?.string,
                                                                           sound: i["sound"]?.bool, bass: i["bass"]?.double, treble: i["treble"]?.double).edl; return [:] }
  },
  ReelTool(name: "delete_audio_overlay", description: "Takes an audio overlay off the project. The file is not deleted. Undoable.", inputSchema: obj(["project": projectArg, "id": ["type": "string", "pattern": "^o[0-9]{1,3}$"]], ["project", "id"])) { i in
    try edit(i, "delete_audio_overlay") { e, _, m in e = try deleteAudioOverlay(e, m, i["id"]!.string!).edl; return [:] }
  },
  ReelTool(name: "mute_clip_audio", description: "Silences a clip's own sound in the preview and the export (muted true, the default), or brings it back (false). The picture is untouched, and its words leave the captions. Use it when an audio overlay carries the sound instead. Undoable.", inputSchema: obj(["project": projectArg, "clip": clipArg, "muted": ["type": "boolean", "default": true]], ["project", "clip"])) { i in
    try edit(i, "mute_clip_audio") { e, _, m in let r = try muteClipAudio(e, m, i["clip"]!.string!, i["muted"]?.bool ?? true); e = r.edl; return r.info }
  },
  ReelTool(name: "transcribe_source", description: "Gets the words of an added video (source, an id like s1 from get_project) or of an audio overlay (overlay, like o1), for the captions and the timeline. WhisperX runs in the background; get_status shows how far it is. With script (the exact words spoken) they are placed on the audio instead, which spells names right and is much faster. The project's own video is transcribed with transcribe.", inputSchema: obj(["project": projectArg, "source": ["type": "string", "pattern": "^s[0-9]{1,3}$"], "overlay": ["type": "string", "pattern": "^o[0-9]{1,3}$"], "script": ["type": "string", "maxLength": 6000], "wait": ["type": "boolean", "default": false]], ["project"])) { i in
    let n = try name(i)
    let l = try Store.load(n)
    let target: (file: String, what: String)
    if let s = i["source"]?.string { guard let src = l.project.edits.sources.first(where: { $0.id == s }) else { throw ToolError("not_found", "No source \(s)") }; target = (src.file, src.label) }
    else if let o = i["overlay"]?.string { guard let ov = l.project.edits.audioOverlays?.first(where: { $0.id == o }) else { throw ToolError("not_found", "No audio overlay \(o)") }; target = (ov.file, ov.label) }
    else { throw ToolError("invalid_input", "Give source (s1) or overlay (o1)") }
    let script = i["script"]?.string
    if i["wait"]?.bool == true { return ["project": .string(n), "words": .number(Double(try await Jobs.transcribeFile(n, file: target.file, script: script, what: target.what)))] }
    Task.detached { _ = try? await Jobs.transcribeFile(n, file: target.file, script: script, what: target.what) }
    return ["project": .string(n), "started": true]
  },
  ReelTool(name: "undo", description: "Steps back the last edit (cuts and their approval, trims, splits, clip changes, word cuts, corrections, audio and face overlays with their windows, muted clips, clip names, a clip's look, placement and hidden title, animation changes). Settings (captions, title, speed, sections, the reel's look, music, voice volume and bass and treble, caption, caption position, status, references, cost) are not edits. changed false means there was nothing to undo.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let (m, label) = try Store.step(try name(i), undo: true)
    return result(m, ["step": label.map { .string($0) } ?? .null])
  },
  ReelTool(name: "redo", description: "Steps forward again after an undo.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let (m, label) = try Store.step(try name(i), undo: false)
    return result(m, ["step": label.map { .string($0) } ?? .null])
  },
  ReelTool(name: "set_captions", description: "Turns the burned in captions on or off. A project with a transcript has them on until this says otherwise.", inputSchema: obj(["project": projectArg, "enabled": ["type": "boolean"]], ["project", "enabled"])) { i in
    try edit(i, "set_captions") { e, _, _ in e.export.captions = i["enabled"]!.bool!; return [:] }
  },
  ReelTool(name: "set_title", description: "Sets the burned in title at the top of the frame: enabled turns it on or off, text sets what it says.", inputSchema: obj(["project": projectArg, "enabled": ["type": "boolean"], "text": ["type": "string", "maxLength": 80]], ["project", "enabled"])) { i in
    try edit(i, "set_title") { e, _, _ in e.export.title = i["enabled"]!.bool!; if let t = i["text"]?.string { e.titleText = t.isEmpty ? nil : t }; return [:] }
  },
  ReelTool(name: "set_speed", description: "Sets the playback speed, 0.1x to 4x in steps of 0.1. Preview and export play at it: picture, voice, captions and animations together, so the export is the cut length divided by the speed.", inputSchema: obj(["project": projectArg, "speed": ["type": "number", "minimum": 0.1, "maximum": 4]], ["project", "speed"])) { i in
    let s = (i["speed"]!.double! * 10).rounded() / 10
    return try edit(i, "set_speed") { e, _, _ in e.export.speed = abs(s - 1) < 1e-6 ? nil : s; return [:] }
  },
  ReelTool(name: "set_sections", description: "Divides the script into named sections, shown in the transcript as headings. Replaces them all; an empty list clears them. Each starts at a word index (from) and runs to the next one. Not an edit, no undo step.", inputSchema: obj(["project": projectArg, "sections": ["type": "array", "maxItems": 200, "items": obj(["title": ["type": "string", "minLength": 1, "maxLength": 80], "from": ["type": "integer", "minimum": 0]], ["title", "from"])]], ["project", "sections"])) { i in
    try edit(i, "set_sections") { e, _, _ in
      var seen = Set<Int>()
      let list = i["sections"]!.array!.compactMap { s -> (String, Int)? in guard let t = s["title"]?.string, let f = s["from"]?.int else { return nil }; return (t, f) }
        .sorted { $0.1 < $1.1 }.filter { seen.insert($0.1).inserted }
      e.sections = list.isEmpty ? nil : list.enumerated().map { Section(id: "s\($0.offset + 1)", title: $0.element.0, from: $0.element.1) }
      return ["sections": .number(Double(list.count))]
    }
  },
  ReelTool(name: "list_animation_kinds", description: "The kinds of coded animation the animation layer can play, with the fields each one reads and its usual length.", inputSchema: obj([:])) { _ in
    .object(["kinds": .array(ANIMATION_KINDS.map { ["id": .string($0.id), "title": .string($0.title), "description": .string($0.description), "fields": .array($0.fields.map { .string($0) }), "defaultLength": .number($0.defaultLength)] })])
  },
  ReelTool(name: "get_animations", description: "The animation layer (animations.json): every animation with its id, kind, start and end in edit time, outStart and outEnd in the export, side, position and fields.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let s = ReelState.of(try Store.load(try name(i)), words: false)
    return ["project": i["project"]!, "animations": s["animations"] ?? []]
  },
  ReelTool(name: "add_animation", description: "Adds a coded animation to the animation layer at its own timestamps (edit time). It is laid over the video in the preview and burned into the export under the captions. Returns its id. Undo takes it back.", inputSchema: obj(animFields.merging(["project": projectArg]) { a, _ in a }, ["project", "kind", "start", "end"])) { i in
    try edit(i, "add_animation") { _, anims, _ in
      var a = ReelAnimation(kind: i["kind"]!.string!, start: 0, end: 0)
      applyFields(&a, i)
      try checkAnimation(a)
      let before = Set(anims.map(\.id))
      anims = normalizeAnimations(anims + [a])
      return ["created": .string(anims.first { !before.contains($0.id) }?.id ?? "")]
    }
  },
  ReelTool(name: "update_animation", description: "Changes an animation of the layer by id: only the fields given change (move it with start and end, retext it, change its side).", inputSchema: obj(animFields.merging(["project": projectArg, "id": ["type": "string", "minLength": 1, "maxLength": 40]]) { a, _ in a }, ["project", "id"])) { i in
    try edit(i, "update_animation") { _, anims, _ in
      guard let k = anims.firstIndex(where: { $0.id == i["id"]!.string! }) else { throw ToolError("not_found", "No animation \(i["id"]!.string!). Ids: \(anims.map(\.id).joined(separator: ", "))") }
      applyFields(&anims[k], i)
      try checkAnimation(anims[k])
      return [:]
    }
  },
  ReelTool(name: "remove_animation", description: "Takes an animation off the layer by id. Undo brings it back.", inputSchema: obj(["project": projectArg, "id": ["type": "string", "minLength": 1, "maxLength": 40]], ["project", "id"])) { i in
    try edit(i, "remove_animation") { _, anims, _ in
      let id = i["id"]!.string!
      guard anims.contains(where: { $0.id == id }) else { throw ToolError("not_found", "No animation \(id)") }
      anims.removeAll { $0.id == id }
      return [:]
    }
  },
  ReelTool(name: "set_animations", description: "Replaces the whole animation layer with this list; an empty list clears it. Keep an id to keep an animation, a new one gets a1, a2 and so on.", inputSchema: obj(["project": projectArg, "animations": ["type": "array", "maxItems": 100, "items": obj(animFields.merging(["id": ["type": "string", "maxLength": 40]]) { a, _ in a }, ["kind", "start", "end"])]], ["project", "animations"])) { i in
    try edit(i, "set_animations") { _, anims, _ in
      let list = try i["animations"]!.array!.map { j -> ReelAnimation in
        var a = ReelAnimation(id: j["id"]?.string ?? "", kind: j["kind"]!.string!, start: 0, end: 0)
        applyFields(&a, j)
        try checkAnimation(a)
        return a
      }
      anims = list
      return ["animations": .number(Double(list.count))]
    }
  },
  ReelTool(name: "transcribe", description: "Transcribes the project's speech with WhisperX for word timings, in the background (a minute or two a video): the project's own video again, then every added video that has no words yet, one after another; one that fails or has no speech does not stop the rest. Poll get_status, which says how far it is. Replaces the project's own transcript; word cuts are word indexes, so cut words of an old transcript may no longer match. wait true answers when every video is done, with the words and the videos done and failed.", inputSchema: obj(["project": projectArg, "wait": ["type": "boolean", "default": false]], ["project"])) { i in
    let n = try name(i)
    let todo = try Jobs.pendingVideos(n, redoMain: true)
    if todo.isEmpty {
      if !(try Store.load(n)).project.main.hasAudio { throw ToolError("no_audio", "The video has no sound to transcribe, and every added video with sound already has its words") }
      return ["project": .string(n), "started": false, "videos": .array([])]
    }
    if i["wait"]?.bool == true {
      let r = try await Jobs.transcribeAll(n, redoMain: true)
      return ["project": .string(n), "words": .number(Double(r.words)), "done": .array(r.done.map { .string($0) }),
              "failed": .array(r.failed.map { ["video": .string($0.0), "error": .string($0.1)] })]
    }
    Store.setStatus(n, ["state": "transcribing", "kind": "transcribe", "message": "Queued", "pid": .number(Double(getpid()))])
    Task.detached { _ = try? await Jobs.transcribeAll(n, redoMain: true) }
    return ["project": .string(n), "started": true, "videos": .array(todo.map { .string($0.label) })]
  },
  ReelTool(name: "import_transcript", description: "Sets the project's words from a JSON file of [{w, s, e}] (word, start and end in source seconds of the project's own video), for example a transcript made elsewhere.", inputSchema: obj(["project": projectArg, "path": ["type": "string", "minLength": 1, "maxLength": 2048]], ["project", "path"])) { i in
    let n = try name(i)
    _ = try Store.load(n)
    let url = URL(fileURLWithPath: (i["path"]!.string! as NSString).expandingTildeInPath)
    struct T: Decodable { var words: [Word] }
    let data = try Data(contentsOf: url)
    guard let words = (try? JSONDecoder().decode([Word].self, from: data)) ?? (try? JSONDecoder().decode(T.self, from: data).words) else { throw ToolError("invalid_input", "The file has to be a list of {w, s, e} or an object with a words list") }
    try Store.saveWords(n, words, engine: "imported")
    return ["project": .string(n), "words": .number(Double(words.count))]
  },
  ReelTool(name: "get_status", description: "What is running on a project: state (ready, transcribing, exporting, error), a message, progress for an export (0 to 1), and for a finished export its result (file, seconds).", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let n = try name(i)
    var s = Store.status(n).object ?? [:]
    s["project"] = .string(n)
    s["rev"] = .number(Double(Store.revs(n).0))
    return .object(s)
  },
  ReelTool(name: "export", description: "Renders the edit to an MP4: the kept ranges of the clips joined, at the speed, with the look, the placed clips, the face windows, the voice overs, the music, the voice volume and bass and treble, the animation layer and the captions and title when they are on (captions and title here override the setting for this export only). The source video is never written. Default file: exports/<project>-edited.mp4 in the project folder. Returns at once; poll get_status, or pass wait true.", inputSchema: obj(["project": projectArg, "path": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "Where to write the MP4 instead of the default."], "wait": ["type": "boolean", "default": false],
    "captions": ["type": "boolean", "description": "Override the captions setting for this export."], "title": ["type": "boolean", "description": "Override the title setting for this export."]], ["project"])) { i in
    let n = try name(i)
    _ = try Store.load(n)
    let target = i["path"]?.string.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let caps = i["captions"]?.bool, title = i["title"]?.bool
    if i["wait"]?.bool == true { return ["project": .string(n), "result": try await Jobs.export(n, to: target, captions: caps, title: title)] }
    Store.setStatus(n, ["state": "exporting", "kind": "export", "progress": 0, "message": "Queued"])
    Task.detached { _ = try? await Jobs.export(n, to: target, captions: caps, title: title) }
    return ["project": .string(n), "started": true, "file": .string((target ?? Jobs.defaultExportURL(n)).path)]
  },
  ReelTool(name: "rename_project", description: "Renames a project: title is what it is called on screen (free text), and its folder and name become the matching lowercase-and-dashes name (Sankalp Intro becomes sankalp-intro, with -2 when taken). Returns the new name, which every later call uses; the old one is remembered so the app's open tab follows. The video and the edits are untouched.", inputSchema: obj(["project": projectArg, "title": ["type": "string", "minLength": 1, "maxLength": 120]], ["project", "title"])) { i in
    let r = try Store.rename(try name(i), title: i["title"]!.string!)
    return ["project": .string(r.name), "previous": .string(r.previous), "title": i["title"]!]
  },
  ReelTool(name: "get_logs", description: "Reads the QA logs in the _dump folder: one line per tool call (from the app or from an agent), app action and error, with the time, the build, the arguments, whether it worked, the error and how long it took. source app or mcp (default both), errors_only for the failures.", inputSchema: obj(["source": ["type": "string", "enum": ["app", "mcp"]], "errors_only": ["type": "boolean", "default": false], "limit": ["type": "integer", "minimum": 1, "maximum": 1000, "default": 80]])) { i in
    ["folder": .string(Log.dir.path), "lines": .array(Log.tail(source: i["source"]?.string, errorsOnly: i["errors_only"]?.bool ?? false, limit: i["limit"]?.int ?? 80))]
  },
  ReelTool(name: "open_in_app", description: "Opens a project in a tab of the Reel Editor app, starting the app when it is not open, so Sankalp sees the edits as they land. Give project (a name from list_projects) or path (a <name>.reel.json file saved anywhere, which is put on the list first, as add_project does). Every later call names it by the project returned. The app reloads on its own whenever a tool changes an open project; get_app_state shows what it has on screen.", inputSchema: obj([
    "project": projectArg,
    "path": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "Absolute path of a project file (.reel.json), instead of project."],
  ])) { i in
    let n: String
    if let path = i["path"]?.string {
      n = try Store.register(file: URL(fileURLWithPath: (path as NSString).expandingTildeInPath))
    } else if i["project"]?.string != nil {
      n = try name(i)
    } else { throw ToolError("invalid_input", "Give project (a name from list_projects) or path (a .reel.json file)") }
    _ = try Store.load(n)
    let file: JSON = Store.document(n).map { .string($0.path) } ?? .null
    guard ToolContext.mayOpen else { return ["project": .string(n), "file": file, "opened": false, "skipped": "REEL_EDITOR_NO_OPEN is set"] }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    p.arguments = ["reeleditor://open?project=\(n)"]
    try p.run(); p.waitUntilExit()
    return ["project": .string(n), "file": file, "opened": .bool(p.terminationStatus == 0)]
  },
  ReelTool(name: "get_rules", description: "Reads Sankalp's rule books now: every .md, .markdown and .txt file in a project's rules folder (each project keeps its own; a new one starts with the folder saved last, the projects folder's _rules until he picks one), with its text. Give project for that project's folder; without it, the folder saved last. Call it when he asks you to read the rules again, or before editing when you have not seen them.", inputSchema: obj(["project": projectArg])) { i in
    let p = i["project"]?.string != nil ? try name(i) : nil
    if let p { _ = try Store.load(p) }
    let dir = Rules.dir(for: p)
    let books = Rules.books(in: dir)
    return ["folder": .string(dir.path), "default": .bool(Rules.isDefault(dir)), "count": .number(Double(books.count)),
            "books": .array(books.map { ["name": .string($0.name), "file": .string($0.file), "chars": .number(Double($0.text.count)), "text": .string($0.text)] })]
  },
  ReelTool(name: "set_rules_folder", description: "Sets the folder of rule books for a project and saves it as the last one, which every new project starts with. Without folder, the projects folder's _rules. Without project, only the folder new projects start with is set. A chat already running keeps the rules it started with; get_rules reads the new folder at once.", inputSchema: obj([
    "project": projectArg,
    "folder": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "Absolute path of a folder of rule books (.md, .markdown, .txt). Left out, the default _rules."],
  ])) { i in
    let p = i["project"]?.string != nil ? try name(i) : nil
    if let p { _ = try Store.load(p) }
    var folder: URL? = nil
    if let f = i["folder"]?.string {
      let u = URL(fileURLWithPath: (f as NSString).expandingTildeInPath, isDirectory: true)
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: u.path, isDirectory: &isDir), isDir.boolValue else { throw ToolError("not_found", "No folder at \(u.path)") }
      folder = u
    }
    try Rules.setDir(folder, project: p)
    let dir = Rules.dir(for: p)
    return ["project": p.map { .string($0) } ?? .null, "folder": .string(dir.path), "last": .string(Rules.lastDir.path), "count": .number(Double(Rules.books(in: dir).count))]
  },
  // Writing rule books (Sankalp, 2 Nov 2026), so an agent can write custom rules for a project when he asks.
  ReelTool(name: "write_rule_book", description: "Writes a rule book, a new one or a whole new text for one, into a project's rules folder (without project, the folder new projects start with). name is its path inside the folder, like trims.md or voice/tone.md (.md when left out; .md, .markdown and .txt only). The text it had is kept in the folder's hidden .previous folder. The answer says which other projects read the same folder: rules meant only for this project go in a folder of its own, made with make_project_rules_folder first. To change a few lines, edit_rule_book.", inputSchema: obj([
    "project": projectArg,
    "name": ["type": "string", "minLength": 1, "maxLength": 200, "description": "The rule book's path inside the rules folder, for example trims.md."],
    "text": ["type": "string", "minLength": 1, "maxLength": 200000, "description": "The whole text of the rule book, in markdown."],
  ], ["name", "text"])) { i in
    let p = i["project"]?.string != nil ? try name(i) : nil
    if let p { _ = try Store.load(p) }
    let dir = Rules.dir(for: p)
    let r = try Rules.write(dir, i["name"]?.string ?? "", i["text"]?.string ?? "")
    var o = rulesAnswer(p, dir)
    o["name"] = .string(r.name); o["file"] = .string(r.url.path); o["created"] = .bool(r.created)
    if let k = r.previous { o["previous"] = .string(k) }
    return .object(o)
  },
  ReelTool(name: "edit_rule_book", description: "Changes part of a rule book in a project's rules folder (without project, the folder new projects start with): old is replaced by new, as exact text. old must be found once, or give all true to replace every one. The text it had is kept in the folder's hidden .previous folder. get_rules shows the books and their text.", inputSchema: obj([
    "project": projectArg,
    "name": ["type": "string", "minLength": 1, "maxLength": 200, "description": "The rule book's path inside the rules folder, as get_rules names it."],
    "old": ["type": "string", "minLength": 1, "maxLength": 200000, "description": "The exact text to replace."],
    "new": ["type": "string", "maxLength": 200000, "description": "The text to put in its place; empty removes it."],
    "all": ["type": "boolean", "description": "True replaces every place old is found."],
  ], ["name", "old", "new"])) { i in
    let p = i["project"]?.string != nil ? try name(i) : nil
    if let p { _ = try Store.load(p) }
    let dir = Rules.dir(for: p)
    let (url, book) = try Rules.bookURL(dir, i["name"]?.string ?? "")
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { throw ToolError("not_found", "No rule book \(book) in \(dir.path); write_rule_book makes a new one") }
    let old = i["old"]?.string ?? "", new = i["new"]?.string ?? ""
    let n = text.components(separatedBy: old).count - 1
    if n == 0 { throw ToolError("not_found", "old is not in \(book); read it with get_rules and copy the text exactly") }
    if n > 1 && i["all"]?.bool != true { throw ToolError("ambiguous", "old is in \(book) \(n) times; give more of the text around it, or all true") }
    let kept = Rules.keepPrevious(dir, url, book)
    try text.replacingOccurrences(of: old, with: new).write(to: url, atomically: true, encoding: .utf8)
    var o = rulesAnswer(p, dir)
    o["name"] = .string(book); o["file"] = .string(url.path); o["replaced"] = .number(Double(n))
    if let kept { o["previous"] = .string(kept) }
    return .object(o)
  },
  ReelTool(name: "delete_rule_book", description: "Takes a rule book out of a project's rules folder (without project, the folder new projects start with), so it is no longer read. Its text is kept in the folder's hidden .previous folder, from where it can be put back by hand. The answer names the other projects that read the same folder, which lose it too.", inputSchema: obj([
    "project": projectArg,
    "name": ["type": "string", "minLength": 1, "maxLength": 200, "description": "The rule book's path inside the rules folder, as get_rules names it."],
  ], ["name"])) { i in
    let p = i["project"]?.string != nil ? try name(i) : nil
    if let p { _ = try Store.load(p) }
    let dir = Rules.dir(for: p)
    let (url, book) = try Rules.bookURL(dir, i["name"]?.string ?? "")
    guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("not_found", "No rule book \(book) in \(dir.path); get_rules lists them") }
    guard let kept = Rules.keepPrevious(dir, url, book) else { throw ToolError("write_failed", "Could not keep a copy of \(book), so it was left in place") }
    try FileManager.default.removeItem(at: url)
    var o = rulesAnswer(p, dir)
    o["name"] = .string(book); o["deleted"] = true; o["previous"] = .string(kept)
    return .object(o)
  },
  ReelTool(name: "make_project_rules_folder", description: "Gives a project a rules folder of its own, so rules written for it reach no other project: <projects folder>/_rules-by-project/<project>, with copies of the rule books it reads now unless copy is false, and the project pointed at it. The folder new projects start with is not changed. A project that already has its own folder keeps it. Then write_rule_book and edit_rule_book with this project change only its rules.", inputSchema: obj([
    "project": projectArg,
    "copy": ["type": "boolean", "description": "False starts the folder empty. True by default: copies of the rule books the project reads now."],
  ], ["project"])) { i in
    let p = try name(i)
    _ = try Store.load(p)
    let r = try Rules.makeOwn(p, copy: i["copy"]?.bool ?? true)
    var o = rulesAnswer(p, r.dir)
    o["copied"] = .array(r.copied.map { .string($0) }); o["already"] = .bool(r.already)
    return .object(o)
  },
  ReelTool(name: "get_app_state", description: "What the Reel Editor app shows right now: whether it is open, its tabs, the project in front and its file, the playhead (edit time) and whether it plays, the clip under the playhead, and what Sankalp has selected (a range, words with their text, an animation). Read it to talk about what he is looking at, for example \"cut this\" means the selection. running false means the app is not open; open_in_app starts it.", inputSchema: obj([:])) { _ in
    guard let s = AppState.read(), var o = s.object else { return ["running": false, "hint": "The Reel Editor app is not open. open_in_app opens a project in it."] }
    o["running"] = true
    o["pid"] = nil
    return .object(o)
  },
]

// Every tool: the Mac app's own, the ones ported from the web editor (ToolsWeb.swift) and the web editor's names for the
// Mac tools that do the same thing (list_reels, get_timeline, import_video).
public let reelTools: [ReelTool] = { let base = coreTools + webTools + auditTools + focusTools; return base + webAliases(base) }()

public let toolByName: [String: ReelTool] = Dictionary(uniqueKeysWithValues: reelTools.map { ($0.name, $0) })

public enum ToolReply { case ok(JSON), failure(code: String, message: String) }

// Calling a tool by name, the one door the app and the MCP server both use.
public func callTool(_ name: String, _ input: JSON?) async -> ToolReply {
  guard let tool = toolByName[name] else { return .failure(code: "unknown_tool", message: "Unknown tool \(name)") }
  var args = input.flatMap { $0.isNull ? nil : $0 } ?? [:]
  // The web editor calls a project a reel: reel is taken as project in every tool.
  if var o = args.object, let r = o["reel"], o["project"] == nil { o.removeValue(forKey: "reel"); o["project"] = r; args = .object(o) }
  let started = Date()
  let reply: ToolReply = await {
    let problems = validate(tool.inputSchema, args)
    if !problems.isEmpty { return .failure(code: "invalid_input", message: problems.joined(separator: "; ")) }
    do { return .ok(try await tool.run(args)) }
    catch let e as ToolError { return .failure(code: e.code, message: e.message) }
    catch let e as EdlError { return .failure(code: e.code, message: e.message) }
    catch { return .failure(code: "internal_error", message: String(describing: error).prefix(400).description) }
  }()
  // The QA log: every call, from the app or from an agent, with how it went.
  let ms = Int(Date().timeIntervalSince(started) * 1000)
  switch reply {
  case .ok(let r):
    // Who edited the project, for its Project card.
    if let p = r["project"]?.string, r["changed"]?.bool == true || ["create_project", "import_video"].contains(name) { Editors.record(p, tool: name) }
    var extra: [String: JSON] = ["by": .string(ToolContext.client)]
    for k in ["changed", "created", "duration", "project", "step", "overlaysMoved"] { if let v = r[k] { extra[k] = v } }
    Log.write("tool", name, args: args, ms: ms, extra: extra)
  case .failure(let code, let message):
    Log.write("tool", name, args: args, ok: false, error: "\(code): \(message)", ms: ms, extra: ["by": .string(ToolContext.client)])
  }
  return reply
}

// What a rules tool answers with: the folder, its rule books, and the other projects that read the same folder.
func rulesAnswer(_ project: String?, _ dir: URL) -> [String: JSON] {
  let path = dir.standardizedFileURL.path
  let others = Store.names().filter { $0 != project && Rules.dir(for: $0).standardizedFileURL.path == path }
  return ["project": project.map { .string($0) } ?? .null, "folder": .string(dir.path), "books": .array(Rules.books(in: dir).map { .string($0.name) }),
          "sharedWith": .array(others.map { .string($0) })]
}
