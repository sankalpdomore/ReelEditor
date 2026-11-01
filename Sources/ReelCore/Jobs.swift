// The two long jobs: transcribing the speech for word timings (WhisperX, the same script the web editor uses) and
// exporting the edit to an MP4. Both report through the project's status.json, which the app shows and get_status reads.
import AVFoundation
import Foundation

public enum Jobs {
  // ------------------------------------------------------------------------------------------------------------------
  // Transcription

  struct Settings: Decodable { var whisperxPython: String?; var whisperxScript: String? }
  static var settings: Settings { (try? Store.read(Settings.self, Store.root.appendingPathComponent("settings.json"))) ?? Settings() }

  static func firstFile(_ candidates: [String?]) -> String? {
    candidates.compactMap { $0 }.map { ($0 as NSString).expandingTildeInPath }.first { FileManager.default.isExecutableFile(atPath: $0) || FileManager.default.fileExists(atPath: $0) }
  }

  public static func whisperx() -> (python: String, script: String)? {
    let env = ProcessInfo.processInfo.environment
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    let python = firstFile([env["REEL_WHISPERX_PYTHON"], settings.whisperxPython, "~/Coding projects/WhisperX/venv/bin/python"])
    let script = firstFile([env["REEL_WHISPERX_SCRIPT"], settings.whisperxScript,
                            Bundle.main.resourceURL?.appendingPathComponent("transcribe_whisperx.py").path,
                            exe.appendingPathComponent("../Resources/transcribe_whisperx.py").standardized.path,
                            exe.appendingPathComponent("../../Resources/transcribe_whisperx.py").standardized.path])
    guard let python, let script else { return nil }
    return (python, script)
  }

  static func run(_ exe: String, _ args: [String]) async throws -> (Int32, String) {
    try await withCheckedThrowingContinuation { cont in
      let p = Process()
      p.executableURL = URL(fileURLWithPath: exe)
      p.arguments = args
      let err = Pipe()
      p.standardError = err
      p.standardOutput = FileHandle.nullDevice
      p.terminationHandler = { proc in
        let text = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        cont.resume(returning: (proc.terminationStatus, String(text.suffix(600))))
      }
      do { try p.run() } catch { cont.resume(throwing: ToolError("transcribe_failed", "Could not start \(exe): \(error.localizedDescription)")) }
    }
  }

  public static func transcribe(_ name: String) async throws -> Int {
    let l = try Store.load(name)
    guard l.project.main.hasAudio else { throw ToolError("no_audio", "The video has no sound to transcribe") }
    let words = try await words(name, of: l.project.main.file, script: nil, what: "the video")
    try Store.saveWords(name, words, engine: "whisperx")
    return words.count
  }

  // The words of an added video or an audio overlay, kept in media/words-<hash>.json. With script, the exact words are
  // placed on the audio (WhisperX's force align mode), which spells names right and is much faster.
  public static func transcribeFile(_ name: String, file: String, script: String?, what: String) async throws -> Int {
    let words = try await words(name, of: file, script: script, what: what)
    try Store.withLock(name) { try Store.write(Transcript(engine: script == nil ? "whisperx" : "whisperx-align", words: words), Store.wordsFile(name, file)) }
    return words.count
  }

  static func words(_ name: String, of file: String, script: String?, what: String) async throws -> [Word] {
    guard let wx = whisperx() else { throw ToolError("no_transcriber", "WhisperX was not found. Set whisperxPython (and whisperxScript) in \(Store.root.path)/settings.json, or import a transcript with import_transcript") }
    let media = Store.dir(name).appendingPathComponent("media", isDirectory: true)
    try FileManager.default.createDirectory(at: media, withIntermediateDirectories: true)
    let key = UUID().uuidString.prefix(8)
    let wav = media.appendingPathComponent("audio-\(key).wav"), out = media.appendingPathComponent("words-\(key).raw.json")
    let scriptFile = media.appendingPathComponent("script-\(key).txt")
    defer { for f in [wav, out, scriptFile] { try? FileManager.default.removeItem(at: f) } }
    Store.setStatus(name, ["state": "transcribing", "kind": "transcribe", "message": .string("Reading the sound of \(what)")])
    do {
      try await Media.writeWav(URL(fileURLWithPath: file), to: wav)
      if let script { try script.write(to: scriptFile, atomically: true, encoding: .utf8) }
      Store.setStatus(name, ["state": "transcribing", "kind": "transcribe", "message": .string(script == nil ? "WhisperX is listening to \(what), a minute or two" : "Placing the script on \(what)")])
      let (code, stderr) = try await run(wx.python, [wx.script, wav.path, out.path] + (script == nil ? [] : [scriptFile.path]))
      guard code == 0 else { throw ToolError("transcribe_failed", "WhisperX stopped with code \(code): \(stderr)") }
      let words = try Store.read([Word].self, out)
      Store.setStatus(name, ["state": "ready", "kind": "transcribe", "message": .string("\(words.count) words from \(what)")])
      return words
    } catch {
      Store.setStatus(name, ["state": "error", "kind": "transcribe", "message": .string(String(describing: error).prefix(400).description)])
      throw error
    }
  }

  // ------------------------------------------------------------------------------------------------------------------
  // Export

  // Exports go beside the project file, in "<name> exports".
  public static func defaultExportURL(_ name: String) -> URL { Store.exportsDir(name).appendingPathComponent("\(name)-edited.mp4") }

  static func session(_ asset: AVAsset, _ preset: String, to url: URL, type: AVFileType) throws -> AVAssetExportSession {
    guard let s = AVAssetExportSession(asset: asset, presetName: preset) else { throw ToolError("export_failed", "Could not start an export session") }
    s.outputURL = url
    s.outputFileType = type
    return s
  }

  // Runs an export session, reporting its progress as the part from `from` to `to` of the whole export.
  static func run(_ session: AVAssetExportSession, _ name: String, from: Double, to: Double, _ what: String) async throws {
    let ticker = Task {
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: 500_000_000)
        if Task.isCancelled { break } // woken by the cancel: the export is over, its own status follows
        let p = from + (to - from) * Double(session.progress)
        Store.setStatus(name, ["state": "exporting", "kind": "export", "progress": .number(p), "message": .string("\(what) \(Int(p * 100))%")])
      }
    }
    await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in session.exportAsynchronously { c.resume() } }
    ticker.cancel()
    await ticker.value
    guard session.status == .completed else { throw ToolError("export_failed", session.error?.localizedDescription ?? "The export did not finish") }
  }

  public static func export(_ name: String, to target: URL? = nil) async throws -> JSON { try await export(name, to: target, captions: nil, title: nil) }

  // captions and title override the project's settings for this export only.
  public static func export(_ name: String, to target: URL?, captions: Bool?, title: Bool?) async throws -> JSON {
    let l = try Store.load(name)
    let out = target ?? defaultExportURL(name)
    if out.standardizedFileURL.path == URL(fileURLWithPath: l.project.main.file).standardizedFileURL.path || l.project.edits.sources.contains(where: { $0.file == out.path }) {
      throw ToolError("invalid_path", "The export cannot overwrite a source video")
    }
    Store.setStatus(name, ["state": "exporting", "kind": "export", "progress": 0, "message": "Building the composition"])
    do {
      try FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? FileManager.default.removeItem(at: out)
      let rc = try await Compose.build(l)
      // The layer tree is made on the main thread and committed there, Core Animation renders it from there.
      let tool = await MainActor.run { () -> AVVideoCompositionCoreAnimationTool in
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let parent = CALayer(), video = CALayer()
        parent.frame = CGRect(origin: .zero, size: rc.renderSize)
        video.frame = parent.frame
        parent.addSublayer(video)
        parent.addSublayer(Overlay.layer(l, rc, contentsScale: 1, captions: true, captionsOn: captions, titleOn: title))
        CATransaction.commit()
        CATransaction.flush()
        return AVVideoCompositionCoreAnimationTool(postProcessingAsVideoLayer: video, in: parent)
      }
      if rc.customCompositor {
        // AVFoundation's animation tool draws nothing but white over a custom compositor's frames, so a reel drawn by
        // ReelCompositor is exported in two passes: the composed picture and the mixed sound to a ProRes file beside the
        // export, then that file with the captions, title and animations laid on by the animation tool.
        let mid = out.deletingLastPathComponent().appendingPathComponent(".\(name)-pass1-\(UUID().uuidString.prefix(8)).mov")
        defer { try? FileManager.default.removeItem(at: mid) }
        let prores = AVAssetExportSession.allExportPresets().contains(AVAssetExportPresetAppleProRes422LPCM)
        let first = try session(rc.composition, prores ? AVAssetExportPresetAppleProRes422LPCM : AVAssetExportPresetHighestQuality, to: mid, type: .mov)
        first.videoComposition = rc.videoComposition
        first.audioMix = rc.audioMix
        first.audioTimePitchAlgorithm = .spectral
        try await run(first, name, from: 0, to: 0.6, "Drawing the picture")
        let asset = AVURLAsset(url: mid, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
        let comp = AVMutableComposition()
        let range = CMTimeRange(start: .zero, duration: try await asset.load(.duration))
        guard let v = try await asset.loadTracks(withMediaType: .video).first, let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ToolError("export_failed", "The first pass has no picture") }
        try vt.insertTimeRange(range, of: v, at: .zero)
        if let a = try await asset.loadTracks(withMediaType: .audio).first, let at = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) { try at.insertTimeRange(range, of: a, at: .zero) }
        let vc = AVMutableVideoComposition()
        vc.renderSize = rc.renderSize
        vc.frameDuration = CMTime(value: 1, timescale: 30)
        let ins = AVMutableVideoCompositionInstruction()
        ins.timeRange = range
        ins.layerInstructions = [AVMutableVideoCompositionLayerInstruction(assetTrack: vt)]
        vc.instructions = [ins]
        vc.animationTool = tool
        let second = try session(comp, AVAssetExportPresetHighestQuality, to: out, type: .mp4)
        second.videoComposition = vc
        second.shouldOptimizeForNetworkUse = true
        try await run(second, name, from: 0.6, to: 1, "Laying on the captions and animations")
      } else {
        let vc = rc.videoComposition
        vc.animationTool = tool
        let s = try session(rc.composition, AVAssetExportPresetHighestQuality, to: out, type: .mp4)
        s.videoComposition = vc
        s.audioMix = rc.audioMix
        s.audioTimePitchAlgorithm = .spectral
        s.shouldOptimizeForNetworkUse = true
        try await run(s, name, from: 0, to: 1, "Rendering")
      }
      let result: JSON = ["file": .string(out.path), "seconds": .number(round3(rc.duration)), "width": .number(rc.renderSize.width), "height": .number(rc.renderSize.height),
                          "captions": .bool(captions ?? exportFlags(l.project.edits, hasWords: l.hasAnyWords).captions), "title": .bool(title ?? exportFlags(l.project.edits, hasWords: l.hasAnyWords).title),
                          "animations": .number(Double(l.animations.animations.count)), "overlays": .number(Double(l.project.edits.audioOverlays?.count ?? 0)),
                          "faces": .number(Double(rc.faces)), "music": .bool(rc.music), "compositor": .bool(rc.customCompositor)]
      Store.setStatus(name, ["state": "ready", "kind": "export", "progress": 1, "message": "Exported", "result": result])
      return result
    } catch {
      Store.setStatus(name, ["state": "error", "kind": "export", "message": .string(String(describing: error).prefix(400).description)])
      throw error
    }
  }
}
