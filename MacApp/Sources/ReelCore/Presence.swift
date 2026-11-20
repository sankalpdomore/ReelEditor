// Who is connected over MCP. Each running reel-mcp, once a client has introduced itself (the initialize call's
// clientInfo, for example claude-code or codex-mcp-client), keeps a small file in <root>/.mcp/<pid>.json with the
// client, this Mac's name and the last tool it ran, refreshed every few seconds and removed when it exits. The app reads
// them to show the MCP status in its tab bar. A file whose process is gone or that has not been refreshed is ignored.
import Foundation

public struct MCPPresence: Codable, Sendable, Identifiable {
  public var pid: Int32
  public var client: String // clientInfo.name as the client sent it
  public var clientVersion: String
  public var device: String // the Mac the server runs on (stdio servers always run beside their client)
  public var startedAt: Double
  public var lastSeen: Double
  public var lastTool: String?
  public var lastToolAt: Double?
  // The Claude Code session this server runs under, when its client is Claude Code: the account it is signed in to,
  // the config folder (~/.claude, ~/.claude-2 and so on), the session's name and its transcript, from which the app
  // adds up the tokens it has used. Only the email and organisation are read from the account file, never a token.
  public var account: String? = nil
  public var accountOrg: String? = nil
  public var profile: String? = nil // the config folder's name: claude, claude-2, claude-3
  public var sessionId: String? = nil
  public var sessionName: String? = nil
  public var sessionCwd: String? = nil
  public var transcript: String? = nil
  public var id: Int32 { pid }

  public init(pid: Int32, client: String, clientVersion: String, device: String, startedAt: Double, lastSeen: Double) {
    self.pid = pid; self.client = client; self.clientVersion = clientVersion; self.device = device; self.startedAt = startedAt; self.lastSeen = lastSeen
  }

  // The service by its usual name.
  public var service: String {
    let c = client.lowercased()
    if c.contains("claude-code") || c == "claude code" { return "Claude Code" }
    if c.contains("claude") { return "Claude" }
    if c.contains("codex") { return "Codex" }
    if c.contains("cursor") { return "Cursor" }
    if c.contains("windsurf") { return "Windsurf" }
    if c.contains("vscode") || c.contains("visual studio") { return "VS Code" }
    if c.contains("zed") { return "Zed" }
    if c.contains("inspector") { return "MCP Inspector" }
    return client.isEmpty ? "Unknown client" : client
  }
}

public struct ClaudeSession: Sendable {
  public var account: String? = nil
  public var accountOrg: String? = nil
  public var profile: String
  public var sessionId: String? = nil
  public var sessionName: String? = nil
  public var cwd: String? = nil
  public var transcript: String? = nil
}

public enum Presence {
  // The parent of a process, read with sysctl, so the app can find the Claude Code session behind any running reel-mcp.
  public static func parentPid(of pid: Int32) -> Int32? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    let pp = info.kp_eproc.e_ppid
    return pp > 1 ? pp : nil
  }

  // The Claude Code session behind a running reel-mcp, worked out from outside it, so a server started before it
  // reported its session still shows its account: its parent's <config>/sessions/<pid>.json is looked for in every
  // ~/.claude* folder, and that folder's account file names the account.
  public static func claudeSession(server pid: Int32) -> ClaudeSession? {
    guard let parent = parentPid(of: pid) else { return nil }
    let fm = FileManager.default
    let home = fm.homeDirectoryForCurrentUser
    let configs = ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? [])
      .filter { $0.lastPathComponent.hasPrefix(".claude") && fm.fileExists(atPath: $0.appendingPathComponent("sessions/\(parent).json").path) }
    guard let config = configs.first else { return nil }
    // ~/.claude is the default folder, whose account file is ~/.claude.json; any other folder keeps its own inside it.
    let own = config.appendingPathComponent(".claude.json")
    let accountFile = config.lastPathComponent == ".claude" ? home.appendingPathComponent(".claude.json") : own
    return session(config: config, accountFile: accountFile, parent: parent)
  }

  static func session(config: URL, accountFile: URL, parent: Int32) -> ClaudeSession {
    let fm = FileManager.default
    var s = ClaudeSession(profile: config.lastPathComponent.trimmingCharacters(in: CharacterSet(charactersIn: ".")))
    if let d = try? Data(contentsOf: accountFile), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let a = o["oauthAccount"] as? [String: Any] {
      s.account = a["emailAddress"] as? String
      s.accountOrg = a["organizationName"] as? String
    }
    let sessionFile = config.appendingPathComponent("sessions/\(parent).json")
    if let d = try? Data(contentsOf: sessionFile), let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
      s.sessionId = o["sessionId"] as? String
      s.sessionName = o["name"] as? String
      s.cwd = o["cwd"] as? String
      if let id = s.sessionId {
        let projects = config.appendingPathComponent("projects")
        let dirs = (try? fm.contentsOfDirectory(at: projects, includingPropertiesForKeys: nil)) ?? []
        s.transcript = dirs.map { $0.appendingPathComponent("\(id).jsonl") }.first { fm.fileExists(atPath: $0.path) }?.path
      }
    }
    return s
  }

  // The Claude Code session that started this process: CLAUDE_CONFIG_DIR (or ~/.claude) is inherited from it, and
  // <config>/sessions/<parent pid>.json names the session. Nil fields when the parent is not Claude Code.
  public static func claudeSession(parent: Int32 = getppid()) -> ClaudeSession {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    let config = env ?? home.appendingPathComponent(".claude")
    var s = session(config: config, accountFile: env.map { $0.appendingPathComponent(".claude.json") } ?? home.appendingPathComponent(".claude.json"), parent: parent)
    // A Claude the app starts for its own chat names itself, since it keeps no session file.
    if s.sessionName == nil, let n = ProcessInfo.processInfo.environment["REEL_MCP_SESSION_NAME"], !n.isEmpty { s.sessionName = n }
    return s
  }

  public static var dir: URL { Store.root.appendingPathComponent(".mcp", isDirectory: true) }
  public static let STALE: Double = 20 // seconds without a refresh before a connection counts as gone

  public static var deviceName: String { Host.current().localizedName ?? ProcessInfo.processInfo.hostName }

  static func file(_ pid: Int32) -> URL { dir.appendingPathComponent("\(pid).json") }

  public static func write(_ p: MCPPresence) {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? JSONEncoder().encode(p).write(to: file(p.pid), options: .atomic)
  }

  // The outside lookup above, kept per server process for a minute, since the app reads the connections every 2 seconds.
  nonisolated(unsafe) private static var cache: [Int32: (at: Double, s: ClaudeSession?)] = [:]
  private static let cacheLock = NSLock()
  static func sessionCache(_ pid: Int32) -> ClaudeSession? {
    let now = Date().timeIntervalSince1970
    cacheLock.lock(); defer { cacheLock.unlock() }
    if let c = cache[pid], now - c.at < 60 { return c.s }
    let s = claudeSession(server: pid)
    cache[pid] = (now, s)
    return s
  }

  public static func remove(_ pid: Int32) { try? FileManager.default.removeItem(at: file(pid)) }

  // The live connections, newest first. Files of processes that are gone are cleaned up.
  public static func live() -> [MCPPresence] {
    let now = Date().timeIntervalSince1970
    let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
    var out: [MCPPresence] = []
    for url in items where url.pathExtension == "json" {
      guard let p = try? JSONDecoder().decode(MCPPresence.self, from: Data(contentsOf: url)) else { continue }
      let alive = kill(p.pid, 0) == 0 || errno == EPERM
      if !alive || now - p.lastSeen > STALE * 3 { try? FileManager.default.removeItem(at: url); continue }
      if now - p.lastSeen <= STALE {
        var q = p
        if q.account == nil || q.sessionName == nil, let c = sessionCache(q.pid) {
          q.account = q.account ?? c.account; q.accountOrg = q.accountOrg ?? c.accountOrg; q.profile = q.profile ?? c.profile
          q.sessionId = q.sessionId ?? c.sessionId; q.sessionName = q.sessionName ?? c.sessionName
          q.sessionCwd = q.sessionCwd ?? c.cwd; q.transcript = q.transcript ?? c.transcript
        }
        out.append(q)
      }
    }
    return out.sorted { $0.startedAt > $1.startedAt }
  }
}
