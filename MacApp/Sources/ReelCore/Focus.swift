// What Claude is working on, shown live in the app's transcript (Sankalp, 2 Nov 2026): the paragraph it is reading, the
// part it is auditing, the words it is cutting. An agent's tool calls write it to the project's cache folder
// (_cache/<name>/focus.json): get_words, audit_audio, cut_range and delete_words set it on their own, and set_focus says
// anything else in Claude's own words. The app reads it twice a second, lights up those paragraphs with the action
// beside them, and lets it go when it is a minute and a half old or the chat's turn ends.
//
// The paragraphs are the app's: a new one at every section, and after a sentence once a paragraph has 40 words (or at 90
// words regardless). get_paragraphs lists them, so Claude can work through the reel paragraph by paragraph.
import Foundation

public struct AgentFocus: Codable, Equatable, Sendable {
  public var action: String // Reading, Auditing the sound, Applying trims, or Claude's own words
  public var start: Double // edit seconds
  public var end: Double
  public var by: String // the client, Claude Code or the app's chat
  public var t: Double // when, seconds since 1970
  public init(action: String, start: Double, end: Double, by: String, t: Double) { self.action = action; self.start = start; self.end = end; self.by = by; self.t = t }
}

public enum Focus {
  public static let STALE: Double = 90
  static func url(_ name: String) -> URL { Store.dir(name).appendingPathComponent("focus.json") }

  // Only an agent's calls show; the app's own buttons do not.
  public static func set(_ name: String, _ action: String, _ start: Double, _ end: Double) {
    guard Log.source == "mcp" else { return }
    let f = AgentFocus(action: action, start: round3(min(start, end)), end: round3(max(start, end)), by: ToolContext.client, t: Date().timeIntervalSince1970)
    try? FileManager.default.createDirectory(at: Store.dir(name), withIntermediateDirectories: true)
    if let d = try? JSONEncoder().encode(f) { try? d.write(to: url(name), options: .atomic) }
  }

  public static func clear(_ name: String) { try? FileManager.default.removeItem(at: url(name)) }

  // The focus, while it is fresh.
  public static func read(_ name: String) -> AgentFocus? {
    guard let d = try? Data(contentsOf: url(name)), let f = try? JSONDecoder().decode(AgentFocus.self, from: d) else { return nil }
    return Date().timeIntervalSince1970 - f.t < STALE ? f : nil
  }
}

// The transcript's paragraphs, as the app shows them: each with the section starting there and its run of word indexes.
public func transcriptParagraphs(_ texts: [String], _ sections: [Section]?) -> [(title: String?, words: Swift.Range<Int>)] {
  let starts = Dictionary((sections ?? []).map { ($0.from, $0.title) }, uniquingKeysWith: { a, _ in a })
  var out: [(title: String?, words: Swift.Range<Int>)] = []
  var from = 0
  for i in texts.indices {
    let n = i - from
    if i > from && (starts[i] != nil || (n >= 40 && texts[i - 1].last.map { ".?!".contains($0) } == true) || n >= 90) {
      out.append((starts[from], from..<i)); from = i
    }
  }
  if from < texts.count { out.append((starts[from], from..<texts.count)) }
  return out
}

// The edit time span of a run of word indexes of the main video, nil when no clip plays any of them.
func span(_ plan: Plan, _ words: [Word], _ r: Swift.Range<Int>) -> Range? {
  let mapped = mapWords(plan, Array(words[r]))
  guard let a = mapped.compactMap({ $0 }).first, let b = mapped.compactMap({ $0 }).last else { return nil }
  return Range(s: a.s, e: b.e)
}

func spanOf(_ p: LayoutParagraph) -> Range? { guard let a = p.words.first, let b = p.words.last else { return nil }; return Range(s: a.s, e: b.e) }

let focusTools: [ReelTool] = [
  ReelTool(name: "get_paragraphs", description: "The transcript's paragraphs as the app shows them, in the order the reel plays: clip by clip, each clip with the words of its own video. Each has n, its clip and video (source id and file name), the section title when one starts there, the first and last word index of the project's own video (none for another video's words), start and end in edit seconds, how many words and how many are kept, and the opening words. Work through a reel paragraph by paragraph: get_words with paragraph n reads one, and the app lights it up for Sankalp while you work on it.", inputSchema: obj(["project": projectArg], ["project"])) { i in
    let l = try Store.load(try name(i))
    let layout = transcriptLayout(l)
    guard !layout.isEmpty else { throw ToolError("no_words", "This project has no transcript yet. Run transcribe first.") }
    let list: [JSON] = layout.map { p in
      var o: [String: JSON] = ["n": .number(Double(p.n)), "clip": .string(p.clip), "source": .string(p.source), "video": .string(p.label),
                               "words": .number(Double(p.words.count)), "kept": .number(Double(p.words.filter { !$0.cut }.count)),
                               "opens": .string(p.words.prefix(8).map(\.w).joined(separator: " "))]
      if let a = p.words.compactMap(\.index).first, let b = p.words.compactMap(\.index).last { o["firstWord"] = .number(Double(a)); o["lastWord"] = .number(Double(b)) }
      if let t = p.title { o["title"] = .string(t) }
      if let s = spanOf(p) { o["start"] = .number(round3(s.s)); o["end"] = .number(round3(s.e)) }
      return .object(o)
    }
    return ["project": .string(l.project.name), "paragraphs": .array(list), "count": .number(Double(list.count)), "clips": .number(Double(l.plan.clips.count))]
  },
  ReelTool(name: "set_focus", description: "Shows Sankalp what you are working on: the app lights up the paragraphs in that span of the transcript with your action beside them, for example \"Checking the joins\" or \"Planning the cuts\". get_words, audit_audio, cut_range and delete_words already show Reading, Auditing the sound and Applying trims on their own. Give paragraph n, or start and end in edit seconds, or from and to word indexes. done true clears it when you finish.", inputSchema: obj([
    "project": projectArg,
    "action": ["type": "string", "minLength": 1, "maxLength": 60, "description": "What you are doing, a few words."],
    "paragraph": ["type": "integer", "minimum": 0, "description": "A paragraph's n from get_paragraphs."],
    "start": sec("Start of the span, edit seconds."), "end": sec("End of the span, edit seconds."),
    "from": ["type": "integer", "minimum": 0, "description": "First word index of the span."], "to": ["type": "integer", "minimum": 0, "description": "Last word index of the span."],
    "done": ["type": "boolean", "description": "True clears what is shown."],
  ], ["project"])) { i in
    let n = try name(i)
    if i["done"]?.bool == true { Focus.clear(n); return ["project": .string(n), "cleared": true] }
    guard let action = i["action"]?.string else { throw ToolError("invalid_input", "Give action, the few words saying what you are doing, or done true") }
    let l = try Store.load(n)
    let plan = l.plan
    var r: Range? = nil
    if let p = i["paragraph"]?.int {
      let paras = transcriptLayout(l)
      guard p < paras.count else { throw ToolError("not_found", "There are \(paras.count) paragraphs, 0 to \(paras.count - 1)") }
      r = spanOf(paras[p])
    } else if let a = i["start"]?.double, let b = i["end"]?.double { r = Range(s: a, e: b) }
    else if let a = i["from"]?.int, let b = i["to"]?.int, a <= b, b < l.words.count { r = span(plan, l.words, a..<(b + 1)) }
    guard let r else { throw ToolError("invalid_input", "Give paragraph, start and end, or from and to") }
    Focus.set(n, action, r.s, r.e)
    return ["project": .string(n), "action": .string(action), "start": .number(round3(r.s)), "end": .number(round3(r.e))]
  },
]
