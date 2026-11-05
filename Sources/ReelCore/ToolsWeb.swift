// The tools the web reel editor gained after 23 Oct 2026 (lib/reel-tools/tools.ts), ported with the same names, the same
// arguments and the same meaning, so an agent can use either editor the same way. The web editor's `reel` argument is this
// app's `project` (callTool takes either). Each one notes in its description where the Mac app differs.
import Foundation

private let overlayId: JSON = ["type": "string", "pattern": "^o[0-9]{1,3}$", "description": "An overlay's id from get_project (audioOverlays), for example o1."]
private let lookValues: [String: JSON] = [
  "saturation": ["type": "number", "minimum": -100, "maximum": 100], "brightness": ["type": "number", "minimum": -100, "maximum": 100], "exposure": ["type": "number", "minimum": -100, "maximum": 100],
  "contrast": ["type": "number", "minimum": -100, "maximum": 100], "temperature": ["type": "number", "minimum": -100, "maximum": 100, "description": "Minus is cooler, plus warmer."],
  "sharpness": ["type": "number", "minimum": 0, "maximum": 100], "vignette": ["type": "number", "minimum": 0, "maximum": 100],
]
private let placeSchema: JSON = ["type": "object", "description": "Zooms and moves the picture inside the window: zoom 0.5 to 4 (1 as recorded), x and y -1 to 1 as shares of the window's own width and height.",
                                 "properties": ["zoom": ["type": "number", "minimum": 0.5, "maximum": 4], "x": ["type": "number", "minimum": -1, "maximum": 1], "y": ["type": "number", "minimum": -1, "maximum": 1]], "additionalProperties": false]
private let windowSchema: JSON = ["type": "object", "description": "The window: x (share of the frame's width its left edge is at), y (share of the height its middle is at) and w (share of the width it is wide), and moves, each { at, x, y, dur } easing to a new place at that many seconds into the overlay.",
  "properties": [
    "x": ["type": "number", "minimum": -1, "maximum": 2], "y": ["type": "number", "minimum": -1, "maximum": 2], "w": ["type": "number", "minimum": 0.05, "maximum": 1],
    "ratio": ["type": "number", "minimum": 0.2, "maximum": 3, "description": "The window's height over its width, the picture cropped to fill it. Leave out to follow the file's own shape."],
    "radius": ["type": "number", "minimum": 0, "maximum": 540, "description": "Corner radius in px of a 1080 wide frame, default 40."],
    "place": placeSchema,
    "moves": ["type": "array", "maxItems": 30, "items": ["type": "object", "properties": ["at": ["type": "number", "minimum": 0], "x": ["type": "number", "minimum": -1, "maximum": 2], "y": ["type": "number", "minimum": -1, "maximum": 2], "dur": ["type": "number", "minimum": 0, "maximum": 10]], "required": ["at", "x", "y"], "additionalProperties": false]],
  ], "required": ["x", "y", "w"], "additionalProperties": false]
private let referencesSchema: JSON = ["type": "array", "maxItems": 20, "description": "The links, in the order shown.", "items": ["type": "object", "properties": [
  "kind": ["type": "string", "enum": ["format", "json"]], "title": ["type": "string", "minLength": 1, "maxLength": 120, "description": "The name shown on the link."], "path": ["type": "string", "minLength": 1, "maxLength": 300]],
  "required": ["kind", "title", "path"], "additionalProperties": false]]
private let sectionId: JSON = ["type": "string", "pattern": "^d[0-9]{1,3}$", "maxLength": 8, "description": "The id of the part, d1, d2 and so on, as get_draft_reel lists them."]

// A setting change through the same door as an edit: Store.mutate saves it with no undo step, since it leaves the clips, cuts,
// words, overlays and animations as they were.
private func setting(_ i: JSON, _ label: String, _ fn: @escaping (inout Edl) throws -> [String: JSON]) throws -> JSON {
  try edit(i, label) { e, _, _ in try fn(&e) }
}

private func openInFinder(_ args: [String]) throws -> Bool {
  guard ToolContext.mayOpen else { return false }
  let p = Process()
  p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
  p.arguments = args
  try p.run(); p.waitUntilExit()
  return p.terminationStatus == 0
}

// A file picked in a browser or a Finder dialog gives its name and size but not its folder: it is looked for by both in
// Downloads, Desktop and Movies, three folders deep, hidden folders and packages skipped.
private func locate(_ fileName: String, size: Int) -> URL? {
  let fm = FileManager.default
  let home = fm.homeDirectoryForCurrentUser
  var budget = 20000
  func walk(_ dir: URL, _ depth: Int) -> URL? {
    let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles])) ?? []
    for u in items {
      budget -= 1; if budget < 0 { return nil }
      if u.lastPathComponent == fileName, let s = try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize, s == size { return u }
    }
    if depth >= 3 { return nil }
    for u in items where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && u.pathExtension.range(of: "^(app|photoslibrary|fcpbundle|imovielibrary|tvlibrary)$", options: [.regularExpression, .caseInsensitive]) == nil && u.lastPathComponent != "node_modules" {
      if let hit = walk(u, depth + 1) { return hit }
    }
    return nil
  }
  for r in ["Downloads", "Desktop", "Movies"] { if let hit = walk(home.appendingPathComponent(r), 0) { return hit } }
  return nil
}

let webTools: [ReelTool] = [
  // ---------------------------------------------------------------------------------------------------------------------
  // Cuts waiting for approval

  ReelTool(name: "approve_cuts", description: "Approves cuts made from the chat (an agent through MCP), which wait until Sankalp approves them: range cuts by id (cuts) and cut words by index (words), or every waiting one when neither is given. Run it when Sankalp says to approve. Approved cuts stay cut and are drawn like any other. Undo takes the approval back.", inputSchema: obj([
    "project": projectArg, "cuts": ["type": "array", "items": ["type": "string", "maxLength": 12], "maxItems": 200], "words": ["type": "array", "items": ["type": "integer", "minimum": 0], "maxItems": 2000],
  ], ["project"])) { i in
    try edit(i, "approve_cuts") { e, _, _ in let r = approveCuts(e, ids: i["cuts"]?.array?.compactMap(\.string), words: i["words"]?.array?.compactMap(\.int)); e = r.edl; return r.info }
  },

  // ---------------------------------------------------------------------------------------------------------------------
  // A clip's title, look and placement

  ReelTool(name: "set_clip_title", description: "Hides the reel's title over one clip, from its first frame to its last, or shows it again: visible false hides it, true clears the hiding. The preview and the export leave the title out there (titleHides in get_project), and it moves with the clip when clips are reordered and with the cuts. The picture and sound are untouched. Undoable.", inputSchema: obj([
    "project": projectArg, "clip": clipArg, "visible": ["type": "boolean", "description": "False hides the title over the clip, true shows it."],
  ], ["project", "clip", "visible"])) { i in
    try edit(i, "set_clip_title") { e, _, m in let r = try setClipTitle(e, m, i["clip"]!.string!, i["visible"]!.bool!); e = r.edl; return r.info }
  },
  ReelTool(name: "set_clip_look", description: "Sets the look of one clip's own picture, or of several at once (clips), so the reel can carry several looks, one per stretch of clips: look a saved look's name (list_video_looks), values a look of its own (saturation, brightness, exposure, contrast, temperature, sharpness, vignette, as set_video_look takes them; all 0 is off), off true for no look at all, or reel_look true to go back to the reel's own look. A face window drawn over the clip keeps the reel's look. The preview and the export follow it and it moves with the clip. One undo step.", inputSchema: obj([
    "project": projectArg, "clip": clipArg, "clips": ["type": "array", "maxItems": 100, "items": clipArg, "description": "Several clips set alike, in place of clip."],
    "look": ["type": "string", "maxLength": 80, "description": "A saved look's name or file name."],
    "values": ["type": "object", "properties": .object(lookValues), "additionalProperties": false, "description": "A look of its own, the keys of set_video_look."],
    "name": ["type": ["string", "null"], "maxLength": 60, "description": "The name shown for values, null for a custom look."],
    "off": ["type": "boolean"], "reel_look": ["type": "boolean", "description": "True puts the reel's own look back on the clip."],
    "visible": ["type": "boolean", "description": "Older form: false is off, true is the reel's look."],
  ], ["project"])) { i in
    let ids = (i["clips"]?.array?.compactMap(\.string)).flatMap { $0.isEmpty ? nil : $0 } ?? i["clip"]?.string.map { [$0] } ?? []
    if ids.isEmpty { throw ToolError("invalid_input", "Give clip or clips") }
    let mode: ClipLookMode
    if let t = i["look"]?.string { let tpl = try Looks.get(t); var l = tpl.look; l.name = tpl.name; mode = .own(l) }
    else if let v = i["values"] {
      var o = v.object ?? [:]
      if let n = i["name"]?.string { o["name"] = .string(n) }
      mode = normalizeLook(JSON.object(o)).map { .own($0) } ?? .off
    } else if i["off"]?.bool == true || i["visible"]?.bool == false { mode = .off }
    else { mode = .reel }
    return try edit(i, "set_clip_look") { e, _, m in
      var info: [String: JSON] = [:]
      for id in ids { let r = try setClipLook(e, m, id, mode); e = r.edl; info = r.info }
      info["clips"] = .array(ids.map { .string($0) })
      info.removeValue(forKey: "clip")
      return info
    }
  },
  ReelTool(name: "set_clip_placement", description: "Places one clip's own picture in the frame: zoom it in or out and move it left, right, up or down. zoom is a factor (1 as recorded, 2 twice as big, 0.5 to 4), x and y move the picture's centre as a share of the frame's width and height (x 0.25 a quarter of the frame to the right, y 0.25 a quarter down, -1 to 1); what the picture no longer covers shows black. Omit a field to keep it as it is on the clip, reset true puts the picture back as recorded. A face window over the clip, its sound, the captions and the title are not moved. The preview and the export follow it and it moves with the clip. One undo step.", inputSchema: obj([
    "project": projectArg, "clip": clipArg, "zoom": ["type": "number", "minimum": 0.5, "maximum": 4], "x": ["type": "number", "minimum": -1, "maximum": 1], "y": ["type": "number", "minimum": -1, "maximum": 1],
    "reset": ["type": "boolean", "description": "True puts the picture back as recorded."],
  ], ["project", "clip"])) { i in
    try edit(i, "set_clip_placement") { e, _, m in
      let id = i["clip"]!.string!
      if i["reset"]?.bool == true { let r = try setClipPlace(e, m, id, nil); e = r.edl; return r.info }
      if i["zoom"] == nil && i["x"] == nil && i["y"] == nil { throw ToolError("invalid_input", "Give zoom, x, y or reset") }
      let cur = clipsOf(e, m).first { $0.id == id }?.place
      let next = ReelPlace(zoom: i["zoom"]?.double ?? cur?.zoom ?? 1, x: i["x"]?.double ?? cur?.x ?? 0, y: i["y"]?.double ?? cur?.y ?? 0)
      let r = try setClipPlace(e, m, id, next); e = r.edl; return r.info
    }
  },

  // ---------------------------------------------------------------------------------------------------------------------
  // Face overlays

  ReelTool(name: "add_face_overlay", description: "Lays a video over the reel as its own layer, Face, above the Video layer: the face of a call out in a small rounded window (a #333 border, a soft shadow) over the picture, from an edit time. Its sound is the overlay's sound (the voice), so mute the clip it sits over (mute_clip) when that clip has sound of its own. It follows the cuts, can be trimmed (update_audio_overlay), split (split_overlay) and moved, and window.moves animates it: at a time into the overlay it eases to a new place. The window is x (share of the frame's width its left edge is at), y (share of the height its middle is at) and w (share of the width it is wide), for example x 0.04, y 0.5, w 0.36 is the left middle. x and y can go outside the frame (-1 to 2), which is how it slides in or out. layer video puts a screen recording or landing page on the Video layer in its window instead. The preview and the export draw it. Undoable.", inputSchema: obj([
    "project": projectArg,
    "path": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "A video file with the face and its voice (mp4, mov, m4v). It is only read."],
    "start": sec("Where it begins, in edit time seconds. Default 0."), "in": sec("Seconds into the file where the part that plays starts. Default 0."), "out": sec("Seconds into the file where it ends. Default its end."),
    "gain": ["type": "number", "minimum": 0, "maximum": 2, "description": "Volume of its sound, 1 is as it is. Default 1."],
    "label": ["type": "string", "maxLength": 80, "description": "The name shown on the layer. Default the file's name."],
    "window": windowSchema,
    "mute_clip": ["type": "string", "minLength": 1, "maxLength": 40, "description": "A clip id whose own sound is muted at the same time."],
    "transcribe": ["type": "boolean", "default": true, "description": "Get the words of its sound for the captions (WhisperX in the background)."],
    "script": ["type": "string", "maxLength": 6000, "description": "The exact words spoken, placed on the sound instead of transcribing."],
    "layer": ["type": "string", "enum": ["face", "video"], "default": "face"],
  ], ["project", "path", "window"])) { i in
    guard let win = normalizeWindow(i["window"]) else { throw ToolError("invalid_input", "window needs x, y and w as numbers") }
    let url = try Store.videoURL(i["path"]!.string!)
    let info = try await Media.probe(url)
    let label = i["label"]?.string ?? humanClipLabel(url.path)
    let out = try edit(i, "add_face_overlay") { e, _, m in
      var r = try addAudioOverlay(e, m, file: url.path, duration: info.duration, label: label, start: i["start"]?.double ?? 0, inn: i["in"]?.double, out: i["out"]?.double, gain: i["gain"]?.double,
                                  window: win, layer: i["layer"]?.string)
      if let c = i["mute_clip"]?.string { r.edl = try muteClipAudio(r.edl, m, c, true).edl; r.info["mutedClip"] = .string(c) }
      e = r.edl; return r.info
    }
    let n = try name(i)
    let script = i["script"]?.string
    var transcribing = false
    if info.hasAudio, (i["transcribe"]?.bool ?? true) || script != nil, Jobs.whisperx() != nil {
      transcribing = true
      Task.detached { _ = try? await Jobs.transcribeFile(n, file: url.path, script: script, what: label) }
    }
    var o = out.object ?? [:]; o["words"] = ["transcribing": .bool(transcribing)]
    return .object(o)
  },
  ReelTool(name: "set_face_window", description: "Sets where the window of a face overlay is and how it moves: x, y, w as for add_face_overlay, and moves (replacing the old ones), each easing to a new place at a time into the overlay. This is how a face is animated: the window of a call out sits at the left middle and jumps to the top right, for example. Undoable.", inputSchema: obj([
    "project": projectArg, "id": overlayId, "window": windowSchema,
  ], ["project", "id", "window"])) { i in
    guard let win = normalizeWindow(i["window"]) else { throw ToolError("invalid_input", "window needs x, y and w as numbers") }
    return try edit(i, "set_face_window") { e, _, m in let r = try setFaceWindow(e, m, i["id"]!.string!, win); e = r.edl; return r.info }
  },
  ReelTool(name: "split_overlay", description: "Splits an audio or face overlay in two at an edit time, so each half can be trimmed, moved or deleted on its own. A face overlay's window carries over: the second half starts where the window is at that moment and keeps the moves still to come. Undoable.", inputSchema: obj([
    "project": projectArg, "id": overlayId, "at": sec("The edit time to split at, inside the overlay."),
  ], ["project", "id", "at"])) { i in
    try edit(i, "split_overlay") { e, _, m in let r = try splitAudioOverlay(e, m, i["id"]!.string!, i["at"]!.double!); e = r.edl; return r.info }
  },

  // ---------------------------------------------------------------------------------------------------------------------
  // The reel's settings: none of these is an undo step

  ReelTool(name: "set_music", description: "Sets the music bed: volume (gain 0 to 1), fades (seconds), mute, the track and the clip of it that plays (start, end, seconds, end 0 is the track's end, repeated from start where it ends). track is an absolute path to an audio file, or the name of a file in the projects folder's _music (the Mac app has no music library of its own); null takes the track away. none true removes the music completely; choosing a track again brings it back. Only the fields given change. Muted or with no track nothing plays. The preview and the export play it at its volume with its fades, never sped up with the reel and never ducked under the voice (duck is kept for older files and ignored). A setting, not an undo step.", inputSchema: obj([
    "project": projectArg, "gain": ["type": "number", "minimum": 0, "maximum": 1], "fadeIn": sec("Fade in, seconds."), "fadeOut": sec("Fade out, seconds."),
    "duck": ["type": "boolean"], "mute": ["type": "boolean"], "none": ["type": "boolean", "description": "True removes the music completely."],
    "track": ["type": ["string", "null"], "maxLength": 2048], "start": sec("Where in the track the clip starts."), "end": sec("Where it ends, 0 for the track's end."),
  ], ["project"])) { i in
    if let t = i["track"]?.string {
      var probe = Edl(); probe.music = MusicSettings(); probe.music!.track = t
      guard let url = Compose.musicFile(probe) else { throw ToolError("not_found", "No audio file \(t), give an absolute path or the name of a file in \(Store.root.appendingPathComponent("_music").path)") }
      _ = try await Media.probeAudio(url)
    }
    return try setting(i, "set_music") { e in
      var m = e.music ?? MusicSettings()
      if let v = i["gain"]?.double { m.gain = round3(v) }
      if let v = i["fadeIn"]?.double { m.fadeIn = round3(v) }
      if let v = i["fadeOut"]?.double { m.fadeOut = round3(v) }
      if let v = i["duck"]?.bool { m.duck = v }
      if let v = i["mute"]?.bool { m.mute = v }
      if let v = i["start"]?.double { m.start = round3(v) }
      if let v = i["end"]?.double { m.end = round3(v) }
      if let t = i["track"] { m.track = t.string; if t.string != nil && i["none"] == nil { m.none = nil } } // choosing a track brings the music back
      if let v = i["none"]?.bool { m.none = v ? true : nil }
      if m.none == true { m.track = nil }
      e.music = m
      return ["music": JSON.from(m)]
    }
  },
  ReelTool(name: "set_video_look", description: "Sets the look of the reel's picture, for the whole reel: saturation, brightness, exposure, contrast, temperature (minus is cooler, plus warmer), each -100 to 100, and sharpness and vignette, 0 to 100. 0 is as recorded, a value left out stays as it is, reset true puts every one back to 0, template lays a saved look on first (list_video_looks). Shown in the preview and laid on the export under the animations and the captions. A clip can have its own (set_clip_look). A setting, not an undo step.", inputSchema: obj(lookValues.merging([
    "project": projectArg, "reset": ["type": "boolean"],
    "template": ["type": "string", "maxLength": 80, "description": "A saved look, by name or file name, laid on first; values given with it change it."],
    "name": ["type": ["string", "null"], "maxLength": 60, "description": "The look's name; null for a custom look."],
  ]) { a, _ in a }, ["project"])) { i in
    let tpl = try i["template"]?.string.map { try Looks.get($0) }
    return try setting(i, "set_video_look") { e in
      var merged: [String: JSON] = i["reset"]?.bool == true ? [:] : tpl.map { JSON.from($0.look).object ?? [:] } ?? (e.look.map { JSON.from($0).object ?? [:] } ?? [:])
      for k in LOOK_KEYS { if let v = i[k], v.double != nil { merged[k] = v } }
      if let n = i["name"] { merged["name"] = n.string.map { .string($0) } ?? .null }
      e.look = normalizeLook(JSON.object(merged))
      return ["look": e.look.map { JSON.from($0) } ?? .null]
    }
  },
  ReelTool(name: "list_video_looks", description: "Lists the saved video looks (one JSON file each in the projects folder's _looks, or looksDir of settings.json) with their values and which one is the default every new project starts with.", inputSchema: obj(["project": ["type": "string", "maxLength": 120, "description": "Ignored."]])) { _ in
    ["folder": .string(Looks.dir.path), "looks": JSON.from(Looks.list())]
  },
  ReelTool(name: "save_video_look", description: "Saves a video look as a template, by name: a project's current look (project) or the values given (they change the project's look when both are given, and the project then carries the saved look). default true makes it the look every new project starts with, the only default.", inputSchema: obj(lookValues.merging([
    "name": ["type": "string", "minLength": 1, "maxLength": 60], "project": projectArg, "default": ["type": "boolean"],
  ]) { a, _ in a }, ["name"])) { i in
    let from = try i["project"]?.string.map { try Store.checkName($0) }
    var base = (try from.map { try Store.load($0).project.edits.look.map { JSON.from($0).object ?? [:] } ?? [:] }) ?? [:]
    for k in LOOK_KEYS { if let v = i[k], v.double != nil { base[k] = v } }
    let values = normalizeLook(JSON.object(base)) ?? ReelLook()
    let saved = try Looks.save(i["name"]!.string!, values: values, makeDefault: i["default"]?.bool == true, from: from)
    if let from { _ = try Store.update(from) { p in p.edits.look = saved.look; return [:] } }
    return ["saved": JSON.from(saved)]
  },
  ReelTool(name: "set_reel_caption", description: "Sets the caption to post with the reel, saved in its project.json as caption. Write it when the reel is edited, from the reel's own content and its format's caption rules. An empty text clears it. A setting, not an undo step.", inputSchema: obj([
    "project": projectArg, "text": ["type": "string", "maxLength": 4000],
  ], ["project", "text"])) { i in
    try setting(i, "set_reel_caption") { e in
      let t = i["text"]!.string!
      e.caption = t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : String(t.prefix(4000))
      return ["caption": e.caption.map { .string($0) } ?? .null]
    }
  },
  ReelTool(name: "set_title_text", description: "Sets this reel's own title text, saved as titleText, the text the burned in title shows when the title is on (set_title). reset true clears it. The look of the title stays the fixed reel look. Shown in the preview and burned in by the export. A setting, not an undo step.", inputSchema: obj([
    "project": projectArg, "text": ["type": "string", "maxLength": 200], "reset": ["type": "boolean"],
  ], ["project"])) { i in
    try setting(i, "set_title_text") { e in
      if i["reset"]?.bool == true || i["text"] == nil { e.titleText = nil } else { e.titleText = String(i["text"]!.string!.prefix(200)) }
      return ["titleText": e.titleText.map { .string($0) } ?? .null]
    }
  },
  ReelTool(name: "set_caption_position", description: "Sets where this reel's captions sit: x and y are the middle of the captions in px of the 1080 by 1920 frame (1920 by 1080 for a landscape video), x from the frame's centre (0 is centred, minus is left) and y down from the top. reset true goes back to the caption style's default place. The same as set_caption_style with x and y, saved in the caption style.", inputSchema: obj([
    "project": projectArg, "x": ["type": "number", "minimum": -1920, "maximum": 1920], "y": ["type": "number", "minimum": 0, "maximum": 1920], "reset": ["type": "boolean"],
  ], ["project"])) { i in
    try setting(i, "set_caption_position") { e in
      // Kept in the caption style since 2 Nov 2026; an older captionPos is folded into it.
      var s = e.captionStyle ?? TextStyle()
      if i["reset"]?.bool == true { s.x = nil; s.y = nil }
      else {
        s.x = (i["x"]?.double ?? s.x ?? e.captionPos?.x ?? 0).rounded()
        s.y = (i["y"]?.double ?? s.y ?? e.captionPos?.y ?? Captions.builtIn(landscape: false).y ?? 1490).rounded()
      }
      e.captionPos = nil
      e.captionStyle = s == TextStyle() ? nil : s
      return ["captionPos": s.x.map { x in ["x": .number(x), "y": .number(s.y ?? 0)] } ?? .null]
    }
  },
  ReelTool(name: "set_voice_gain", description: "Sets how loud all the voices are together, against the music: the video clips' own sound and every voice over and face overlay (not the music or the sound effects), from 0 (silent) to 10 (1000 percent), 1 is as recorded. It plays in the preview and is applied in the export (above 1 the voice is limited so it does not clip). A setting, not an undo step.", inputSchema: obj([
    "project": projectArg, "gain": ["type": "number", "minimum": 0, "maximum": 10, "description": "1 is 100 percent, 10 is 1000 percent."],
  ], ["project", "gain"])) { i in
    try setting(i, "set_voice_gain") { e in
      let g = round3(max(0, min(10, i["gain"]!.double!)))
      e.voiceGain = g == 1 ? nil : g
      return ["voiceGain": .number(g)]
    }
  },
  ReelTool(name: "set_voice_eq", description: "Sets the bass and treble of all the voices together, the same voices set_voice_gain raises: each in dB, -12 to 12, 0 is as recorded. Bass is a low shelf at 120 Hz, treble a high shelf at 6 kHz. A side left out stays as it is. Saved as voiceEq, left out when both are 0. It plays in the preview and is applied in the export, before the limiter. One overlay's own bass and treble are set with update_audio_overlay. A setting, not an undo step.", inputSchema: obj([
    "project": projectArg, "bass": ["type": "integer", "minimum": -12, "maximum": 12], "treble": ["type": "integer", "minimum": -12, "maximum": 12],
  ], ["project"])) { i in
    try setting(i, "set_voice_eq") { e in
      e.voiceEq = normalizeEq(bass: i["bass"]?.double ?? e.voiceEq?.bass ?? 0, treble: i["treble"]?.double ?? e.voiceEq?.treble ?? 0)
      return ["voiceEq": JSON.from(e.voiceEq ?? AudioEq())]
    }
  },
  ReelTool(name: "set_references", description: "Sets the documents and files a reel is made from: kind format is a format doc (path inside content/documents without .md) and kind json a JSON file (path from the repo root). Replaces the list, an empty list clears it. The Mac app stores and returns them (get_project references); it adds no default links of its own. A setting, not an undo step.", inputSchema: obj([
    "project": projectArg, "references": referencesSchema,
  ], ["project", "references"])) { i in
    try setting(i, "set_references") { e in
      let clean = normalizeReferences(i["references"])
      e.references = clean.isEmpty ? nil : clean
      return ["references": .number(Double(clean.count))]
    }
  },
  ReelTool(name: "set_reel_status", description: "Sets where a reel stands, saved as status: draft while it is being made, live once it is posted (published is taken as live). A reel never set reads as draft; set_draft_published and add_post_link set live. A setting, not an undo step.", inputSchema: obj([
    "project": projectArg, "status": ["type": "string", "enum": ["draft", "live", "published"]],
  ], ["project", "status"])) { i in
    let live = i["status"]!.string! != "draft"
    return try setting(i, "set_reel_status") { e in e.status = live ? "live" : nil; return ["status": .string(live ? "live" : "draft")] }
  },
  ReelTool(name: "add_post_link", description: "Records where the reel was published, saved in the project file as posts: the platform (LinkedIn, X, Instagram, YouTube, TikTok, Facebook, Threads or any other; read from the link when left out), the post's url, when it was posted (ISO 8601) and a note. A link already recorded is updated, not added twice. Sets the reel's status to live unless live is false. Any agent can call it, so an agent that posted the reel or knows its links records them here. A record, not an undo step.", inputSchema: obj([
    "project": projectArg,
    "url": ["type": "string", "minLength": 8, "maxLength": 600, "description": "The post's link, https."],
    "platform": ["type": "string", "maxLength": 40],
    "postedAt": ["type": "string", "maxLength": 40, "description": "When it was posted, ISO 8601."],
    "note": ["type": "string", "maxLength": 400],
    "live": ["type": "boolean", "default": true],
  ], ["project", "url"])) { i in
    let url = i["url"]!.string!.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let u = URL(string: url), let scheme = u.scheme?.lowercased(), scheme == "https" || scheme == "http", u.host != nil else { throw ToolError("invalid_url", "Give the post's full link, starting https://") }
    let platform = ReelPost.platformName(i["platform"]?.string, url: url)
    var added = false
    let r = try setting(i, "add_post_link") { e in
      var posts = e.posts ?? []
      let stamp = ISO8601DateFormatter().string(from: Date())
      if let k = posts.firstIndex(where: { $0.url == url }) {
        posts[k].platform = platform
        if let d = i["postedAt"]?.string { posts[k].postedAt = d }
        if let n = i["note"]?.string { posts[k].note = n }
      } else {
        posts.append(ReelPost(platform: platform, url: url, postedAt: i["postedAt"]?.string, note: i["note"]?.string, added: stamp)); added = true
      }
      e.posts = posts
      if i["live"]?.bool != false { e.status = "live" }
      return ["posts": JSON.from(posts), "status": .string(e.status ?? "draft")]
    }
    guard case .object(var o) = r else { return r }
    o["added"] = .bool(added); o["platform"] = .string(platform)
    return .object(o)
  },
  ReelTool(name: "remove_post_link", description: "Takes a link out of where the reel was published (posts). The status stays as it is; set it with set_reel_status. A record, not an undo step.", inputSchema: obj([
    "project": projectArg, "url": ["type": "string", "minLength": 1, "maxLength": 600],
  ], ["project", "url"])) { i in
    let url = i["url"]!.string!.trimmingCharacters(in: .whitespacesAndNewlines)
    return try setting(i, "remove_post_link") { e in
      let before = e.posts ?? []
      guard before.contains(where: { $0.url == url }) else { throw ToolError("not_found", "No post with the link \(url); get_project lists them under posts") }
      let left = before.filter { $0.url != url }
      e.posts = left.isEmpty ? nil : left
      return ["posts": JSON.from(left), "removed": .string(url)]
    }
  },
  ReelTool(name: "record_generation_cost", description: "Records what the reel's AI generations cost, saved as cost with a total per currency and in rupees. Call it as each generation is made: an Argon video (kind argon-video, ₹16.25 each when cost is left out; a video from another account gets cost 0 and its account named) or a HeyGen voice take (kind heygen-voice with its seconds, 1 credit a minute at $0.049 a credit when credits and cost are left out; give credits with basis measured when the balance was read before and after). A failed try is recorded with failed true and costs nothing. Lines are added; replace true sets the whole list, and remove takes line ids (g1, g2 and so on) out. A record, not an undo step.", inputSchema: obj([
    "project": projectArg,
    "items": ["type": "array", "maxItems": 200, "items": ["type": "object", "properties": [
      "kind": ["type": "string", "pattern": "^[a-z0-9-]{1,40}$"], "part": ["type": "string", "minLength": 1, "maxLength": 60], "count": ["type": "integer", "minimum": 1, "maximum": 999],
      "seconds": ["type": "number", "minimum": 0], "credits": ["type": "number", "minimum": 0], "cost": ["type": "number", "minimum": 0], "currency": ["type": "string", "pattern": "^[A-Za-z]{3}$"],
      "date": ["type": "string", "pattern": "^\\d{4}-\\d{2}-\\d{2}$"], "account": ["type": "string", "maxLength": 60], "basis": ["type": "string", "enum": ["measured", "rate", "estimate"]],
      "failed": ["type": "boolean"], "note": ["type": "string", "maxLength": 300],
    ], "required": ["kind", "part"], "additionalProperties": false]],
    "replace": ["type": "boolean"], "remove": ["type": "array", "items": ["type": "string", "pattern": "^g\\d+$"], "maxItems": 200],
  ], ["project"])) { i in
    try setting(i, "record_generation_cost") { e in
      let remove = Set(i["remove"]?.array?.compactMap(\.string) ?? [])
      let kept = i["replace"]?.bool == true ? [] : (e.cost?.items ?? []).filter { !remove.contains($0.id) }.map { JSON.from($0) }
      e.cost = normalizeCost(kept + (i["items"]?.array ?? []))
      return ["cost": e.cost.map { JSON.from($0) } ?? .null]
    }
  },

  // ---------------------------------------------------------------------------------------------------------------------
  // Comments on the script

  ReelTool(name: "list_comments", description: "Lists the comments left on words of the reel's script or on ranges of its timeline, saved in the project's comments.json. By default only the unresolved ones. Each has an id, from and to (word indexes, -1 for a range), words (what was commented on), start and end (source seconds of the words, edit seconds for a range), the comment, its status and when it was left. Read these at the start of a session on a reel, act on each one and then call resolve_comment.", inputSchema: obj([
    "project": projectArg, "status": ["type": "string", "enum": ["unresolved", "resolved", "all"], "default": "unresolved"],
  ], ["project"])) { i in
    try Comments.list(try name(i), status: i["status"]?.string ?? "unresolved")
  },
  ReelTool(name: "add_comment", description: "Leaves a comment, unresolved. On a run of words of the script: from and to are word indexes as get_project lists them. Or on a range of the timeline: start and end are edit seconds, and list_comments returns it with range true and from and to -1.", inputSchema: obj([
    "project": projectArg, "from": ["type": "integer", "minimum": 0, "description": "First word index."], "to": ["type": "integer", "minimum": 0, "description": "Last word index."],
    "start": ["type": "number", "minimum": 0, "description": "Start of a timeline range, edit seconds, instead of from and to."], "end": ["type": "number", "minimum": 0, "description": "End of a timeline range, edit seconds."],
    "comment": ["type": "string", "minLength": 1, "maxLength": 4000],
  ], ["project", "comment"])) { i in
    try Comments.add(try name(i), from: i["from"]?.int, to: i["to"]?.int, start: i["start"]?.double, end: i["end"]?.double, comment: i["comment"]!.string!)
  },
  ReelTool(name: "resolve_comment", description: "Marks a comment resolved once what it asks for is done, with a short note of what was done. The comment stays in comments.json as resolved.", inputSchema: obj([
    "project": projectArg, "id": ["type": "string", "minLength": 1, "maxLength": 60, "description": "A comment id from list_comments."], "note": ["type": "string", "maxLength": 2000, "description": "What was done about it."],
  ], ["project", "id"])) { i in
    try Comments.setStatus(try name(i), id: i["id"]!.string!, resolved: true, note: i["note"]?.string)
  },
  ReelTool(name: "edit_comment", description: "Changes the words of a comment, keeping what it points at and whether it is resolved.", inputSchema: obj([
    "project": projectArg, "id": ["type": "string", "minLength": 1, "maxLength": 60], "comment": ["type": "string", "minLength": 1, "maxLength": 4000],
  ], ["project", "id", "comment"])) { i in
    try Comments.edit(try name(i), id: i["id"]!.string!, comment: i["comment"]!.string!)
  },
  ReelTool(name: "reopen_comment", description: "Marks a resolved comment unresolved again.", inputSchema: obj([
    "project": projectArg, "id": ["type": "string", "minLength": 1, "maxLength": 60],
  ], ["project", "id"])) { i in
    try Comments.setStatus(try name(i), id: i["id"]!.string!, resolved: false)
  },

  // ---------------------------------------------------------------------------------------------------------------------
  // Draft reels

  ReelTool(name: "create_draft_reel", description: "Starts a new reel as a draft: the plan for a reel before anything is made, the script in sections, each with what it needs (a talking head clip to generate, a walkthrough to record, the voice, the edit, data to recount). Show it to Sankalp for review before generating or recording anything. It makes the project folder with a draft.json and no video; create_project (or import_video) with the same name puts the video in it later. list_projects lists it with draft true.", inputSchema: obj([
    "project": projectArg,
    "title": ["type": "string", "minLength": 1, "maxLength": 160, "description": "What the reel is."],
    "format": ["type": "string", "maxLength": 200, "description": "The title of the format doc the reel follows."],
    "planPost": ["type": "string", "maxLength": 200, "description": "Slug of the reel's own calendar post."],
    "summary": ["type": "string", "maxLength": 600],
    "references": referencesSchema,
    "sections": ["type": "array", "minItems": 1, "maxItems": 40, "description": "The script in order.", "items": ["type": "object", "properties": [
      "part": ["type": "string", "maxLength": 60], "title": ["type": "string", "maxLength": 120],
      "logo": ["type": "string", "pattern": "^[a-z0-9-]+$", "maxLength": 80], "time": ["type": "string", "maxLength": 40], "script": ["type": "string", "maxLength": 4000],
      "needs": ["type": "array", "maxItems": 12, "items": ["type": "object", "properties": [
        "kind": ["type": "string", "enum": ["talking-head", "walkthrough", "voice", "edit", "data", "post"]], "label": ["type": "string", "maxLength": 120],
        "detail": ["type": "string", "maxLength": 600], "required": ["type": "boolean"],
      ], "required": ["kind", "label", "required"], "additionalProperties": false]],
    ], "required": ["part", "title", "script"], "additionalProperties": false]],
  ], ["project", "title", "sections"])) { i in
    try Drafts.create(try name(i), i)
  },
  ReelTool(name: "get_draft_reel", description: "Reads a draft reel's plan: its sections with the script and the needs of each, their status, and the post it went live as.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let n = try name(i)
    guard let d = Drafts.read(n) else { throw ToolError("not_found", "No draft called \(n)") }
    return ["project": .string(n), "draft": JSON.from(d)]
  },
  ReelTool(name: "set_draft_section_status", description: "Marks one part of a draft reel pending, running or done, as the parts are put on the timeline one by one. needsDone true also ticks off every need of the part (false puts them back to todo). Returns how many parts are done and pending.", inputSchema: obj([
    "project": projectArg, "section": sectionId, "status": ["type": "string", "enum": ["pending", "running", "done"]], "needsDone": ["type": "boolean"],
  ], ["project", "section", "status"])) { i in
    try Drafts.setSectionStatus(try name(i), section: i["section"]!.string!, status: i["status"]!.string!, needsDone: i["needsDone"]?.bool)
  },
  ReelTool(name: "set_draft_need_status", description: "Sets one step of a draft part (a clip to generate, a recording, the voice, the stitch) to todo, running or done. step is its position in the part's needs (0 is the first) or a piece of its label such as voice. Starting a step (running) also marks its part running.", inputSchema: obj([
    "project": projectArg, "section": sectionId,
    "step": ["description": "The step: its index (0 is the first, up to 20) or a piece of its label.", "anyOf": [["type": "integer", "minimum": 0, "maximum": 20], ["type": "string", "minLength": 1, "maxLength": 120]]],
    "status": ["type": "string", "enum": ["todo", "running", "done"]],
  ], ["project", "section", "step", "status"])) { i in
    let step = i["step"]!
    if let n = step.int { if n < 0 || n > 20 { throw ToolError("invalid_input", "step is 0 to 20, or a piece of the step's label") } }
    else if let s = step.string { if s.isEmpty || s.count > 120 { throw ToolError("invalid_input", "step's label piece is 1 to 120 characters") } }
    else { throw ToolError("invalid_input", "step is an integer or a string") }
    return try Drafts.setNeedStatus(try name(i), section: i["section"]!.string!, step: step, status: i["status"]!.string!)
  },
  ReelTool(name: "set_draft_published", description: "Records that a draft reel is live: ties it to the calendar post it is recorded as (post, the slug) and, on the last part (section), keeps what went live as code blocks (blocks, each with a label and a text) and a row of links. The part is marked done with its needs ticked off; script and time replace the part's plan text when given. With no part pending, a project with a video has its status set to live.", inputSchema: obj([
    "project": projectArg, "post": ["type": "string", "pattern": "^[a-z0-9-]{1,160}$"], "section": sectionId,
    "script": ["type": "string", "maxLength": 4000], "time": ["type": "string", "maxLength": 60],
    "blocks": ["type": "array", "maxItems": 8, "items": ["type": "object", "properties": ["label": ["type": "string", "maxLength": 120], "text": ["type": "string", "maxLength": 4000]], "required": ["label", "text"], "additionalProperties": false]],
    "links": ["type": "array", "maxItems": 12, "items": ["type": "object", "properties": ["label": ["type": "string", "maxLength": 120], "url": ["type": "string", "maxLength": 400]], "required": ["label", "url"], "additionalProperties": false]],
  ], ["project", "post", "section"])) { i in
    let n = try name(i)
    var out = try Drafts.setPublished(n, i).object ?? [:]
    if out["pending"]?.int == 0, Store.exists(n) {
      _ = try? Store.update(n) { p in p.edits.status = "live"; return [:] }
      out["status"] = "live"
    }
    return .object(out)
  },

  // ---------------------------------------------------------------------------------------------------------------------
  // Source files, Finder and renaming

  ReelTool(name: "check_sources", description: "Lists every source file of a project, its own video (main), each added video (s1 and so on) and each voice or face overlay (o1 and so on, one per file), with its path, the path it was added from (origin), whether the file is still there (found) and whether the original is (originFound). A source with found false cannot play or export; relink_source links the file again. The Mac app reads each file where it is, so linked is always true.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let n = try name(i)
    let l = try Store.load(n)
    let fm = FileManager.default
    func entry(_ id: String, _ kind: String, _ label: String, _ file: String, _ origin: String?, _ duration: Double) -> JSON {
      let o = origin ?? file
      return ["id": .string(id), "kind": .string(kind), "label": .string(label), "url": .string(file), "origin": .string(o), "linked": true, "found": .bool(fm.fileExists(atPath: file)), "originFound": .bool(fm.fileExists(atPath: o)), "duration": .number(duration)]
    }
    var list: [JSON] = [entry(MAIN, "main", "The project's own video", l.project.main.file, l.project.main.origin, l.project.main.duration)]
    for s in l.project.edits.sources { list.append(entry(s.id, "source", s.label, s.file, s.origin, s.duration)) }
    var seen = Set<String>()
    for o in l.project.edits.audioOverlays ?? [] where seen.insert(o.file).inserted { list.append(entry(o.id, "overlay", o.label, o.file, o.origin, o.duration)) }
    return ["project": .string(n), "sources": .array(list), "missing": .number(Double(list.filter { $0["found"]?.bool == false }.count))]
  },
  ReelTool(name: "relink_source", description: "Attaches a source file of a project again after it was moved or deleted: the project is pointed at the file and its path is recorded as the origin. Give path (absolute), or file_name and size (bytes) to look for it in Downloads, Desktop and Movies. The file has to be as long as the one it replaces, within half a second, unless force is true. The undo history is pointed at it too. Not an undo step.", inputSchema: obj([
    "project": projectArg,
    "source": ["type": "string", "pattern": "^(main|[so][0-9]{1,3})$", "maxLength": 8, "description": "main for the project's own video, s1 and so on for an added video, o1 and so on for an overlay, as check_sources lists them."],
    "path": ["type": "string", "minLength": 1, "maxLength": 2048], "file_name": ["type": "string", "minLength": 1, "maxLength": 255], "size": ["type": "integer", "minimum": 0],
    "force": ["type": "boolean", "default": false],
  ], ["project", "source"])) { i in
    let n = try name(i)
    var url: URL
    if let p = i["path"]?.string { url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath).resolvingSymlinksInPath() }
    else if let f = i["file_name"]?.string, let size = i["size"]?.int {
      guard let hit = locate((f as NSString).lastPathComponent, size: size) else { throw ToolError("not_found", "\((f as NSString).lastPathComponent) was not found in Downloads, Desktop or Movies. Give its path instead") }
      url = hit
    } else { throw ToolError("invalid_input", "Give path (the file's absolute path), or file_name and size to look for it in Downloads, Desktop and Movies") }
    guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("not_found", "No file at \(url.path)") }
    let m = try await Store.relink(n, source: i["source"]!.string!, to: url, force: i["force"]?.bool == true)
    return result(m, ["origin": .string(url.path), "linked": true])
  },
  ReelTool(name: "reveal_in_finder", description: "Shows an exported video in Finder, selected in its folder. file is the export's path (as export returns it) or its name in the project's exports folder; left out, the last export. Only a video file inside the project's folder, or the last export's file, can be shown.", inputSchema: obj([
    "project": projectArg, "file": ["type": "string", "minLength": 1, "maxLength": 2048], "url": ["type": "string", "minLength": 1, "maxLength": 2048, "description": "The web editor's name for file."],
  ], ["project"])) { i in
    let n = try name(i)
    _ = try Store.load(n)
    let last = Store.status(n)["result"]?["file"]?.string
    let given = i["file"]?.string ?? i["url"]?.string
    let path: String
    if let g = given { path = g.hasPrefix("/") || g.hasPrefix("~") ? (g as NSString).expandingTildeInPath : Store.exportsDir(n).appendingPathComponent((g as NSString).lastPathComponent).path }
    else if let last { path = last } else { path = Jobs.defaultExportURL(n).path }
    let url = URL(fileURLWithPath: path).standardizedFileURL
    let inside = url.path.hasPrefix(Store.exportsDir(n).standardizedFileURL.path + "/") || url.path.hasPrefix(Store.dir(n).standardizedFileURL.path + "/") || url.path == last.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    guard inside, Store.VIDEO_EXTENSIONS.contains(url.pathExtension.lowercased()) else { throw ToolError("invalid_path", "Only an export of this project can be shown") }
    guard FileManager.default.fileExists(atPath: url.path) else { throw ToolError("not_found", "No export at \(url.path)") }
    let shown = try openInFinder(["-R", url.path])
    return ["project": .string(n), "shown": .string(url.path), "opened": .bool(shown)]
  },
  ReelTool(name: "open_project_folder", description: "Opens the project's exports folder in Finder, \"<name> exports\" beside the project file, where its exports are written.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let n = try name(i)
    _ = try Store.load(n)
    let dir = Store.exportsDir(n)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let opened = try openInFinder([dir.path])
    return ["project": .string(n), "opened": .string(dir.path), "shown": .bool(opened)]
  },
  ReelTool(name: "rename_reel", description: "Renames a project's folder to exactly `to` (lowercase letters, digits and dashes, by the naming formula: date, what it is, version), keeping its title. rename_project instead takes a title and makes the name from it. The old name is remembered so the app's open tab follows. Returns the new name, which every later call uses.", inputSchema: obj([
    "project": projectArg, "to": ["type": "string", "pattern": "^[a-z0-9-]{1,120}$", "description": "The new name."],
  ], ["project", "to"])) { i in
    let r = try Store.rename(try name(i), to: i["to"]!.string!)
    return ["project": .string(r.name), "reel": .string(r.name), "changed": .bool(r.name != r.previous), "from": .string(r.previous)]
  },
]

// The web editor's names for Mac tools that do the same thing, so an agent using either name gets the same result.
func webAliases(_ base: [ReelTool]) -> [ReelTool] {
  func alias(_ name: String, _ target: String, _ map: @escaping @Sendable (JSON) -> JSON = { $0 }) -> ReelTool? {
    guard let t = base.first(where: { $0.name == target }) else { return nil }
    let run = t.run
    return ReelTool(name: name, description: "The web editor's name for \(target): \(t.description)", inputSchema: t.inputSchema) { i in map(try await run(i)) }
  }
  return [
    alias("list_reels", "list_projects") { r in var o = r.object ?? [:]; o["reels"] = o["projects"]; return .object(o) },
    alias("get_timeline", "get_project"),
    alias("import_video", "create_project"),
  ].compactMap { $0 }
}
