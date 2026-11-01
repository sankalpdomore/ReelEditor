// Where a project lives on disk and how it is changed safely. A project is a folder under ~/Movies/Reel Editor (or
// $REEL_EDITOR_HOME) holding only JSON: project.json (the source video's path and the edit decision list),
// animations.json (the coded animation layer), transcript.json (the words), history.json (undo) and status.json (what
// is running). The source video is only ever read. Every change takes a file lock on the project, so the app and the
// MCP server can edit the same project at once, and every file is written whole or not at all.
import Foundation

public struct Project: Codable, Equatable, Sendable {
  public var app = "reel-editor-mac"
  public var version = 1
  public var rev = 0 // counts the saves, so an open window knows another caller changed it
  public var name: String // the folder's name, lowercase letters, digits and dashes
  public var title: String? = nil // what the project is called on screen, free text; nil shows the name
  public var rulesDir: String? = nil // the folder of rule books this project's chat starts with; nil is the last one saved
  public var createdAt: String
  public var main: Source // the video the project was made from
  public var edits = Edl()
}

public struct Transcript: Codable, Sendable { public var engine: String; public var words: [Word] }

public struct Snapshot: Codable, Equatable, Sendable {
  public var clips: [Clip]?
  public var sources: [Source]
  public var cuts: [Cut]
  public var deleted: [Int]
  public var corrections: [String: String]
  public var animations: [ReelAnimation]
  public var audioOverlays: [AudioOverlay]? = nil // nil in a step written before overlays existed: they are left as they are
}
public struct HistoryStep: Codable, Sendable { public var label: String; public var snap: Snapshot }
public struct History: Codable, Sendable { public var past: [HistoryStep] = []; public var future: [HistoryStep] = [] }

public struct ToolError: Error, CustomStringConvertible {
  public let code: String; public let message: String
  public init(_ code: String, _ message: String) { self.code = code; self.message = message }
  public var description: String { message }
}

// Everything about one project, read in one go.
public struct Loaded: Sendable {
  public var project: Project
  public var animations: AnimationFile
  public var words: [Word]
  public var history: History
  public var extra = ExtraWords() // the words of the added videos and of the audio overlays
  public var main: EdlMain { EdlMain(duration: project.main.duration, words: words) }
  public var hasAnyWords: Bool { !words.isEmpty || !extra.isEmpty }
  public var plan: Plan { buildPlan(project.edits, main) }
}

public enum Store {
  public static let HISTORY_LIMIT = 100
  public static let NAME = try! NSRegularExpression(pattern: "^[a-z0-9-]{1,120}$")
  public static let VIDEO_EXTENSIONS = ["mp4", "mov", "m4v"]

  public static var root: URL {
    if let h = ProcessInfo.processInfo.environment["REEL_EDITOR_HOME"], !h.isEmpty { return URL(fileURLWithPath: (h as NSString).expandingTildeInPath) }
    return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Movies/Reel Editor")
  }

  public static func checkName(_ name: String) throws -> String {
    guard NAME.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)) != nil else { throw ToolError("invalid_name", "A project name is lowercase letters, digits and dashes only (^[a-z0-9-]+$)") }
    return name
  }
  // Where the words of an added video or an audio overlay are kept: media/words-<hash of its path>.json.
  public static func wordsFile(_ name: String, _ path: String) -> URL {
    var h: UInt64 = 1469598103934665603
    for b in path.utf8 { h = (h ^ UInt64(b)) &* 1099511628211 }
    return dir(name).appendingPathComponent("media/words-\(String(h, radix: 16)).json")
  }
  // ------------------------------------------------------------------------------------------------------------------
  // One file per project (Sankalp, 1 Nov 2026): everything a project holds lives in a single JSON document,
  // <name>.reel.json, saved in any folder, with one section per kind of data: project (the source video and the edit
  // decision list), animations, transcript, history, comments, draft and words (the words of the added videos and voice
  // overs, by a hash of their path). projects.json in the root remembers where each document is and when it was opened.
  // The code still names each kind by its old file name: file(name, "project.json") is a key whose reads and writes
  // land in that section of the document. What is not project data stays out of it, in the app's own folder for the
  // project, dir(name) = <root>/_cache/<name>: the running job's status, the lock, the waveform caches. Exports go
  // beside the document, in "<name> exports".

  public static let DOC_EXT = ".reel.json"
  static let PARTS = ["project.json": "project", "animations.json": "animations", "transcript.json": "transcript",
                      "history.json": "history", "comments.json": "comments", "draft.json": "draft"]

  public static var cacheRoot: URL { root.appendingPathComponent("_cache", isDirectory: true) }
  public static func dir(_ name: String) -> URL {
    let d = cacheRoot.appendingPathComponent(name, isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    return d
  }
  public static func file(_ name: String, _ f: String) -> URL { dir(name).appendingPathComponent(f) }

  // The project's document, where it was saved.
  public static func document(_ name: String) -> URL? { registry()[name].map { URL(fileURLWithPath: $0.path) } }
  public static func exportsDir(_ name: String) -> URL {
    (document(name)?.deletingLastPathComponent() ?? root).appendingPathComponent("\(name) exports", isDirectory: true)
  }
  // A project with its video (not only a draft) is saved under this name.
  public static func exists(_ name: String) -> Bool { (try? docObject(name))?["project"] != nil }

  // The registry: project name to where its document is, and when it was last opened.
  public struct Entry: Codable, Sendable { public var path: String; public var openedAt: Double? = nil }
  static var registryURL: URL { root.appendingPathComponent("projects.json") }
  public static func registry() -> [String: Entry] {
    migrateOnce()
    return (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: registryURL))) ?? [:]
  }
  static func editRegistry(_ fn: (inout [String: Entry]) throws -> Void) throws {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try fileLock(root.appendingPathComponent(".projects.lock")) {
      var r = (try? JSONDecoder().decode([String: Entry].self, from: Data(contentsOf: registryURL))) ?? [:]
      try fn(&r)
      try write(r, registryURL)
    }
  }
  // Remembers when a project was opened, for the Open a reel list.
  public static func touch(_ name: String) { try? editRegistry { r in r[name]?.openedAt = Date().timeIntervalSince1970 } }
  // Takes a project off the list; its document is left where it is.
  public static func forget(_ name: String) throws {
    guard registry()[name] != nil else { throw ToolError("not_found", "No project called \(name) on the list") }
    try editRegistry { r in r[name] = nil }
  }

  // Adds a document saved anywhere to the list, by its path, and returns its project name. A different file with the
  // same project name already on the list is refused, since a name stands for one project.
  public static func register(file url: URL) throws -> String {
    let u = url.standardizedFileURL
    guard let data = try? Data(contentsOf: u), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ToolError("not_found", "\(u.path) is not a Reel Editor project file")
    }
    let name = ((o["project"] as? [String: Any])?["name"] as? String) ?? (o["name"] as? String) ?? ""
    guard (try? checkName(name)) != nil, o["project"] != nil || o["draft"] != nil else { throw ToolError("invalid_file", "\(u.path) is not a Reel Editor project file") }
    if let e = registry()[name], URL(fileURLWithPath: e.path).standardizedFileURL.path != u.path, FileManager.default.fileExists(atPath: e.path) {
      throw ToolError("exists", "Another project called \(name) is on the list, at \(e.path). Rename one of them first")
    }
    try editRegistry { r in r[name] = Entry(path: u.path, openedAt: Date().timeIntervalSince1970) }
    return name
  }

  // A new, empty document for a name, in a folder (the root when none is given), put on the list.
  public static func newDocument(_ name: String, in folder: URL?) throws -> URL {
    let n = try checkName(name)
    if let e = registry()[n], FileManager.default.fileExists(atPath: e.path) { return URL(fileURLWithPath: e.path) }
    let f = (folder ?? root).appendingPathComponent(n + DOC_EXT)
    if FileManager.default.fileExists(atPath: f.path) { throw ToolError("exists", "\(f.path) already exists") }
    try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
    try writeDoc(f, ["format": "reel-editor-mac/1", "name": n])
    try editRegistry { r in r[n] = Entry(path: f.standardizedFileURL.path, openedAt: Date().timeIntervalSince1970) }
    return f
  }

  // The document as a JSON object, and writing it back whole, sorted and readable.
  // Parsed documents are kept by path and modification time, so polling and listing read a file only when it changed.
  nonisolated(unsafe) static var parsed: [String: (Date, [String: Any])] = [:]
  static let parsedLock = NSLock()
  static func docObject(_ name: String) throws -> [String: Any] {
    guard let f = document(name) else { throw ToolError("not_found", "No project called \(name). list_projects shows them") }
    let m = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date
    parsedLock.lock()
    if let m, let c = parsed[f.path], c.0 == m { parsedLock.unlock(); return c.1 }
    parsedLock.unlock()
    guard let d = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else {
      throw ToolError("not_found", "The project file \(f.path) is missing or unreadable")
    }
    if let m { parsedLock.lock(); parsed[f.path] = (m, o); parsedLock.unlock() }
    return o
  }
  static func writeDoc(_ url: URL, _ o: [String: Any]) throws {
    let d = try JSONSerialization.data(withJSONObject: o, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try d.write(to: url, options: .atomic)
  }

  // Which section of a document a key URL stands for: (project, section, word hash).
  static func part(_ url: URL) -> (name: String, key: String, sub: String?)? {
    // Compared as built, not standardized: standardizing drops /private only from paths that exist, so a key (never a
    // real file) and the cache folder would disagree under /private/tmp.
    let base = cacheRoot.path + "/"
    let p = url.path
    guard p.hasPrefix(base) else { return nil }
    let rel = p.dropFirst(base.count).split(separator: "/", maxSplits: 1).map(String.init)
    guard rel.count == 2 else { return nil }
    if let k = PARTS[rel[1]] { return (rel[0], k, nil) }
    if rel[1].hasPrefix("media/words-") && rel[1].hasSuffix(".json") { return (rel[0], "words", String(rel[1].dropFirst(12).dropLast(5))) }
    return nil
  }

  // An exclusive lock on a file, across processes.
  static func fileLock<T>(_ url: URL, _ fn: () throws -> T) throws -> T {
    let fd = open(url.path, O_CREAT | O_RDWR, 0o644)
    guard fd >= 0 else { throw ToolError("io_error", "Could not lock \(url.path)") }
    defer { flock(fd, LOCK_UN); close(fd) }
    flock(fd, LOCK_EX)
    return try fn()
  }

  // Projects kept the old way, a folder of JSON files in the root, become one document each the first time the store is
  // used: the files' contents go into the document's sections unchanged, the document is saved in the root and put on
  // the list, the waveform caches move to the app's folder, and the old folder is kept in <root>/_migrated.
  nonisolated(unsafe) static var migrated = false
  static func migrateOnce() {
    if migrated { return }
    migrated = true
    let fm = FileManager.default
    guard let items = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
    for d in items {
      let n = d.lastPathComponent
      guard (try? checkName(n)) != nil, fm.fileExists(atPath: d.appendingPathComponent("project.json").path) || fm.fileExists(atPath: d.appendingPathComponent("draft.json").path) else { continue }
      let doc = root.appendingPathComponent(n + DOC_EXT)
      guard !fm.fileExists(atPath: doc.path) else { continue }
      var o: [String: Any] = ["format": "reel-editor-mac/1", "name": n]
      for (f, k) in PARTS {
        if let data = try? Data(contentsOf: d.appendingPathComponent(f)), let v = try? JSONSerialization.jsonObject(with: data) { o[k] = v }
      }
      var words: [String: Any] = [:]
      let media = d.appendingPathComponent("media")
      for w in (try? fm.contentsOfDirectory(at: media, includingPropertiesForKeys: nil)) ?? [] where w.lastPathComponent.hasPrefix("words-") && w.pathExtension == "json" {
        if let data = try? Data(contentsOf: w), let v = try? JSONSerialization.jsonObject(with: data) { words[String(w.deletingPathExtension().lastPathComponent.dropFirst(6))] = v }
      }
      if !words.isEmpty { o["words"] = words }
      do {
        try writeDoc(doc, o)
        try editRegistry { r in r[n] = Entry(path: doc.standardizedFileURL.path, openedAt: nil) }
        let cache = cacheRoot.appendingPathComponent(n, isDirectory: true)
        try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
        if fm.fileExists(atPath: media.path) && !fm.fileExists(atPath: cache.appendingPathComponent("media").path) { try? fm.copyItem(at: media, to: cache.appendingPathComponent("media")) }
        let keep = root.appendingPathComponent("_migrated", isDirectory: true)
        try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
        try? fm.moveItem(at: d, to: keep.appendingPathComponent(n))
        Log.write("core", "migrate_project", extra: ["project": .string(n), "document": .string(doc.path)])
      } catch { Log.error("migrate_project", String(describing: error), args: ["project": .string(n)]) }
    }
  }

  public static func slug(_ s: String) -> String {
    let lowered = s.lowercased().map { $0.isLetter && $0.isASCII || $0.isNumber && $0.isASCII ? $0 : "-" }
    let joined = String(lowered).split(separator: "-").joined(separator: "-")
    return joined.isEmpty ? "video" : String(joined.prefix(80))
  }

  // A project is named date, name, version: 2026-10-21-sankalp-intro-v1, the next free version when that is taken.
  public static func freeName(for video: URL) -> String {
    let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
    let base = "\(df.string(from: Date()))-\(slug(video.deletingPathExtension().lastPathComponent))"
    var v = 1
    while registry()["\(base)-v\(v)"] != nil || FileManager.default.fileExists(atPath: root.appendingPathComponent("\(base)-v\(v)" + DOC_EXT).path) { v += 1 }
    return "\(base)-v\(v)"
  }

  // The projects on the list whose documents hold a video project (a draft without a video is listed by Drafts).
  public static func names() -> [String] {
    registry().filter { FileManager.default.fileExists(atPath: $0.value.path) && exists($0.key) }.map(\.key).sorted()
  }

  // A project's own fields without its history and words, for lists that only need the title and the video. Cached by
  // the document's modification time, so a list polled every two seconds reads a document only when it changed.
  nonisolated(unsafe) static var peeked: [String: (Date, Project)] = [:]
  static let peekLock = NSLock()
  public static func peek(_ name: String) -> Project? {
    guard let f = document(name) else { return nil }
    let m = (try? FileManager.default.attributesOfItem(atPath: f.path)[.modificationDate]) as? Date ?? .distantPast
    peekLock.lock(); defer { peekLock.unlock() }
    if let c = peeked[f.path], c.0 == m { return c.1 }
    guard let p = try? read(Project.self, file(name, "project.json")) else { return nil }
    peeked[f.path] = (m, p)
    return p
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Reading and writing JSON

  // A project's sections are read from and written into its one document (part above); any other file is read and
  // written as itself.
  public static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
    if let pt = part(url) {
      let o = try docObject(pt.name)
      let v: Any? = pt.sub.map { ((o["words"] as? [String: Any])?[$0]) as Any? } ?? o[pt.key]
      guard let v, !(v is NSNull) else { throw ToolError("not_found", "\(pt.name) has no \(pt.key)") }
      return try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed]))
    }
    return try JSONDecoder().decode(type, from: Data(contentsOf: url))
  }
  public static func write<T: Encodable>(_ value: T, _ url: URL) throws {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    if let pt = part(url) {
      let v = try JSONSerialization.jsonObject(with: enc.encode(value), options: [.fragmentsAllowed])
      // Where the document is, read under the lock, so a write never lands at the old place of a document being moved.
      try fileLock(file(pt.name, ".doc.lock")) {
        guard let f = document(pt.name) else { throw ToolError("not_found", "No project called \(pt.name). list_projects shows them") }
        var o = (try? docObject(pt.name)) ?? ["format": "reel-editor-mac/1", "name": pt.name]
        if let sub = pt.sub { var w = o["words"] as? [String: Any] ?? [:]; w[sub] = v; o["words"] = w } else { o[pt.key] = v }
        try writeDoc(f, o)
      }
      return
    }
    try enc.encode(value).write(to: url, options: .atomic)
  }
  // Whether a key URL or a file has something in it.
  public static func has(_ url: URL) -> Bool {
    if let pt = part(url) {
      guard let o = try? docObject(pt.name) else { return false }
      return pt.sub.map { (o["words"] as? [String: Any])?[$0] != nil } ?? (o[pt.key] != nil)
    }
    return FileManager.default.fileExists(atPath: url.path)
  }

  public static func load(_ name: String) throws -> Loaded {
    _ = try checkName(name)
    guard let project = try? read(Project.self, file(name, "project.json")) else { throw ToolError("not_found", "No project called \(name). list_projects shows them") }
    let anims = (try? read(AnimationFile.self, file(name, "animations.json"))) ?? AnimationFile()
    let words = (try? read(Transcript.self, file(name, "transcript.json")).words) ?? []
    let history = (try? read(History.self, file(name, "history.json"))) ?? History()
    var extra = ExtraWords()
    for s in project.edits.sources { if let w = try? read(Transcript.self, wordsFile(name, s.file)).words { extra.sources[s.id] = w } }
    for o in project.edits.audioOverlays ?? [] { if let w = try? read(Transcript.self, wordsFile(name, o.file)).words { extra.overlays[o.file] = w } }
    return Loaded(project: project, animations: anims, words: words, history: history, extra: extra)
  }

  // When the project's document last changed, cheap enough to poll: any save from any process moves it.
  public static func revs(_ name: String) -> (Int, Int, Date?) {
    let t = document(name).flatMap { (try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate]) as? Date }
    return (0, 0, t)
  }

  // One caller at a time per project, across processes: an exclusive lock on the project's .lock file.
  public static func withLock<T>(_ name: String, _ fn: () throws -> T) throws -> T { try fileLock(file(name, ".lock"), fn) }

  // ------------------------------------------------------------------------------------------------------------------
  // Creating a project

  public static func videoURL(_ path: String) throws -> URL {
    let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath).resolvingSymlinksInPath()
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { throw ToolError("not_found", "No file at \(path)") }
    guard VIDEO_EXTENSIONS.contains(url.pathExtension.lowercased()) else { throw ToolError("invalid_path", "Not a video (\(VIDEO_EXTENSIONS.joined(separator: ", ")))") }
    return url
  }

  public static func create(video: URL, name: String?) async throws -> Loaded { try await create(video: video, name: name, link: true, folder: nil) }
  public static func create(video: URL, name: String?, link: Bool) async throws -> Loaded { try await create(video: video, name: name, link: link, folder: nil) }

  // A new project from a video, its document saved in folder (the root when nil) as <name>.reel.json. link false copies
  // the video beside the document (<name> source.<ext>) instead of reading it where it is. A draft of the same name
  // (create_draft_reel) gets its video in its own document. A new project starts with the saved look marked default, as
  // in the web editor.
  public static func create(video: URL, name: String?, link: Bool, folder: URL?) async throws -> Loaded {
    let info = try await Media.probe(video)
    let n = try name.map(checkName) ?? freeName(for: video)
    if exists(n) { throw ToolError("exists", "A project called \(n) already exists") }
    let doc = try newDocument(n, in: folder)
    var path = video.path
    if !link {
      let copy = doc.deletingLastPathComponent().appendingPathComponent("\(n) source.\(video.pathExtension.lowercased())")
      try? FileManager.default.removeItem(at: copy)
      try FileManager.default.copyItem(at: video, to: copy)
      path = copy.path
    }
    let iso = ISO8601DateFormatter().string(from: Date())
    let main = Source(id: MAIN, file: path, duration: info.duration, hasAudio: info.hasAudio, width: info.width, height: info.height, label: video.lastPathComponent, origin: video.path)
    var project = Project(name: n, createdAt: iso, main: main)
    project.rulesDir = Rules.lastDir.path // a new project starts with the rules folder saved last
    if let d = Looks.defaultLook() { project.edits.look = d.look }
    try write(project, file(n, "project.json"))
    try write(AnimationFile(), file(n, "animations.json"))
    try write(["state": "ready"] as [String: String], file(n, "status.json"))
    Log.write("core", "create_project", extra: ["project": .string(n), "document": .string(doc.path)])
    return try load(n)
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Changing a project

  public struct Mutation { public var loaded: Loaded; public var changed: Bool; public var info: [String: JSON] }

  static func snapshot(_ p: Project, _ a: AnimationFile) -> Snapshot {
    Snapshot(clips: p.edits.clips, sources: p.edits.sources, cuts: p.edits.cuts, deleted: p.edits.deleted, corrections: p.edits.corrections, animations: a.animations, audioOverlays: p.edits.audioOverlays ?? [])
  }

  // Reads the project, lets the edit change its EDL and its animations, and saves what changed. An edit that changes the
  // picture, the words or the animations leaves one undo step and clears redo. Settings (captions, title, speed,
  // sections) are saved without a step. An edit that changes nothing writes nothing.
  public static func mutate(_ name: String, _ label: String, _ edit: (inout Edl, inout [ReelAnimation], EdlMain) throws -> [String: JSON]) throws -> Mutation {
    try withLock(name) {
      var l = try load(name)
      let before = l.project, beforeAnims = l.animations
      var edl = l.project.edits, anims = l.animations.animations
      let info: [String: JSON]
      do { info = try edit(&edl, &anims, l.main) } catch let e as EdlError { throw ToolError(e.code, e.message) }
      edl = canonical(edl, l.main)
      if let o = edl.audioOverlays { let clean = normalizeOverlays(o); edl.audioOverlays = clean.isEmpty ? nil : clean }
      anims = normalizeAnimations(anims)
      let edlChanged = edl != before.edits, animChanged = anims != beforeAnims.animations
      if !edlChanged && !animChanged { return Mutation(loaded: l, changed: false, info: info) }
      var after = before; after.edits = edl
      var afterAnims = beforeAnims; afterAnims.animations = anims
      if snapshot(before, beforeAnims) != snapshot(after, afterAnims) {
        l.history.past.append(HistoryStep(label: label, snap: snapshot(before, beforeAnims)))
        if l.history.past.count > HISTORY_LIMIT { l.history.past.removeFirst(l.history.past.count - HISTORY_LIMIT) }
        l.history.future = []
        try write(l.history, file(name, "history.json"))
      }
      if edlChanged { after.rev += 1; try write(after, file(name, "project.json")) }
      if animChanged { afterAnims.rev += 1; try write(afterAnims, file(name, "animations.json")) }
      l.project = after; l.animations = afterAnims
      return Mutation(loaded: l, changed: true, info: info)
    }
  }

  public static func step(_ name: String, undo: Bool) throws -> (Mutation, String?) {
    try withLock(name) {
      var l = try load(name)
      var from = undo ? l.history.past : l.history.future
      var to = undo ? l.history.future : l.history.past
      guard let step = from.popLast() else { return (Mutation(loaded: l, changed: false, info: [:]), nil) }
      to.append(HistoryStep(label: step.label, snap: snapshot(l.project, l.animations)))
      if undo { l.history.past = from; l.history.future = to } else { l.history.future = from; l.history.past = to }
      var p = l.project, a = l.animations
      p.edits.clips = step.snap.clips; p.edits.sources = step.snap.sources; p.edits.cuts = step.snap.cuts
      p.edits.deleted = step.snap.deleted; p.edits.corrections = step.snap.corrections
      if let o = step.snap.audioOverlays { p.edits.audioOverlays = o.isEmpty ? nil : o }
      p.edits = canonical(p.edits, l.main)
      a.animations = step.snap.animations
      if p != l.project { p.rev += 1; try write(p, file(name, "project.json")) }
      if a != l.animations { a.rev += 1; try write(a, file(name, "animations.json")) }
      try write(l.history, file(name, "history.json"))
      l.project = p; l.animations = a
      return (Mutation(loaded: l, changed: true, info: [:]), step.label)
    }
  }

  // Changes the project's settings or records (the look, the music, the caption, a relinked file and so on): written
  // under the lock with no undo step, and nothing is written when nothing changed.
  public static func update(_ name: String, _ fn: (inout Project) throws -> [String: JSON]) throws -> Mutation {
    try withLock(name) {
      var l = try load(name)
      var p = l.project
      let info: [String: JSON]
      do { info = try fn(&p) } catch let e as EdlError { throw ToolError(e.code, e.message) }
      p.edits = canonical(p.edits, l.main)
      if p == l.project { return Mutation(loaded: l, changed: false, info: info) }
      p.rev += 1
      try write(p, file(name, "project.json"))
      l.project = p
      return Mutation(loaded: l, changed: true, info: info)
    }
  }

  // A source file was linked again at a new path: the undo history is pointed at it too, so an undo never brings back the
  // missing path, and the words read from the old path are kept for the new one.
  static func movedFile(_ name: String, from old: String, to new: String) {
    if var h = try? read(History.self, file(name, "history.json")) {
      func fix(_ s: inout Snapshot) {
        s.sources = s.sources.map { var x = $0; if x.file == old { x.file = new; x.origin = new }; return x }
        s.audioOverlays = s.audioOverlays?.map { var x = $0; if x.file == old { x.file = new; x.origin = new }; return x }
      }
      for i in h.past.indices { fix(&h.past[i].snap) }
      for i in h.future.indices { fix(&h.future[i].snap) }
      try? write(h, file(name, "history.json"))
    }
    let from = wordsFile(name, old), to = wordsFile(name, new)
    if has(from) && !has(to), let t = try? read(Transcript.self, from) { try? write(t, to) }
  }

  // Points a source of the project (main, an added video s1, or an overlay o1 and every part split from it) at a file again,
  // after it was moved or deleted. The file has to be as long as the one it replaces, within half a second, unless force.
  public static func relink(_ name: String, source id: String, to url: URL, force: Bool) async throws -> Mutation {
    let l = try load(name)
    let edl = l.project.edits
    let old: (file: String, duration: Double, video: Bool)
    if id == MAIN { old = (l.project.main.file, l.project.main.duration, true) }
    else if let s = edl.sources.first(where: { $0.id == id }) { old = (s.file, s.duration, true) }
    else if let o = edl.audioOverlays?.first(where: { $0.id == id }) { old = (o.file, o.duration, o.window != nil) }
    else { throw ToolError("not_found", "No source \(id). The sources are \(([MAIN] + edl.sources.map(\.id) + (edl.audioOverlays ?? []).map(\.id)).joined(separator: ", "))") }
    let seconds = old.video ? try await Media.probe(url).duration : try await Media.probeAudio(url)
    if !force && old.duration > 0 && abs(seconds - old.duration) > 0.5 {
      throw ToolError("duration_mismatch", "\(url.lastPathComponent) is \(String(format: "%.1f", seconds)) s long, the source it replaces was \(String(format: "%.1f", old.duration)) s. Pick the same file, or pass force true to link it anyway")
    }
    let new = url.path
    let m = try update(name) { p in
      if id == MAIN { p.main.file = new; p.main.origin = new }
      p.edits.sources = p.edits.sources.map { var x = $0; if x.file == old.file { x.file = new; x.origin = new }; return x }
      p.edits.audioOverlays = p.edits.audioOverlays?.map { var x = $0; if x.file == old.file { x.file = new; x.origin = new }; return x }
      return ["source": .string(id), "previous": .string(old.file), "file": .string(new), "seconds": .number(round3(seconds))]
    }
    try withLock(name) { movedFile(name, from: old.file, to: new) }
    return m
  }

  // Renames the project's folder to exactly `to` (the web editor's rename_reel), keeping its title.
  public static func rename(_ name: String, to: String) throws -> (name: String, previous: String) {
    let next = try checkName(to)
    if next == name { _ = try load(name); return (name, name) }
    if registry()[next] != nil { throw ToolError("exists", "A project called \(next) already exists") }
    var l = try load(name)
    try withLock(name) {
      l.project.name = next
      l.project.rev += 1
      try write(l.project, file(name, "project.json"))
    }
    try moveProject(name, to: next)
    return (next, name)
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Status of a long job (transcription, export)

  public static func setStatus(_ name: String, _ status: [String: JSON]) {
    var s = status
    s["updatedAt"] = .number(Date().timeIntervalSince1970)
    try? write(JSON.object(s), file(name, "status.json"))
  }
  public static func status(_ name: String) -> JSON { (try? read(JSON.self, file(name, "status.json"))) ?? ["state": "ready"] }

  // ------------------------------------------------------------------------------------------------------------------
  // Renaming

  // Gives a project a new title and moves its folder to the matching name (Sankalp Intro becomes sankalp-intro, or
  // sankalp-intro-2 when that is taken). The old name is remembered in .renames.json, so a window or an agent still
  // holding it can find the project. The video and the edits are untouched.
  public static func rename(_ name: String, title raw: String) throws -> (name: String, previous: String) {
    let title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !title.isEmpty else { throw ToolError("invalid_input", "The title cannot be empty") }
    var l = try load(name)
    var next = slug(title)
    if next != name {
      var n = 2
      let base = next
      while registry()[next] != nil { next = "\(base)-\(n)"; n += 1 }
    }
    try withLock(name) {
      l.project.title = title
      l.project.name = next
      l.project.rev += 1
      try write(l.project, file(name, "project.json"))
    }
    if next != name { try moveProject(name, to: next) }
    return (next, name)
  }

  // A renamed project's document becomes <next>.reel.json in the same folder, its place on the list and its app folder
  // move with it, and the old name is remembered in .renames.json for windows and agents still holding it.
  static func moveProject(_ name: String, to next: String) throws {
    let fm = FileManager.default
    guard let from = document(name) else { throw ToolError("not_found", "No project called \(name)") }
    let to = from.deletingLastPathComponent().appendingPathComponent(next + DOC_EXT)
    if fm.fileExists(atPath: to.path) { throw ToolError("exists", "\(to.path) already exists") }
    try fm.moveItem(at: from, to: to)
    var doc = (try? JSONSerialization.jsonObject(with: Data(contentsOf: to)) as? [String: Any]) ?? [:]
    doc["name"] = next
    try? writeDoc(to, doc)
    try editRegistry { r in let e = r[name]; r[name] = nil; r[next] = Entry(path: to.standardizedFileURL.path, openedAt: e?.openedAt) }
    let oldCache = cacheRoot.appendingPathComponent(name), newCache = cacheRoot.appendingPathComponent(next)
    if fm.fileExists(atPath: oldCache.path) && !fm.fileExists(atPath: newCache.path) { try? fm.moveItem(at: oldCache, to: newCache) }
    var map = renames()
    for (k, v) in map where v == name { map[k] = next }
    map[name] = next
    try? write(map, root.appendingPathComponent(".renames.json"))
  }

  // Moves a project's document into another folder under the same file name (Sankalp, 1 Nov 2026). Only the document
  // moves: the video and every other source are read where they are, exports made earlier stay where they are, and new
  // exports go beside the document's new place. The edits are held while it moves, and the list points at the new path.
  public static func relocate(_ name: String, to folder: URL) throws -> (from: URL, to: URL) {
    let fm = FileManager.default
    guard let from = document(name), fm.fileExists(atPath: from.path) else { throw ToolError("not_found", "No project file for \(name). list_projects shows them") }
    var isDir: ObjCBool = false
    if fm.fileExists(atPath: folder.path, isDirectory: &isDir), !isDir.boolValue { throw ToolError("invalid_path", "\(folder.path) is a file, not a folder") }
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    let to = folder.standardizedFileURL.appendingPathComponent(from.lastPathComponent)
    if to.resolvingSymlinksInPath().path == from.resolvingSymlinksInPath().path { return (from, to) }
    if fm.fileExists(atPath: to.path) { throw ToolError("exists", "\(to.path) already exists. Pick another folder, or move that file first") }
    try withLock(name) {
      try fileLock(file(name, ".doc.lock")) {
        try fm.moveItem(at: from, to: to)
        do { try editRegistry { r in r[name] = Entry(path: to.path, openedAt: r[name]?.openedAt) } }
        catch { try? fm.moveItem(at: to, to: from); throw error }
      }
    }
    Log.write("core", "move_project", extra: ["project": .string(name), "from": .string(from.path), "to": .string(to.path)])
    return (from, to)
  }

  // Old project names and what each one is called now.
  public static func renames() -> [String: String] { (try? read([String: String].self, root.appendingPathComponent(".renames.json"))) ?? [:] }

  public static func saveWords(_ name: String, _ words: [Word], engine: String) throws {
    try withLock(name) { try write(Transcript(engine: engine, words: words), file(name, "transcript.json")) }
  }
}
