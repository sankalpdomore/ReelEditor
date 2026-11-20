// The dump folder, for fast QA: every tool call (from the app or from an agent through MCP), every app action and every
// error is one JSON line in <root>/_dump/<source>-<date>.jsonl, source being app or mcp. A line has the time, the
// process, the build, what happened, its arguments (long text shortened), whether it worked, the error and how long it
// took. get_logs reads them back. The folder name starts with an underscore, so it is never taken for a project.
import Foundation

public enum Log {
  public static var source = "app" // set to mcp by the MCP server
  public static var dir: URL { Store.root.appendingPathComponent("_dump", isDirectory: true) }
  private static let lock = NSLock()

  // The build this process runs: Contents/Resources/build.json, written by build.sh, or "dev" for a swift build.
  public static let build: String = {
    struct B: Decodable { var built: String; var git: String }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    for url in [Bundle.main.resourceURL?.appendingPathComponent("build.json"), exe.appendingPathComponent("../Resources/build.json")].compactMap({ $0 }) {
      if let b = try? JSONDecoder().decode(B.self, from: Data(contentsOf: url)) { return "\(b.built) \(b.git)" }
    }
    return "dev"
  }()

  static func file(_ day: String) -> URL { dir.appendingPathComponent("\(source)-\(day).jsonl") }

  // Shortens what is logged: long strings cut, long lists counted.
  static func short(_ v: JSON, depth: Int = 0) -> JSON {
    switch v {
    case .string(let s): return .string(s.count > 300 ? String(s.prefix(300)) + "…" : s)
    case .array(let a): return a.count > 20 || depth > 2 ? .string("[\(a.count) items]") : .array(a.map { short($0, depth: depth + 1) })
    case .object(let o): return depth > 3 ? .string("{…}") : .object(o.mapValues { short($0, depth: depth + 1) })
    default: return v
    }
  }

  public static func write(_ kind: String, _ name: String, args: JSON? = nil, ok: Bool = true, error: String? = nil, ms: Int? = nil, extra: [String: JSON] = [:]) {
    let now = Date()
    let iso = ISO8601DateFormatter().string(from: now)
    var line: [String: JSON] = ["t": .string(iso), "pid": .number(Double(getpid())), "src": .string(source), "build": .string(build), "kind": .string(kind), "name": .string(name), "ok": .bool(ok)]
    if let args { line["args"] = short(args) }
    if let error { line["error"] = .string(String(error.prefix(600))) }
    if let ms { line["ms"] = .number(Double(ms)) }
    for (k, v) in extra { line[k] = short(v) }
    let data = Data((JSON.object(line).text() + "\n").utf8)
    lock.lock(); defer { lock.unlock() }
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = file(String(iso.prefix(10)))
    if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
    else { try? data.write(to: url) }
  }

  public static func error(_ name: String, _ message: String, args: JSON? = nil) { write("error", name, args: args, ok: false, error: message) }

  // The latest lines, newest last: from both sources unless one is named, errors only when asked.
  public static func tail(source: String? = nil, errorsOnly: Bool = false, limit: Int = 100) -> [JSON] {
    let files = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.pathExtension == "jsonl" && (source == nil || $0.lastPathComponent.hasPrefix("\(source!)-")) }
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
    var lines: [JSON] = []
    for f in files.suffix(4) {
      guard let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
      for l in text.split(separator: "\n") {
        guard let j = try? JSONDecoder().decode(JSON.self, from: Data(l.utf8)) else { continue }
        if errorsOnly && j["ok"]?.bool != false { continue }
        lines.append(j)
      }
    }
    lines.sort { ($0["t"]?.string ?? "") < ($1["t"]?.string ?? "") }
    return Array(lines.suffix(limit))
  }
}
