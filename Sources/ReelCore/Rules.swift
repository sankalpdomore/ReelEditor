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
  public static func setDir(_ folder: URL?, project: String?) throws {
    let target = folder ?? defaultDir
    if folder == nil { try? FileManager.default.createDirectory(at: defaultDir, withIntermediateDirectories: true) }
    if let project { _ = try Store.update(project) { p in p.rulesDir = target.path; return [:] } }
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
