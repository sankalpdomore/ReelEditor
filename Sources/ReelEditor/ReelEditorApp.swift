// Reel Editor for Mac. One window laid out like the web reel editor, in the web app's design language (Design.swift):
// a top bar, then a row of project tabs, the open one white and joined to the page, a close button on each and
// + New / Open project at the end. Every project opens as a
// tab at launch, and a project made later (File > Open Video, a video dropped on the window or the Dock icon, or an
// agent's create_project) gets a tab of its own. reeleditor://open?project=<name> brings a project's tab to the front,
// which the MCP tool open_in_app uses.
import AppKit
import ReelCore
import SwiftUI
import UniformTypeIdentifiers

// A tab: a project, or a new tab (project nil) that shows the welcome screen until a video is opened in it.
struct EditorTab: Identifiable, Equatable { let id = UUID(); var project: String? }

@MainActor final class AppModel: ObservableObject {
  static let shared = AppModel()
  @Published private(set) var projects: [String] = []
  @Published var tabs: [EditorTab] = [] { didSet { UserDefaults.standard.set(tabs.compactMap(\.project), forKey: Self.tabsKey) } }
  @Published var selected: UUID?
  @Published var error: String? { didSet { if let error { Log.error("app", error) } } }
  @Published var creating = false
  @Published private(set) var chat: [ChatMessage] = [] // the Chat tab, shared with the agents over MCP
  private var chatStamp: Date? = nil
  private var chatTimer: Timer?
  @Published private(set) var mcp: [MCPPresence] = [] // agents connected through reel-mcp right now
  @Published private(set) var titles: [String: String] = [:] // project name to the title shown on its tab
  @Published private(set) var live: Set<String> = []
  // The MCP details panel under the pill. REEL_EDITOR_MCP=editor (or all) opens it on that tab, for a snapshot.
  @Published var mcpOpen = ProcessInfo.processInfo.environment["REEL_EDITOR_MCP"] != nil
  // The sessions talking to this editor: the ones that have called one of its tools or listen to its Chat tab, latest first.
  // Ends one session's connection: its reel-mcp is asked to quit (SIGTERM), which removes its heartbeat, so the session
  // loses the editor's tools until it reconnects (/mcp in Claude Code). The Claude session itself keeps running.
  func disconnect(_ p: MCPPresence) {
    let ok = kill(p.pid, SIGTERM) == 0
    Log.write("app", "mcp_disconnect", ok: ok, error: ok ? nil : String(cString: strerror(errno)),
              extra: ["pid": .number(Double(p.pid)), "session": p.sessionName.map { .string($0) } ?? .null, "account": p.account.map { .string($0) } ?? .null])
    if ok { mcp.removeAll { $0.pid == p.pid } } else { error = "Could not disconnect that session: \(String(cString: strerror(errno)))" }
  }

  func isTalking(_ p: MCPPresence) -> Bool { p.lastTool != nil || p.listening == true }
  var talking: [MCPPresence] { mcp.filter { $0.lastTool != nil || $0.listening == true }.sorted { ($0.lastToolAt ?? 0) > ($1.lastToolAt ?? 0) } } // the projects whose reel is posted (status live); the rest are drafts
  @AppStorage("transcribeNew") var transcribeNew = true
  private var editors: [String: EditorModel] = [:]
  private var known: Set<String>
  private var timer: Timer?

  // The tabs open at launch are the ones left open last time (Sankalp, 1 Nov 2026), not every project on the list; a
  // project made later by an agent still opens in a tab of its own.
  static let tabsKey = "openTabs"
  init() {
    let names = Store.names()
    known = Set(names)
    projects = names
    let kept = (UserDefaults.standard.stringArray(forKey: Self.tabsKey) ?? []).filter { names.contains($0) }
    tabs = kept.isEmpty ? [EditorTab(project: nil)] : kept.map { EditorTab(project: $0) }
    selected = tabs.first?.id
    mcp = Presence.live()
    timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.refresh() } }
    chatTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { _ in MainActor.assumeIsolated { AppModel.shared.readChat() } }
    readChat()
    Log.write("app", "launch", extra: ["projects": .number(Double(names.count))])
  }

  var listening: [MCPPresence] { mcp.filter { $0.listening == true } }

  func readChat() {
    let st = Chat.stamp()
    guard st != chatStamp else { return }
    chatStamp = st
    chat = Chat.all()
  }

  // What is on screen, in words, sent in front of a direct chat message.
  func screenContext() -> String {
    guard let e = editor else { return "no project open" }
    var parts = ["project \(e.name)", "playhead \(timecode(e.clock.time))"]
    if let c = locate(e.plan, e.clock.time)?.clip { parts.append("clip \(c.id)") }
    if let s = e.selection { parts.append("selected range \(timecode(s.s)) to \(timecode(s.e))") }
    if let r = e.selectedWords { parts.append("selected words \(r.lowerBound) to \(r.upperBound): \"\(e.words[r].map(\.text).joined(separator: " "))\"") }
    if let a = e.selectedAnimation { parts.append("selected animation \(a)") }
    return parts.joined(separator: ", ")
  }

  // Sends a message from the Chat tab with what is on screen: the project, the playhead, the selection and its words.
  func send(_ text: String) {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty else { return }
    var context: [String: JSON] = [:]
    if let e = editor {
      context["project"] = .string(e.name)
      context["projectTitle"] = .string(e.title)
      context["playhead"] = .number(round3(e.clock.time))
      if let c = locate(e.plan, e.clock.time)?.clip { context["clip"] = .string(c.id) }
      if let s = e.selection { context["selection"] = ["start": .number(round3(s.s)), "end": .number(round3(s.e))] }
      if let r = e.selectedWords {
        context["selectedWords"] = ["from": .number(Double(r.lowerBound)), "to": .number(Double(r.upperBound)), "text": .string(e.words[r].map(\.text).joined(separator: " "))]
      }
      if let a = e.selectedAnimation { context["selectedAnimation"] = .string(a) }
    }
    Chat.post(t, project: editor?.name, context: context.isEmpty ? nil : .object(context))
    readChat()
  }

  var current: EditorTab? { tabs.first { $0.id == selected } }
  var editor: EditorModel? { current?.project.flatMap { editors[$0] } }

  // The editor of a project, made the first time its tab is shown and kept while the tab is open.
  func editor(for name: String) -> EditorModel? {
    if let e = editors[name] { return e }
    do {
      let e = EditorModel(try Store.load(name)); e.start(); editors[name] = e
      Store.touch(name)
      Log.write("app", "open_project", args: ["project": .string(name), "file": .string(Store.document(name)?.path ?? "")])
      return e
    }
    catch { self.error = String(describing: error); return nil }
  }

  func select(_ id: UUID) {
    guard id != selected else { return }
    editor?.player.pause()
    selected = id
  }

  func newTab() { let t = EditorTab(project: nil); tabs.append(t); select(t.id); Log.write("app", "new_tab") }

  func close(_ id: UUID) {
    guard let i = tabs.firstIndex(where: { $0.id == id }) else { return }
    Log.write("app", "close_tab", args: ["project": tabs[i].project.map { .string($0) } ?? .null])
    if let n = tabs[i].project, !tabs.contains(where: { $0.id != id && $0.project == n }) { editors[n]?.stop(); editors[n] = nil }
    tabs.remove(at: i)
    if tabs.isEmpty { tabs = [EditorTab(project: nil)] }
    if selected == id { selected = tabs[min(i, tabs.count - 1)].id }
  }

  func closeCurrent() { if let s = selected { close(s) } }

  // Brings a project's tab to the front, making one when it has none: in the new tab in front if there is one.
  func open(_ name: String, focus: Bool = true) {
    if let t = tabs.first(where: { $0.project == name }) { if focus { select(t.id) }; return }
    if focus, let i = tabs.firstIndex(where: { $0.id == selected && $0.project == nil }) { tabs[i].project = name; return }
    let t = EditorTab(project: name)
    tabs.append(t)
    if focus { select(t.id) }
  }

  // New projects, from this app or from an agent, get a tab of their own (in the background, so typing is not interrupted).
  private var recordedPids: Set<Int32> = []
  private var recordedAt = Date.distantPast

  func refresh() {
    mcp = Presence.live()
    // The accounts, tokens and limits behind the connections go to the log when the connections change, and every 20 minutes.
    let pids = Set(mcp.map(\.pid))
    if pids != recordedPids || Date().timeIntervalSince(recordedAt) > AccountLimits.STALE {
      recordedPids = pids; recordedAt = Date()
      let now = mcp
      Task { await AccountLimits.shared.record(now) }
    }
    let n = Store.names()
    // A project renamed elsewhere (an agent's rename_project) keeps its tab under the new name.
    let moved = Store.renames()
    for i in tabs.indices {
      if let p = tabs[i].project, !n.contains(p), let to = moved[p], n.contains(to) { follow(p, to); tabs[i].project = to }
    }
    let ps = n.map { ($0, Store.peek($0)) }
    let t = Dictionary(uniqueKeysWithValues: ps.map { ($0.0, $0.1?.title ?? $0.0) })
    if t != titles { titles = t }
    let l = Set(ps.filter { $0.1?.edits.status == "live" }.map(\.0))
    if l != live { live = l }
    if n != projects { projects = n }
    let fresh = n.filter { !known.contains($0) }
    known.formUnion(n)
    for f in fresh { open(f, focus: false) }
  }

  // Renames from the title at the top of the transcript: the tab and the editor follow the project to its new name.
  func rename(_ name: String, to title: String) {
    do {
      let r = try Store.rename(name, title: title)
      Log.write("app", "rename_project", args: ["from": .string(name), "to": .string(r.name), "title": .string(title)])
      follow(name, r.name)
      for i in tabs.indices where tabs[i].project == name { tabs[i].project = r.name }
      refresh()
    } catch { self.error = String(describing: error) }
  }

  private func follow(_ old: String, _ new: String) {
    known.insert(new)
    editors[old]?.stop()
    editors[old] = nil
  }

  // New Project from Video: the video, then where to save the project's file (the last folder used, at first the Reel
  // Editor folder), named after the video by default.
  func chooseVideo() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, UTType(filenameExtension: "m4v") ?? .movie]
    panel.message = "Choose a video. It is only read, never changed."
    if panel.runModal() == .OK, let url = panel.url { create(url) }
  }

  @AppStorage("projectFolder") var projectFolder = ""
  func chooseWhere(for video: URL) -> (folder: URL, name: String)? {
    let panel = NSSavePanel()
    panel.title = "Save the project"
    panel.message = "The project is one file holding every edit. The video stays where it is."
    panel.nameFieldStringValue = Store.freeName(for: video) + Store.DOC_EXT
    panel.directoryURL = projectFolder.isEmpty ? Store.root : URL(fileURLWithPath: projectFolder, isDirectory: true)
    panel.canCreateDirectories = true
    guard panel.runModal() == .OK, let u = panel.url else { return nil }
    var base = u.lastPathComponent
    for ext in [Store.DOC_EXT, ".json"] where base.hasSuffix(ext) { base = String(base.dropLast(ext.count)) }
    let folder = u.deletingLastPathComponent()
    projectFolder = folder.path
    return (folder, Store.slug(base))
  }

  // Open Project: a project file saved anywhere, put on the list and opened in a tab.
  func chooseProject() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.message = "Choose a Reel Editor project file (.reel.json)."
    panel.directoryURL = projectFolder.isEmpty ? Store.root : URL(fileURLWithPath: projectFolder, isDirectory: true)
    if panel.runModal() == .OK, let url = panel.url { openProject(url) }
  }

  func openProject(_ url: URL) {
    do {
      let n = try Store.register(file: url)
      Log.write("app", "add_project", args: ["project": .string(n), "file": .string(url.path)])
      known.insert(n)
      projects = Store.names()
      open(n)
    } catch { self.error = String(describing: error) }
  }

  // Takes a project off the Open a reel list and closes its tabs; the file stays where it is.
  func forget(_ name: String) {
    for t in tabs where t.project == name { close(t.id) }
    do { try Store.forget(name); Log.write("app", "remove_project", args: ["project": .string(name)]); refresh() }
    catch { self.error = String(describing: error) }
  }

  func create(_ url: URL) {
    guard let place = chooseWhere(for: url) else { return }
    creating = true
    let transcribe = transcribeNew
    Task {
      defer { creating = false }
      do {
        let l = try await Store.create(video: try Store.videoURL(url.path), name: place.name, link: true, folder: place.folder)
        let n = l.project.name
        Log.write("app", "create_project", args: ["project": .string(n), "video": .string(url.path)])
        if transcribe && l.project.main.hasAudio {
          Store.setStatus(n, ["state": "transcribing", "kind": "transcribe", "message": "Queued"])
          Task.detached { _ = try? await Jobs.transcribe(n) }
        }
        known.insert(n)
        projects = Store.names()
        open(n)
      } catch { self.error = String(describing: error) }
    }
  }

  func handle(url: URL) {
    if url.scheme == "reeleditor" {
      if let project = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "project" })?.value {
        refresh()
        if projects.contains(project) { open(project) }
      }
    } else if url.isFileURL { if url.lastPathComponent.hasSuffix(".json") { openProject(url) } else { create(url) } }
    NSApp.activate(ignoringOtherApps: true)
  }
}

extension String { var nilIfEmpty: String? { isEmpty ? nil : self } }

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationWillFinishLaunching(_ notification: Notification) { DesignFonts.register() }
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    Theme.apply(UserDefaults.standard.string(forKey: Theme.key) ?? Theme.light.rawValue)
    // A snapshot run (below) stays in the background, so it never takes the keyboard from the app being typed in.
    if ProcessInfo.processInfo.environment["REEL_EDITOR_SNAPSHOT"] == nil { NSApp.activate(ignoringOtherApps: true) }
    // A click anywhere that is not a text field takes the keyboard back from a field (the chat's input, a name, a
    // number), so Space plays and pauses again and the editing keys work, as clicking out of a field does on the web.
    NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { e in
      guard let w = e.window, w.firstResponder is NSTextView || w.firstResponder is NSTextField else { return e }
      let hit = w.contentView?.hitTest(w.contentView?.convert(e.locationInWindow, from: nil) ?? e.locationInWindow)
      var v: NSView? = hit
      while let x = v { if x is NSTextView || x is NSTextField { return e }; v = x.superview }
      DispatchQueue.main.async { w.makeFirstResponder(nil) }
      return e
    }
    // REEL_EDITOR_SNAPSHOT=<file.png>: writes a picture of the window every few seconds, and the tabs beside it, for
    // checking the layout without screen recording access. The video does not show in it, only the interface.
    if let path = ProcessInfo.processInfo.environment["REEL_EDITOR_SNAPSHOT"] {
      Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { _ in
        MainActor.assumeIsolated {
          guard let window = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }), let view = window.contentView?.superview ?? window.contentView,
                let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
          view.cacheDisplay(in: view.bounds, to: rep)
          try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
          let app = AppModel.shared
          let tabs = app.tabs.map { ($0.id == app.selected ? "* " : "  ") + ($0.project.map { "\(app.titles[$0] ?? $0) [\($0)]" } ?? "New Tab") }
            + ["mcp: " + (app.mcp.map { "\($0.service) on \($0.device), last \($0.lastTool ?? "none")" }.joined(separator: "; ").nilIfEmpty ?? "not connected")]
          try? tabs.joined(separator: "\n").write(toFile: path + ".tabs.txt", atomically: true, encoding: .utf8)
        }
      }
    }
  }
  func application(_ application: NSApplication, open urls: [URL]) { Task { @MainActor in urls.forEach { AppModel.shared.handle(url: $0) } } }
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

// The window's look: Light unless Sankalp picks Dark or System (View > Appearance, or the Project panel). Saved per Mac.
enum Theme: String, CaseIterable, Identifiable {
  case light, dark, system
  var id: String { rawValue }
  var title: String { rawValue.capitalized }
  var scheme: ColorScheme? { self == .light ? .light : self == .dark ? .dark : nil }
  static let key = "theme"
  static func apply(_ raw: String) {
    let t = Theme(rawValue: raw) ?? .light
    NSApp.appearance = t == .system ? nil : NSAppearance(named: t == .light ? .aqua : .darkAqua)
  }
}

@main
struct ReelEditorApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @StateObject private var app = AppModel.shared
  @AppStorage(Theme.key) private var theme = Theme.light.rawValue

  var body: some Scene {
    Window("Reel Editor", id: "main") {
      MainView(app: app)
        .frame(minWidth: 1100, minHeight: 720)
        .preferredColorScheme((Theme(rawValue: theme) ?? .light).scheme)
        .onAppear { Theme.apply(theme) }
        .onChange(of: theme) { _, t in Theme.apply(t) }
        .onOpenURL { app.handle(url: $0) }
        .modifier(DropVideo(app: app))
        .alert("Reel Editor", isPresented: Binding(get: { app.error != nil }, set: { if !$0 { app.error = nil } })) { Button("OK") { app.error = nil } } message: { Text(app.error ?? "") }
    }
    .windowStyle(.hiddenTitleBar)
    .handlesExternalEvents(matching: ["*"])
    .commands { EditorCommands(app: app, theme: $theme) }
  }
}

// The menus, sent to the project in the front tab.
struct EditorCommands: Commands {
  @ObservedObject var app: AppModel
  @Binding var theme: String
  @AppStorage(UIZoom.key) private var zoom = 1.0

  var body: some Commands {
    CommandGroup(replacing: .newItem) {
      Button("New Project from Video…") { app.chooseVideo() }.keyboardShortcut("n")
      Button("Open Project…") { app.chooseProject() }.keyboardShortcut("o")
      Button("New Tab") { app.newTab() }.keyboardShortcut("t")
      Toggle("Transcribe New Videos", isOn: $app.transcribeNew)
    }
    CommandGroup(replacing: .saveItem) {
      Button("Close Tab") { app.closeCurrent() }.keyboardShortcut("w")
      Button("Export…") { app.editor?.chooseExport() }.keyboardShortcut("e").disabled(app.editor == nil)
    }
    CommandGroup(replacing: .undoRedo) {
      Button("Undo Edit") { app.editor?.undo() }.keyboardShortcut("z").disabled(app.editor?.loaded.history.past.isEmpty ?? true)
      Button("Redo Edit") { app.editor?.redo() }.keyboardShortcut("z", modifiers: [.command, .shift]).disabled(app.editor?.loaded.history.future.isEmpty ?? true)
    }
    CommandGroup(after: .sidebar) {
      Picker("Appearance", selection: $theme) { ForEach(Theme.allCases) { Text($0.title).tag($0.rawValue) } }
      Divider()
      Button("Zoom In") { zoom = UIZoom.step(zoom, 1) }.keyboardShortcut("+").disabled(zoom >= UIZoom.steps.last!)
      Button("Zoom In ") { zoom = UIZoom.step(zoom, 1) }.keyboardShortcut("=").disabled(zoom >= UIZoom.steps.last!) // Cmd = too, the same key without Shift
      Button("Zoom Out") { zoom = UIZoom.step(zoom, -1) }.keyboardShortcut("-").disabled(zoom <= UIZoom.steps.first!)
      Button("Actual Size") { zoom = 1 }.keyboardShortcut("0")
      Divider()
      Button("Next Tab") { step(1) }.keyboardShortcut("]", modifiers: [.command, .shift])
      Button("Previous Tab") { step(-1) }.keyboardShortcut("[", modifiers: [.command, .shift])
    }
    CommandMenu("Edit Video") {
      Button("Cut Selection") { app.editor?.cutSelection() }.keyboardShortcut(.delete, modifiers: .command).disabled(app.editor == nil)
      Button("Restore Selection") { app.editor?.restoreSelection() }.keyboardShortcut(.delete, modifiers: [.command, .shift]).disabled(app.editor == nil)
      Button("Split at Playhead") { app.editor?.splitAtPlayhead() }.keyboardShortcut("b").disabled(app.editor == nil)
      Divider()
      Button("Play or Pause") { app.editor?.togglePlay() }.keyboardShortcut("p").disabled(app.editor == nil)
    }
  }

  func step(_ d: Int) {
    guard let i = app.tabs.firstIndex(where: { $0.id == app.selected }), !app.tabs.isEmpty else { return }
    app.select(app.tabs[(i + d + app.tabs.count) % app.tabs.count].id)
  }
}

// The window, laid out like the web reel editor: the top bar (brand, undo and redo, the reel's name, the layouts and
// Export), the row of project tabs under it, then the editor or the Open a reel page.
// The whole interface's zoom, Cmd plus and Cmd minus in 10% steps, Cmd 0 back to 100%, like a browser's page zoom.
// Saved per Mac. The window is laid out at its size divided by the zoom and then scaled, so everything reflows.
enum UIZoom {
  static let key = "uiZoom"
  static let steps: [Double] = [0.6, 0.7, 0.8, 0.9, 1.0, 1.1, 1.2, 1.3, 1.4]
  static func step(_ z: Double, _ d: Int) -> Double {
    let i = steps.firstIndex { abs($0 - z) < 0.01 } ?? 4 // index 4 is 100%, where a saved odd value falls back to
    return steps[max(0, min(steps.count - 1, i + d))]
  }
}

private struct UIZoomKey: EnvironmentKey { static let defaultValue = 1.0 }
extension EnvironmentValues { var uiZoom: Double { get { self[UIZoomKey.self] } set { self[UIZoomKey.self] = newValue } } }

struct MainView: View {
  @ObservedObject var app: AppModel
  @AppStorage(UIZoom.key) private var zoom = 1.0

  var body: some View {
    GeometryReader { g in
      let z = max(0.5, zoom)
      content
        .frame(width: g.size.width / z, height: g.size.height / z)
        .scaleEffect(z, anchor: .topLeading)
        .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
        .environment(\.uiZoom, z)
    }
    .background(Ink.page)
    .ignoresSafeArea(.container, edges: .top)
    .navigationTitle(app.current?.project.map { app.titles[$0] ?? $0 } ?? "Reel Editor")
  }

  var content: some View {
    VStack(spacing: 0) {
      if let e = app.editor { TopBar(app: app, model: e) } else { TopBar(app: app, model: nil) }
      TabStrip(app: app)
      Group {
        if let tab = app.current, let name = tab.project {
          if let model = app.editor(for: name) { EditorView(model: model).id(name) }
          else {
            VStack(spacing: 12) {
              Icon("warning-circle", size: 32).foregroundStyle(Ink.muted)
              Text("Could not open \(name)").font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
            }
          }
        } else { Welcome(app: app) }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .font(.inter())
    .foregroundStyle(Ink.text)
    .background(Ink.page)
    .coordinateSpace(.named("window"))
    // Dropdown menus, over everything, inside the window.
    .overlay(alignment: .topLeading) { MenuLayer() }
    // The MCP details drop down from the pill, right aligned under it; a click anywhere else closes them.
    .overlay(alignment: .topTrailing) {
      if app.mcpOpen {
        ZStack(alignment: .topTrailing) {
          Color.black.opacity(0.001).onTapGesture { withAnimation(.cardClose) { app.mcpOpen = false } }
          MCPDetails(app: app)
            .overlay(alignment: .topTrailing) { MenuArrow().frame(width: 16, height: 8).offset(x: -16, y: -7) }
            .padding(.top, 56 + 40 + 8).padding(.trailing, 16)
            .transition(.card(from: .topTrailing))
        }
      }
    }
  }
}

// The top bar, 56 high: room for the window buttons, the brand, undo and redo on the left, the reel's name in the middle,
// the layouts and Export on the right. The empty parts move the window, as a title bar does.
struct TopBar: View {
  @ObservedObject var app: AppModel
  var model: EditorModel?
  @Environment(\.uiZoom) private var zoom

  var body: some View {
    HStack(spacing: 16) {
      Color.clear.frame(width: 60 / zoom, height: 1) // the close, minimise and zoom buttons, which do not zoom
      HStack(spacing: 8) {
        Icon("film-strip", size: 16).foregroundStyle(Ink.onPrimary)
          .frame(width: 28, height: 28)
          .background(RoundedRectangle(cornerRadius: 8).fill(Ink.strong))
        Text("Reel editor").font(.inter(16, .semibold)).foregroundStyle(Ink.strong).fixedSize()
      }
      if let model { UndoRedo(model: model) }
      Spacer(minLength: 16)
      HStack(spacing: 12) {
        Text(app.current?.project.map { app.titles[$0] ?? $0 } ?? "Open a reel")
          .font(.inter(14)).foregroundStyle(Ink.secondary).lineLimit(1).truncationMode(.middle)
        if let model { StatusMenu(model: model) }
      }
      .layoutPriority(-1)
      Spacer(minLength: 16)
      if let model { EditorActions(model: model) }
    }
    .padding(.horizontal, 20)
    .frame(height: 56)
    .background(WindowDragArea())
    .overlay(alignment: .bottom) { Hairline() }
  }
}

// The Draft or Live pill beside the reel's name; a click switches it (set_reel_status).
struct StatusMenu: View {
  @ObservedObject var model: EditorModel
  @State private var open = false
  var body: some View {
    Button { open.toggle() } label: { StatusPill(kind: model.live ? .live : .draft) }
      .buttonStyle(.plain)
      .help("Where the reel stands: Draft while it is made, Live once posted")
      .popover(isPresented: $open, arrowEdge: .bottom) {
        OptionList(options: [("draft", "Draft"), ("live", "Live, posted")], selected: model.live ? "live" : "draft", icons: ["draft": "note-pencil", "live": "check-circle"]) { s in
          model.run("set_reel_status", ["status": .string(s)]); open = false
        }
      }
  }
}

struct UndoRedo: View {
  @ObservedObject var model: EditorModel
  var body: some View {
    HStack(spacing: 4) {
      Button { model.undo() } label: { Icon("arrow-counter-clockwise", size: 16) }.pill(.ghost, .icon)
        .disabled(model.loaded.history.past.isEmpty).help("Undo (Cmd Z)")
      Button { model.redo() } label: { Icon("arrow-clockwise", size: 16) }.pill(.ghost, .icon)
        .disabled(model.loaded.history.future.isEmpty).help("Redo (Shift Cmd Z)")
    }
  }
}

// The right end of the top bar: Wide, Tall and Distraction free as tabs, then Export.
struct EditorActions: View {
  @ObservedObject var model: EditorModel
  @AppStorage("layoutLandscape") private var layoutLandscape = EditorLayout.wide.rawValue
  @AppStorage("layoutPortrait") private var layoutPortrait = EditorLayout.tall.rawValue

  var body: some View {
    let landscape = model.exportSize.width >= model.exportSize.height
    let current = model.focus ? "focus" : (landscape ? layoutLandscape : layoutPortrait)
    HStack(spacing: 12) {
      SegmentTabs(items: [
        SegmentItem(value: EditorLayout.wide.rawValue, label: "Wide", icon: "rows"),
        SegmentItem(value: EditorLayout.tall.rawValue, label: "Tall", icon: "columns"),
        SegmentItem(value: "focus", label: "Distraction free", icon: "corners-out"),
      ], selection: Binding(get: { current }, set: { v in
        if v == "focus" { model.focus = true; return }
        model.focus = false
        if landscape { layoutLandscape = v } else { layoutPortrait = v }
        Log.write("app", "layout", args: ["layout": .string(v), "landscape": .bool(landscape)])
      }))
      if model.status["state"]?.string == "exporting" {
        Button {} label: { HStack(spacing: 8) { Spinner(size: 14); Text("Exporting \(Int((model.status["progress"]?.double ?? 0) * 100))%") } }
          .pill(.outline, .md).disabled(true)
      } else {
        Button { model.chooseExport() } label: { IconLabel("Export", icon: "download-simple", size: 16) }
          .pill(.primary, .md).help("Export an MP4 (Cmd E)")
      }
    }
  }
}

// The row of project tabs under the top bar, as in the web editor: the open tab white with a #ddd border joined to the
// page below, the others grey text, a close button on each, then + New / Open project. The MCP status sits at the
// right end. Dragging the empty part moves the window.
struct TabStrip: View {
  @ObservedObject var app: AppModel
  static let tabWidth: CGFloat = 240

  var body: some View {
    HStack(spacing: 0) {
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          HStack(alignment: .bottom, spacing: 4) {
            ForEach(app.tabs) { tab in TabItem(app: app, tab: tab).id(tab.id) }
            Button { app.newTab() } label: { HStack(spacing: 4) { Icon("plus", size: 12); Text("New / Open project") }.font(.inter(13)) }
              .buttonStyle(.plain).foregroundStyle(Ink.faint)
              .padding(.horizontal, 12).frame(height: 32)
              .help("New Tab (Cmd T)")
              .id("new-tab")
          }
          .padding(.leading, 16)
        }
        .onChange(of: app.selected) { _, id in if let id { withAnimation { proxy.scrollTo(id) } } }
      }
      Spacer(minLength: 12)
      MCPStatus(app: app).padding(.trailing, 16).padding(.bottom, 4)
    }
    .frame(height: 40, alignment: .bottom)
    .background(alignment: .bottom) { Hairline().background(Ink.sunken.frame(height: 40), alignment: .bottom) }
    .background(WindowDragArea())
  }
}

struct TabItem: View {
  @ObservedObject var app: AppModel
  let tab: EditorTab
  @State private var hover = false

  var body: some View {
    let selected = app.selected == tab.id
    HStack(spacing: 8) {
      if let p = tab.project { StatusPill(kind: app.live.contains(p) ? .live : .draft) }
      Text(tab.project.map { app.titles[$0] ?? $0 } ?? "New / Open project")
        .font(.inter(14, selected ? .medium : .regular))
        .foregroundStyle(selected ? Ink.strong : Ink.secondary)
        .lineLimit(1).truncationMode(.tail)
        .frame(maxWidth: .infinity, alignment: .leading)
      Button { app.close(tab.id) } label: { Icon("x", size: 12).frame(width: 20, height: 20) }
        .buttonStyle(.plain)
        .foregroundStyle(Ink.text)
        .background(Circle().fill(Ink.hover.opacity(hover ? 1 : 0)))
        .opacity(hover || selected ? 1 : 0)
        .help("Close Tab (Cmd W)")
    }
    .padding(.leading, 16).padding(.trailing, 8)
    .frame(maxWidth: TabStrip.tabWidth).frame(height: 36)
    .fixedSize(horizontal: tab.project == nil, vertical: false)
    .background {
      UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
        .fill(selected ? Ink.page : hover ? Ink.hover : .clear)
    }
    .overlay {
      if selected {
        TopOpenBorder(radius: 8).stroke(Ink.border, lineWidth: 1)
      }
    }
    .contentShape(Rectangle())
    .onHover { hover = $0 }
    .onTapGesture { app.select(tab.id) }
    .help(tab.project ?? "New Tab")
  }
}

// The open tab's outline: its top and sides with rounded top corners, open at the bottom so it joins the page.
struct TopOpenBorder: Shape {
  let radius: CGFloat
  func path(in r: CGRect) -> Path {
    Path { p in
      p.move(to: CGPoint(x: r.minX, y: r.maxY + 1))
      p.addLine(to: CGPoint(x: r.minX, y: r.minY + radius))
      p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.minX + radius, y: r.minY), radius: radius)
      p.addLine(to: CGPoint(x: r.maxX - radius, y: r.minY))
      p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY + radius), radius: radius)
      p.addLine(to: CGPoint(x: r.maxX, y: r.maxY + 1))
    }
  }
}

// The MCP status at the right end of the tab row: the Claude logo and "Claude connected" (or the other client's name),
// green, or "MCP not connected", grey. The sessions themselves are in the details panel, which drops down under it.
struct MCPStatus: View {
  @ObservedObject var app: AppModel

  // Claude, or whichever client is talking to the editor, else connected at all.
  var client: String? { (app.talking.first ?? app.mcp.first).map { $0.service.hasPrefix("Claude") ? "Claude" : $0.service } }
  // "Claude session (1)": the sessions using this editor, or connected at all when none has used it yet.
  var count: Int { app.talking.isEmpty ? app.mcp.count : app.talking.count }
  var label: String { client.map { "\($0) \(count == 1 ? "session" : "sessions") (\(count))" } ?? "MCP not connected" }

  var body: some View {
    let connected = !app.mcp.isEmpty
    Button { withAnimation(app.mcpOpen ? .cardClose : .cardOpen) { app.mcpOpen.toggle() } } label: {
      HStack(spacing: 6) {
        Circle().fill(connected ? Ink.green : Ink.ghost).frame(width: 6, height: 6)
        if client == "Claude" { BrandMark(name: "claude", size: 14) }
        Text(label).lineLimit(1).foregroundStyle(connected ? Ink.text : Ink.secondary).padding(.leading, 2)
        Icon(app.mcpOpen ? "caret-up" : "caret-down", size: 10).foregroundStyle(Ink.muted)
      }
    }
    .pill(.outline, .xs)
    .fixedSize()
    .help(connected ? "Agents connected through MCP. Click for their accounts and usage" : "No agent is connected through MCP")
  }
}

// A green light that breathes while an agent is connected. Grey and still when none is.
struct LiveDot: View {
  let on: Bool
  @State private var lit = true
  var body: some View {
    ZStack {
      if on { Circle().fill(Ink.green.opacity(0.25)).frame(width: 14, height: 14).scaleEffect(lit ? 1 : 0.6).opacity(lit ? 0.9 : 0) }
      Circle().fill(on ? Ink.green : Ink.ghost).frame(width: 8, height: 8)
    }
    .frame(width: 14, height: 14)
    .animation(on ? .easeInOut(duration: 1.2).repeatForever(autoreverses: true) : .default, value: lit)
    .onAppear { if on { lit = false } }
    .onChange(of: on) { _, v in lit = !v }
  }
}

// The details panel: a white card that drops down from the MCP pill, its right edge on the pill's, inside the window,
// growing out of its top right corner and shrinking back into it (DESIGN.md's dropdown motion).
struct MCPDetails: View {
  @ObservedObject var app: AppModel
  @ObservedObject private var limits = AccountLimits.shared
  @State private var usage: [Int32: TokenUsage] = [:]
  @State private var listHeight: CGFloat = 120 // the tree's own height, so the panel is only as tall as it needs
  @AppStorage("mcpDetailsTab") private var tab = ProcessInfo.processInfo.environment["REEL_EDITOR_MCP"] ?? "editor" // This editor, or All sessions
  static let width: CGFloat = 420

  static func ago(_ t: Double) -> String {
    let s = Int(Date().timeIntervalSince1970 - t)
    return s < 60 ? "\(max(0, s)) s ago" : s < 3600 ? "\(s / 60) min ago" : s < 86400 ? "\(s / 3600) h ago" : "\(s / 86400) d ago"
  }

  static var command: String {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent().appendingPathComponent("reel-mcp").path
    return "claude mcp add --scope user reel-editor -- \"\(exe)\""
  }

  // A personal account's organisation is named after its email; it says nothing, so it is left out.
  static func org(_ o: String?) -> String? { o.flatMap { $0.hasSuffix("'s Organization") || $0.hasSuffix("\u{2019}s Organization") ? nil : $0 } }

  // Accounts with their sessions: the ones talking to this editor on its tab, every connection on All sessions.
  var accounts: [(account: String, profile: String?, org: String?, items: [MCPPresence])] {
    let list = tab == "editor" ? app.talking : app.mcp
    let g = Dictionary(grouping: list) { $0.account ?? "" }
    return g.map { (account: $0.key, profile: $0.value.first?.profile, org: Self.org($0.value.first?.accountOrg), items: $0.value) }
      .sorted { a, b in
        let ta = a.items.contains { app.isTalking($0) }, tb = b.items.contains { app.isTalking($0) }
        return ta != tb ? ta : (a.account.isEmpty ? "~" : a.account) < (b.account.isEmpty ? "~" : b.account)
      }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 8) {
        LiveDot(on: !app.mcp.isEmpty)
        Text(app.mcp.isEmpty ? "MCP not connected" : "Connected through MCP").font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
        Spacer()
        let n = tab == "editor" ? app.talking.count : app.mcp.count
        if !app.mcp.isEmpty { Chip(text: "\(n) \(n == 1 ? "session" : "sessions")") }
        Button { withAnimation(.cardClose) { app.mcpOpen = false } } label: { Icon("x", size: 14) }.pill(.ghost, .iconSm).help("Close (Escape)")
      }
      if app.mcp.isEmpty {
        Note("No agent is using Reel Editor's tools right now. An agent connects when a session that has the reel-editor MCP server starts. To add it to Claude Code:")
        CommandBox(text: Self.command)
      } else {
        SegmentTabs(items: [SegmentItem(value: "editor", label: "This editor", icon: "film-strip"), SegmentItem(value: "all", label: "All sessions", icon: "users-three")], selection: $tab, fullWidth: true)
        ScrollView {
          VStack(alignment: .leading, spacing: 16) {
            if tab == "editor" && app.talking.isEmpty {
              VStack(alignment: .leading, spacing: 8) {
                Text("No Claude has used this editor yet").font(.inter(14, .semibold)).foregroundStyle(Ink.strong)
                Note("\(app.mcp.count) \(app.mcp.count == 1 ? "session has" : "sessions have") the editor's tools but none has called one. Ask Claude to do something in the reel editor, or to listen to its Chat tab, and it shows here.")
              }
            }
            ForEach(accounts, id: \.account) { a in
              AccountTree(account: a.account.isEmpty ? nil : a.account, profile: a.profile, org: a.org, sessions: a.items, usage: usage,
                          talking: a.items.contains { app.isTalking($0) }, limits: limits)
            }
          }
          .padding(.vertical, 4)
          .onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { listHeight = $0 }
        }
        .frame(height: min(listHeight, 460))
        Note("Limits are read as the LiveAssistant app reads them, one word on Haiku per account (about 2,000 tokens), at most every 20 minutes. This editor's part is an estimate: the account's use times its sessions' share of the tokens the account spent in that window. Every reading goes to the app's log.")
      }
    }
    .padding(16)
    .frame(width: Self.width)
    // The shadow is on the card's shape only: on the whole view it fell on every part inside, the tabs included.
    .cardChrome()
    .font(.inter())
    .foregroundStyle(Ink.text)
    .task(id: app.mcp.map(\.pid)) { usage = await limits.record(app.mcp) }
    // Once an account's limits are known, how much of them this editor's sessions used.
    .task(id: limits.usage.mapValues(\.updated).description + app.talking.map(\.pid).description) {
      for (profile, items) in Dictionary(grouping: app.talking, by: { $0.profile ?? "" }) where !profile.isEmpty && limits.usage[profile] != nil {
        await limits.computeShare(profile: profile, account: items.first?.account, sessions: items)
      }
    }
  }
}

// One account as a tree, as the LiveAssistant app draws it: the account on top (a filled circle when a session of it is
// talking to this editor), and a line down from it with a branch to its 5 hour limit, its weekly limit and each of its
// sessions, the last one ending in a rounded corner.
struct AccountTree: View {
  // The plan's icon: a group for Team and Enterprise, a crown for Max, a person for Pro and anything else.
  static func planIcon(_ plan: String?) -> String {
    switch plan?.lowercased() { case "team", "enterprise": return "users-three"; case "max": return "crown-simple"; default: return "user" }
  }
  let account: String?
  let profile: String?
  let org: String?
  let sessions: [MCPPresence]
  let usage: [Int32: TokenUsage]
  let talking: Bool
  @ObservedObject var limits: AccountLimits

  var body: some View {
    let u = profile.flatMap { limits.usage[$0] }
    let five = u?.windows.first { $0.key == "five_hour" }, week = u?.windows.first { $0.key == "seven_day" }
    let showLimits = account != nil && profile != nil
    let n = (showLimits ? 2 : 0) + sessions.count
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .top, spacing: 8) {
        Icon("user", size: 10, fill: true).foregroundStyle(talking ? Ink.onPrimary : Ink.page)
          .frame(width: 16, height: 16).background(Circle().fill(talking ? Ink.strong : Ink.ghost))
          .padding(.top, 2)
          .help(talking ? "A Claude account talking to this editor" : "A Claude account")
        // The email on the first line, the plan with its icon and the organisation whole on the line under it.
        VStack(alignment: .leading, spacing: 2) {
          HStack(spacing: 4) {
            Icon("envelope-simple", size: 12).foregroundStyle(Ink.muted)
            Text(account ?? "Account not known").font(.inter(14, .semibold)).foregroundStyle(Ink.strong).lineLimit(1).truncationMode(.middle)
          }
          let plan = profile.flatMap { limits.plans[$0] }
          let detail = [plan, org].compactMap { $0 }
          if !detail.isEmpty {
            HStack(spacing: 4) {
              Icon(Self.planIcon(plan), size: 12).foregroundStyle(Ink.muted)
              Text(detail.joined(separator: " \u{00B7} ")).lineLimit(1)
            }
            .font(.inter(12)).foregroundStyle(Ink.faint)
          }
        }
        Spacer(minLength: 4)
        if let profile, account != nil {
          if limits.checking.contains(profile) { Spinner(size: 12) }
          else { Button { limits.refresh(profile, account: account, force: true) } label: { Icon("arrow-clockwise", size: 12) }.pill(.ghost, .iconSm)
            .help(u.map { "Limits read \(MCPDetails.ago($0.updated.timeIntervalSince1970)). Refresh" } ?? "Read the limits") }
        }
      }
      .padding(.bottom, 4)
      if showLimits, let profile {
        if let p = limits.problems[profile], u == nil {
          Text(p).font(.inter(12)).foregroundStyle(Ink.red).lineLimit(2).frame(minHeight: TREE_ROW).treeChild(0, of: n)
        } else {
          UsageMeterRow(title: "5-hour", fraction: five?.utilization, reset: AccountLimits.resetText(five?.resetsAt), app: limits.appShare[profile]?["five_hour"]).treeChild(0, of: n)
        }
        UsageMeterRow(title: "Weekly", fraction: week?.utilization, reset: AccountLimits.resetText(week?.resetsAt), app: limits.appShare[profile]?["seven_day"]).treeChild(1, of: n)
      }
      ForEach(Array(sessions.enumerated()), id: \.element.pid) { i, p in
        SessionLeaf(p: p, usage: usage[p.pid]).treeChild((showLimits ? 2 : 0) + i, of: n)
      }
    }
  }
}

// A session as a leaf of its account's tree: a green dot, its name, its tokens on the right, and under it the config
// folder, the project folder and its last tool.
struct SessionLeaf: View {
  let p: MCPPresence
  let usage: TokenUsage?
  @State private var confirming = false
  @State private var hover = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Circle().fill(p.lastTool != nil || p.listening == true ? Ink.green : Ink.ghost).frame(width: 6, height: 6)
        Text(p.sessionName ?? p.service).font(.inter(13, .medium)).foregroundStyle(Ink.text).lineLimit(1)
        Spacer(minLength: 8)
        if let u = usage, u.total > 0 {
          Text("\(compactCount(u.total))").font(.inter(12, .medium)).foregroundStyle(Ink.secondary).monospacedDigit()
            .help("\(compactCount(u.output)) written, \(compactCount(u.input + u.cacheWrite)) read, \(compactCount(u.cacheRead)) from the cache, \(u.messages) messages")
        }
        if confirming {
          Button("Cancel") { confirming = false }.pill(.ghost, .xs)
          Button { AppModel.shared.disconnect(p); confirming = false } label: { IconLabel("Disconnect", icon: "plugs", size: 12) }.pill(.destructive, .xs)
        } else {
          Button { confirming = true } label: { IconLabel("Disconnect", icon: "plugs", size: 12) }.pill(.outline, .xs)
            .help("Disconnect this session from the editor. In that Claude session, /mcp and reconnect reel-editor bring it back.")
        }
      }
      .frame(height: TREE_ROW)
      Text([p.profile, p.sessionCwd.map { URL(fileURLWithPath: $0).lastPathComponent },
            p.lastTool.map { "last \($0) \(p.lastToolAt.map { MCPDetails.ago($0) } ?? "")" } ?? "no tool yet",
            p.listening == true ? "listening" : nil].compactMap { $0 }.joined(separator: " \u{00B7} "))
        .font(.inter(11)).foregroundStyle(Ink.faint).lineLimit(1).padding(.leading, 14).padding(.bottom, 4)
      if confirming {
        Note("It loses the editor's tools until you run /mcp in that session and reconnect reel-editor.").padding(.leading, 14).padding(.bottom, 4)
      }
    }
    .contentShape(Rectangle())
    .onHover { hover = $0 }
  }
}

// A command to copy: monospaced in a grey box, a Copy button beside it.
struct CommandBox: View {
  let text: String
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(text).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.text).textSelection(.enabled)
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Ink.sunken))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.border, lineWidth: 1))
      Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) } label: { IconLabel("Copy command", icon: "copy", size: 12) }
        .pill(.outline, .xs)
    }
  }
}

// The empty part of the top bar and the tab row moves the window, as a title bar does, and a double click zooms it.
struct WindowDragArea: NSViewRepresentable {
  final class Area: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
    override func mouseDown(with e: NSEvent) {
      if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
    }
  }
  func makeNSView(context: Context) -> NSView { Area() }
  func updateNSView(_ v: NSView, context: Context) {}
}

struct DropVideo: ViewModifier {
  @ObservedObject var app: AppModel
  @State private var dropping = false
  func body(content: Content) -> some View {
    content
      .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
        for p in providers { _ = p.loadObject(ofClass: URL.self) { url, _ in if let url { Task { @MainActor in app.create(url) } } } }
        return true
      }
      .overlay {
        if dropping {
          RoundedRectangle(cornerRadius: 20).strokeBorder(Ink.strong, style: StrokeStyle(lineWidth: 2, dash: [6, 4])).padding(8).allowsHitTesting(false)
        }
      }
  }
}

// A new tab: the web editor's Open a reel page. A dashed drop area with Choose a video, then every project as a card,
// newest first, with when it was made and how long its video is. A card opens the project, or brings its tab forward.
struct Welcome: View {
  @ObservedObject var app: AppModel

  struct Row: Identifiable { let id: String; let title: String; let created: Date?; let opened: Date?; let file: String; let duration: Double; let open: Bool; var live = false }

  // The projects on the list, the most recently opened first, each with where its file is saved.
  var rows: [Row] {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    let plain = ISO8601DateFormatter()
    let reg = Store.registry()
    return app.projects.map { n in
      let p = Store.peek(n)
      let d = p.flatMap { iso.date(from: $0.createdAt) ?? plain.date(from: $0.createdAt) }
      let opened = reg[n]?.openedAt.map { Date(timeIntervalSince1970: $0) }
      return Row(id: n, title: app.titles[n] ?? n, created: d, opened: opened, file: reg[n]?.path ?? "", duration: p?.main.duration ?? 0, open: app.tabs.contains { $0.project == n }, live: app.live.contains(n))
    }
    .sorted { ($0.opened ?? $0.created ?? .distantPast) > ($1.opened ?? $1.created ?? .distantPast) }
  }

  static let when: DateFormatter = { let f = DateFormatter(); f.dateFormat = "d MMM, h:mm a"; return f }()

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        Text("Open a reel").font(.inter(32, .bold)).foregroundStyle(Ink.strong)
        VStack(spacing: 16) {
          Icon("upload-simple", size: 32).foregroundStyle(Ink.secondary)
          Text("Drop a video here, it is transcribed on this Mac with a time on every word").font(.inter(16)).foregroundStyle(Ink.secondary)
            .multilineTextAlignment(.center)
          if app.creating {
            HStack(spacing: 8) { Spinner(); Text("Reading the video").foregroundStyle(Ink.secondary) }.frame(height: 40)
          } else {
            HStack(spacing: 12) {
              Button { app.chooseVideo() } label: { Text("Choose a video").font(.inter(16, .medium)) }.pill(.outline, .md)
              Button { app.chooseProject() } label: { IconLabel("Open project", icon: "folder-open", size: 16).font(.inter(16, .medium)) }.pill(.outline, .md)
                .help("Open a project file (.reel.json) saved anywhere (Cmd O)")
            }
            Toggle("Transcribe new videos", isOn: $app.transcribeNew).toggleStyle(.pillSwitch).fixedSize()
          }
        }
        .padding(.vertical, 48).padding(.horizontal, 24)
        .frame(maxWidth: .infinity)
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.borderHover, style: StrokeStyle(lineWidth: 1, dash: [4, 3])))

        if !rows.isEmpty {
          Text("Recent projects").font(.inter(18, .semibold)).foregroundStyle(Ink.strong).padding(.top, 8)
          VStack(spacing: 12) {
            ForEach(rows) { r in ProjectCard(row: r) { app.open(r.id) } }
          }
        }
      }
      .padding(.vertical, 40)
      .frame(maxWidth: 720)
      .frame(maxWidth: .infinity)
    }
    .background(Ink.page)
  }
}

struct ProjectCard: View {
  let row: Welcome.Row
  let open: () -> Void
  @State private var hover = false
  var body: some View {
    Button(action: open) {
      HStack(alignment: .top, spacing: 12) {
        VStack(alignment: .leading, spacing: 4) {
          HStack(spacing: 8) {
            Text(row.title).font(.inter(16)).foregroundStyle(Ink.strong).lineLimit(1)
            StatusPill(kind: row.live ? .live : .draft)
          }
          HStack(spacing: 8) {
            if let o = row.opened { Text("Opened \(Welcome.when.string(from: o))") } else if let c = row.created { Text("Created \(Welcome.when.string(from: c))") }
            if row.open { Text("·"); Text("Open in a tab") }
          }
          .font(.inter(13)).foregroundStyle(Ink.faint)
          // Where the project's file is saved, the home folder written as ~.
          HStack(spacing: 4) {
            Icon("file", size: 12)
            Text(row.file.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle)
          }
          .font(.inter(12)).foregroundStyle(Ink.ghost)
        }
        Spacer(minLength: 12)
        Text(String(format: "%.1f s", row.duration)).font(.inter(16)).foregroundStyle(Ink.faint).monospacedDigit()
      }
      .padding(.horizontal, 24).padding(.vertical, 16)
      .background(RoundedRectangle(cornerRadius: 12).fill(hover ? Ink.sunken : Ink.page))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(hover ? Ink.borderHover : Ink.border, lineWidth: 1))
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .contextMenu {
      Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: row.file)]) }
      Button("Remove from this list") { AppModel.shared.forget(row.id) }
    }
  }
}
