// Who edited a project (Sankalp, 1 Nov 2026), for the Project card: this app, or each agent session by its name and
// account (a Claude Code session, the app's own chat), with how many edits it made and its last one. Kept in the app's
// folder for the project, _cache/<name>/editors.json, so the project file holds only the edit itself.
import Foundation

public struct ProjectEditor: Codable, Sendable, Identifiable {
  public var who: String
  public var account: String?
  public var edits: Int
  public var first: Double
  public var last: Double
  public var lastTool: String
  public var id: String { who }
}

public enum Editors {
  static func file(_ name: String) -> URL { Store.file(name, "editors.json") }

  // The editors of a project, the most recent first.
  public static func list(_ name: String) -> [ProjectEditor] {
    ((try? Store.read([ProjectEditor].self, file(name))) ?? []).sorted { $0.last > $1.last }
  }

  // Counts an edit by whoever is calling: the app, or the agent session over MCP.
  public static func record(_ name: String, tool: String) {
    let who = Log.source == "app" ? "Reel Editor app" : (ToolContext.session ?? ToolContext.client)
    let account = Log.source == "app" ? nil : ToolContext.account
    let now = Date().timeIntervalSince1970
    _ = try? Store.fileLock(Store.file(name, ".editors.lock")) {
      var all = (try? Store.read([ProjectEditor].self, file(name))) ?? []
      if let i = all.firstIndex(where: { $0.who == who }) {
        all[i].edits += 1; all[i].last = now; all[i].lastTool = tool
        if let account { all[i].account = account }
      } else {
        all.append(ProjectEditor(who: who, account: account, edits: 1, first: now, last: now, lastTool: tool))
      }
      try Store.write(all, file(name))
    }
  }
}
