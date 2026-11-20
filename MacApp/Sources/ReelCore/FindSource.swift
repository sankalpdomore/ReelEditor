// Missing videos found on this Mac (Sankalp, 15 Nov 2026): when a project's video was moved, renamed or its folder
// emptied, the chat's Claude looks for it instead of asking for a path. Spotlight is asked for files of the same name and
// for videos of the same length (a renamed copy), and the usual folders are walked by name, Downloads, Desktop, Movies,
// Documents, Pictures, iCloud Drive and every disk under /Volumes. A file whose name and length both match is linked
// again with relink_source's checks. Only with Sankalp's leave: Find missing videos in App settings, searchMac in
// settings.json, which no tool can turn on. Folders he names in the chat are searched without it.
import CoreServices
import Foundation

public enum FindSource {
  static let KEY = "searchMac"

  public static var allowed: Bool { Rules.settings()[KEY] as? Bool ?? false }
  public static func setAllowed(_ on: Bool) throws {
    var s = Rules.settings()
    s[KEY] = on
    try Rules.saveSettings(s)
  }

  public struct Candidate: Sendable {
    public var path: String
    public var size: Int?
    public var duration: Double?
    public var modified: Date?
    public var nameMatches: Bool
    public var lengthMatches: Bool
    public var inTrash: Bool
    public var inCloud: Bool // an iCloud file not downloaded to this Mac, which cannot be read until it is

    var score: Int { (nameMatches ? 2 : 0) + (lengthMatches ? 3 : 0) - (inTrash ? 4 : 0) - (inCloud ? 1 : 0) }
    var json: JSON {
      var o: [String: JSON] = ["path": .string(path), "nameMatches": .bool(nameMatches), "lengthMatches": .bool(lengthMatches)]
      if let size { o["size"] = .number(Double(size)) }
      if let duration { o["duration"] = .number(round3(duration)) }
      if let modified { o["modified"] = .string(ISO8601DateFormatter().string(from: modified)) }
      if inTrash { o["inTrash"] = true }
      if inCloud { o["inCloud"] = true }
      return .object(o)
    }
  }

  // The folders walked by name: the usual ones in the home folder and every other disk. REEL_FIND_ROOTS (paths joined by
  // colons) replaces them, so the tests never walk Sankalp's own folders.
  static var roots: [URL] {
    if let r = ProcessInfo.processInfo.environment["REEL_FIND_ROOTS"] { return r.split(separator: ":").map { URL(fileURLWithPath: String($0), isDirectory: true) } }
    let home = FileManager.default.homeDirectoryForCurrentUser
    var out = ["Downloads", "Desktop", "Movies", "Documents", "Pictures", "Library/Mobile Documents/com~apple~CloudDocs", ".Trash"].map { home.appendingPathComponent($0, isDirectory: true) }
    let volumes = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: "/Volumes"), includingPropertiesForKeys: [.isSymbolicLinkKey])) ?? []
    out += volumes.filter { (try? $0.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true } // the start-up disk is a link to /
    return out
  }
  static var spotlightOn: Bool { ProcessInfo.processInfo.environment["REEL_FIND_ROOTS"] == nil || ProcessInfo.processInfo.environment["REEL_FIND_SPOTLIGHT"] == "1" }

  // Every file that may be the missing one: its name (any case) or its length within half a second, best first.
  // Spotlight's own size and length are used where it has them, so a file in a private folder is listed without being
  // opened; a file found by walking is opened only when its name matches.
  public static func search(file: String, duration: Double, video: Bool, folders: [URL], wholeMac: Bool) async -> [Candidate] {
    let name = (file as NSString).lastPathComponent
    var found: [String: Candidate] = [:]
    func add(_ c: Candidate) {
      guard c.path != file, !skipped(c.path) else { return }
      if let old = found[c.path], old.score >= c.score { return }
      found[c.path] = c
    }
    func lengthMatches(_ d: Double?) -> Bool { d.map { duration > 0 && abs($0 - duration) <= 0.5 } ?? false }

    if wholeMac && spotlightOn {
      let type = video ? "public.movie" : "public.audiovisual-content"
      var queries = ["kMDItemFSName == \"\(escape(name))\"c"]
      // A renamed copy is the same length to the frame, so only videos within a tenth of a second are asked for.
      if duration > 0 { queries.append("kMDItemContentTypeTree == \"\(type)\" && kMDItemDurationSeconds >= \(duration - 0.1) && kMDItemDurationSeconds <= \(duration + 0.1)") }
      for q in queries {
        for hit in spotlight(q, limit: 60) {
          add(Candidate(path: hit.path, size: hit.size, duration: hit.duration, modified: hit.modified, nameMatches: hit.name.caseInsensitiveCompare(name) == .orderedSame,
                        lengthMatches: lengthMatches(hit.duration), inTrash: inTrash(hit.path), inCloud: false))
        }
      }
    }

    var walked: [(URL, Bool)] = []
    for root in (wholeMac ? roots : []) + folders { walk(root, name: name, depth: 0, budget: 40_000, into: &walked) }
    // A folder Sankalp names is small and his own choice, so its videos are also opened for their length, which finds a
    // renamed copy there when Spotlight has not indexed it.
    var opened = 0
    for folder in folders {
      for u in mediaFiles(folder) where opened < 200 && !walked.contains(where: { $0.0 == u }) { walked.append((u, false)); opened += 1 }
    }
    for (u, cloud) in walked {
      let path = cloud ? u.deletingLastPathComponent().appendingPathComponent(cloudName(u.lastPathComponent)).path : u.path
      let v = try? u.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
      var d = cloud ? nil : found[path]?.duration
      if !cloud && d == nil { d = video ? try? await Media.probe(u).duration : try? await Media.probeAudio(u) }
      let c = Candidate(path: path, size: cloud ? nil : v?.fileSize, duration: d, modified: v?.contentModificationDate,
                        nameMatches: (path as NSString).lastPathComponent.caseInsensitiveCompare(name) == .orderedSame, lengthMatches: lengthMatches(d), inTrash: inTrash(path), inCloud: cloud)
      guard c.nameMatches || c.lengthMatches else { continue }
      add(c)
    }
    return found.values.filter { $0.nameMatches || $0.lengthMatches }
      .sorted { $0.score != $1.score ? $0.score > $1.score : ($0.modified ?? .distantPast) > ($1.modified ?? .distantPast) }
  }

  // The file to link without asking: the only match of name and length outside the Trash, or the newest of several that
  // are all the same size (copies of one file). Anything less sure is left for Sankalp to pick.
  public static func sure(_ list: [Candidate]) -> Candidate? {
    let both = list.filter { $0.nameMatches && $0.lengthMatches && !$0.inTrash && !$0.inCloud }
    guard let first = both.first else { return nil }
    if both.count == 1 { return first }
    guard Set(both.map { $0.size ?? -1 }).count == 1, first.size != nil else { return nil }
    return both.max { ($0.modified ?? .distantPast) < ($1.modified ?? .distantPast) }
  }

  // ------------------------------------------------------------------------------------------------------------------

  // App bundles, Photos and the other libraries, and the Library folder (all but iCloud Drive) hold no video to link.
  static func skipped(_ path: String) -> Bool {
    let lib = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library").path + "/"
    if path.hasPrefix(lib) && !path.hasPrefix(lib + "Mobile Documents/") { return true }
    if path.hasPrefix(Store.root.appendingPathComponent("_cache").path + "/") { return true }
    return path.range(of: "\\.(app|photoslibrary|fcpbundle|imovielibrary|tvlibrary|musiclibrary)/", options: [.regularExpression, .caseInsensitive]) != nil
  }
  static func inTrash(_ path: String) -> Bool { path.contains("/.Trash/") || path.contains("/.Trashes/") }

  // An iCloud file not on this Mac is a hidden stand in, .IMG_4591.MOV.icloud, beside where the file will be.
  static func cloudName(_ standIn: String) -> String { String(standIn.dropFirst().dropLast(".icloud".count)) }

  static func walk(_ dir: URL, name: String, depth: Int, budget: Int, into out: inout [(URL, Bool)]) {
    var left = budget
    func go(_ dir: URL, _ depth: Int) {
      let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isPackageKey])) ?? []
      for u in items {
        left -= 1; if left < 0 { return }
        let n = u.lastPathComponent
        if n.caseInsensitiveCompare(name) == .orderedSame { out.append((u, false)) }
        else if n.hasPrefix("."), n.hasSuffix(".icloud"), cloudName(n).caseInsensitiveCompare(name) == .orderedSame { out.append((u, true)) }
      }
      guard depth < 5 else { return }
      for u in items where !u.lastPathComponent.hasPrefix(".") || u.lastPathComponent == ".Trash" {
        let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])
        guard v?.isDirectory == true, v?.isPackage != true, u.lastPathComponent != "node_modules", !skipped(u.path + "/") else { continue }
        go(u, depth + 1)
        if left < 0 { return }
      }
    }
    go(dir, depth)
  }

  static func mediaFiles(_ dir: URL) -> [URL] {
    guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
    var out: [URL] = []
    for case let u as URL in e where Media.AUDIO_EXTENSIONS.contains(u.pathExtension.lowercased()) {
      out.append(u)
      if out.count >= 400 { break }
    }
    return out
  }

  // A Spotlight query run to its end; quotes, backslashes and the * wildcard in a name are escaped.
  static func escape(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "*", with: "\\*")
  }

  struct Hit { var path: String; var name: String; var size: Int?; var duration: Double?; var modified: Date? }

  static func spotlight(_ q: String, limit: Int) -> [Hit] {
    guard let query = MDQueryCreate(kCFAllocatorDefault, q as CFString, nil, nil) else { return [] }
    MDQuerySetMaxCount(query, limit)
    guard MDQueryExecute(query, CFOptionFlags(kMDQuerySynchronous.rawValue)) else { return [] }
    var out: [Hit] = []
    for i in 0..<MDQueryGetResultCount(query) {
      guard let raw = MDQueryGetResultAtIndex(query, i) else { continue }
      let item = Unmanaged<MDItem>.fromOpaque(raw).takeUnretainedValue()
      guard let path = MDItemCopyAttribute(item, kMDItemPath) as? String else { continue }
      out.append(Hit(path: path, name: (path as NSString).lastPathComponent, size: (MDItemCopyAttribute(item, kMDItemFSSize) as? NSNumber)?.intValue,
                     duration: (MDItemCopyAttribute(item, kMDItemDurationSeconds) as? NSNumber)?.doubleValue,
                     modified: MDItemCopyAttribute(item, kMDItemFSContentChangeDate) as? Date))
    }
    return out
  }
}

let findTools: [ReelTool] = [
  ReelTool(name: "find_source", description: "Looks for a project's missing source files on this Mac and links them again: its own video (main), added videos (s1 and so on) and overlays (o1 and so on), each one check_sources lists with found false, or only source. Spotlight is asked for files of the same name and for videos of the same length (a renamed copy), and Downloads, Desktop, Movies, Documents, Pictures, iCloud Drive, the Trash and other disks are searched by name. Each source gets its candidates, best first, with path, size, duration, modified, nameMatches, lengthMatches (within half a second), inTrash and inCloud (in iCloud, not downloaded to this Mac). With relink true, a source whose name and length match one file (or copies of the same size) is linked to it, as relink_source does, and relinked names it; any other source keeps its candidates for Sankalp to pick, then relink_source path links his pick. Searching this Mac needs his leave: Find missing videos in App settings. Without it the tool fails with not_allowed unless folders is given, the folders he names, which are searched alone. Not an undo step.", inputSchema: obj([
    "project": projectArg,
    "source": ["type": "string", "pattern": "^(main|[so][0-9]{1,3})$", "maxLength": 8, "description": "One source to look for, as check_sources lists them; left out, every missing one."],
    "relink": ["type": "boolean", "default": false, "description": "Link each source that has one sure match."],
    "folders": ["type": "array", "maxItems": 10, "items": ["type": "string", "minLength": 1, "maxLength": 2048], "description": "Folders Sankalp named to look in, absolute or starting with ~, searched by name and by the length of every video in them."],
  ], ["project"])) { i in
    let n = try name(i)
    let l = try Store.load(n)
    let folders = (i["folders"]?.array ?? []).compactMap(\.string).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true).resolvingSymlinksInPath() }
    for f in folders where !FileManager.default.fileExists(atPath: f.path) { throw ToolError("not_found", "No folder at \(f.path)") }
    let wholeMac = FindSource.allowed
    guard wholeMac || !folders.isEmpty else {
      throw ToolError("not_allowed", "Searching this Mac for missing files is off. Ask Sankalp to turn on Find missing videos in App settings (beside Export), or to name the folder the files are in (folders), or to give a file's path for relink_source")
    }
    var all: [(id: String, label: String, file: String, duration: Double, video: Bool)] = [(MAIN, "The project's own video", l.project.main.file, l.project.main.duration, true)]
    all += l.project.edits.sources.map { ($0.id, $0.label, $0.file, $0.duration, true) }
    var seen = Set<String>()
    for o in l.project.edits.audioOverlays ?? [] where seen.insert(o.file).inserted { all.append((o.id, o.label, o.file, o.duration, o.window != nil)) }
    if let one = i["source"]?.string, !all.contains(where: { $0.id == one }) { throw ToolError("not_found", "No source \(one). The sources are \(all.map(\.id).joined(separator: ", "))") }
    let wanted = all.filter { s in i["source"]?.string.map { $0 == s.id } ?? !FileManager.default.fileExists(atPath: s.file) }
    var out: [JSON] = []
    var linked = 0
    var linkedFiles: [String: String] = [:] // an old path already linked, for a second source of the same file
    for s in wanted {
      var o: [String: JSON] = ["id": .string(s.id), "label": .string(s.label), "file": .string(s.file), "duration": .number(round3(s.duration))]
      if let done = linkedFiles[s.file] { o["relinked"] = .string(done); out.append(.object(o)); continue }
      let list = await FindSource.search(file: s.file, duration: s.duration, video: s.video, folders: folders, wholeMac: wholeMac)
      o["candidates"] = .array(list.prefix(10).map(\.json))
      if i["relink"]?.bool == true {
        if let pick = FindSource.sure(list) {
          do {
            _ = try await Store.relink(n, source: s.id, to: URL(fileURLWithPath: pick.path), force: false)
            o["relinked"] = .string(pick.path); linkedFiles[s.file] = pick.path; linked += 1
          } catch let e as ToolError { o["note"] = .string(e.message) }
        } else {
          o["note"] = .string(list.isEmpty ? "Not found" : "No sure match: name and length do not both match one file. Ask Sankalp which one, then relink_source path")
        }
      }
      out.append(.object(o))
    }
    // Counted as check_sources counts them, from the file as it is now.
    let now = try Store.load(n).project
    var files = [now.main.file] + now.edits.sources.map(\.file)
    var overlayFiles = Set<String>()
    for o in now.edits.audioOverlays ?? [] where overlayFiles.insert(o.file).inserted { files.append(o.file) }
    let missing = files.filter { !FileManager.default.fileExists(atPath: $0) }.count
    var searched = folders.map { JSON.string($0.path) }
    if wholeMac { searched = [.string("this Mac")] + searched }
    return ["project": .string(n), "searched": .array(searched), "sources": .array(out), "relinked": .number(Double(linked)), "missing": .number(Double(missing))]
  },
]
