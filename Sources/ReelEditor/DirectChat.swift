// Chatting with Claude directly from the app: the app starts the claude command line itself (as the LiveAssistant app
// does), on the account picked (its config folder, CLAUDE_CONFIG_DIR), with this app's reel-editor MCP server as its
// only tools, and keeps it running for the conversation. A message goes in as one stream-json line with what is on
// screen; Claude's answers, the tools it runs and the end of each turn come back as stream-json lines. The command line
// signs in by itself; no token is read here. Every turn's cost is logged.
//
// Each project has a chat of its own (Sankalp, 2 Nov 2026): a new project opens on a fresh chat, and going back to a
// project shows its conversation again. Each one has its own Claude, started with its first message and kept while the
// project's tab is open, so a Claude still working on one project carries on while another is in front. A project's
// conversation and what it used are kept beside its project file as <name>-chat-history.json (before 2 Nov 2026 in its
// cache folder, moved from there on first load), and the chat
// shown with no project open in _chat/direct.json.
import AppKit
import ReelCore
import SwiftUI

struct DirectMessage: Identifiable, Codable, Equatable {
  var id = UUID()
  var role: String // you, claude, activity, rules (the rule books sent when a Claude starts), note (a fresh Claude taking over), error
  var text: String
  var t = Date()
  var tool: String? = nil // for a tool Claude ran: its name, and what it worked on (a range, a paragraph)
  var detail: String? = nil
}

// What this chat has used since it was last cleared (Sankalp, 2 Nov 2026), shown above the chat's input: the tokens of
// every turn, the turns, the tools Claude ran and its share of the account's 5 hour limit. The cost the command line
// reports is kept for the log only: on a subscription it is not what is paid. Kept beside the messages, so it survives a
// restart of the app, and cleared with them.
struct ChatTurn: Codable, Equatable { var t: Date; var weight: Double } // a turn's tokens, cache reads at a tenth
struct ChatUsage: Codable, Equatable {
  var log: [ChatTurn]? = nil
  var cost = 0.0
  var input = 0.0
  var output = 0.0
  var cacheRead = 0.0
  var cacheWrite = 0.0
  var turns = 0
  var tools = 0
  var tokens: Double { input + output + cacheRead + cacheWrite }
}

// One project's chat: its conversation, what it used and the Claude running for it. key is the project's name, empty for
// the chat shown with no project open.
@MainActor final class ChatSession {
  var key: String
  weak var owner: DirectChat?
  var messages: [DirectMessage] = [] { willSet { owner?.changed(self) } }
  var state = "off" { willSet { owner?.changed(self) } } // off, starting, ready, thinking
  var usage = ChatUsage() { willSet { owner?.changed(self) } }
  // This chat's part of the account's 5 hour limit, estimated as the MCP panel estimates the editor's: the account's use
  // times this chat's share of the tokens the account spent since the window began (the chat keeps no transcript of its
  // own, so its turns are added to the account's sessions). Nil until the account's limits have been read.
  var fiveHour: (chat: Double, account: Double, resets: Date?)? = nil { willSet { owner?.changed(self) } }
  var proc: Process?
  var input: FileHandle?
  var buffer = Data()
  var lastAssistantId: String?
  var procCost = 0.0 // the cost the running Claude reported last, which counts up over its whole conversation
  var rulesSent: String? // the folder whose rule books this conversation's Claude started with
  var rulesAdded: [String] = [] // rule books dropped in since it started, told with the next message
  var madeOwnRules = false // Claude gave the project a rules folder of its own in this turn
  var interrupting: DispatchWorkItem?
  var queuedComments: [(shown: String, extra: String)] = []
  var recovered = false // this request already restarted Claude once because its context was full

  var project: String? { key.isEmpty ? nil : key }
  // A project's chat is kept beside its project file, <name>-chat-history.json, the messages and what the chat used in one
  // file (Sankalp, 2 Nov 2026); the chat with no project open stays in _chat. Chats kept in the cache folder before that
  // are read once and moved there.
  struct History: Codable { var messages: [DirectMessage]; var usage: ChatUsage }
  var history: URL? { key.isEmpty ? nil : Store.chatHistory(key) }
  var file: URL { key.isEmpty ? Store.root.appendingPathComponent("_chat/direct.json") : Store.file(key, "chat.json") }
  var usageFile: URL { key.isEmpty ? Store.root.appendingPathComponent("_chat/direct-usage.json") : Store.file(key, "chat-usage.json") }

  init(_ key: String) {
    self.key = key
    if let h = history, let d = try? Data(contentsOf: h), let saved = try? JSONDecoder().decode(History.self, from: d) {
      messages = saved.messages; usage = saved.usage
      return
    }
    messages = (try? JSONDecoder().decode([DirectMessage].self, from: Data(contentsOf: file))) ?? []
    usage = (try? JSONDecoder().decode(ChatUsage.self, from: Data(contentsOf: usageFile))) ?? ChatUsage()
    if history != nil && (!messages.isEmpty || usage.turns > 0) { save() } // an older chat moved beside the project
  }

  func save() {
    let fm = FileManager.default
    if let h = history {
      let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
      guard (try? enc.encode(History(messages: Array(messages.suffix(400)), usage: usage)).write(to: h, options: .atomic)) != nil else { return }
      try? fm.removeItem(at: file); try? fm.removeItem(at: usageFile) // the old place, once the new one is written
      return
    }
    try? fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
    try? JSONEncoder().encode(Array(messages.suffix(400))).write(to: file, options: .atomic)
    try? JSONEncoder().encode(usage).write(to: usageFile, options: .atomic)
  }
}

@MainActor final class DirectChat: ObservableObject {
  static let shared = DirectChat()
  @AppStorage("directProfile") var profile = "claude"
  @AppStorage("directModel") var model = "sonnet"
  @AppStorage("directEffort") var effort = "default" // the claude command line's --effort: low, medium, high, xhigh, max
  @Published private(set) var rules: [Rules.Book] = [] // the rule books of the project in front, as last read
  @Published private(set) var rulesDir = ""

  // The project in front, whose chat and rules folder the chat shows.
  var project: String? { AppModel.shared.current?.project }

  // Every project's chat opened since launch, loaded from its file the first time it is in front.
  private var sessions: [String: ChatSession] = [:]
  private func session(_ key: String) -> ChatSession {
    if let s = sessions[key] { return s }
    let s = ChatSession(key); s.owner = self; sessions[key] = s
    return s
  }
  private var front: ChatSession { session(project ?? "") }
  private var shown = ""

  var messages: [DirectMessage] { front.messages }
  var state: String { front.state }
  var usage: ChatUsage { front.usage }
  var fiveHour: (chat: Double, account: Double, resets: Date?)? { front.fiveHour }

  // Whether a project's Claude is working on what it was asked, for the editor to hold Sankalp's edits meanwhile.
  func isWorking(_ project: String) -> Bool { sessions[project]?.state == "thinking" }

  func changed(_ s: ChatSession) { if s.key == (project ?? "") { objectWillChange.send() } }

  // Another project came to the front: the chat shows its conversation and its rule books.
  func frontChanged() {
    let k = project ?? ""
    guard k != shown else { return }
    shown = k
    objectWillChange.send()
    _ = front
    reloadRules()
    Task { await updateShare() }
  }

  // A project's tab was closed: its Claude is ended, or ended once it finishes the turn it is on.
  func closed(_ name: String) {
    guard let s = sessions[name], s.state != "thinking" else { return }
    stop(s); sessions[name] = nil
  }

  // A project renamed: its chat follows it (its files moved with the project's cache folder).
  func renamed(_ old: String, _ new: String) {
    guard let s = sessions.removeValue(forKey: old) else { return }
    s.key = new; sessions[new] = s
    frontChanged()
  }

  // Reads the rules folder of the project in front again, for the count and the path shown in the chat. Only a change is
  // published, so reading it every few seconds redraws nothing.
  func reloadRules() {
    let d = Rules.dir(for: project), b = Rules.books(in: d)
    if b != rules { rules = b }
    if d.path != rulesDir { rulesDir = d.path }
  }

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
      append("rules", "Saved \(saved.count) rule \(saved.count == 1 ? "book" : "books") to \(home): \(saved.joined(separator: ", ")).\(front.proc == nil ? " Claude starts with them." : " Claude reads them with your next message.")")
      if front.proc != nil { front.rulesAdded += saved }
      Log.write("app", "rules_dropped", args: ["project": project.map { .string($0) } ?? .null, "files": .array(saved.map { .string($0) })])
    }
    if !already.isEmpty { append("rules", "Already in the rules folder: \(already.joined(separator: ", ")).") }
    if !skipped.isEmpty { append("error", "Only .md, .markdown and .txt files are rule books: \(skipped.joined(separator: ", ")) not saved.") }
  }

  init() {
    // Rule books added or changed outside the app (in Finder, by an agent, through iCloud) show without a restart
    // (Sankalp, 4 Nov 2026): the folder of the project in front is read again every 5 seconds and when the app comes to
    // the front. The timer lives here, not in a view, where every redraw made it anew and it never fired.
    Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in Task { @MainActor in DirectChat.shared.reloadRules() } }
    NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
      Task { @MainActor in DirectChat.shared.reloadRules() }
    }
    // REEL_EDITOR_DIRECT_SAY=<text> sends one message a few seconds after launch, for checking the direct chat end to end.
    if let say = ProcessInfo.processInfo.environment["REEL_EDITOR_DIRECT_SAY"] {
      DispatchQueue.main.asyncAfter(deadline: .now() + 3) { DirectChat.shared.send(say, context: AppModel.shared.screenContext()) }
    }
  }

  private func append(_ role: String, _ text: String, to s: ChatSession? = nil) {
    let s = s ?? front
    s.messages.append(DirectMessage(role: role, text: text)); s.save()
  }

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
  rules or rule books again, call get_rules. When he asks for new rules or changes to them, write them with \
  write_rule_book or edit_rule_book, and take one out with delete_rule_book. Rules meant for one project only go in a folder of its own: when the answer lists \
  other projects in sharedWith, call make_project_rules_folder for it first. Then follow the new rules. A cut he asks for here may be \
  made with approved true. Never export unless he asks. Answer in a few plain lines, say where in the reel to look, and \
  never use the em dash character.

  You have no shell and no file reader, only these tools, and they cover everything the rule books ask for: \
  get_project leaves out a long transcript, so read the words with get_words, a page at a time (nextStart gives the \
  next page), which also lists every pause. Where a rule book says to run audit-audio.py, call audit_audio instead: \
  it is the same audit on this project's files. Paths under tools/reel-tools or the web editor's folders do not exist \
  here. When he asks you to trim or edit, do the whole pass yourself with these tools and make the cuts, waiting for \
  his approval in the editor; do not ask him to run scripts or paste transcripts.

  The app shows him live what you work on: the paragraphs your tools touch light up in the transcript with what you are \
  doing. So for a trim pass, unless he asks for another way: run audit_audio once for the whole reel, call \
  get_paragraphs, then go paragraph by paragraph in order: read it with get_words paragraph n, decide its cuts by the \
  rule books and the audit's findings in it, make them all in one cut_range call with ranges, or with delete_words, then move to the next. Use \
  set_focus to show anything else you are doing, such as checking the joins. When he sends a new message or stops you, \
  do what the new message says.

  A reel can be made of several videos, its clips in the order they play; get_paragraphs and get_words go clip by clip \
  and name each clip's video. To put a part somewhere else, use move_range (start, end, to); to put in a part of any \
  video between two places, use insert_clip (video main, a source id or a path, in and out of that video, at). get_words \
  with video reads one video's own words in its own seconds, the parts not in the reel too. The videos are never \
  changed: every edit is in the project's file and can be undone. The captions' look (font, weight, size, case, \
  spacing, colours, outline, shadow, a box behind the line or the spoken word, the spoken word's colour, how a line \
  comes in, where they sit, the widest line and words a line) is set with set_caption_style and read with \
  get_caption_style; hide_captions and show_captions hide them over a stretch, words or a clip. Text layers go on the \
  Animation layer with add_text_layer (for a part of the reel or whole true), styled the same way, with enter and exit \
  motions; update_text_layer changes one. list_fonts lists the fonts. When you talk about a clip, call it clip 5 for \
  the clip the tools call c5, as the app shows it, never c5.
  """

  // Starts the Claude of a project's chat (the one in front unless given), with that project's rule books.
  func start(_ chat: ChatSession? = nil) {
    let s = chat ?? front
    guard s.proc == nil, let bin = AccountLimits.claudeBinary else { if AccountLimits.claudeBinary == nil { append("error", "The claude command line was not found", to: s) }; return }
    let mcpPath = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("reel-mcp").path
    let config: [String: Any] = ["mcpServers": ["reel-editor": ["command": mcpPath, "env": ["REEL_MCP_SESSION_NAME": "Reel Editor chat"]]]]
    guard let configJSON = String(data: (try? JSONSerialization.data(withJSONObject: config)) ?? Data(), encoding: .utf8) else { return }
    let dir = Store.root.appendingPathComponent("_direct")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    // The rule books go into the system prompt once, for the whole conversation, through a file, so their length never
    // runs into the limit of a command line argument. The file is temporary, outside the projects folder.
    if s.key == (project ?? "") { reloadRules() }
    let rulesFolder = Rules.dir(for: s.project)
    let books = Rules.books(in: rulesFolder)
    let (rulesText, truncated) = Rules.prompt(books, from: rulesFolder, project: s.project)
    s.rulesSent = rulesFolder.path
    let promptFile = FileManager.default.temporaryDirectory.appendingPathComponent("reel-editor-system-prompt-\(getpid())-\(UUID().uuidString.prefix(8)).md")
    do { try (Self.systemPrompt + (rulesText.isEmpty ? "" : "\n\n" + rulesText)).write(to: promptFile, atomically: true, encoding: .utf8) }
    catch { append("error", "Could not write the rules for Claude: \(error)", to: s); return }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: bin)
    p.arguments = ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose", "--model", model,
                   "--mcp-config", configJSON, "--strict-mcp-config", "--allowedTools", "mcp__reel-editor", "--tools", "",
                   "--setting-sources", "", "--no-session-persistence", "--system-prompt-file", promptFile.path]
      + (effort == "default" ? [] : ["--effort", effort])
    // A whole trim pass reads long pages of words and runs the audio audit, which can take minutes: room for both.
    var env = AccountLimits.environment(profile)
    env["MAX_MCP_OUTPUT_TOKENS"] = env["MAX_MCP_OUTPUT_TOKENS"] ?? "60000"
    env["MCP_TOOL_TIMEOUT"] = env["MCP_TOOL_TIMEOUT"] ?? "1800000"
    p.environment = env
    p.currentDirectoryURL = dir
    let inPipe = Pipe(), outPipe = Pipe()
    p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
    outPipe.fileHandleForReading.readabilityHandler = { [weak s] h in
      let d = h.availableData
      Task { @MainActor in if let s { DirectChat.shared.receive(d, s) } }
    }
    p.terminationHandler = { [weak s] ended in Task { @MainActor in if let s { DirectChat.shared.ended(s, ended) } } }
    do { try p.run() } catch { append("error", "Could not start Claude: \(error)", to: s); return }
    s.proc = p; s.input = inPipe.fileHandleForWriting; s.buffer = Data(); s.procCost = 0
    s.state = "starting"
    // Shown once per conversation, not with every message.
    if !books.isEmpty {
      append("rules", "\(books.count) rule \(books.count == 1 ? "book" : "books") sent to Claude with your request: \(books.map(\.name).joined(separator: ", "))\(truncated ? ". Some were left out for length; Claude can read them all with get_rules" : "")", to: s)
    }
    Log.write("app", "direct_chat_start", args: ["project": s.project.map { .string($0) } ?? .null], extra: ["profile": .string(profile), "model": .string(model), "effort": .string(effort), "rules": .number(Double(books.count))])
  }

  func stop() { stop(front) }
  private func stop(_ s: ChatSession) {
    let p = s.proc
    s.proc = nil; s.input = nil; s.rulesSent = nil
    p?.terminate()
    s.interrupting?.cancel(); s.interrupting = nil
    if let p = s.project { Focus.clear(p) }
    s.state = "off"
  }

  func restart() { let s = front; stop(s); start(s) }

  // Clears the chat of the project in front; the other projects' chats are kept.
  func clear() { let s = front; s.messages = []; s.usage = ChatUsage(); s.fiveHour = nil; s.save(); AppModel.shared.editor?.resetReview() }

  func updateShare() async {
    let s = front
    guard let u = AccountLimits.shared.usage[profile], let w = u.windows.first(where: { $0.key == "five_hour" }) else { s.fiveHour = nil; return }
    let since = (w.resetsAt ?? Date().addingTimeInterval(5 * 3600)).addingTimeInterval(-5 * 3600)
    let mine = (s.usage.log ?? []).filter { $0.t >= since }.reduce(0) { $0 + $1.weight }
    let config = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".\(profile)")
    let others = await SessionUsage.shared.accountWeight(config: config, since: since)
    s.fiveHour = (mine + others > 0 ? w.utilization * mine / (mine + others) : 0, w.utilization, w.resetsAt)
  }

  // Stops what Claude is doing and keeps the conversation (Sankalp, 2 Nov 2026): the command line is asked to interrupt
  // the turn, as the Agent SDK does, so the next message goes to the same Claude. If it has not stopped within five
  // seconds it is ended, and the next message starts a new one.
  func interrupt() {
    let s = front
    guard s.state == "thinking", let input = s.input else { return }
    let req: [String: Any] = ["type": "control_request", "request_id": "stop-\(UUID().uuidString.prefix(8))", "request": ["subtype": "interrupt"]]
    if let d = try? JSONSerialization.data(withJSONObject: req) { input.write(d + Data([0x0A])) }
    append("activity", "Stopped by you", to: s)
    Log.write("app", "direct_chat_interrupt", extra: ["profile": .string(profile)])
    let w = DispatchWorkItem { [weak self, weak s] in
      guard let self, let s, s.state == "thinking" else { return }
      self.stop(s)
      self.append("error", "Claude did not stop in time, so it was ended. Your next message starts a new one.", to: s)
    }
    s.interrupting = w
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    if let p = s.project { Focus.clear(p) }
  }

  // Sends a message with what is on screen in front of it.
  // A comment left on words or a range for Claude goes straight to the chat (Sankalp, 2 Nov 2026): shown as a message of
  // his, with what it is on, and sent with the comment's id so Claude acts on it and resolves it. While Claude works on
  // something else, the comment waits and goes as soon as that turn ends (Stop sends it at once).
  func sendComment(_ comment: String, on: String, id: String?) {
    let shown = "Comment on \(on): \(comment)"
    let extra = "\n\nThis is a comment Sankalp left on the reel\(id.map { ", id \($0)" } ?? ""). Do what it asks now, then call resolve_comment\(id.map { " with id \($0)" } ?? "") and a short note of what you did."
    if state == "thinking" {
      front.queuedComments.append((shown, extra))
      append("activity", "Comment saved. Claude gets it when it finishes this step, or press Stop to give it now")
    } else {
      send(shown, context: AppModel.shared.screenContext(), extra: extra)
    }
  }

  // A comment waits for its own project's Claude, and goes with the project's own screen context only when it is in front.
  private func sendQueuedComments(_ s: ChatSession) {
    guard !s.queuedComments.isEmpty, s.state != "thinking" else { return }
    let q = s.queuedComments; s.queuedComments = []
    let context = s.key == (project ?? "") ? AppModel.shared.screenContext() : "project \(s.key), not in front"
    send(q.map(\.shown).joined(separator: "\n\n"), context: context, extra: q.map(\.extra).joined(), to: s)
  }

  // extra goes to Claude after the message but is not shown in the chat.
  func send(_ text: String, context: String, extra: String = "", to chat: ChatSession? = nil, shown: Bool = true) {
    let s = chat ?? front
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    if s.proc == nil { start(s) }
    guard let input = s.input else { return }
    if shown { append("you", t, to: s); s.recovered = false }
    // A project whose rules folder is not the one this conversation started with: Claude is pointed at its rules.
    var screen = context
    if let p = s.project { let d = Rules.dir(for: p).path; if d != s.rulesSent { screen += ", its rule books are in \(d), not the ones you started with: read them with get_rules project \(p) before editing it" } }
    if !s.rulesAdded.isEmpty { screen += ", new rule books were added since you started (\(s.rulesAdded.joined(separator: ", "))): read them with get_rules\(s.project.map { " project \($0)" } ?? "") and follow them"; s.rulesAdded = [] }
    let line: [String: Any] = ["type": "user", "message": ["role": "user", "content": "[On screen: \(screen)]\n\n\(t)\(extra)"]]
    guard let data = try? JSONSerialization.data(withJSONObject: line) else { return }
    input.write(data + Data([0x0A]))
    s.state = "thinking"
    s.lastAssistantId = nil
  }

  private func receive(_ data: Data, _ s: ChatSession) {
    if data.isEmpty { return }
    s.buffer.append(data)
    while let nl = s.buffer.firstIndex(of: 0x0A) {
      let line = s.buffer[s.buffer.startIndex..<nl]
      s.buffer.removeSubrange(s.buffer.startIndex...nl)
      guard let o = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
      handle(o, s)
    }
  }

  private func handle(_ o: [String: Any], _ s: ChatSession) {
    switch o["type"] as? String {
    case "system":
      if o["subtype"] as? String == "init", s.state == "starting" { s.state = "ready" }
    case "assistant":
      guard let m = o["message"] as? [String: Any], let content = m["content"] as? [[String: Any]] else { return }
      let id = m["id"] as? String
      for c in content {
        // The bare Prompt is too long that comes as an answer when the context is full is the turn's error, shown (or
        // recovered from) with the result, not a bubble of Claude's.
        if c["type"] as? String == "text", let t = c["text"] as? String, !t.isEmpty, !(t.count < 80 && Self.contextFull(t)) {
          // The parts of one answer join into one bubble.
          if id != nil, id == s.lastAssistantId, let i = s.messages.lastIndex(where: { $0.role == "claude" }), i == s.messages.count - 1 {
            s.messages[i].text += t; s.save()
          } else { append("claude", t, to: s) }
          s.lastAssistantId = id
        } else if c["type"] as? String == "tool_use", let name = c["name"] as? String {
          s.usage.tools += 1
          let tool = name.replacingOccurrences(of: "mcp__reel-editor__", with: "")
          if tool == "make_project_rules_folder" { s.madeOwnRules = true }
          s.messages.append(DirectMessage(role: "activity", text: tool.replacingOccurrences(of: "_", with: " "), tool: tool, detail: Self.detail(tool, c["input"] as? [String: Any] ?? [:])))
          s.save()
          s.lastAssistantId = nil
        }
      }
    case "rate_limit_event":
      if let u = AccountLimits.parse(o) { AccountLimits.shared.ingest(profile, u) }
    case "result":
      s.state = "ready"
      s.lastAssistantId = nil
      // A context that filled up mid request is not shown as an error: Claude starts fresh and carries on, once.
      let full = o["is_error"] as? Bool == true && s.interrupting == nil && !s.recovered && Self.contextFull(o["result"] as? String)
      if o["is_error"] as? Bool == true, s.interrupting == nil, !full { append("error", (o["result"] as? String) ?? "Claude stopped with an error", to: s) }
      var extra: [String: JSON] = ["profile": .string(profile), "model": .string(model)]
      if let c = o["total_cost_usd"] as? NSNumber {
        extra["cost_usd"] = .number(c.doubleValue)
        s.usage.cost += max(0, c.doubleValue - s.procCost) // the reported cost is the running Claude's total so far
        s.procCost = c.doubleValue
      }
      if let u = o["usage"] as? [String: Any] {
        for k in ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"] { if let v = u[k] as? NSNumber { extra[k] = .number(v.doubleValue) } }
        let n = { (k: String) in (u[k] as? NSNumber)?.doubleValue ?? 0 }
        s.usage.input += n("input_tokens"); s.usage.output += n("output_tokens")
        s.usage.cacheRead += n("cache_read_input_tokens"); s.usage.cacheWrite += n("cache_creation_input_tokens")
        let w = n("input_tokens") + n("output_tokens") + n("cache_creation_input_tokens") + n("cache_read_input_tokens") / 10
        s.usage.log = (s.usage.log ?? []) + [ChatTurn(t: Date(), weight: w)]
      }
      s.usage.turns += 1
      if let p = s.project { Focus.clear(p) } // the turn is over: nothing is being worked on
      if s.key == (project ?? "") { reloadRules() } // Claude may have written rule books
      // A rules folder Claude gave the project itself needs no telling with the next message.
      if s.madeOwnRules { s.rulesSent = Rules.dir(for: s.project).path; s.madeOwnRules = false }
      s.interrupting?.cancel(); s.interrupting = nil
      if s.key == (project ?? "") { Task { await updateShare() } }
      extra["chat_cost_usd"] = .number(s.usage.cost)
      s.save()
      Log.write("app", "direct_chat_turn", args: ["project": s.project.map { .string($0) } ?? .null], extra: extra)
      if full { carryOn(s); return }
      // Claude is done with what it was asked: a notification with its last words (Sankalp, 2 Nov 2026).
      let said = s.messages.last { $0.role == "claude" }?.text.replacingOccurrences(of: "\n", with: " ")
      let failed = o["is_error"] as? Bool == true
      Notify.send(failed ? "Claude stopped: \(Notify.title(s.project))" : "Claude is done: \(Notify.title(s.project))", failed && said == nil ? "Claude stopped with an error" : said ?? "Finished", project: s.project)
      // A project whose tab was closed while its Claude worked: ended now that the turn is over.
      if let p = s.project, !AppModel.shared.tabs.contains(where: { $0.project == p }) { stop(s); sessions[p] = nil; return }
      DispatchQueue.main.async { DirectChat.shared.sendQueuedComments(s) }
    default: break
    }
  }

  // Claude's context filled up in the middle of a request (Prompt is too long, Sankalp, 2 Nov 2026): the request would
  // fail the same way again in that conversation, so a new Claude takes it over with the request and what was already
  // done, read from the chat, and carries on from there. Only once per request, so it can never loop.
  static func contextFull(_ text: String?) -> Bool {
    guard let t = text?.lowercased() else { return false }
    return ["prompt is too long", "context length", "context window", "too many tokens", "maximum context"].contains { t.contains($0) }
  }

  private func carryOn(_ s: ChatSession) {
    guard let ask = s.messages.lastIndex(where: { $0.role == "you" }) else { return }
    s.recovered = true
    let since = s.messages[(ask + 1)...]
    let done = since.filter { $0.role == "activity" }.suffix(300).map { "- " + ($0.tool ?? $0.text) + ($0.detail.map { ", " + $0 } ?? "") }
    let said = since.filter { $0.role == "claude" }.map(\.text).joined(separator: "\n").suffix(2000)
    append("note", "Claude's memory of this chat filled up, so a fresh Claude is taking over and carrying on from where it stopped", to: s)
    stop(s)
    let text = """
    [The Claude working on this request ran out of room in its context and stopped. You are taking over: carry on from \
    where it stopped and finish the request. What it did is already saved in the project, so do not redo it; read the \
    project again as you need (get_timeline, get_words), and make many cuts in one cut_range call with ranges.]

    The request: \(s.messages[ask].text)

    What was done before it stopped:
    \(done.isEmpty ? "- nothing yet" : done.joined(separator: "\n"))
    \(said.isEmpty ? "" : "\nWhat it said:\n" + said)
    """
    let context = s.key == (project ?? "") ? AppModel.shared.screenContext() : "project \(s.key), not in front"
    send(text, context: context, to: s, shown: false)
    Log.write("app", "direct_chat_carry_on", args: ["project": s.project.map { .string($0) } ?? .null], extra: ["done": .number(Double(done.count))])
  }

  // What a tool call worked on, in a few words for the chat: the times of a cut, the words, the paragraph read.
  static func detail(_ tool: String, _ i: [String: Any]) -> String? {
    let num = { (k: String) in (i[k] as? NSNumber)?.doubleValue }
    let tc = { (x: Double) in timecode(x).components(separatedBy: ".")[0] }
    switch tool {
    case "cut_range", "restore_range":
      if let r = i["ranges"] as? [[String: Any]], !r.isEmpty {
        let a = r.compactMap { ($0["start"] as? NSNumber)?.doubleValue }.min() ?? 0, b = r.compactMap { ($0["end"] as? NSNumber)?.doubleValue }.max() ?? 0
        return "\(r.count) \(r.count == 1 ? "cut" : "cuts"), \(tc(a)) to \(tc(b))"
      }
      if let a = num("start"), let b = num("end") { return "\(tc(a)) to \(tc(b))" }
    case "delete_words", "restore_words":
      if let a = num("from"), let b = num("to") { return "words \(Int(a)) to \(Int(b))" }
      if let ix = i["indexes"] as? [NSNumber], let a = ix.first, let b = ix.last { return ix.count == 1 ? "word \(a)" : "\(ix.count) words, \(a) to \(b)" }
    case "get_words":
      if let p = num("paragraph") { return "paragraph \(Int(p) + 1)" }
      if let s = num("start") { return "from word \(Int(s))" }
      if let a = num("from") { return num("to").map { "\(tc(a)) to \(tc($0))" } ?? "from \(tc(a))" }
    case "audit_audio":
      if let a = num("from") ?? num("to") { return "\(tc(num("from") ?? 0)) to \(num("to").map(tc) ?? "the end")" }
      return "the whole reel"
    case "set_focus": return i["action"] as? String
    case "write_rule_book", "edit_rule_book", "delete_rule_book": return i["name"] as? String
    case "correct_word": return (i["text"] as? String).map { "to \"\($0)\"" }
    case "add_animation", "update_animation": return i["kind"] as? String
    default: break
    }
    return nil
  }

  private func ended(_ s: ChatSession, _ p: Process) {
    guard s.proc === p else { return } // a Claude already replaced or stopped
    s.proc = nil; s.input = nil
    if s.state != "off" { s.state = "off"; append("error", "Claude stopped. Your next message starts it again.", to: s) }
  }
}
