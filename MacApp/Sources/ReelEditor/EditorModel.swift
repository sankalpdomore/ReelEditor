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
struct WordView: Identifiable { let id: Int; let text: String; let s: Double?; let e: Double?; let cut: Bool; var pending = false; var extra = false
  var caption: String? = nil // what the captions say over this word instead, from a caption rewrite (edit_caption)
  var captionId: String? = nil // that rewrite's id
  var captionEnd = false // the last word of the rewrite in its paragraph, where the transcript shows the caption's words
  var take: String? = nil // a word a new take says over (Record new audio): switched off, its overlay's id
  var takeOf: String? = nil // a word the new take itself says, its overlay's id
  var takeFirst = false, takeLast = false // the take's first and last word, the ends of its green band
  var placeholder = false // New take, standing for the take's words while they are found
}

// Record new audio (Sankalp, 21 Nov 2026): the words picked, edit seconds, while the recording card is open.
struct RetakeRequest: Identifiable, Equatable { let id = UUID(); let start: Double; let end: Double; let words: String }
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
  @Published var retake: RetakeRequest? = nil // the recording card, open over the words picked
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
      // With REEL_EDITOR_RETAKE=1 the selected words open the Record new audio card.
      if ProcessInfo.processInfo.environment["REEL_EDITOR_RETAKE"] == "1", let r = selectedWords, let (a, b) = selectedWordRange {
        retake = RetakeRequest(start: a, end: b, words: words[r].filter { !$0.cut }.map(\.text).joined(separator: " "))
        selectedWords = nil
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
    // Record new audio (Sankalp, 21 Nov 2026): the words a new take says over are switched off, and the take's own words
    // take their place in the transcript as words of their own, in green after the last of them, so each can be selected,
    // its caption edited, cut, and lit by the playhead. A cut word is not under a take.
    let takes = (edl.audioOverlays ?? []).filter(\.isTake)
    if !takes.isEmpty {
      for k in all.indices where !all[k].cut {
        guard let s = all[k].s, let e = all[k].e else { continue }
        let m = (s + e) / 2
        if let o = takes.first(where: { m >= $0.start && m < $0.editEnd }) { all[k].take = o.id }
      }
      let spoken = extraEditWords(plan, edl, loaded.extra)
      var placed = Set<String>()
      for pi in paras.indices {
        var ids = paras[pi].words
        for o in takes where !placed.contains(o.id) {
          guard let at = ids.lastIndex(where: { all[$0].take == o.id }) else { continue }
          placed.insert(o.id)
          let said = spoken.filter { $0.from == o.id }
          var added: [Int] = []
          for (k, w) in said.enumerated() {
            let mid = (w.s + w.e) / 2
            var v = WordView(id: all.count, text: w.w, s: w.s, e: w.e, cut: plan.cuts.contains { mid >= $0.s && mid < $0.e }, extra: true)
            v.takeOf = o.id; v.takeFirst = k == 0; v.takeLast = k == said.count - 1
            added.append(all.count); all.append(v)
          }
          // While its words are found, the take is one placeholder word, New take, that selects it all the same.
          if said.isEmpty {
            var v = WordView(id: all.count, text: AudioOverlay.takeLabel, s: o.start, e: o.editEnd, cut: false, extra: true)
            v.takeOf = o.id; v.takeFirst = true; v.takeLast = true; v.placeholder = true
            added.append(all.count); all.append(v)
          }
          ids.insert(contentsOf: added, at: at + 1)
        }
        paras[pi] = Paragraph(id: paras[pi].id, title: paras[pi].title, words: ids, clip: paras[pi].clip, source: paras[pi].source, label: paras[pi].label, clipStart: paras[pi].clipStart)
      }
    }
    // The caption rewrites over each word, by the word's middle, as the captions lay them in: over a take, its own words.
    if let rw = edl.captionRewrites, !rw.isEmpty {
      for k in all.indices where all[k].take == nil && !all[k].placeholder {
        guard let s = all[k].s, let e = all[k].e else { continue }
        let m = (s + e) / 2
        if let r = rw.first(where: { m >= $0.start && m < $0.end }) { all[k].caption = r.text; all[k].captionId = r.id }
      }
      for p in paras {
        let live = p.words.filter { all[$0].take == nil }
        for (k, id) in live.enumerated() where all[id].captionId != nil {
          if k == live.count - 1 || all[live[k + 1]].captionId != all[id].captionId { all[id].captionEnd = true }
        }
      }
    }
    words = all
    // A selection of words that are gone (a take's words after Remove new audio) is dropped, so nothing reads past the
    // end of the list (Sankalp, 22 Nov 2026: removing a take crashed the app).
    if let r = selectedWords, r.upperBound >= words.count { selectedWords = nil }
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
      Task { await warmVoice() }
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

  // The captions drawn again, after the caption timing changes in App settings' Developer card.
  func redrawCaptions() { derive() }

  // Each video's voice levels, read off the main thread the first time a file is in the project, then the captions drawn
  // again fitted to them (Voice.swift).
  private var voiceRead = Set<String>()
  private func warmVoice() async {
    let files = Voice.files(loaded).filter { !voiceRead.contains($0) }
    guard !files.isEmpty else { return }
    voiceRead.formUnion(files)
    await Task.detached(priority: .utility) { Voice.warm(files) }.value
    derive()
  }

  private func loadMedia() async {
    await warmVoice()
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
    // A word a new take says over is never lit; inside a take its own words are.
    let w = words.filter { !$0.cut && $0.take == nil && !$0.placeholder && ($0.s ?? .infinity) <= t + 0.01 }.max { ($0.s ?? 0) < ($1.s ?? 0) }
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

  // The picture of some words played with no sound while a take is recorded, at the pace they were said (the reel's speed
  // taken off), from a second before them, so the take can follow the lips.
  func playAlong(from t: Double) {
    seek(editOf(plan, max(0, outputOf(plan, t) - 1)))
    player.isMuted = true
    player.playImmediately(atRate: Float(1 / speed))
    clock.playing = true
  }

  // And the reel played as it is, with its sound, from a second before some words: to hear a take in place.
  func playFrom(_ t: Double) {
    player.pause()
    player.isMuted = false
    seek(editOf(plan, max(0, outputOf(plan, t) - 1)))
    player.play()
    clock.playing = true
  }

  func stopPlaying() { player.pause(); player.isMuted = false; clock.playing = false }

  // A new take's words come back from the transcriber as spoken, often with no full stops or capitals. Once they are in,
  // they go to Claude as a comment on the take, to fix their punctuation by the rule books without changing a word
  // (Sankalp, 21 Nov 2026). It waits up to five minutes for the words, and gives up when the take comes off first.
  func askClaudeToPunctuate(take id: String) {
    Task { @MainActor in
      for _ in 0..<600 {
        guard loaded.project.edits.audioOverlays?.contains(where: { $0.id == id }) == true else { return }
        let ws = extraWords.filter { $0.from == id }
        if let a = ws.first?.s, let b = ws.last?.e {
          let said = ws.map(\.w).joined(separator: " ")
          let note = "I recorded this as a new take. Its captions are the transcriber's words as I said them: fix their full stops, commas, question marks and capitals with edit_caption by the rule books, so they read as sentences. Keep every word I said."
          let on = "the new take \"\(said)\" (\(id), at \(timecode(a).components(separatedBy: ".")[0]))"
          run("add_comment", ["start": .number(round3(a)), "end": .number(round3(b)), "comment": .string(note)]) { res in
            DirectChat.shared.sendComment(note, on: on, id: res["comment"]?["id"]?.string)
          }
          return
        }
        try? await Task.sleep(for: .milliseconds(500))
      }
    }
  }

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
    guard let r = selectedWords, r.upperBound < words.count else { return nil }
    let ws = words[r].filter { $0.s != nil }
    guard let a = ws.first?.s, let b = ws.last?.e else { return nil }
    return (a, b)
  }

  // Words of the other videos have no index for delete_words, so a selection with any of them is cut by its times.
  var selectionHasExtra: Bool { selectedWords.map { $0.upperBound >= mainWordCount } ?? false }

  // The kind of a word, for a selection to stay among one kind: the project's own video's, another video's, or a take's.
  // A word a new take says over is switched off and has none: it is never selected.
  func kind(_ id: Int) -> String? {
    guard words.indices.contains(id) else { return nil }
    let w = words[id]
    if w.take != nil { return nil }
    if let t = w.takeOf { return "take:" + t }
    return id < mainWordCount ? "main" : "other"
  }

  // The new takes a selection is in.
  var selectedTakes: [String] {
    guard let r = selectedWords, r.upperBound < words.count else { return [] }
    return Array(Set(words[r].compactMap { $0.takeOf ?? $0.take })).sorted()
  }
  func cutSelection() {
    if let r = selectedWords, selectionHasExtra { if let (a, b) = selectedWordRange { run("cut_range", ["start": .number(a), "end": .number(b)]) }; selectedWords = nil }
    else if let r = selectedWords { run("delete_words", ["indexes": .array(r.map { .number(Double($0)) })]); selectedWords = nil }
    else if let s = selection { run("cut_range", ["start": .number(s.s), "end": .number(s.e)]); selection = nil }
    else if selectedCut != nil { restoreSelection() } // Delete on a selected cut takes the cut away (Sankalp, 6 Nov 2026)
  }

  func restoreSelection() {
    if let r = selectedWords {
      if !selectionHasExtra { run("restore_words", ["indexes": .array(r.map { .number(Double($0)) })]) }
      if let (a, b) = selectedWordRange { run("restore_range", ["start": .number(a), "end": .number(b)]) }
      selectedWords = nil
    } else if let s = selection { run("restore_range", ["start": .number(s.s), "end": .number(s.e)]); selection = nil }
    else if let c = selectedCut {
      // A cut on the timeline can be words cut as well as a range, so both come back.
      let cutWords = words.filter { w in w.cut && !w.extra && w.id < mainWordCount && (w.s ?? -1) >= c.s - 0.001 && (w.e ?? .infinity) <= c.e + 0.001 }.map(\.id)
      if !cutWords.isEmpty { run("restore_words", ["indexes": .array(cutWords.map { .number(Double($0)) })]) }
      run("restore_range", ["start": .number(c.s), "end": .number(c.e)]); selectedCut = nil
    }
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

  // Asks the chat's Claude to find the project's missing files on this Mac and link them again (find_source), with
  // leave from Find missing videos in App settings (Sankalp, 15 Nov 2026).
  func askClaudeToFind() {
    if UserDefaults.standard.string(forKey: "chatDock") == "side" { UserDefaults.standard.set(true, forKey: "chatSide") }
    else if floating != .chat { toggle(.chat) }
    let extra = "\n\nCall find_source with relink true. It links every file whose name and length match one file on this Mac. For any file it could not link, list its candidates in a few lines (where each one is, its length, when it changed) and ask Sankalp which one to link, then link his pick with relink_source path. If nothing was found, say which files and where they were, and ask him where they are now."
    DirectChat.shared.send("My videos for this project are missing. Find them on this Mac and link them again.", context: AppModel.shared.screenContext(), extra: extra)
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
