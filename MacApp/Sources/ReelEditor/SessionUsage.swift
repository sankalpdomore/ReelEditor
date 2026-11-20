// How many tokens a connected Claude Code session has used, added up from its transcript (and its subagents'
// transcripts): every assistant message's usage, counted once per message id. Read in the background and kept per file
// with how far it was read, so opening the MCP details again only reads what was written since.
import Foundation

struct TokenUsage: Equatable, Sendable {
  var input = 0, output = 0, cacheRead = 0, cacheWrite = 0, messages = 0
  var total: Int { input + output + cacheRead + cacheWrite }
  static func + (a: TokenUsage, b: TokenUsage) -> TokenUsage {
    TokenUsage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite, messages: a.messages + b.messages)
  }
}

actor SessionUsage {
  static let shared = SessionUsage()
  private struct FileState { var offset: UInt64 = 0; var byId: [String: TokenUsage] = [:]; var at: [String: Double] = [:]; var tail = Data() }
  private static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
  private var files: [String: FileState] = [:]

  // The session's own transcript plus <session id>/subagents/*.jsonl beside it.
  func usage(transcript: String) -> TokenUsage {
    var paths = [transcript]
    let sub = URL(fileURLWithPath: transcript).deletingPathExtension().appendingPathComponent("subagents")
    if let more = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) {
      paths += more.filter { $0.pathExtension == "jsonl" }.map(\.path)
    }
    return paths.reduce(TokenUsage()) { $0 + read($1) }
  }

  private func read(_ path: String) -> TokenUsage {
    var st = files[path] ?? FileState()
    if let h = FileHandle(forReadingAtPath: path) {
      defer { try? h.close() }
      if let end = try? h.seekToEnd(), end < st.offset { st = FileState() } // rewritten from the start
      try? h.seek(toOffset: st.offset)
      if let data = try? h.readToEnd(), !data.isEmpty {
        st.offset += UInt64(data.count)
        var buf = st.tail + data
        var lines = buf.split(separator: 0x0A, omittingEmptySubsequences: false)
        st.tail = Data(lines.removeLast()) // a line still being written
        buf = Data()
        for line in lines where line.count > 20 {
          guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["type"] as? String == "assistant",
                let m = o["message"] as? [String: Any], let u = m["usage"] as? [String: Any] else { continue }
          let id = m["id"] as? String ?? UUID().uuidString
          func n(_ k: String) -> Int { (u[k] as? NSNumber)?.intValue ?? 0 }
          st.byId[id] = TokenUsage(input: n("input_tokens"), output: n("output_tokens"), cacheRead: n("cache_read_input_tokens"), cacheWrite: n("cache_creation_input_tokens"), messages: 1)
          if let t = o["timestamp"] as? String, let d = Self.iso.date(from: t) { st.at[id] = d.timeIntervalSince1970 }
        }
      }
    }
    files[path] = st
    return st.byId.values.reduce(TokenUsage(), +)
  }

  // The weight of what a file's messages since a moment cost against a plan's limits, an estimate: new input, cache
  // writes and output in full, cache reads at a tenth (they are charged far less).
  private func weight(_ path: String, since: Double) -> Double {
    _ = read(path)
    guard let st = files[path] else { return 0 }
    var w = 0.0
    for (id, u) in st.byId where (st.at[id] ?? 0) >= since {
      w += Double(u.input + u.cacheWrite + u.output) + Double(u.cacheRead) / 10
    }
    return w
  }

  // A session's own weight since a moment, its agents included.
  func sessionWeight(transcript: String, since: Date) -> Double {
    var paths = [transcript]
    let sub = URL(fileURLWithPath: transcript).deletingPathExtension().appendingPathComponent("subagents")
    if let more = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil) { paths += more.filter { $0.pathExtension == "jsonl" }.map(\.path) }
    return paths.reduce(0) { $0 + weight($1, since: since.timeIntervalSince1970) }
  }

  // Every session of an account since a moment: each transcript in <config>/projects, and its agents', written since.
  func accountWeight(config: URL, since: Date) -> Double {
    let fm = FileManager.default
    var total = 0.0
    let projects = config.appendingPathComponent("projects")
    for dir in (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? [] {
      guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { continue }
      for case let f as URL in en where f.pathExtension == "jsonl" {
        let m = (try? f.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
        if m >= since { total += weight(f.path, since: since.timeIntervalSince1970) }
      }
    }
    return total
  }
}

// 1234567 as 1.2M, 45200 as 45.2k.
func compactCount(_ n: Int) -> String {
  let d = Double(n)
  if d >= 1_000_000_000 { return String(format: "%.1fB", d / 1_000_000_000) }
  if d >= 1_000_000 { return String(format: "%.1fM", d / 1_000_000) }
  if d >= 1_000 { return String(format: "%.1fk", d / 1_000) }
  return "\(n)"
}
