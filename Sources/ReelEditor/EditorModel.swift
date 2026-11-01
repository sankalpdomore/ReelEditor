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

struct WordView: Identifiable { let id: Int; let text: String; let s: Double?; let e: Double?; let cut: Bool; var pending = false } // pending: cut from the chat, waiting for approval
// A paragraph of the transcript: a section heading when one starts there, and a run of word indexes.
struct Paragraph: Identifiable { let id: Int; let title: String?; let words: Swift.Range<Int> }

@MainActor final class EditorModel: ObservableObject {
  let name: String
  @Published private(set) var loaded: Loaded
  @Published private(set) var plan: Plan
  @Published private(set) var rc: ReelComposition?
  @Published private(set) var words: [WordView] = []
  @Published private(set) var captionGroups: [Overlay.CaptionGroup] = []
  @Published private(set) var paragraphs: [Paragraph] = []
  @Published private(set) var extraWords: [ExtraEditWord] = [] // the words of the added clips and the voice overs, edit time
  @Published private(set) var overlayPeaks: [String: [Float]] = [:] // the waveform of each audio overlay file
  @Published var prompt: NamePrompt? = nil
  @Published private(set) var currentWord: Int? = nil
  @Published var selection: ReelCore.Range? = nil // edit time
  @Published var selectedWords: ClosedRange<Int>? = nil
  @Published var selectedAnimation: String? = nil
  @Published private(set) var status: JSON = [:]
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
  @Published var focus = false // the Distraction free layout: only the video
  // The card floating over the editor: a layer's settings above the layer that was clicked on the timeline, or the
  // Project or Chat card under the transcript's head. floatingAt is the click, in the editor's coordinates.
  enum Floating: Equatable { case animation(String), clip(String), overlay(String), project, chat }
  // REEL_EDITOR_FLOAT=project (or chat) opens that card at launch, for checking it in a snapshot.
  @Published var floating: Floating? = ["project": Floating.project, "chat": .chat][ProcessInfo.processInfo.environment["REEL_EDITOR_FLOAT"] ?? ""]
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
    // REEL_EDITOR_SELECT=words:5-9 or range:1.5-3 opens with that selection, for checking the selection menus in a snapshot.
    if let sel = ProcessInfo.processInfo.environment["REEL_EDITOR_SELECT"], let colon = sel.firstIndex(of: ":") {
      let nums = sel[sel.index(after: colon)...].split(separator: "-").compactMap { Double($0) }
      if nums.count == 2 {
        if sel.hasPrefix("words") { selectedWords = Int(nums[0])...Int(nums[1]) } else { selection = ReelCore.Range(s: nums[0], e: nums[1]) }
      }
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
    words = loaded.words.enumerated().map { i, w in WordView(id: i, text: edl.corrections[String(i)] ?? w.w, s: mapped[i]?.s, e: mapped[i]?.e, cut: cut[i], pending: waiting.contains(i)) }
    captionGroups = flags.captions ? Overlay.captionGroups(loaded, plan, speed: speed) : []
    extraWords = extraEditWords(plan, edl, loaded.extra)
    // A new paragraph at every section, and after a sentence once a paragraph has 40 words (or at 90 words regardless).
    let starts = Dictionary((edl.sections ?? []).map { ($0.from, $0.title) }, uniquingKeysWith: { a, _ in a })
    var paras: [Paragraph] = []
    var from = 0
    for i in words.indices {
      let n = i - from
      if i > from && (starts[i] != nil || (n >= 40 && words[i - 1].text.last.map { ".?!".contains($0) } == true) || n >= 90) {
        paras.append(Paragraph(id: paras.count, title: starts[from], words: from..<i)); from = i
      }
    }
    if from < words.count { paras.append(Paragraph(id: paras.count, title: starts[from], words: from..<words.count)) }
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
    status = Store.status(name)
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
    let w = words.last { !$0.cut && ($0.s ?? .infinity) <= t + 0.01 }
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

  func cutSelection() {
    if let r = selectedWords { run("delete_words", ["indexes": .array(r.map { .number(Double($0)) })]); selectedWords = nil }
    else if let s = selection { run("cut_range", ["start": .number(s.s), "end": .number(s.e)]); selection = nil }
  }

  func restoreSelection() {
    if let r = selectedWords {
      run("restore_words", ["indexes": .array(r.map { .number(Double($0)) })])
      if let (a, b) = selectedWordRange { run("restore_range", ["start": .number(a), "end": .number(b)]) }
      selectedWords = nil
    } else if let s = selection { run("restore_range", ["start": .number(s.s), "end": .number(s.e)]); selection = nil }
  }

  func splitAtPlayhead() { run("split_clip", ["at": .number(clock.time)]) }

  func deleteClipAtPlayhead() {
    guard let c = locate(plan, clock.time)?.clip else { return }
    run("delete_clip", ["clip": .string(c.id)])
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

  func transcribe() {
    let n = name
    Log.write("app", "transcribe", args: ["project": .string(n)])
    Store.setStatus(n, ["state": "transcribing", "kind": "transcribe", "message": "Starting"])
    status = Store.status(n)
    Task.detached { do { _ = try await Jobs.transcribe(n) } catch { await MainActor.run { self.error = String(describing: error) } } }
  }

  // Export from the top bar's button or Cmd E: asks where to save the MP4, the project's exports folder by default.
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
    Store.setStatus(n, ["state": "exporting", "kind": "export", "progress": 0, "message": "Starting"])
    status = Store.status(n)
    Task {
      do { let r = try await Jobs.export(n, to: url); if let f = r["file"]?.string { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f)]) } }
      catch { self.error = String(describing: error) }
    }
  }
}
