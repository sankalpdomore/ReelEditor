// The 5 hour and weekly limits of each Claude account an agent is connected from, read the way the LiveAssistant app
// reads them: the claude command line is started once with that account's config folder (CLAUDE_CONFIG_DIR, none for
// ~/.claude), sent one tiny message on the smallest model, and the rate_limit_event line it prints after the reply
// carries each window's use (0 to 1) and when it resets. The command line signs in by itself; no token is ever read
// here. A check costs about 2,000 tokens, so an account is checked at most every 20 minutes unless Refresh is pressed.
// Every reading, and the tokens each connected session has used, is written to the app's log (Log, the _dump folder).
import Foundation
import ReelCore

struct PlanWindow: Equatable, Sendable { let key: String; let utilization: Double; let resetsAt: Date? }
struct PlanUsage: Equatable, Sendable { let windows: [PlanWindow]; let status: String; let updated: Date }

@MainActor final class AccountLimits: ObservableObject {
  static let shared = AccountLimits()
  @Published private(set) var usage: [String: PlanUsage] = [:] // by config folder name: claude, claude-2, claude-3
  @Published private(set) var checking: Set<String> = []
  @Published private(set) var problems: [String: String] = [:]
  @Published private(set) var plans: [String: String] = [:] // Max, Team, Pro, from claude auth status (no tokens used)
  // How much of each window the sessions talking to this editor used, as LiveAssistant estimates its own share: the
  // account's use times this app's part of the tokens all the account's sessions spent since the window began. By
  // config folder name, then window key (five_hour, seven_day), a fraction of the whole limit.
  @Published private(set) var appShare: [String: [String: Double]] = [:]

  func computeShare(profile: String, account: String?, sessions: [MCPPresence]) async {
    guard let u = usage[profile] else { return }
    let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".\(profile)")
    var out: [String: Double] = [:]
    var extra: [String: JSON] = ["profile": .string(profile), "account": account.map { .string($0) } ?? .null, "sessions": .array(sessions.compactMap { $0.sessionName.map { .string($0) } })]
    for w in u.windows {
      guard let reset = w.resetsAt else { continue }
      let since = reset.addingTimeInterval(w.key == "seven_day" ? -7 * 86400 : -5 * 3600)
      var mine = 0.0
      for p in sessions { if let t = p.transcript { mine += await SessionUsage.shared.sessionWeight(transcript: t, since: since) } }
      let all = await SessionUsage.shared.accountWeight(config: config, since: since)
      let part = all > 0 ? min(1, mine / all) : 0
      out[w.key] = w.utilization * part
      extra["\(w.key)_app_percent"] = .number((w.utilization * part * 1000).rounded() / 10)
      extra["\(w.key)_others_percent"] = .number((w.utilization * (1 - part) * 1000).rounded() / 10)
      extra["\(w.key)_left_percent"] = .number(((1 - w.utilization) * 1000).rounded() / 10)
    }
    appShare[profile] = out
    Log.write("app", "editor_share_of_limits", extra: extra)
  }
  static let STALE: TimeInterval = 20 * 60

  func refresh(_ profile: String, account: String?, force: Bool = false) {
    if checking.contains(profile) { return }
    if !force, let u = usage[profile], Date().timeIntervalSince(u.updated) < Self.STALE { return }
    checking.insert(profile)
    Task.detached(priority: .utility) {
      let plan = Self.plan(profile)
      await MainActor.run { if let plan { self.plans[profile] = plan } }
      let r = Self.probe(profile)
      await MainActor.run {
        self.checking.remove(profile)
        switch r {
        case .success(let u):
          self.usage[profile] = u
          self.problems[profile] = nil
          var extra: [String: JSON] = ["profile": .string(profile), "account": account.map { .string($0) } ?? .null, "status": .string(u.status)]
          for w in u.windows {
            extra["\(w.key)_used_percent"] = .number((w.utilization * 100).rounded())
            extra["\(w.key)_left_percent"] = .number(((1 - w.utilization) * 100).rounded())
            if let r = w.resetsAt { extra["\(w.key)_resets"] = .string(ISO8601DateFormatter().string(from: r)) }
          }
          Log.write("app", "account_limits", extra: extra)
        case .failure(let e):
          self.problems[profile] = e.message
          Log.error("account_limits", e.message, args: ["profile": .string(profile), "account": account.map { .string($0) } ?? .null])
        }
      }
    }
  }

  // A reading that came with a direct chat turn (DirectChat), kept as if it had been checked.
  func ingest(_ profile: String, _ u: PlanUsage) {
    usage[profile] = u
    var extra: [String: JSON] = ["profile": .string(profile), "from": "direct chat"]
    for w in u.windows { extra["\(w.key)_used_percent"] = .number((w.utilization * 100).rounded()) }
    Log.write("app", "account_limits", extra: extra)
  }

  // Adds up each connection's tokens, writes what was read to the log (the account, the session, its tokens), and asks
  // for the limits of every account behind them (each at most every 20 minutes). Called when the connections change,
  // every 20 minutes, and when the MCP details open.
  @discardableResult
  func record(_ mcp: [MCPPresence]) async -> [Int32: TokenUsage] {
    var out: [Int32: TokenUsage] = [:]
    for p in mcp {
      guard let t = p.transcript else { continue }
      let u = await SessionUsage.shared.usage(transcript: t)
      out[p.pid] = u
      Log.write("app", "mcp_session_usage", extra: [
        "pid": .number(Double(p.pid)), "account": p.account.map { .string($0) } ?? .null, "profile": p.profile.map { .string($0) } ?? .null,
        "session": p.sessionName.map { .string($0) } ?? .null, "tokens_total": .number(Double(u.total)), "tokens_output": .number(Double(u.output)),
        "tokens_input": .number(Double(u.input)), "tokens_cache_read": .number(Double(u.cacheRead)), "tokens_cache_write": .number(Double(u.cacheWrite)),
        "messages": .number(Double(u.messages)), "last_tool": p.lastTool.map { .string($0) } ?? .null,
      ])
    }
    var seen = Set<String>()
    for p in mcp { if let profile = p.profile, let a = p.account, seen.insert(profile).inserted { refresh(profile, account: a) } }
    return out
  }

  struct ProbeError: Error { let message: String }

  nonisolated static var claudeBinary: String? { Decipher.claudeBinary }

  // The account's plan from claude auth status, which reads the sign in without calling the model.
  nonisolated static func plan(_ profile: String) -> String? {
    guard let bin = claudeBinary else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["auth", "status"]
    p.environment = environment(profile)
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: killer)
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit(); killer.cancel()
    guard let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let t = o["subscriptionType"] as? String, !t.isEmpty else { return nil }
    return t.prefix(1).uppercased() + t.dropFirst()
  }

  nonisolated static func environment(_ profile: String) -> [String: String] {
    let home = NSHomeDirectory()
    var env = ProcessInfo.processInfo.environment
    env.removeValue(forKey: "CLAUDE_CONFIG_DIR")
    if profile != "claude" { env["CLAUDE_CONFIG_DIR"] = "\(home)/.\(profile)" }
    for k in env.keys where k.hasPrefix("CLAUDE_CODE_") || k == "CLAUDECODE" || k == "CLAUDE_AGENT_SDK_VERSION" { env.removeValue(forKey: k) }
    env.removeValue(forKey: "ANTHROPIC_API_KEY"); env.removeValue(forKey: "ANTHROPIC_AUTH_TOKEN")
    env["PATH"] = "\(home)/.local/bin:/opt/homebrew/bin:/usr/local/bin:" + (env["PATH"] ?? "/usr/bin:/bin")
    env["HOME"] = home
    return env
  }

  nonisolated static func probe(_ profile: String) -> Result<PlanUsage, ProbeError> {
    guard let bin = claudeBinary else { return .failure(ProbeError(message: "The claude command line was not found")) }
    let env = environment(profile)
    let dir = Store.root.appendingPathComponent("_probe")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", "haiku",
                   "--tools", "", "--setting-sources", "", "--no-session-persistence", "--strict-mcp-config",
                   "--system-prompt", "Reply with one word."]
    p.environment = env
    p.currentDirectoryURL = dir
    let input = Pipe(), output = Pipe()
    p.standardInput = input; p.standardOutput = output; p.standardError = FileHandle.nullDevice
    do { try p.run() } catch { return .failure(ProbeError(message: "Could not start claude: \(error)")) }
    let ask = #"{"type":"user","message":{"role":"user","content":"Reply with the single word: ok"}}"# + "\n"
    input.fileHandleForWriting.write(Data(ask.utf8))
    try? input.fileHandleForWriting.close()
    let killer = DispatchWorkItem { if p.isRunning { p.terminate() } }
    DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: killer)
    let data = output.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    killer.cancel()
    for line in data.split(separator: 0x0A) {
      guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any], o["type"] as? String == "rate_limit_event",
            let u = parse(o) else { continue }
      return .success(u)
    }
    return .failure(ProbeError(message: "claude gave no rate limit reading (exit \(p.terminationStatus))"))
  }

  // rate_limit_info.unifiedWindows: five_hour and seven_day, each with utilization 0 to 1 and resetsAt in Unix seconds.
  nonisolated static func parse(_ obj: [String: Any]) -> PlanUsage? {
    guard let info = obj["rate_limit_info"] as? [String: Any], let unified = info["unifiedWindows"] as? [String: Any] else { return nil }
    var windows: [PlanWindow] = []
    for (key, value) in unified {
      guard let w = value as? [String: Any], let u = (w["utilization"] as? NSNumber)?.doubleValue else { continue }
      windows.append(PlanWindow(key: key, utilization: u, resetsAt: (w["resetsAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }))
    }
    guard !windows.isEmpty else { return nil }
    let order = ["five_hour": 0, "seven_day": 1]
    windows.sort { (order[$0.key] ?? 9, $0.key) < (order[$1.key] ?? 9, $1.key) }
    return PlanUsage(windows: windows, status: info["status"] as? String ?? "allowed", updated: Date())
  }

  static func title(_ key: String) -> String { key == "five_hour" ? "5 hour limit" : key == "seven_day" ? "Weekly limit" : key.replacingOccurrences(of: "_", with: " ").capitalized }

  // "resets in 2h 4m", or "resets Wed 6 PM" a day or more away, as LiveAssistant writes it.
  static func resetText(_ d: Date?) -> String {
    guard let d else { return "" }
    let s = d.timeIntervalSinceNow
    if s <= 0 { return "resetting" }
    if s < 3600 { return "resets in \(Int(s / 60))m" }
    if s < 86400 { return "resets in \(Int(s / 3600))h \(Int(s.truncatingRemainder(dividingBy: 3600) / 60))m" }
    let f = DateFormatter(); f.dateFormat = "EEE h a"
    return "resets " + f.string(from: d)
  }
}
