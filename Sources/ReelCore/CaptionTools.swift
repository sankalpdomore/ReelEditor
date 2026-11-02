// The tools for the captions and the text layers (Sankalp, 2 Nov 2026), so an agent styles the captions, hides them over
// stretches of the reel and adds text layers on the Animation layer, the same as the app's Captions and Text cards do.
// Captions.swift holds the style and how it is drawn. Every change here is one undo step.
import Foundation

let colourPattern = "^#?[0-9a-fA-F]{3}([0-9a-fA-F]{3})?$"

// The fields of a text style, for captions and text layers alike, in px of the 1080 by 1920 frame (1920 by 1080 landscape).
let styleFields: [String: JSON] = [
  "font": ["type": "string", "minLength": 1, "maxLength": 80, "description": "A font family on this Mac; list_fonts lists them. Advercase (the reels' font) and Inter are bundled."],
  "weight": ["type": "integer", "minimum": 100, "maximum": 900, "description": "100 to 900: 400 regular, 700 bold, 900 black. The nearest the family has is used."],
  "italic": ["type": "boolean"],
  "size": ["type": "number", "minimum": 8, "maximum": 400, "description": "Font size, px of the frame."],
  "letterSpacing": ["type": "number", "minimum": -20, "maximum": 80, "description": "px added between letters, below 0 tighter."],
  "lineHeight": ["type": "number", "minimum": 0.6, "maximum": 3, "description": "Line height, times the size, for text on more than one line."],
  "uppercase": ["type": "boolean", "description": "Every letter in capitals."],
  "color": ["type": "string", "pattern": .string(colourPattern), "description": "The text's colour, #rrggbb."],
  "strokeWidth": ["type": "number", "minimum": 0, "maximum": 40, "description": "The outline round the letters, px; 0 for none."],
  "strokeColor": ["type": "string", "pattern": .string(colourPattern)],
  "shadow": ["type": "number", "minimum": 0, "maximum": 80, "description": "A soft shadow round the letters, its blur in px; 0 for none."],
  "shadowColor": ["type": "string", "pattern": .string(colourPattern)],
  "box": ["type": "string", "enum": ["none", "line", "word"], "description": "A box behind the text: none, line (the whole line) or word (for captions, the word being spoken)."],
  "boxColor": ["type": "string", "pattern": .string(colourPattern)],
  "boxOpacity": ["type": "number", "minimum": 0, "maximum": 1],
  "boxPadX": ["type": "number", "minimum": 0, "maximum": 160, "description": "The box's padding across, px."],
  "boxPadY": ["type": "number", "minimum": 0, "maximum": 160, "description": "The box's padding up and down, px."],
  "boxRadius": ["type": "number", "minimum": 0, "maximum": 200, "description": "The box's corner radius, px."],
  "x": ["type": "number", "minimum": -1920, "maximum": 1920, "description": "Where the middle sits across, px from the frame's centre, minus is left."],
  "y": ["type": "number", "minimum": 0, "maximum": 1920, "description": "Where the middle sits down, px from the top (1920 tall portrait, 1080 landscape)."],
  "maxWidth": ["type": "number", "minimum": 100, "maximum": 1920, "description": "The widest a line may run, px; longer text breaks onto another line (a caption line ends there)."],
  "align": ["type": "string", "enum": ["left", "center", "right"], "description": "Lines of text aligned, for text on more than one line."],
]
let captionOnlyFields: [String: JSON] = [
  "maxWords": ["type": "integer", "minimum": 1, "maximum": 12, "description": "The most words a caption line holds."],
  "highlight": ["type": "string", "pattern": "^(none|#?[0-9a-fA-F]{3}([0-9a-fA-F]{3})?)$", "description": "The colour of the word being spoken, or none to keep it the text's colour."],
  "animation": ["type": "string", "enum": ["none", "pop", "fade", "rise"], "description": "How each caption line comes in."],
]
let clearField: JSON = ["type": "array", "maxItems": 30, "items": ["type": "string", "enum": .array(TextStyle.KEYS.map { .string($0) })], "description": "Fields to put back to the default."]

func landscape(_ l: Loaded) -> Bool { l.project.main.width > l.project.main.height }

// The style a call sets: the fields given on top of `own`, the fields in clear taken off.
func styled(_ own: TextStyle?, _ i: JSON, reset: Bool) throws -> TextStyle? {
  var s = reset ? TextStyle() : (own ?? TextStyle())
  try s.apply(i)
  if let clear = i["clear"]?.array?.compactMap(\.string), !clear.isEmpty {
    var j: [String: JSON] = [:]
    for k in clear { j[k] = .null }
    try s.apply(.object(j))
  }
  return s == TextStyle() ? nil : s
}

func hideList(_ hides: [CaptionHide]) -> JSON { .array(hides.map { ["id": .string($0.id), "start": .number(round3($0.start)), "end": .number(round3($0.end))] }) }

// The stretches merged where they meet or overlap, in order, each keeping the first id among those merged.
func mergedHides(_ list: [CaptionHide]) -> [CaptionHide] {
  var out: [CaptionHide] = []
  for h in list.sorted(by: { $0.start < $1.start }) where h.end - h.start > 0.001 {
    if let last = out.last, h.start <= last.end + 0.001 { out[out.count - 1].end = max(last.end, h.end) } else { out.append(h) }
  }
  return out
}

// A stretch of the reel from a call: start and end (edit seconds), from and to (word indexes of the project's own
// video) or clip (a clip id, all of it).
func stretch(_ i: JSON, _ e: Edl, _ main: EdlMain) throws -> Range {
  let plan = buildPlan(e, main)
  if let c = i["clip"]?.string {
    guard let p = plan.clips.first(where: { $0.id == c }) else { throw ToolError("not_found", "No clip \(c). Clips: \(plan.clips.map(\.id).joined(separator: ", "))") }
    return Range(s: p.editStart, e: p.editEnd)
  }
  if let a = i["from"]?.int, let b = i["to"]?.int {
    guard a <= b, b < main.words.count, let r = span(plan, main.words, a..<(b + 1)) else { throw ToolError("invalid_input", "from and to have to be word indexes of the project's own video, from no more than to, with at least one in the reel") }
    return r
  }
  if let a = i["start"]?.double, let b = i["end"]?.double {
    guard b > a else { throw ToolError("invalid_input", "end has to be after start") }
    return Range(s: max(0, a), e: min(plan.editDuration, b))
  }
  throw ToolError("invalid_input", "Give start and end (edit seconds), from and to (word indexes) or clip")
}

let stretchFields: [String: JSON] = [
  "start": sec("Edit time it starts, seconds."), "end": sec("Edit time it ends, seconds."),
  "from": ["type": "integer", "minimum": 0, "description": "First word index of the stretch (the project's own video)."],
  "to": ["type": "integer", "minimum": 0, "description": "Last word index of the stretch."],
  "clip": ["type": "string", "pattern": "^c[0-9]{1,4}$", "description": "A clip id: the whole clip."],
]

func checkMotions(_ i: JSON) throws {
  if let v = i["enter"]?.string, !Captions.ENTERS.contains(v) { throw ToolError("invalid_input", "enter is one of \(Captions.ENTERS.joined(separator: ", "))") }
  if let v = i["exit"]?.string, !Captions.EXITS.contains(v) { throw ToolError("invalid_input", "exit is one of \(Captions.EXITS.joined(separator: ", "))") }
}

let motionFields: [String: JSON] = [
  "enter": ["type": "string", "enum": .array(Captions.ENTERS.map { .string($0) }), "description": "How it comes in: fade (default), pop, rise, drop, slide-left, slide-right, typewriter (letter by letter) or none."],
  "exit": ["type": "string", "enum": .array(Captions.EXITS.map { .string($0) }), "description": "How it goes out: fade (default), pop, rise, drop, slide-left, slide-right or none."],
]

let captionTools: [ReelTool] = [
  ReelTool(name: "get_caption_style", description: "The captions' look on this project: style (what they are drawn in now: the built in reel look, then the default saved for new projects, then the project's own), own (the fields the project sets itself), savedDefault, burnIn (whether they are burned into the export), the stretches they are hidden over (hides, edit seconds) and whether the frame is landscape. Sizes and places are px of the 1080 by 1920 frame (1920 by 1080 landscape).", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let l = try Store.load(try name(i))
    let land = landscape(l), e = l.project.edits
    return ["project": .string(l.project.name), "landscape": .bool(land), "style": JSON.from(Captions.style(e, landscape: land)), "own": e.captionStyle.map { JSON.from($0) } ?? .null,
            "savedDefault": Captions.savedDefault(landscape: land).map { JSON.from($0) } ?? .null, "burnIn": .bool(exportFlags(e, hasWords: l.hasAnyWords).captions),
            "hides": hideList(e.captionHides ?? [])]
  },
  ReelTool(name: "set_caption_style", description: "Styles this project's captions: any of the fields below changes (the font and its weight, italic, size, letter spacing and case; the colour, outline and shadow; a box behind the line or behind the word being spoken, its colour, opacity, padding and corners; the highlight colour of the spoken word; how a line comes in; where the captions sit, the widest line and the most words a line). Fields left out stay as they are; clear puts fields back to the default, reset true puts them all back. burnIn turns the burned in captions on or off. saveAsDefault true makes this look the one new projects start with, resetDefault true clears that. Shown in the preview and the export at once. One undo step.", inputSchema: obj(styleFields.merging(captionOnlyFields) { a, _ in a }.merging([
    "project": projectArg, "clear": clearField, "reset": ["type": "boolean"], "burnIn": ["type": "boolean"], "saveAsDefault": ["type": "boolean"],
    "resetDefault": ["type": "boolean", "description": "True clears the look saved for new projects, back to the built in reel look."],
  ]) { a, _ in a }, ["project"])) { i in
    let n = try name(i)
    let land = landscape(try Store.load(n))
    let r = try edit(i, "set_caption_style") { e, _, _ in
      e.captionStyle = try styled(e.captionStyle, i, reset: i["reset"]?.bool == true)
      if i["reset"]?.bool == true || i["x"] != nil || i["y"] != nil { e.captionPos = nil }
      if let b = i["burnIn"]?.bool { e.export.captions = b }
      return ["style": JSON.from(Captions.style(e, landscape: land)), "own": e.captionStyle.map { JSON.from($0) } ?? .null]
    }
    if i["resetDefault"]?.bool == true { try Captions.saveDefault(nil, landscape: land) }
    if i["saveAsDefault"]?.bool == true { try Captions.saveDefault(Captions.style(try Store.load(n).project.edits, landscape: land), landscape: land) }
    return r
  },
  ReelTool(name: "list_fonts", description: "The font families the captions and text layers can use: every family on this Mac, Advercase (the reels' font) and Inter first, both bundled with the app.", inputSchema: obj([:])) { _ in
    let f = Captions.families()
    return ["bundled": ["Advercase", "Inter"], "families": .array(f.map { .string($0) }), "count": .number(Double(f.count))]
  },
  ReelTool(name: "hide_captions", description: "Hides the captions over a stretch of the reel: start and end in edit seconds, from and to as word indexes of the project's own video, or a whole clip. A stretch that meets or overlaps another joins it. The words stay in the transcript; only the burned in captions are left out there, in the preview and the export. One undo step.", inputSchema: obj(stretchFields.merging(["project": projectArg]) { a, _ in a }, ["project"])) { i in
    try edit(i, "hide_captions") { e, _, main in
      let r = try stretch(i, e, main)
      let ids = Set((e.captionHides ?? []).map(\.id))
      var k = 1; while ids.contains("h\(k)") { k += 1 }
      let list = mergedHides((e.captionHides ?? []) + [CaptionHide(id: "h\(k)", start: round3(r.s), end: round3(r.e))])
      e.captionHides = list
      let id = list.first { $0.start <= r.s + 0.001 && $0.end >= r.e - 0.001 }?.id ?? "h\(k)"
      return ["hidden": .string(id), "start": .number(round3(r.s)), "end": .number(round3(r.e)), "hides": hideList(list)]
    }
  },
  ReelTool(name: "show_captions", description: "Shows the captions again: id (from get_caption_style or hide_captions) takes that hidden stretch away, a stretch (start and end, from and to, or clip) is taken out of every hidden stretch it overlaps, and all true shows them everywhere. One undo step.", inputSchema: obj(stretchFields.merging([
    "project": projectArg, "id": ["type": "string", "pattern": "^h[0-9]{1,4}$"], "all": ["type": "boolean"],
  ]) { a, _ in a }, ["project"])) { i in
    try edit(i, "show_captions") { e, _, main in
      var list = e.captionHides ?? []
      if i["all"]?.bool == true { list = [] }
      else if let id = i["id"]?.string {
        guard list.contains(where: { $0.id == id }) else { throw ToolError("not_found", "No hidden stretch \(id). Hidden: \(list.map(\.id).joined(separator: ", "))") }
        list.removeAll { $0.id == id }
      } else {
        let r = try stretch(i, e, main)
        let ids = Set(list.map(\.id))
        var next = 1
        list = list.flatMap { h -> [CaptionHide] in
          guard h.start < r.e && h.end > r.s else { return [h] }
          var parts: [CaptionHide] = []
          if h.start < r.s - 0.001 { parts.append(CaptionHide(id: h.id, start: h.start, end: round3(r.s))) }
          if h.end > r.e + 0.001 {
            while ids.contains("h\(next)") || parts.contains(where: { $0.id == "h\(next)" }) { next += 1 }
            parts.append(CaptionHide(id: parts.isEmpty ? h.id : "h\(next)", start: round3(r.e), end: h.end)); next += 1
          }
          return parts
        }
      }
      e.captionHides = list.isEmpty ? nil : mergedHides(list)
      return ["hides": hideList(e.captionHides ?? [])]
    }
  },
  ReelTool(name: "add_text_layer", description: "Adds a text layer to the Animation layer: text (its words, on more than one line too) from start to end in edit seconds, or over the whole reel with whole true, in its own style (the same fields as set_caption_style: font, weight, size, colour, outline, shadow, box, x and y, widest line, alignment), coming in with enter and going out with exit. Shown in the preview and burned into the export under the captions. Returns its id; update_text_layer changes it and remove_animation takes it away. One undo step.", inputSchema: obj(styleFields.merging(motionFields) { a, _ in a }.merging([
    "project": projectArg, "text": ["type": "string", "minLength": 1, "maxLength": 1000, "description": "The words."],
    "start": sec("Edit time it appears, seconds."), "end": sec("Edit time it is gone, seconds, at least 0.5 s after start."),
    "whole": ["type": "boolean", "description": "True runs it over the whole reel, start to end."],
  ]) { a, _ in a }, ["project", "text"])) { i in
    try checkMotions(i)
    return try edit(i, "add_text_layer") { e, anims, main in
      let total = buildPlan(e, main).editDuration
      let s = i["whole"]?.bool == true ? 0 : (i["start"]?.double ?? 0)
      let en = i["whole"]?.bool == true ? total : (i["end"]?.double ?? min(total, s + 3))
      guard en - s >= 0.5 else { throw ToolError("invalid_animation", "A text layer runs at least 0.5 s: end has to be 0.5 s or more after start") }
      var a = ReelAnimation(kind: "text", start: round3(s), end: round3(min(en, total)), side: "center")
      a.text = i["text"]?.string
      a.style = try styled(nil, i, reset: true)
      a.enter = i["enter"]?.string; a.exit = i["exit"]?.string
      let before = Set(anims.map(\.id))
      anims = normalizeAnimations(anims + [a])
      return ["created": .string(anims.first { !before.contains($0.id) }?.id ?? "")]
    }
  },
  ReelTool(name: "update_text_layer", description: "Changes a text layer by id: its text, start and end (or whole true for the whole reel), enter and exit, and any style field (the rest stay as they are; clear puts fields back to the default, reset true all of them). One undo step.", inputSchema: obj(styleFields.merging(motionFields) { a, _ in a }.merging([
    "project": projectArg, "id": ["type": "string", "minLength": 1, "maxLength": 40], "text": ["type": "string", "minLength": 1, "maxLength": 1000],
    "start": sec("Edit time it appears, seconds."), "end": sec("Edit time it is gone, seconds."), "whole": ["type": "boolean"], "clear": clearField, "reset": ["type": "boolean"],
  ]) { a, _ in a }, ["project", "id"])) { i in
    try checkMotions(i)
    return try edit(i, "update_text_layer") { e, anims, main in
      let id = i["id"]!.string!
      guard let k = anims.firstIndex(where: { $0.id == id && $0.kind == "text" }) else { throw ToolError("not_found", "No text layer \(id). Text layers: \(anims.filter { $0.kind == "text" }.map(\.id).joined(separator: ", "))") }
      if i["whole"]?.bool == true { anims[k].start = 0; anims[k].end = round3(buildPlan(e, main).editDuration) }
      if let v = i["start"]?.double { anims[k].start = round3(v) }
      if let v = i["end"]?.double { anims[k].end = round3(v) }
      guard anims[k].end - anims[k].start >= 0.5 else { throw ToolError("invalid_animation", "A text layer runs at least 0.5 s") }
      if let t = i["text"]?.string { anims[k].text = t }
      if let v = i["enter"]?.string { anims[k].enter = v }
      if let v = i["exit"]?.string { anims[k].exit = v }
      anims[k].style = try styled(anims[k].style, i, reset: i["reset"]?.bool == true)
      return ["id": .string(id)]
    }
  },
]
