// What the Reel Editor app shows right now, so any agent connected over MCP can see it with get_app_state (Sankalp,
// 1 Nov 2026): the open tabs, the project in front with its file, the playhead, whether it plays, the clip under the
// playhead and what is selected. The app writes <root>/.app-state.json with its process id whenever this changes; the
// file of an app that has quit (its process is gone) is ignored, and the app removes it when it quits.
import Foundation

public enum AppState {
  public static var file: URL { Store.root.appendingPathComponent(".app-state.json") }

  public static func write(_ state: JSON) { try? Store.write(state, file) }
  public static func clear() { try? FileManager.default.removeItem(at: file) }

  // The state the running app wrote, or nil when the app is not open.
  public static func read() -> JSON? {
    guard let s = try? Store.read(JSON.self, file), let pid = s["pid"]?.int, pid > 0, kill(Int32(pid), 0) == 0 else { return nil }
    return s
  }
}
