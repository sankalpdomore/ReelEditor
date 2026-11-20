// The files a project keeps beside its edits, ported from the web editor's lib/reel-tools (comments.ts, draft.ts, looks.ts):
// the comments left on its script (comments.json), the plan of a draft reel before anything is made (draft.json) and the
// saved video looks every project can start from (one JSON file each in <projects folder>/_looks). None of them is an edit,
// so none leaves an undo step. Each is written whole under the project's lock.
import Foundation

// ---------------------------------------------------------------------------------------------------------------------
// Comments on words of the script, or on a range of the timeline (range true, from and to -1, start and end edit seconds)

public struct ReelComment: Codable, Equatable, Sendable {
  public var id: String
  public var range: Bool? = nil
  public var from: Int // first word index, -1 for a range
  public var to: Int // last word index, -1 for a range
  public var words: String // the words commented on as they were, or the range in plain words
  public var start: Double // source seconds where the words start, edit seconds for a range
  public var end: Double
  public var comment: String
  public var status: String // unresolved or resolved
  public var created: String
  public var resolved: String? = nil
  public var resolution: String? = nil
  public var edited: String? = nil
}

public enum Comments {
  struct File: Codable { var comments: [ReelComment] }
  static func url(_ name: String) -> URL { Store.file(name, "comments.json") }
  static func now() -> String { ISO8601DateFormatter().string(from: Date()) }

  public static func read(_ name: String) -> [ReelComment] { (try? Store.read(File.self, url(name)).comments) ?? [] }
  static func save(_ name: String, _ list: [ReelComment]) throws { try Store.write(File(comments: list), url(name)) }

  public static func list(_ name: String, status: String = "unresolved") throws -> JSON {
    _ = try Store.load(name)
    let all = read(name)
    return ["project": .string(name), "unresolved": .number(Double(all.filter { $0.status == "unresolved" }.count)),
            "comments": JSON.from(status == "all" ? all : all.filter { $0.status == status })]
  }

  public static func add(_ name: String, from: Int?, to: Int?, start: Double?, end: Double?, comment raw: String) throws -> JSON {
    let l = try Store.load(name)
    return try Store.withLock(name) {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw ToolError("invalid_input", "The comment is empty") }
      let id = "c" + String(Int(Date().timeIntervalSince1970 * 1000), radix: 36) + String(UUID().uuidString.lowercased().prefix(3))
      var c: ReelComment
      if from == nil && to == nil {
        guard let s = start, let e = end, s >= 0, e > s else { throw ToolError("invalid_input", "Give from and to (word indexes) or start and end (edit seconds, end after start)") }
        func clock(_ t: Double) -> String { String(format: "%d:%04.1f", Int(t) / 60, t.truncatingRemainder(dividingBy: 60)) }
        c = ReelComment(id: id, range: true, from: -1, to: -1, words: "Timeline \(clock(round3(s))) to \(clock(round3(e)))", start: round3(s), end: round3(e), comment: String(text.prefix(4000)), status: "unresolved", created: now())
      } else {
        guard let f = from, let t = to, f >= 0, t >= f, t < l.words.count else { throw ToolError("invalid_input", "from and to are word indexes, to not before from, inside the script (\(l.words.count) words)") }
        let ws = Array(l.words[f...t])
        c = ReelComment(id: id, from: f, to: t, words: String(ws.enumerated().map { l.project.edits.corrections[String(f + $0.offset)] ?? $0.element.w }.joined(separator: " ").prefix(400)),
                        start: round3(ws.first!.s), end: round3(ws.last!.e), comment: String(text.prefix(4000)), status: "unresolved", created: now())
      }
      let all = read(name) + [c]
      try save(name, all)
      return ["project": .string(name), "comment": JSON.from(c), "unresolved": .number(Double(all.filter { $0.status == "unresolved" }.count))]
    }
  }

  public static func edit(_ name: String, id: String, comment raw: String) throws -> JSON {
    _ = try Store.load(name)
    return try Store.withLock(name) {
      let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !text.isEmpty else { throw ToolError("invalid_input", "The comment is empty") }
      var all = read(name)
      guard let k = all.firstIndex(where: { $0.id == id }) else { throw ToolError("not_found", "No comment \(id) on \(name)") }
      all[k].comment = String(text.prefix(4000)); all[k].edited = now()
      try save(name, all)
      return ["project": .string(name), "comment": JSON.from(all[k])]
    }
  }

  public static func setStatus(_ name: String, id: String, resolved: Bool, note: String? = nil) throws -> JSON {
    _ = try Store.load(name)
    return try Store.withLock(name) {
      var all = read(name)
      guard let k = all.firstIndex(where: { $0.id == id }) else { throw ToolError("not_found", "No comment \(id) on \(name)") }
      all[k].status = resolved ? "resolved" : "unresolved"
      if resolved {
        all[k].resolved = now()
        if let n = note?.trimmingCharacters(in: .whitespacesAndNewlines), !n.isEmpty { all[k].resolution = String(n.prefix(2000)) }
      } else { all[k].resolved = nil; all[k].resolution = nil }
      try save(name, all)
      return ["project": .string(name), "comment": JSON.from(all[k]), "unresolved": .number(Double(all.filter { $0.status == "unresolved" }.count))]
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// A draft reel: the plan for a reel before anything is made, a project folder with a draft.json and no video yet. Each
// section is a part of the script with what it needs (a talking head clip to generate, a walkthrough to record, the voice,
// the edit). A section is pending until it is marked done; a reel with no pending part and a post is posted.

public struct DraftNeed: Codable, Equatable, Sendable { public var kind: String; public var label: String; public var detail: String? = nil; public var required: Bool; public var status: String? = nil }
public struct DraftBlock: Codable, Equatable, Sendable { public var label: String; public var text: String }
public struct DraftLink: Codable, Equatable, Sendable { public var label: String; public var url: String }
public struct DraftSection: Codable, Equatable, Sendable {
  public var id: String
  public var part: String
  public var title: String
  public var logo: String? = nil
  public var time: String? = nil
  public var status: String? = nil // pending (nil), running or done
  public var script: String
  public var needs: [DraftNeed]
  public var blocks: [DraftBlock]? = nil
  public var links: [DraftLink]? = nil
  public var isPending: Bool { status != "done" }
}
public struct DraftReel: Codable, Equatable, Sendable {
  public var title: String
  public var format: String? = nil
  public var planPost: String? = nil
  public var post: String? = nil
  public var summary: String? = nil
  public var references: [ReelReference]? = nil
  public var created: String
  public var sections: [DraftSection]
  public var hasPending: Bool { sections.contains { $0.isPending } }
}

public enum Drafts {
  static func url(_ name: String) -> URL { Store.file(name, "draft.json") }
  public static func read(_ name: String) -> DraftReel? { try? Store.read(DraftReel.self, url(name)) }

  // The projects on the list that hold a draft and no video yet.
  public static func names() -> [String] {
    Store.registry().keys.filter { Store.has(url($0)) && !Store.exists($0) }.sorted()
  }

  static func load(_ name: String) throws -> DraftReel {
    _ = try Store.checkName(name)
    guard let d = read(name) else { throw ToolError("not_found", "No draft called \(name)") }
    return d
  }
  static func section(_ d: DraftReel, _ id: String, _ name: String) throws -> Int {
    guard let k = d.sections.firstIndex(where: { $0.id == id }) else { throw ToolError("not_found", "No section \(id) in \(name), the ids are \(d.sections.map(\.id).joined(separator: ", "))") }
    return k
  }
  static func withDraftLock<T>(_ name: String, _ fn: () throws -> T) throws -> T {
    try FileManager.default.createDirectory(at: Store.dir(name), withIntermediateDirectories: true)
    return try Store.withLock(name, fn)
  }

  public static func create(_ name: String, _ i: JSON) throws -> JSON {
    let n = try Store.checkName(name)
    if read(n) != nil { throw ToolError("exists", "A draft called \(n) already exists") }
    if Store.exists(n) { throw ToolError("exists", "A project called \(n) already exists") }
    _ = try Store.newDocument(n, in: nil)
    func s(_ v: JSON?, _ max: Int) -> String? { v?.string.map { String($0.prefix(max)) } }
    let refs = normalizeReferences(i["references"])
    let sections = (i["sections"]?.array ?? []).enumerated().map { k, x in
      DraftSection(id: "d\(k + 1)", part: s(x["part"], 60) ?? "", title: s(x["title"], 120) ?? "",
                   logo: x["logo"]?.string.flatMap { $0.range(of: "^[a-z0-9-]{1,80}$", options: .regularExpression) != nil ? $0 : nil },
                   time: s(x["time"], 40), script: s(x["script"], 4000) ?? "",
                   needs: (x["needs"]?.array ?? []).map { nd in DraftNeed(kind: nd["kind"]?.string ?? "edit", label: s(nd["label"], 120) ?? "", detail: s(nd["detail"], 600), required: nd["required"]?.bool == true, status: "todo") })
    }
    let draft = DraftReel(title: String((i["title"]?.string ?? "").trimmingCharacters(in: .whitespaces).prefix(160)), format: i["format"]?.string, planPost: i["planPost"]?.string,
                          summary: s(i["summary"], 600), references: refs.isEmpty ? nil : refs, created: ISO8601DateFormatter().string(from: Date()), sections: sections)
    try withDraftLock(n) { try Store.write(draft, url(n)) }
    return ["project": .string(n), "sections": .number(Double(sections.count))]
  }

  public static func setSectionStatus(_ name: String, section id: String, status: String, needsDone: Bool?) throws -> JSON {
    try withDraftLock(name) {
      var d = try load(name)
      let k = try section(d, id, name)
      d.sections[k].status = status
      if let nd = needsDone { for j in d.sections[k].needs.indices { d.sections[k].needs[j].status = nd ? "done" : "todo" } }
      try Store.write(d, url(name))
      let done = d.sections.filter { !$0.isPending }.count
      return ["project": .string(name), "section": .string(id), "status": .string(status), "done": .number(Double(done)), "pending": .number(Double(d.sections.count - done)), "total": .number(Double(d.sections.count))]
    }
  }

  public static func setNeedStatus(_ name: String, section id: String, step: JSON, status: String) throws -> JSON {
    try withDraftLock(name) {
      var d = try load(name)
      let k = try section(d, id, name)
      let needs = d.sections[k].needs
      let at: Int = step.int ?? needs.firstIndex { $0.label.lowercased().contains((step.string ?? "\u{0}").lowercased()) } ?? -1
      guard at >= 0 && at < needs.count else { throw ToolError("not_found", "No step \(step.text()) in \(id), the steps are \(needs.enumerated().map { "\($0.offset): \($0.element.label)" }.joined(separator: "; "))") }
      d.sections[k].needs[at].status = status
      if status == "running" && d.sections[k].status != "done" { d.sections[k].status = "running" }
      if status != "running" && d.sections[k].status == "running" && !d.sections[k].needs.contains(where: { $0.status == "running" }) { d.sections[k].status = "pending" }
      try Store.write(d, url(name))
      return ["project": .string(name), "section": .string(id), "step": .number(Double(at)), "label": .string(needs[at].label), "status": .string(status), "steps": .array(d.sections[k].needs.map { .string($0.status ?? "todo") })]
    }
  }

  public static func setPublished(_ name: String, _ i: JSON) throws -> JSON {
    try withDraftLock(name) {
      var d = try load(name)
      let k = try section(d, i["section"]?.string ?? "", name)
      d.post = String((i["post"]?.string ?? "").prefix(160))
      d.sections[k].status = "done"
      for j in d.sections[k].needs.indices { d.sections[k].needs[j].status = "done" }
      if let s = i["script"]?.string { d.sections[k].script = String(s.prefix(4000)) }
      if let t = i["time"]?.string { d.sections[k].time = String(t.prefix(60)) }
      if let b = i["blocks"]?.array { d.sections[k].blocks = b.prefix(8).map { DraftBlock(label: String(($0["label"]?.string ?? "").prefix(120)), text: String(($0["text"]?.string ?? "").prefix(4000))) } }
      if let l = i["links"]?.array { d.sections[k].links = l.prefix(12).map { DraftLink(label: String(($0["label"]?.string ?? "").prefix(120)), url: String(($0["url"]?.string ?? "").prefix(400))) } }
      try Store.write(d, url(name))
      return ["project": .string(name), "post": .string(d.post ?? ""), "section": .string(d.sections[k].id), "blocks": .number(Double(d.sections[k].blocks?.count ?? 0)),
              "links": .number(Double(d.sections[k].links?.count ?? 0)), "pending": .number(Double(d.sections.filter { $0.isPending }.count))]
    }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Saved video looks: one JSON file each, { name, default?, created, from?, look: { saturation ... vignette } }, the same shape
// as the web editor's data/video-look-settings. One of them can be the default that every new project starts with. They
// live in <projects folder>/_looks, or in looksDir of settings.json (point it at the repo's data/video-look-settings to share
// them with the web editor).

public struct LookTemplate: Codable, Equatable, Sendable {
  public var name: String
  public var slug: String
  public var `default`: Bool
  public var created: String? = nil
  public var from: String? = nil
  public var look: ReelLook
}

public enum Looks {
  struct Settings: Decodable { var looksDir: String? }
  public static var dir: URL {
    if let d = (try? Store.read(Settings.self, Store.root.appendingPathComponent("settings.json")))?.looksDir, !d.isEmpty { return URL(fileURLWithPath: (d as NSString).expandingTildeInPath, isDirectory: true) }
    return Store.root.appendingPathComponent("_looks", isDirectory: true)
  }
  static func slugOf(_ name: String) -> String {
    let lowered = String(name.trimmingCharacters(in: .whitespaces).lowercased().map { ($0.isASCII && ($0.isLetter || $0.isNumber)) ? $0 : "-" })
    return String(lowered.split(separator: "-").joined(separator: "-").prefix(60))
  }

  public static func list() -> [LookTemplate] {
    let files = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".json") }.sorted()
    return files.compactMap { f in
      guard let j = try? Store.read(JSON.self, dir.appendingPathComponent(f)), let name = j["name"]?.string,
            var look = normalizeLook(j["look"]) else { return nil }
      look.name = name
      return LookTemplate(name: name, slug: String(f.dropLast(5)), default: j["default"]?.bool == true, created: j["created"]?.string, from: j["from"]?.string, look: look)
    }
  }

  public static func get(_ nameOrSlug: String) throws -> LookTemplate {
    let all = list()
    guard let hit = all.first(where: { $0.slug == nameOrSlug || $0.name.lowercased() == nameOrSlug.lowercased() }) else {
      throw ToolError("not_found", "No video look called \(nameOrSlug), the saved ones are \(all.isEmpty ? "none" : all.map(\.name).joined(separator: ", "))")
    }
    return hit
  }

  public static func defaultLook() -> LookTemplate? { list().first { $0.default } }

  public static func save(_ name: String, values: ReelLook, makeDefault: Bool, from: String?) throws -> LookTemplate {
    var withName = values; withName.name = name
    guard let look = normalizeLook(withName) else { throw ToolError("invalid", "That look is all zeros, there is nothing to save") }
    let slug = slugOf(name)
    guard !slug.isEmpty else { throw ToolError("invalid", "A look needs a name") }
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if makeDefault {
      for t in list() where t.default && t.slug != slug {
        let u = dir.appendingPathComponent("\(t.slug).json")
        if var j = (try? Store.read(JSON.self, u))?.object { j.removeValue(forKey: "default"); try Store.write(JSON.object(j), u) }
      }
    }
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    var values = JSON.from(look).object ?? [:]
    values.removeValue(forKey: "name")
    var file: [String: JSON] = ["name": .string(String(name.trimmingCharacters(in: .whitespaces).prefix(60))), "created": .string(df.string(from: Date())), "look": .object(values)]
    if makeDefault { file["default"] = true }
    if let from { file["from"] = .string(from) }
    try Store.write(JSON.object(file), dir.appendingPathComponent("\(slug).json"))
    return LookTemplate(name: file["name"]!.string!, slug: slug, default: makeDefault, created: file["created"]?.string, from: from, look: look)
  }
}
