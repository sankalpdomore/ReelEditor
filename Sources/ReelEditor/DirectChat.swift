// Chatting with Claude directly from the app: the app starts the claude command line itself (as the LiveAssistant app
// does), on the account picked (its config folder, CLAUDE_CONFIG_DIR), with this app's reel-editor MCP server as its
// only tools, and keeps it running for the conversation. A message goes in as one stream-json line with what is on
// screen; Claude's answers, the tools it runs and the end of each turn come back as stream-json lines. The command line
// signs in by itself; no token is read here. The conversation is kept in
// <projects folder>/_chat/direct.json, and every turn's cost is logged.
import AppKit
import ReelCore
import SwiftUI

struct DirectMessage: Identifiable, Codable, Equatable {
  var id = UUID()
  var role: String // you, claude, activity, rules (the rule books sent when a Claude starts), error
  var text: String
  var t = Date()
}

@MainActor final class DirectChat: ObservableObject {
  static let shared = DirectChat()
  @Published private(set) var messages: [DirectMessage] = []
  @Published private(set) var state = "off" // off, starting, ready, thinking
  @AppStorage("directProfile") var profile = "claude"
  @AppStorage("directModel") var model = "sonnet"
  @AppStorage("directEffort") var effort = "default" // the claude command line's --effort: low, medium, high, xhigh, max
  private var proc: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var lastAssistantId: String?
  @Published private(set) var rules: [Rules.Book] = [] // the rule books of the project in front, as last read
  @Published private(set) var rulesDir = ""
  private var rulesSent: String? // the folder whose rule books this conversation's Claude started with

  // The project in front, whose rules folder the chat shows and starts with.
  var project: String? { AppModel.shared.editor?.name }

  // Reads the rules folder of the project in front again, for the count and the path shown in the chat.
  func reloadRules() { let d = Rules.dir(for: project); rules = Rules.books(in: d); rulesDir = d.path }

  // Points the rule books of the project in front at another folder (nil is the default _rules) and saves it as the
  // folder new projects start with. A Claude already running keeps the rules it started with, is told of the new folder
  // with the next message, and get_rules reads it at once.
  func setRulesFolder(_ url: URL?) {
    do { try Rules.setDir(url, project: project); Log.write("app", "rules_folder", args: ["project": project.map { .string($0) } ?? .null, "folder": .string(Rules.dir(for: project).path)]) }
    catch { append("error", "Could not change the rules folder: \(error)"); return }
    reloadRules()
    // Nothing is copied on its own: the chat says how to bring the rule books over (Sankalp, 1 Nov 2026).
    let home = rulesDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    append("rules", "Rules folder for \(project ?? "new projects") is now \(home), with \(rules.count) rule \(rules.count == 1 ? "book" : "books"). Copy your existing rule books (.md) into this folder, or drop them here in the chat and they are saved there.")
  }

  // Rule books dropped into the chat: saved into the rules folder of the project in front. A file of the same name with
  // other text is kept, and the new one is saved beside it with a number. A Claude already running hears of them with the
  // next message and reads them with get_rules.
  private var rulesAdded: [String] = []
  func addRuleFiles(_ urls: [URL]) {
    let dir = Rules.dir(for: project)
    let fm = FileManager.default
    try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
    var saved: [String] = [], skipped: [String] = [], already: [String] = []
    for u in urls {
      guard Rules.EXTENSIONS.contains(u.pathExtension.lowercased()), let data = try? Data(contentsOf: u) else { skipped.append(u.lastPathComponent); continue }
      var dest = dir.appendingPathComponent(u.lastPathComponent)
      if dest.standardizedFileURL.path == u.standardizedFileURL.path { already.append(dest.lastPathComponent); continue }
      if let old = try? Data(contentsOf: dest) {
        if old == data { already.append(dest.lastPathComponent); continue }
        let base = u.deletingPathExtension().lastPathComponent, ext = u.pathExtension
        var n = 2
        repeat { dest = dir.appendingPathComponent("\(base) \(n).\(ext)"); n += 1 } while fm.fileExists(atPath: dest.path)
      }
      do { try data.write(to: dest, options: .atomic); saved.append(dest.lastPathComponent) }
      catch { append("error", "Could not save \(u.lastPathComponent) to the rules folder: \(error)") }
    }
    reloadRules()
    if !saved.isEmpty {
      let home = dir.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
      append("rules", "Saved \(saved.count) rule \(saved.count == 1 ? "book" : "books") to \(home): \(saved.joined(separator: ", ")).\(proc == nil ? " Claude starts with them." : " Claude reads them with your next message.")")
      if proc != nil { rulesAdded += saved }
      Log.write("app", "rules_dropped", args: ["project": project.map { .string($0) } ?? .null, "files": .array(saved.map { .string($0) })])
    }
    if !already.isEmpty { append("rules", "Already in the rules folder: \(already.joined(separator: ", ")).") }
    if !skipped.isEmpty { append("error", "Only .md, .markdown and .txt files are rule books: \(skipped.joined(separator: ", ")) not saved.") }
  }

  static var file: URL { Store.root.appendingPathComponent("_chat/direct.json") }

  init() {
    messages = (try? JSONDecoder().decode([DirectMessage].self, from: Data(contentsOf: Self.file))) ?? []
    // REEL_EDITOR_DIRECT_SAY=<text> sends one message a few seconds after launch, for checking the direct chat end to end.
    if let say = ProcessInfo.processInfo.environment["REEL_EDITOR_DIRECT_SAY"] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { DirectChat.shared.send(say, context: AppModel.shared.screenContext()) }
    }
  }

  private func save() {
    try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(Array(messages.suffix(400))).write(to: Self.file, options: .atomic)
  }

  private func append(_ role: String, _ text: String) { messages.append(DirectMessage(role: role, text: text)); save() }

  // The accounts the chat can run on: each ~/.claude* config folder that is signed in, with its email, one per email.
  // Two folders can be signed in to the same account (~/.claude-2 and ~/.claude-secondary are both
  // sankalp@nextdoor.company), so the first folder by name stands for it.
  static func accounts() -> [(profile: String, email: String)] {
    var seen = Set<String>()
    return allAccounts().filter { seen.insert($0.email.lowercased()).inserted }
  }

  static func allAccounts() -> [(profile: String, email: String)] {
    let fm = FileManager.default, home = fm.homeDirectoryForCurrentUser
    let dirs = ((try? fm.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []).filter {
      let n = $0.lastPathComponent
      return (n == ".claude" || n.hasPrefix(".claude-")) && fm.fileExists(atPath: $0.appendingPathComponent("projects").path)
    }
    return dirs.compactMap { d in
      let f = d.lastPathComponent == ".claude" ? home.appendingPathComponent(".claude.json") : d.appendingPathComponent(".claude.json")
      guard let data = try? Data(contentsOf: f), let o = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let a = o["oauthAccount"] as? [String: Any], let e = a["emailAddress"] as? String else { return nil }
      return (String(d.lastPathComponent.dropFirst()), e)
    }.sorted { $0.profile < $1.profile }
  }

  static let systemPrompt = """
  You are Claude inside Sankalp's Reel Editor Mac app, chatting with him in its Chat panel. You edit his reels only \
  through the reel-editor tools: list_projects, get_project, cut_range, delete_words, add_animation, set_video_look, \
  set_music and the rest. Each message starts with what is on his screen: the project, the playhead and what is \
  selected. Times are edit seconds. Read get_project before editing and check it after. When he asks you to read the \
  rules or rule books again, call get_rules. A cut he asks for here may be \
  made with approved true. Never export unless he asks. Answer in a few plain lines, say where in the reel to look, and \
  never use the em dash character.
  """

  func start() {
    guard proc == nil, let bin = AccountLimits.claudeBinary else { if AccountLimits.claudeBinary == nil { append("error", "The claude command line was not found") }; return }
    let mcpPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("reel-mcp").path
    let config: [String: Any] = ["mcpServers": ["reel-editor": ["command": mcpPath, "env": ["REEL_MCP_SESSION_NAME": "Reel Editor chat"]]]]
    guard let configJSON = String(data: (try? JSONSerialization.data(withJSONObject: config)) ?? Data(), encoding: .utf8) else { return }
    let dir = Store.root.appendingPathComponent("_direct")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // The rule books go into the system prompt once, for the whole conversation, through a file, so their length never
    // runs into the limit of a command line argument. The file is temporary, outside the projects folder.
    reloadRules()
    let (rulesText, truncated) = Rules.prompt(rules, from: URL(fileURLWithPath: rulesDir), project: project)
    rulesSent = rulesDir
    let promptFile = FileManager.default.temporaryDirectory.appendingPathComponent("reel-editor-system-prompt-\(getpid()).md")
    do { try (Self.systemPrompt + (rulesText.isEmpty ? "" : "\n\n" + rulesText)).write(to: promptFile, atomically: true, encoding: .utf8) }
    catch { append("error", "Could not write the rules for Claude: \(error)"); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", model,
                   "--mcp-config", configJSON, "--strict-mcp-config", "--allowedTools", "mcp__reel-editor", "--tools", "",
                   "--setting-sources", "", "--no-session-persistence", "--system-prompt-file", promptFile.path]
      + (effort == "default" ? [] : ["--effort", effort])
    p.environment = AccountLimits.environment(profile)
    p.currentDirectoryURL = dir
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
    outPipe.fileHandleForReading.readabilityHandler = { h in
      let d = h.availableData
      Task { @MainActor in DirectChat.shared.receive(d) }
    }
    p.terminationHandler = { _ in Task { @MainActor in DirectChat.shared.ended() } }
    do { try p.run() } catch { append("error", "Could not start Claude: \(error)"); return }
    proc = p; input = inPipe.fileHandleForWriting; buffer = Data()
    state = "starting"
    // Shown once per conversation, not with every message.
    if !rules.isEmpty {
      append("rules", "\(rules.count) rule \(rules.count == 1 ? "book" : "books") sent to Claude with your request: \(rules.map(\.name).joined(separator: ", "))\(truncated ? ". Some were left out for length; Claude can read them all with get_rules" : "")")
    }
    Log.write("app", "direct_chat_start", extra: ["profile": .string(profile), "model": .string(model), "effort": .string(effort), "rules": .number(Double(rules.count))])
  }

  func stop() {
    proc?.terminate(); proc = nil; input = nil; rulesSent = nil
    state = "off"
  }

  func restart() { stop(); start() }

  func clear() { messages = []; save() }

  // Sends a message with what is on screen in front of it.
  func send(_ text: String, context: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    if proc == nil { start() }
    guard let input else { return }
    append("you", t)
    // A project whose rules folder is not the one this conversation started with: Claude is pointed at its rules.
    var screen = context
    if let p = project { let d = Rules.dir(for: p).path; if d != rulesSent { screen += ", its rule books are in \(d), not the ones you started with: read them with get_rules project \(p) before editing it" } }
    if !rulesAdded.isEmpty { screen += ", new rule books were added since you started (\(rulesAdded.joined(separator: ", "))): read them with get_rules\(project.map { " project \($0)" } ?? "") and follow them"; rulesAdded = [] }
    let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": "[On screen: \(screen)]\n\n\(t)"]]
    guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
    input.write(data + Data([0x0A]))
    state = "thinking"
    lastAssistantId = nil
  }

  private func receive(_ data: Data) {
    if data.isEmpty { return }
    buffer.append(data)
    while let nl = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<nl]
      buffer.removeSubrange(buffer.startIndex...nl)
      guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      handle(o)
    }
  }

  private func handle(_ o: [String: Any]) {
    switch o["type"] as? String {
    case "system":
      if o["subtype"] as? String == "init", state == "starting" { state = "ready" }
    case "assistant":
      guard let m = o["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] else { return }
      let id = m["id"] as? String
      for c in content {
        if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty {
          // The parts of one answer join into one bubble.
          if id != nil, id == lastAssistantId, let i = messages.lastIndex(where: { $0.role == "claude" }), i == messages.count - 1 {
            messages[i].text += t; save()
          } else { append("claude", t) }
          lastAssistantId = id
        } else if c["type"] as? String == "tool_use", let name = c["name"] as? String {
          append("activity", name.replacingOccurrences(of: "mcp__reel-editor__", with: "").replacingOccurrences(of: "_", with: " "))
          lastAssistantId = nil
        }
      }
    case "rate_limit_event":
      if let u = AccountLimits.parse(o) { AccountLimits.shared.ingest(profile, u) }
    case "result":
      state = "ready"
      lastAssistantId = nil
      if o["is_error"] as? Bool == true { append("error", (o["result"] as? String) ?? "Claude stopped with an error") }
      var extra: [String: JSON] = ["profile": .string(profile), "model": .string(model)]
      if let c = o["total_cost_usd"] as? NSNumber { extra["cost_usd"] = .number(c.doubleValue) }
      if let u = o["usage"] as? [String: Any] {
        for k in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] { if let v = u[k] as? NSNumber { extra[k] = .number(v.doubleValue) } }
      }
      Log.write("app", "direct_chat_turn", extra: extra)
    default: break
    }
  }

  private func ended() {
    proc = nil; input = nil
    if state != "off" { state = "off"; append("error", "Claude stopped. Your next message starts it again.") }
  }
}
