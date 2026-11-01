// The app's chat with the agent connected over MCP, one conversation for every project, kept in <root>/_chat/chat.json.
// Sankalp writes in the app's Chat tab: the message is stored as queued with what he was looking at (the project, the
// playhead, the selection). An agent listening with wait_for_app_message gets the queued messages (they turn delivered,
// with the agent's name), and so they appear in its own chat as the tool's result; it answers with reply_in_app, which
// shows in the app. Every other tool the agent runs is added as a short activity line, so the app shows what it did.
import Foundation

public struct ChatMessage: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  public var t: Double // seconds since 1970
  public var from: String // you, agent or activity
  public var text: String
  public var project: String?
  public var client: String? // the agent's service, for agent and activity lines, and for a delivered message
  public var context: JSON?
  public var status: String? // queued or delivered, for a message from you
}

public enum Chat {
  public static var dir: URL { Store.root.appendingPathComponent("_chat", isDirectory: true) }
  static var file: URL { dir.appendingPathComponent("chat.json") }
  static let LIMIT = 2000

  public static func all() -> [ChatMessage] { (try? Store.read([ChatMessage].self, file)) ?? [] }

  // The file's last change, so the app only rereads it when it changed.
  public static func stamp() -> Date? { (try? FileManager.default.attributesOfItem(atPath: file.path)[.modificationDate]) as? Date }

  static func change<T>(_ fn: (inout [ChatMessage]) -> T) -> T {
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let path = dir.appendingPathComponent(".lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o644)
    if fd >= 0 { flock(fd, LOCK_EX) }
    defer { if fd >= 0 { flock(fd, LOCK_UN); close(fd) } }
    var list = all()
    let r = fn(&list)
    if list.count > LIMIT { list.removeFirst(list.count - LIMIT) }
    try? Store.write(list, file)
    return r
  }

  static func id() -> String { String(UUID().uuidString.prefix(8)).lowercased() }
  static var now: Double { Date().timeIntervalSince1970 }

  @discardableResult
  public static func post(_ text: String, project: String?, context: JSON?) -> ChatMessage {
    let m = ChatMessage(id: id(), t: now, from: "you", text: text, project: project, client: nil, context: context, status: "queued")
    change { $0.append(m) }
    Log.write("chat", "you", args: ["text": .string(text), "project": project.map { .string($0) } ?? .null])
    return m
  }

  @discardableResult
  public static func reply(_ text: String, project: String?, client: String) -> ChatMessage {
    let m = ChatMessage(id: id(), t: now, from: "agent", text: text, project: project, client: client, context: nil, status: nil)
    change { $0.append(m) }
    Log.write("chat", "agent", args: ["text": .string(text), "client": .string(client)])
    return m
  }

  public static func activity(_ text: String, project: String?, client: String) {
    change { $0.append(ChatMessage(id: id(), t: now, from: "activity", text: text, project: project, client: client, context: nil, status: nil)) }
  }

  // The messages from Sankalp nobody has had yet, marked delivered to this agent.
  public static func takeQueued(client: String) -> [ChatMessage] {
    change { list in
      var out: [ChatMessage] = []
      for i in list.indices where list[i].from == "you" && list[i].status == "queued" {
        list[i].status = "delivered"; list[i].client = client
        out.append(list[i])
      }
      return out
    }
  }

  public static func clear() { change { $0.removeAll() } }
}
