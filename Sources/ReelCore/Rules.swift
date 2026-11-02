// Rule books (Sankalp, 1 Nov 2026): plain text files (.md, .markdown, .txt) of how Sankalp wants his reels edited. Each
// project keeps its own rules folder (rulesDir in its file); a new project starts with the folder saved last (rulesDir in
// settings.json, <projects folder>/_rules until one is picked), and picking a folder for a project saves it as the last
// one too. When the app's chat starts a Claude, every rule book of the project in front goes into its system prompt once,
// for the whole conversation, and get_rules reads the folder again whenever Claude is asked to reread them. Subfolders
// are read too; hidden files are skipped.
import Foundation

public enum Rules {
  public struct Book: Sendable, Equatable {
    public let name: String // the path inside the rules folder, for example voice/tone.md
    public let file: String
    public let text: String
  }

  public static let EXTENSIONS: Set<String> = ["md", "markdown", "txt"]
  // Past this many characters in all, the rest is left out of the prompt (get_rules still lists every book).
  public static let PROMPT_LIMIT = 300_000

  static var settingsURL: URL { Store.root.appendingPathComponent("settings.json") }
  static func settings() -> [String: Any] {
    (try? JSONSerialization.jsonObject(with: Data(contentsOf: settingsURL)) as? [String: Any]) ?? [:]
  }

  public static var defaultDir: URL { Store.root.appendingPathComponent("_rules", isDirectory: true) }
  static func url(_ path: String) -> URL { URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true) }

  // The folder saved last, which a new project starts with: the one picked most recently, or the default, made when missing.
  public static var lastDir: URL {
    if let d = settings()["rulesDir"] as? String, !d.isEmpty { return url(d) }
    try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true)
    return defaultDir
  }

  // A project's rules folder: its own, or the last one saved for a project made before projects kept one. Without a
  // project, the last one saved.
  public static func dir(for project: String?) -> URL {
    if let project, let d = Store.peek(project)?.rulesDir, !d.isEmpty { return url(d) }
    return lastDir
  }
  public static func isDefault(_ dir: URL) -> Bool { dir.standardizedFileURL.path == defaultDir.standardizedFileURL.path }

  // Points a project's rule books at a folder (nil is the default _rules), and saves it as the last folder, which the
  // next new project starts with. Without a project only the last folder is saved. The other settings are kept.
  // remember false points the project at the folder without making it the one new projects start with.
  public static func setDir(_ folder: URL?, project: String?, remember: Bool = true) throws {
    let target = folder ?? defaultDir
    if folder == nil { try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true) }
    if let project { _ = try Store.update(project) { p in p.rulesDir = target.path; return [:] } }
    guard remember else { return }
    var s = settings()
    if let folder { s["rulesDir"] = folder.path } else { s["rulesDir"] = nil }
    try FileManager.default.createDirectory(at: Store.root, withIntermediateDirectories: true)
    let d = try JSONSerialization.data(withJSONObject: s, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try d.write(to: settingsURL, options: .atomic)
  }

  // Every rule book in a folder, read now, in the order of their paths.
  public static func books(in dir: URL) -> [Book] {
    let root = dir.standardizedFileURL
    guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]) else { return [] }
    var out: [Book] = []
    for case let u as URL in e where EXTENSIONS.contains(u.pathExtension.lowercased()) {
      guard (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true, let text = try? String(contentsOf: u, encoding: .utf8) else { continue }
      let rel = String(u.standardizedFileURL.path.dropFirst(root.path.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
      out.append(Book(name: rel, file: u.path, text: text))
    }
    return out.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Writing rule books (Sankalp, 2 Nov 2026): an agent can write a new rule book, change one, or give a project a rules
  // folder of its own, so custom rules for one project never reach the others. Before a book is changed, its text is
  // kept in the folder's hidden .previous folder (never read as a rule book), so nothing written by hand is lost.

  // A project's own rules folder: <projects folder>/_rules-by-project/<name>.
  public static func ownDir(for project: String) -> URL {
    Store.root.appendingPathComponent("_rules-by-project", isDirectory: true).appendingPathComponent(project, isDirectory: true)
  }

  // The file of a rule book named by its path inside the folder, .md when it has no extension. The path stays inside the
  // folder: no absolute path, no .., no hidden part.
  public static func bookURL(_ dir: URL, _ raw: String) throws -> (url: URL, name: String) {
    var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let parts = name.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    guard !name.isEmpty, !name.hasPrefix("/"), !name.hasPrefix("~"), !parts.isEmpty,
          !parts.contains(where: { $0 == ".." || $0 == "." || $0.hasPrefix(".") }) else {
      throw ToolError("invalid_input", "Give the rule book's name inside the rules folder, like trims.md or voice/tone.md, with no .. or hidden parts")
    }
    name = parts.joined(separator: "/")
    let ext = (name as NSString).pathExtension.lowercased()
    if ext.isEmpty { name += ".md" }
    else if !EXTENSIONS.contains(ext) { throw ToolError("invalid_input", "A rule book is a .md, .markdown or .txt file, not .\(ext)") }
    return (dir.appendingPathComponent(name), name)
  }

  // Keeps a book's text as it is now in <folder>/.previous/<name> <time>.<ext>, before it is changed.
  @discardableResult
  public static func keepPrevious(_ dir: URL, _ url: URL, _ name: String) -> String? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH.mm.ss"; f.locale = Locale(identifier: "en_US_POSIX")
    let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
    let keep = dir.appendingPathComponent(".previous").appendingPathComponent("\(base) \(f.string(from: Date())).\(ext)")
    try? FileManager.default.createDirectory(at: keep.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? FileManager.default.removeItem(at: keep)
    return (try? FileManager.default.copyItem(at: url, to: keep)) != nil ? keep.path : nil
  }

  // Writes a rule book whole, making its folder when needed.
  public static func write(_ dir: URL, _ raw: String, _ text: String) throws -> (url: URL, name: String, created: Bool, previous: String?) {
    let (url, name) = try bookURL(dir, raw)
    let existed = FileManager.default.fileExists(atPath: url.path)
    let kept = existed ? keepPrevious(dir, url, name) : nil
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (text.hasSuffix("\n") ? text : text + "\n").write(to: url, atomically: true, encoding: .utf8)
    return (url, name, !existed, kept)
  }

  // Gives a project a rules folder of its own, holding copies of the rule books it reads now when copy is true, and
  // points the project at it. The folder new projects start with stays as it is. A project that already has its own
  // folder keeps it as it is.
  public static func makeOwn(_ project: String, copy: Bool) throws -> (dir: URL, copied: [String], already: Bool) {
    let own = ownDir(for: project), now = dir(for: project)
    if now.standardizedFileURL.path == own.standardizedFileURL.path { return (own, [], true) }
    let fm = FileManager.default
    try fm.createDirectory(at: own, withIntermediateDirectories: true)
    var copied: [String] = []
    if copy {
      for b in books(in: now) {
        let to = own.appendingPathComponent(b.name)
        if fm.fileExists(atPath: to.path) { continue }
        try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: b.file), to: to)
        copied.append(b.name)
      }
    }
    try setDir(own, project: project, remember: false)
    return (own, copied, false)
  }

  // The rule books as a part of a system prompt, and whether some were left out for length.
  public static func prompt(_ books: [Book], from dir: URL, project: String?) -> (text: String, truncated: Bool) {
    guard !books.isEmpty else { return ("", false) }
    let call = project.map { "get_rules with project \($0)" } ?? "get_rules"
    var s = "Sankalp's rule books, from \(dir.path)\(project.map { ", the rules folder of \($0)" } ?? ""). Follow them for every edit in this conversation. When he asks you to read the rules again, call \(call), which reads the folder as it is now. Another project can keep its rules in another folder: when he works on one, get_rules with that project reads its rules.\n"
    var truncated = false
    for b in books {
      let part = "\n=== \(b.name) ===\n\(b.text.trimmingCharacters(in: .whitespacesAndNewlines))\n"
      if s.count + part.count > PROMPT_LIMIT { truncated = true; break }
      s += part
    }
    if truncated { s += "\nSome rule books were left out for length; get_rules returns every one.\n" }
    return (s, truncated)
  }
}
