// reel-mcp: the Reel Editor's tools as an MCP server over stdio (JSON-RPC 2.0, one message per line). It edits the same
// project files the app shows, and the app reloads an open project on its own when they change, so Claude or any other
// agent can cut, trim and lay animations while Sankalp watches the window. Logs go to stderr, stdout is only protocol.
import Foundation
import ReelCore

let VERSION = "1.2.0"
Log.source = "mcp"
let out = FileHandle.standardOutput
let writeLock = NSLock()
var signalSources: [DispatchSourceSignal] = []

func send(_ message: JSON) {
  writeLock.lock(); defer { writeLock.unlock() }
  out.write(Data((message.text() + "\n").utf8))
}
func log(_ s: String) { FileHandle.standardError.write(Data("[reel-mcp] \(s)\n".utf8)) }

// This connection, as the app's MCP status shows it: written once the client introduces itself, refreshed every five
// seconds, removed on exit.
let pid = getpid()
var presence: MCPPresence? = nil
let presenceLock = NSLock()
// Fills in the Claude Code session and account this server runs under; looked up again on every heartbeat, since a
// session can be cleared or resumed under a new id while the server keeps running.
func attachSession(_ p: inout MCPPresence) {
  let s = Presence.claudeSession()
  p.account = s.account; p.accountOrg = s.accountOrg; p.profile = s.profile
  p.sessionName = s.sessionName; p.sessionCwd = s.cwd
  ToolContext.session = s.sessionName.map { "\(p.service): \($0)" }; ToolContext.account = s.account
  if s.sessionId != p.sessionId || p.transcript == nil { p.sessionId = s.sessionId; p.transcript = s.transcript }
}

func updatePresence(_ change: (inout MCPPresence) -> Void) {
  presenceLock.lock(); defer { presenceLock.unlock() }
  guard var p = presence else { return }
  change(&p)
  p.lastSeen = Date().timeIntervalSince1970
  presence = p
  Presence.write(p)
}
func leave() -> Never { Log.write("mcp", "exit"); Presence.remove(pid); exit(0) }
let heartbeat = DispatchSource.makeTimerSource(queue: .global())
heartbeat.schedule(deadline: .now() + 5, repeating: 5)
heartbeat.setEventHandler { updatePresence { attachSession(&$0) } }
heartbeat.resume()
for sig in [SIGTERM, SIGINT, SIGHUP] {
  signal(sig, SIG_IGN)
  let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
  src.setEventHandler { leave() }
  src.resume()
  signalSources.append(src)
}

func reply(_ id: JSON, _ result: JSON) { send(["jsonrpc": "2.0", "id": id, "result": result]) }
func error(_ id: JSON, _ code: Int, _ message: String) { send(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]]) }

let instructions = """
Reel Editor edits videos without touching them: each project is one JSON file, <name>.reel.json, holding the edit \
decision list, the animations, the transcript, the undo history, comments and the draft. It is saved in any folder \
(create_project takes folder; the default is \(Store.root.path)), and list_projects shows each project's file; \
add_project puts a file saved elsewhere on the list and remove_project takes one off, leaving the file. \
open_in_app opens a project, or any .reel.json by its path, in the app (starting it when it is closed), and \
get_app_state shows what Sankalp has on screen there: the project in front, the playhead and his selection. Start with list_projects or create_project, \
read get_project, then edit with cut_range, delete_words, trim_clip, split_clip, add_animation and the rest. Times are \
seconds in edit time (the clips end to end, before cuts). Every edit can be undone. The Reel Editor app reloads an open \
project whenever these tools change it; open_in_app shows a project there. export renders an MP4. The tools of the web \
reel editor work here under the same names (list_reels, get_timeline, import_video, set_clip_look, add_face_overlay, \
set_music, set_voice_gain and the rest), and reel is taken as another name for project. A cut made here waits for \
Sankalp's approval (approve_cuts) unless approved is true; read list_comments at the start of a session on a reel.
"""

func handle(_ msg: JSON) async {
  let id = msg["id"]
  guard let method = msg["method"]?.string else { if let id { error(id, -32600, "Invalid request") }; return }
  switch method {
  case "initialize":
    let asked = msg["params"]?["protocolVersion"]?.string ?? "2025-06-18"
    let info = msg["params"]?["clientInfo"]
    let now = Date().timeIntervalSince1970
    presenceLock.lock()
    presence = MCPPresence(pid: pid, client: info?["name"]?.string ?? "", clientVersion: info?["version"]?.string ?? "", device: Presence.deviceName, startedAt: now, lastSeen: now)
    attachSession(&presence!)
    Presence.write(presence!)
    ToolContext.client = presence!.service
    presenceLock.unlock()
    Log.write("mcp", "initialize", args: ["client": info ?? .null, "protocol": .string(asked)], extra: ["version": .string(VERSION)])
    reply(id ?? .null, ["protocolVersion": .string(asked), "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "reel-editor", "version": .string(VERSION)], "instructions": .string(instructions)])
  case "notifications/initialized", "notifications/cancelled": return
  case "ping": reply(id ?? .null, [:])
  case "tools/list":
    reply(id ?? .null, ["tools": .array(reelTools.map { ["name": .string($0.name), "description": .string($0.description), "inputSchema": $0.inputSchema] })])
  case "tools/call":
    let name = msg["params"]?["name"]?.string ?? ""
    updatePresence { $0.lastTool = name; $0.lastToolAt = Date().timeIntervalSince1970 }
    let args = msg["params"]?["arguments"]
    switch await callTool(name, args) {
    case .ok(let result):
      var r: [String: JSON] = ["content": [["type": "text", "text": .string(result.text(pretty: false))]], "isError": false]
      if result.object != nil { r["structuredContent"] = result }
      reply(id ?? .null, .object(r))
    case .failure(let code, let message):
      reply(id ?? .null, ["content": [["type": "text", "text": .string("\(code): \(message)")]], "isError": true])
    }
  default:
    if let id { error(id, -32601, "Method not found: \(method)") }
  }
}

// One thread reads stdin line by line; each request runs as its own task, so a long export does not hold up the others.
Thread.detachNewThread {
  while let line = readLine(strippingNewline: true) {
    let text = line.trimmingCharacters(in: .whitespaces)
    if text.isEmpty { continue }
    guard let data = text.data(using: .utf8), let msg = try? JSONDecoder().decode(JSON.self, from: data) else {
      send(["jsonrpc": "2.0", "id": .null, "error": ["code": -32700, "message": "Parse error"]]); continue
    }
    let batch = msg.array ?? [msg]
    for m in batch { Task { await handle(m) } }
  }
  // stdin closed: let running exports finish their write, then leave.
  Thread.sleep(forTimeInterval: 0.2)
  leave()
}
log("ready, projects in \(Store.root.path)")
Log.write("mcp", "start", extra: ["version": .string(VERSION), "root": .string(Store.root.path)])
RunLoop.main.run() // the main run loop, not dispatchMain: Core Animation commits the export's layers on it
