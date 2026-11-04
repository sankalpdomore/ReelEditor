// One open project: its files, the player, the playhead and what is selected. Every edit goes through the same tools the
// MCP server publishes (ReelCore.callTool), and the project files are polled, so an edit an agent makes through MCP shows
// up here within half a second.
import AVFoundation
import AppKit
import ReelCore
import SwiftUI
import UniformTypeIdentifiers

// The playhead on its own, so only the views that follow it redraw thirty times a second.
@MainActor final class Clock: ObservableObject {
  @Published var time: Double = 0 // edit time
  @Published var playing = false
}

// A name being typed in a sheet: a clip's or an audio overlay's.
enum NamePrompt: Identifiable, Equatable {
  case renameClip(String, String), renameOverlay(String, String)
  var id: String { switch self { case .renameClip(let c, _): return "clip-\(c)"; case .renameOverlay(let o, _): return "overlay-\(o)" } }
}

// A word of the transcript. Words of the project's own video keep their index as id; words of the other videos come after
// them (extra), cut and restored by their times. pending: cut from the chat, waiting for approval.
struct WordView: Identifiable { let id: Int; let text: String; let s: Double?; let e: Double?; let cut: Bool; var pending = false; var extra = false }
// A paragraph of the transcript, in the order the reel plays: a section heading when one starts there, its words, and the
// clip and video it belongs to; clipStart marks the first paragraph of a clip, where its header goes.
struct Paragraph: Identifiable { let id: Int; let title: String?; let words: [Int]; var clip = ""; var source = MAIN; var label = ""; var clipStart = false }

@MainActor final class EditorModel: ObservableObject {
  let name: String
  @Published private(set) var loaded: Loaded
  @Published private(set) var plan: Plan
  @Published private(set) var rc: ReelComposition?
  @Published private(set) var words: [WordView] = []
  // The caption lines in the project's caption style, and the style, for the preview to draw (Captions.swift).
  @Published private(set) var captionLines: [Captions.Line] = []
  @Published private(set) var captionStyle = Captions.builtIn(landscape: false)
  var captionPictures: [String: (image: CGImage, size: CGSize)] = [:] // a line's pictures by line and spoken word, kept until the next change
  @Published private(set) var paragraphs: [Paragraph] = []
  @Published private(set) var extraWords: [ExtraEditWord] = [] // the words of the added clips and the voice overs, edit time
  @Published private(set) var overlayPeaks: [String: [Float]] = [:] // the waveform of each audio overlay file
  @Published var prompt: NamePrompt? = nil
  @Published private(set) var currentWord: Int? = nil
  @Published var selection: ReelCore.Range? = nil // edit time
  @Published var selectedWords: ClosedRange<Int>? = nil
  @Published var selectedAnimation: String? = nil
  @Published var exportOpen = false // the export modal: open from the start of an export, from the app or an agent, until closed
  @Published var selectedCut: ReelCore.Range? = nil // a cut clicked on the timeline, with handles on its edges (edit time)
  @Published private(set) var status: JSON = [:]
  @Published private(set) var agentFocus: AgentFocus? = nil // what Claude is working on, lit up in the transcript
  // The paragraphs Claude has gone through since it started reading this reel (Sankalp, 2 Nov 2026): while it works, the
  // ones it has not reached yet wait in yellow and the ones it has been through go back to plain. Kept across its turns,
  // so "continue" picks up where it was; Clear in the chat starts over.
  @Published private(set) var reviewed: Set<Int> = []
  @Published private(set) var reviewStarted = false
  func resetReview() { reviewed = []; reviewStarted = false }

  // The paragraphs with a word inside a focus's span.
  func paragraphIds(_ f: AgentFocus) -> [Int] {
    paragraphs.filter { p in wordsOf(p).contains { w in guard let s = w.s else { return false }; return s < f.end && (w.e ?? s) > f.start } }.map(\.id)
  }
  func wordsOf(_ p: Paragraph) -> [WordView] { p.words.map { words[$0] } }
  var mainWordCount: Int { loaded.words.count }

  // Work over nearly the whole reel at once, such as the audit of all of it.
  func isWide(_ ids: [Int]) -> Bool { ids.count > 3 && Double(ids.count) >= Double(paragraphs.count) * 0.8 }
  // Waiting for Claude: it is working, has started reading the reel, and has not reached this paragraph yet.
  func awaitsClaude(_ id: Int) -> Bool { agentFocus != nil && reviewStarted && !reviewed.contains(id) }
  @Published var error: String? = nil { didSet { if let error, error != oldValue { Log.error("editor", error, args: ["project": .string(name)]) } } }
  @Published private(set) var thumbs: [String: (step: Double, images: [CGImage])] = [:]
  @Published private(set) var peaks: [String: [Float]] = [:]
  // The timeline's zoom (points per second) and Follow, saved for the next time the app opens.
  @Published var zoom: Double = UserDefaults.standard.object(forKey: "timelineZoom") as? Double ?? 24 {
    didSet { UserDefaults.standard.set(zoom, forKey: "timelineZoom") }
  }
  @Published var follow = UserDefaults.standard.object(forKey: "timelineFollow") as? Bool ?? true {
    didSet { UserDefaults.standard.set(follow, forKey: "timelineFollow") }
  }
  @Published private(set) var overlayVersion = 0
  @Published private(set) var busy = false
  // Claude is editing this reel (Sankalp, 2 Nov 2026): the chat's Claude is working on it, or an agent's tool calls
  // show what it works on. Sankalp's own edits wait until it is done, so the two never undo each other's work; playing,
  // reading, selecting, comments and exports still work. Kept from the live state by poll for the views.
  @Published private(set) var claudeEditing = false
  var editingNow: Bool { DirectChat.shared.isWorking(name) || agentFocus != nil }
  // What still runs while Claude edits: what only reads, the comments (they go to Claude) and an export.
  static func keepsReel(_ tool: String) -> Bool {
    tool.hasPrefix("get_") || tool.hasPrefix("list_") || ["add_comment", "edit_comment", "resolve_comment", "reopen_comment", "export", "reveal_in_finder", "open_project_folder"].contains(tool)
  }
  static let lockedNote = "Claude is editing this reel. Your edits wait until it is done, or press Stop in the chat"
  @Published var focus = false // the Distraction free layout: only the video
  // The card floating over the editor: a layer's settings above the layer that was clicked on the timeline, or the
  // Project or Chat card under the transcript's head. floatingAt is the click, in the editor's coordinates.
  enum Floating: Equatable { case animation(String), clip(String), overlay(String), project, chat, captions, voice }
  // REEL_EDITOR_FLOAT=project (or chat) opens that card at launch, for checking it in a snapshot.
  @Published var floating: Floating? = ["project": Floating.project, "chat": .chat, "captions": .captions, "voice": .voice][ProcessInfo.processInfo.environment["REEL_EDITOR_FLOAT"] ?? ""]
  @Published var floatingAt: CGPoint = .zero
  func show(_ f: Floating, at p: CGPoint) {
    if floating != nil && floating != f { floating = nil } // a different layer: the old card goes at once, the new one springs in
    floatingAt = p
    withAnimation(.cardOpen) { floating = f }
  }
  func toggle(_ f: Floating) { withAnimation(floating == f ? .cardClose : .cardOpen) { floating = floating == f ? nil : f } }
  func closeFloating() { withAnimation(.cardClose) { floating = nil } }

  let clock = Clock()
  let player = AVPlayer()
  private var revs: (Int, Int, Date?)
  private var timer: Timer?
  private var observer: Any?
  private var building = false

  var speed: Double { Compose.speedOf(loaded.project.edits) }
  var title: String { loaded.project.title ?? name }
  var flags: (captions: Bool, title: Bool) { exportFlags(loaded.project.edits, hasWords: loaded.hasAnyWords) }
  var live: Bool { loaded.project.edits.status == "live" }
  // Cuts an agent made from the chat that wait for Sankalp's approval: range cuts and words.
  var waitingCuts: Int { plan.rangeCuts.filter { $0.pending == true }.count + (loaded.project.edits.pendingWords?.count ?? 0) }
  var exportSize: CGSize { rc?.renderSize ?? CGSize(width: loaded.project.main.width, height: loaded.project.main.height) }

  init(_ loaded: Loaded) {
    self.name = loaded.project.name
    self.loaded = loaded
    self.plan = loaded.plan
    self.revs = Store.revs(loaded.project.name)
    derive()
  }

  func start() {
    observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] t in
      MainActor.assumeIsolated { self?.tick(t.seconds) }
    }
    timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.poll() } }
    Task { await rebuild() }
    Task { await loadMedia() }
    Task { await loadOverlayPeaks() }
    status = Store.status(name)
    // REEL_EDITOR_FLOAT=animation:a3 (or clip:c1, overlay:o1) opens that layer's card above the middle of the timeline.
    if let f = ProcessInfo.processInfo.environment["REEL_EDITOR_FLOAT"], let colon = f.firstIndex(of: ":") {
      let id = String(f[f.index(after: colon)...])
      floatingAt = CGPoint(x: 640, y: 640)
      floating = f.hasPrefix("animation") ? .animation(id) : f.hasPrefix("clip") ? .clip(id) : .overlay(id)
    }
    // REEL_EDITOR_FLOAT=captions opens the Captions card from the Captions layer's name, as a click there does.
    if floating == .captions || floating == .voice { floatingAt = CGPoint(x: 120, y: 860) }
    // REEL_EDITOR_SEEK=2.5 opens with the playhead there, for checking the preview at a moment in a snapshot.
    if let t = ProcessInfo.processInfo.environment["REEL_EDITOR_SEEK"].flatMap(Double.init) { DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.seek(t) } }
    // REEL_EDITOR_SELECT=words:5-9 or range:1.5-3 opens with that selection, for checking the selection menus in a snapshot.
    if let sel = ProcessInfo.processInfo.environment["REEL_EDITOR_SELECT"], let colon = sel.firstIndex(of: ":") {
      let nums = sel[sel.index(after: colon)...].split(separator: "-").compactMap { Double($0) }
      if nums.count == 2 {
        if sel.hasPrefix("words") { selectedWords = Int(nums[0])...Int(nums[1]) } else { selection = ReelCore.Range(s: nums[0], e: nums[1]) }
      }
      // cut:12.5 selects the cut at that time, with its handles.
      if sel.hasPrefix("cut"), let t = nums.first { selectedCut = plan.cuts.first { t >= $0.s && t <= $0.e } }
    }
  }

  func stop() {
    player.pause()
    timer?.invalidate()
    if let observer { player.removeTimeObserver(observer) }
    observer = nil
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Reading the project

  private func derive() {
    let edl = loaded.project.edits
    let mapped = mapWords(plan, loaded.words), cut = wordsCut(plan, edl, loaded.words)
    let waiting = Set(edl.pendingWords ?? [])
    // A word inside a range cut that waits for approval waits too, so it shows in amber like a word cut from the chat.
    let waitingRanges = plan.rangeCuts.filter { $0.pending == true }
    var all = loaded.words.enumerated().map { i, w in
      let mid = mapped[i].map { ($0.s + $0.e) / 2 }
      let inWaitingRange = mid.map { m in waitingRanges.contains { m >= $0.s && m < $0.e } } ?? false
      return WordView(id: i, text: edl.corrections[String(i)] ?? w.w, s: mapped[i]?.s, e: mapped[i]?.e, cut: cut[i], pending: waiting.contains(i) || (cut[i] && inWaitingRange))
    }
    // The transcript as the reel plays, clip by clip, every video's words (Sankalp, 2 Nov 2026), the same paragraphs
    // get_paragraphs gives an agent. A word of the project's own video played again in a later clip is shown there too.
    var shown = Set<Int>()
    var paras: [Paragraph] = []
    for p in transcriptLayout(loaded) {
      var ids: [Int] = []
      for w in p.words {
        if let i = w.index, shown.insert(i).inserted { ids.append(i) }
        // Another video's word, or a word of the project's own video played a second time: cut by its times.
        else { ids.append(all.count); all.append(WordView(id: all.count, text: w.w, s: w.s, e: w.e, cut: w.cut, pending: w.pending, extra: true)) }
      }
      if !ids.isEmpty || p.words.isEmpty { paras.append(Paragraph(id: paras.count, title: p.title, words: ids, clip: p.clip, source: p.source, label: p.label, clipStart: p.clipStart)) }
    }
    words = all
    let frame = exportSize
    captionStyle = Captions.style(edl, landscape: frame.width > frame.height)
    captionLines = flags.captions ? Captions.lines(loaded, plan, speed: speed, style: captionStyle, frame: frame) : []
    captionPictures = [:]
    extraWords = extraEditWords(plan, edl, loaded.extra)
    paragraphs = paras
  }

  func reloadFromDisk() async {
    do {
      loaded = try Store.load(name)
      plan = loaded.plan
      revs = Store.revs(name)
      derive()
      if let id = selectedAnimation, !loaded.animations.animations.contains(where: { $0.id == id }) { selectedAnimation = nil }
      await rebuild()
      Task { await loadOverlayPeaks() }
    } catch { self.error = String(describing: error) }
  }

  private func loadOverlayPeaks() async {
    for o in loaded.project.edits.audioOverlays ?? [] where overlayPeaks[o.file] == nil {
      if let p = try? await Media.peaks(URL(fileURLWithPath: o.file)) { overlayPeaks[o.file] = p }
    }
  }

  // Lays an audio file over the project from an edit time, chosen in an open panel; muteClip also silences that clip.
  func chooseOverlay(at start: Double, muteClip: String?) {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.audio, .mpeg4Audio, .mp3, .wav, .aiff, .mpeg4Movie, .quickTimeMovie]
    panel.message = "Choose a voice over or any audio. It is only read, never changed."
    guard panel.runModal() == .OK, let url = panel.url else { return }
    var args: [String: JSON] = ["path": .string(url.path), "start": .number(round3(max(0, min(start, plan.editDuration - 0.1))))]
    if let muteClip { args["mute_clip"] = .string(muteClip) }
    run("add_audio_overlay", args)
  }

  private func poll() {
    let was = status["state"]?.string
    status = Store.status(name)
    // An export whose process ended before it finished (the app quit, an agent's reel-mcp closed) would wait forever and
    // keep the export modal up: it is marked stopped, so the modal says so and can be closed.
    if status["state"]?.string == "exporting", Jobs.interrupted(name, kind: "export") {
      Store.setStatus(name, ["state": "error", "kind": "export", "progress": status["progress"] ?? 0, "message": "The export stopped before it finished: the app or the agent running it closed. Export again."])
      status = Store.status(name)
    }
    if status["state"]?.string == "exporting", !exportOpen { withAnimation(.cardOpen) { exportOpen = true } }
    let locked = editingNow
    if locked != claudeEditing {
      claudeEditing = locked
      if !locked && error == Self.lockedNote { error = nil }
      // A selection made before Claude started is let go, so no Cut or Comment menu stays up while it edits.
      if locked { selectedWords = nil; selection = nil; selectedAnimation = nil; if case .animation = floating { floating = nil }; if case .clip = floating { floating = nil }; if case .overlay = floating { floating = nil } }
    }
    // A transcription or an export that has just ended, from this app or an agent: a notification (Sankalp, 2 Nov 2026).
    if let was, was == "transcribing" || was == "exporting", let now = status["state"]?.string, now == "ready" || now == "error" {
      let export = status["kind"]?.string == "export"
      let what = export ? (now == "ready" ? "Export done" : "Export stopped") : (now == "ready" ? "Transcription done" : "Transcription stopped")
      Notify.send("\(what): \(title)", status["message"]?.string ?? "", project: name)
    }
    let f = Focus.read(name)
    if f != agentFocus {
      withAnimation(.easeOut(duration: 0.25)) {
        agentFocus = f
        if let f {
          let ids = paragraphIds(f)
          if !isWide(ids) {
            if f.action.hasPrefix("Reading") || f.action == "Applying trims" { reviewStarted = true }
            if reviewStarted { reviewed.formUnion(ids) }
          }
        }
      }
    }
    let now = Store.revs(name)
    if now.0 != revs.0 || now.1 != revs.1 || now.2 != revs.2 { revs = now; Task { await reloadFromDisk() } }
  }

  // The composition and the player item again, the playhead kept where it was in edit time.
  func rebuild() async {
    if building { return }
    building = true
    defer { building = false }
    let t = clock.time, wasPlaying = clock.playing
    do {
      let rc = try await Compose.build(loaded)
      player.replaceCurrentItem(with: rc.playerItem())
      self.rc = rc
      overlayVersion += 1
      seek(t)
      if wasPlaying { player.play() }
      error = nil
    } catch {
      player.replaceCurrentItem(with: nil)
      self.rc = nil
      self.error = String(describing: error)
    }
  }

  private func loadMedia() async {
    let sources = [loaded.project.main] + loaded.project.edits.sources
    for s in sources where peaks[s.id] == nil {
      let cache = Store.dir(name).appendingPathComponent("media/peaks-\(s.id).json")
      struct Cached: Codable { var file: String; var peaks: [Float] }
      if let c = try? Store.read(Cached.self, cache), c.file == s.file { peaks[s.id] = c.peaks }
      else if let p = try? await Media.peaks(URL(fileURLWithPath: s.file)) {
        peaks[s.id] = p
        try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Store.write(Cached(file: s.file, peaks: p), cache)
      }
    }
    for s in sources where thumbs[s.id] == nil {
      let gen = AVAssetImageGenerator(asset: AVURLAsset(url: URL(fileURLWithPath: s.file)))
      gen.appliesPreferredTrackTransform = true
      gen.maximumSize = CGSize(width: 192, height: 192)
      gen.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
      gen.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
      let step = max(1, s.duration / 160)
      let times = stride(from: step / 2, to: s.duration, by: step).map { CMTime(seconds: $0, preferredTimescale: 600) }
      var images: [CGImage] = []
      for await r in gen.images(for: times) { if let img = try? r.image { images.append(img) } else if let last = images.last { images.append(last) } }
      thumbs[s.id] = (step, images)
    }
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Playing

  private func tick(_ out: Double) {
    guard out.isFinite else { return }
    let t = editOf(plan, out * speed)
    clock.time = t
    clock.playing = player.rate != 0
    let w = words.filter { !$0.cut && ($0.s ?? .infinity) <= t + 0.01 }.max { ($0.s ?? 0) < ($1.s ?? 0) }
    let cw = w.flatMap { ($0.e ?? 0) + 0.6 >= t ? $0.id : nil }
    if cw != currentWord { currentWord = cw }
  }

  func seek(_ t: Double) {
    let edit = max(0, min(plan.editDuration, t))
    let out = outputOf(plan, edit) / speed
    player.seek(to: CMTime(seconds: out, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    clock.time = edit
  }

  func togglePlay() {
    if player.rate != 0 { player.pause() }
    else {
      if let rc, (player.currentTime().seconds) >= rc.duration - 0.05 { seek(0) }
      player.play()
    }
    clock.playing = player.rate != 0
  }

  func step(_ seconds: Double) { seek(clock.time + seconds) }

  // ------------------------------------------------------------------------------------------------------------------
  // Editing, through the same tools an agent calls

  func run(_ tool: String, _ args: [String: JSON] = [:], then: ((JSON) -> Void)? = nil) {
    if editingNow && !Self.keepsReel(tool) { error = Self.lockedNote; return }
    var a = args
    a["project"] = .string(name)
    busy = true
    Task {
      let reply = await callTool(tool, .object(a))
      busy = false
      switch reply {
      case .ok(let result): await reloadFromDisk(); then?(result)
      case .failure(_, let message): error = message
      }
    }
  }

  var selectedWordRange: (Double, Double)? {
    guard let r = selectedWords else { return nil }
    let ws = words[r].filter { $0.s != nil }
    guard let a = ws.first?.s, let b = ws.last?.e else { return nil }
    return (a, b)
  }

  // Words of the other videos have no index for delete_words, so a selection with any of them is cut by its times.
  var selectionHasExtra: Bool { selectedWords.map { $0.upperBound >= mainWordCount } ?? false }
  func cutSelection() {
    if let r = selectedWords, selectionHasExtra { if let (a, b) = selectedWordRange { run("cut_range", ["start": .number(a), "end": .number(b)]) }; selectedWords = nil }
    else if let r = selectedWords { run("delete_words", ["indexes": .array(r.map { .number(Double($0)) })]); selectedWords = nil }
    else if let s = selection { run("cut_range", ["start": .number(s.s), "end": .number(s.e)]); selection = nil }
  }

  func restoreSelection() {
    if let r = selectedWords {
      if !selectionHasExtra { run("restore_words", ["indexes": .array(r.map { .number(Double($0)) })]) }
      if let (a, b) = selectedWordRange { run("restore_range", ["start": .number(a), "end": .number(b)]) }
      selectedWords = nil
    } else if let s = selection { run("restore_range", ["start": .number(s.s), "end": .number(s.e)]); selection = nil }
  }

  func splitAtPlayhead() { run("split_clip", ["at": .number(clock.time)]) }

  func deleteClipAtPlayhead() {
    guard let c = locate(plan, clock.time)?.clip else { return }
    run("delete_clip", ["clip": .string(c.id)])
  }

  // Asks the chat's Claude to name the project from its script by the rule books' naming rule and rename it (Sankalp,
  // 2 Nov 2026). The rename copies the project file under the new name and checks it before the old one goes to the
  // Trash, and the tab, its chat and the playhead follow the project to its new name.
  func nameFromScript() {
    if editingNow { error = Self.lockedNote; return }
    if UserDefaults.standard.string(forKey: "chatDock") == "side" { UserDefaults.standard.set(true, forKey: "chatSide") }
    else if floating != .chat { toggle(.chat) }
    let extra = "\n\nRead the script (get_project, which also says when the video was recorded, and get_words) and the naming rule in the rule books (get_rules if you have not read it). Make the project's name by that rule. Where the rule books give none, use the date the video was recorded as year-month-day, then two to four words saying what the video is about, lowercase with dashes, for example 2026-11-02-spare-imac-for-claude. Then call rename_project with that name as the title, and tell Sankalp the old name and the new one in one line. The app copies the project file under the new name and checks it before the old file goes to the Trash, and its tab follows."
    DirectChat.shared.send("Name this project from its script, by the naming rule in the rule books.", context: AppModel.shared.screenContext(), extra: extra)
  }

  func addAnimation(_ kind: AnimationKind) {
    let start = round3(clock.time)
    var args: [String: JSON] = ["kind": .string(kind.id), "start": .number(start), "end": .number(round3(min(start + kind.defaultLength, max(start + 0.5, plan.editDuration)))), "side": "right"]
    switch kind.id {
    case "text-pop": args["text"] = "Big idea"
    case "lower-third": args["text"] = "Sankalp Sinha"; args["subtitle"] = "Founder, NextDoor.Company"
    case "counter": args["from"] = 0; args["to"] = 100; args["text"] = "What it counts"
    case "progress-bar": args["text"] = "Progress"; args["to"] = 80
    case "callout": args["text"] = "Look at this"
    case "checklist": args["text"] = "First point\nSecond point\nThird point"
    case "text": args["text"] = "Your text"; args["side"] = "center"
    default: break
    }
    run("add_animation", args) { [weak self] r in self?.selectedAnimation = r["created"]?.string }
  }

  // Points a moved or deleted source file at where it is now (relink_source), chosen in an open panel.
  func relink(_ source: String = "main") {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.movie, .audio, .mpeg4Movie, .quickTimeMovie]
    panel.message = "Find the file this project was made from. It is only read, never changed."
    if panel.runModal() == .OK, let u = panel.url { run("relink_source", ["source": .string(source), "path": .string(u.path)]) }
  }

  // Lays a face video over the reel at the playhead, in a rounded window (add_face_overlay).
  func chooseFace() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.mpeg4Movie, .quickTimeMovie, .movie]
    panel.message = "Choose a video with a face and its voice. It is only read, never changed."
    if panel.runModal() == .OK, let u = panel.url { run("add_face_overlay", ["path": .string(u.path), "start": .number(round3(clock.time))]) }
  }

  func undo() { run("undo") }
  func redo() { run("redo") }

  // ------------------------------------------------------------------------------------------------------------------
  // Long jobs

  // Transcribes every video of the reel that has no words yet, one after another (Sankalp, 2 Nov 2026).
  func transcribe() {
    let n = name
    Log.write("app", "transcribe", args: ["project": .string(n)])
    Store.setStatus(n, ["state": "transcribing", "kind": "transcribe", "message": "Starting", "pid": .number(Double(getpid()))])
    status = Store.status(n)
    Task.detached { do { try await Jobs.transcribeAll(n) } catch { await MainActor.run { self.error = String(describing: error) } } }
  }

  // Export from the top bar's button or Cmd E: asks where to save the MP4, the project's exports folder by default.
  func closeExport() { withAnimation(.cardClose) { exportOpen = false } }

  func chooseExport() {
    guard status["state"]?.string != "exporting" else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.mpeg4Movie]
    panel.nameFieldStringValue = "\(name)-edited.mp4"
    panel.directoryURL = Jobs.defaultExportURL(name).deletingLastPathComponent()
    if panel.runModal() == .OK, let u = panel.url { export(to: u) }
  }

  func export(to url: URL) {
    let n = name
    Log.write("app", "export", args: ["project": .string(n), "file": .string(url.path)])
    Store.setStatus(n, ["state": "exporting", "kind": "export", "progress": 0, "message": "Starting", "pid": .number(Double(getpid()))])
    status = Store.status(n)
    withAnimation(.cardOpen) { exportOpen = true }
    // The modal shows how it went and offers Show in Finder, so Finder no longer opens on its own.
    Task { _ = try? await Jobs.export(n, to: url) }
  }
}
