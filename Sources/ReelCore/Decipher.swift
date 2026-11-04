// Sonnet at medium effort reads the audit's spots where more speech was heard than the transcript has (Sankalp, 4 Nov
// 2026). Sankalp first asked for Haiku; on the spots of his reel run 5 times each, Sonnet medium named both of his
// repeats right 5 of 5 times in 15 to 20 s for about 2.7 cents, Haiku 3 or 4 of 5 for 0.25 to 0.5 cents, so Sonnet medium
// is the default and REEL_DECIPHER_MODEL and REEL_DECIPHER_EFFORT pick another. The audit
// finds them in plain code: wav2vec2 reads letters straight off the sound and keeps every repeat, but spells them badly
// ("that's all fortode" for "that's all for today"), so one Claude call through the claude command line, with no tools, no
// MCP servers and a short system prompt, says for every spot at once what was really said, whether it is a phrase said
// twice, a restart or other missed speech, and where the earlier take is.
import Foundation

public enum Decipher {
  // The claude command line, where its installers put it.
  public static var claudeBinary: String? {
    let home = NSHomeDirectory()
    return ["\(home)/.local/bin/claude", "\(home)/.claude/local/claude", "/opt/homebrew/bin/claude", "/usr/local/bin/claude", "\(home)/.npm-global/bin/claude", "\(home)/.bun/bin/claude"]
      .first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  // The environment of a claude run from reel-mcp: the same account (CLAUDE_CONFIG_DIR is kept), without the markers of
  // the Claude Code session reel-mcp runs under, which would make it a nested session.
  static func environment() -> [String: String] {
    var env = Jobs.toolEnvironment()
    for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDECODE" || k == "CLAUDE_AGENT_SDK_VERSION" { env.removeValue(forKey: k) }
    env.removeValue(forKey: "ANTHROPIC_API_KEY"); env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
    env["HOME"] = NSHomeDirectory()
    return env
  }

  public struct Verdict: Sendable {
    public var kind: String // repeat, restart, missed or none
    public var said: String
    public var earlier: String
    public var earlierStart: Double?
    public var earlierEnd: Double?
    public var keptStart: Double?
  }

  static func line(_ words: [[Any]]) -> String {
    words.compactMap { w -> String? in
      guard w.count == 3, let s = (w[0] as? NSNumber)?.doubleValue, let e = (w[1] as? NSNumber)?.doubleValue, let t = w[2] as? String else { return nil }
      return String(format: "%.2f-%.2f ", s, e) + t
    }.joined(separator: " | ")
  }

  // One Claude call for every spot; nil when the command line is missing or the answer cannot be read, and the spots then
  // go to the chat's Claude as they are.
  public static func spots(_ spots: [(transcript: [[Any]], heard: [[Any]])], log project: String) async -> [Verdict?]? {
    guard !spots.isEmpty, let bin = claudeBinary else { return nil }
    if ProcessInfo.processInfo.environment["REEL_NO_DECIPHER"] == "1" { return nil }
    var prompt = """
    Spots of a talking head video where a letter by letter listener heard more speech than the transcript has. The \
    transcript comes from Whisper, which writes a phrase said twice or a restarted sentence only once and spreads its word \
    times over both takes. The listener spells what it hears phonetically and badly, but it keeps every repeat. Times are \
    seconds of the video. For each spot decide what was really said.

    The rule: when a run of heard words comes twice, allowing for misspelling, and the transcript has it once, it is a \
    repeat or a restart, and the earlier take is the first run. Whisper then often stretches one transcript word over \
    the first run, or puts the words at the times of one run only.

    Example. Transcript words: 4.10-5.30 So | 5.40-5.60 today | 5.62-5.80 I | 5.82-6.10 want. Heard: 4.12-4.30 so | \
    4.35-4.60 tday | 4.62-4.70 i | 4.75-4.90 wan | 5.38-5.50 so | 5.52-5.70 today | 5.72-5.78 i | 5.80-6.08 wand. Answer: \
    {"spot": 1, "kind": "repeat", "said": "So today I want, so today I want", "earlier": "So today I want", \
    "earlier_start": 4.12, "earlier_end": 4.90, "kept_start": 5.38}.

    """
    for (k, s) in spots.enumerated() {
      prompt += "\nSpot \(k + 1).\nTranscript words: \(line(s.transcript))\nHeard: \(line(s.heard))\n"
    }
    prompt += """

    Answer with JSON only, a list with one object per spot: {"spot": n, "kind": "repeat" for a phrase said again, \
    "restart" for a sentence started, dropped and said again, "missed" for other speech the transcript left out, or \
    "none" when the listener only misspelled the same words, "said": the words really spoken over the spot in order, \
    every take written out, "earlier": the words of the earlier take or false start that the transcript does not show \
    twice, empty for none, "earlier_start": the start of the first heard word of that earlier take, "earlier_end": the end \
    of its last heard word, "kept_start": the start of the take that should stay}. Use null for a time you cannot tell.
    """
    // REEL_DECIPHER_MODEL and REEL_DECIPHER_EFFORT pick another model for comparing them; REEL_DECIPHER_PROMPT saves the
    // prompt to a file, to run the same spots again by hand.
    let env = ProcessInfo.processInfo.environment
    if let f = env["REEL_DECIPHER_PROMPT"] { try? prompt.write(toFile: f, atomically: true, encoding: .utf8) }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["-p", "--model", env["REEL_DECIPHER_MODEL"] ?? "sonnet", "--effort", env["REEL_DECIPHER_EFFORT"] ?? "medium"] + ["--output-format", "json", "--system-prompt", "You read speech transcripts and answer in JSON only.",
                   "--tools", "", "--strict-mcp-config", "--setting-sources", "", "--no-session-persistence"]
    p.environment = environment()
    let input = Pipe(), output = Pipe()
    p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
    let started = Date()
    do { try p.run() } catch { return nil }
    input.fileHandleForWriting.write(prompt.data(using: .utf8)!)
    try? input.fileHandleForWriting.close()
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 120, execute: killer)
    let data: Data = await withCheckedContinuation { c in DispatchQueue.global().async { c.resume(returning: output.fileHandleForReading.readDataToEndOfFile()) } }
    p.waitUntilExit(); killer.cancel()
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], var text = o["result"] as? String else {
      Log.write("core", "audit_decipher", args: ["project": .string(project)], ok: false, error: "no answer")
      return nil
    }
    Log.write("core", "audit_decipher", args: ["project": .string(project)], ms: Int(Date().timeIntervalSince(started) * 1000),
              extra: ["model": .string(env["REEL_DECIPHER_MODEL"] ?? "sonnet"), "spots": .number(Double(spots.count)), "cost_usd": .number((o["total_cost_usd"] as? NSNumber)?.doubleValue ?? 0)])
    if let a = text.firstIndex(of: "["), let b = text.lastIndex(of: "]") { text = String(text[a...b]) }
    guard let list = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [[String: Any]] else { return nil }
    var out = [Verdict?](repeating: nil, count: spots.count)
    for v in list {
      guard let n = (v["spot"] as? NSNumber)?.intValue, n >= 1, n <= spots.count else { continue }
      let num = { (k: String) in (v[k] as? NSNumber)?.doubleValue }
      out[n - 1] = Verdict(kind: (v["kind"] as? String ?? "none").lowercased(), said: v["said"] as? String ?? "", earlier: v["earlier"] as? String ?? "",
                           earlierStart: num("earlier_start"), earlierEnd: num("earlier_end"), keptStart: num("kept_start"))
    }
    return out
  }
}
