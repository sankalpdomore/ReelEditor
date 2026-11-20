// Where the voice is in a video (Sankalp, 15 Nov 2026): its loudness every 10 ms, kept in the cache, so a caption shows
// only while its word is heard. The transcriber sometimes stretches a word over the silence before or after it ("Lots"
// held for six seconds while the camera pans, then said at the end), and the caption then sat on screen through the
// silence. Captions.lines fits each such word to the strongest stretch of speech inside its time before drawing it,
// found by the Silero speech detector when WhisperX is on this Mac (19 Nov 2026) and by loudness otherwise; the
// transcript, the cuts and the sound keep the transcriber's times.
import AVFoundation
import Foundation

public enum Voice {
  static let RATE = 16000
  static let STEP = 160 // samples in 10 ms

  // A file's voice: its loudness in dB every 10 ms, and the chance someone is speaking every 10 ms from the Silero
  // speech detector when the WhisperX Python is on this Mac (nil without it, and the loudness alone is used).
  public struct Track: Sendable { public var db: [Float]; public var speech: [Float]? }

  // False in the app, which reads the voice in the background and draws again when it is in: a caption is then drawn
  // from the transcriber's times until the video's voice is read. The MCP server and the export read it at once.
  nonisolated(unsafe) public static var onDemand = true
  nonisolated(unsafe) static var memory: [String: Track?] = [:]
  static let lock = NSLock()

  // A file's voice from memory, the cache folder or the file itself (when onDemand); nil when the file is missing or
  // has no sound.
  public static func track(_ path: String, compute: Bool? = nil) -> Track? {
    guard let key = key(path) else { return nil }
    lock.lock(); let m = memory[key]; lock.unlock()
    if let m { return m }
    let dir = Store.cacheRoot.appendingPathComponent("voice")
    let dbFile = dir.appendingPathComponent("\(key).f32"), vadFile = dir.appendingPathComponent("\(key).vad.f32")
    func floats(_ u: URL) -> [Float]? { (try? Data(contentsOf: u)).map { d in d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } } }
    var db = floats(dbFile), vad = floats(vadFile)
    let canVad = vadTool() != nil
    if db == nil || (vad == nil && canVad) {
      guard compute ?? onDemand else { return db.map { Track(db: $0, speech: nil) } } // read the rest later
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      let samples = read(URL(fileURLWithPath: path))
      if db == nil {
        db = samples.map(levels) ?? []
        try? db!.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: dbFile, options: .atomic)
      }
      if vad == nil, canVad, let samples, !samples.isEmpty {
        // A detector that fails leaves an empty file, so it is not run again on every draw; loudness is used.
        vad = detect(samples) ?? []
        try? vad!.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: vadFile, options: .atomic)
      }
    }
    guard let db, !db.isEmpty else { lock.lock(); memory[key] = .some(nil); lock.unlock(); return nil }
    // The detector's 32 ms windows laid on the 10 ms grid of the loudness.
    let speech = vad.flatMap { v -> [Float]? in v.isEmpty ? nil : (0..<db.count).map { v[min(v.count - 1, $0 * 10 / 32)] } }
    let t = Track(db: db, speech: speech)
    lock.lock(); memory[key] = t; lock.unlock()
    return t
  }

  // The files' voice read now, for the app to call off the main thread.
  public static func warm(_ paths: [String]) { for p in Set(paths) { _ = track(p, compute: true) } }

  // The cache key: the path, the size and the time the file last changed.
  static func key(_ path: String) -> String? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path), let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date else { return nil }
    var h: UInt64 = 0xcbf29ce484222325
    for b in "\(path)|\(size)|\(date.timeIntervalSince1970)".utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(format: "%016llx", h)
  }

  // The sound as 16 kHz mono samples.
  static func read(_ url: URL) -> [Int16]? {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: RATE, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { return nil }
    var out: [Int16] = []
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
      var length = 0
      var ptr: UnsafeMutablePointer<Int8>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
      guard let p = ptr else { continue }
      p.withMemoryRebound(to: Int16.self, capacity: length / 2) { out.append(contentsOf: UnsafeBufferPointer(start: $0, count: length / 2)) }
    }
    return out
  }

  // Loudness in dB every 10 ms.
  static func levels(_ samples: [Int16]) -> [Float] {
    stride(from: 0, to: samples.count - STEP + 1, by: STEP).map { i in
      var sum = 0.0
      for k in i..<(i + STEP) { let v = Double(samples[k]) / 32768; sum += v * v }
      return Float(10 * log10(sum / Double(STEP) + 1e-12))
    }
  }

  // The WhisperX Python and Resources/speech_vad.py, which runs the Silero model faster-whisper ships.
  static func vadTool() -> (python: String, script: String)? {
    guard let python = Jobs.whisperx()?.python else { return nil }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath().deletingLastPathComponent()
    guard let script = Jobs.firstFile([ProcessInfo.processInfo.environment["REEL_VAD_SCRIPT"],
                                       Bundle.main.resourceURL?.appendingPathComponent("speech_vad.py").path,
                                       exe.appendingPathComponent("../Resources/speech_vad.py").standardized.path,
                                       exe.appendingPathComponent("../../Resources/speech_vad.py").standardized.path,
                                       exe.appendingPathComponent("../../../Resources/speech_vad.py").standardized.path]) else { return nil }
    return (python, script)
  }

  // The chance of speech every 32 ms, or nil when the detector could not run.
  static func detect(_ samples: [Int16]) -> [Float]? {
    guard let tool = vadTool() else { return nil }
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("reel-vad-\(UUID().uuidString)")
    let input = tmp.appendingPathExtension("s16"), out = tmp.appendingPathExtension("f32")
    defer { try? FileManager.default.removeItem(at: input); try? FileManager.default.removeItem(at: out) }
    guard (try? samples.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: input)) != nil else { return nil }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: tool.python)
    p.arguments = [tool.script, input.path, out.path]
    p.environment = Jobs.toolEnvironment()
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    guard (try? p.run()) != nil else { return nil }
    p.waitUntilExit()
    guard p.terminationStatus == 0, let d = try? Data(contentsOf: out), !d.isEmpty else { return nil }
    let v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    Log.write("core", "speech_vad", extra: ["windows": .number(Double(v.count))])
    return v
  }

  // The words with each one held far longer than it takes to say fitted to the strongest stretch of speech inside its
  // time, a twentieth of a second either side. A word is held too long past 0.3 s and 0.09 s a letter. Speech is where
  // the Silero detector gives a chance of a half or more, so music, wind or a TV under the voice do not count; without
  // the detector it is what is louder than the room by nearly half the way from its quiet (the tenth percentile) to its
  // loud (the 95th), and a video with no clear voice above its room is left as it is. Stretches of speech are joined
  // across gaps under a quarter of a second.
  public static func fit(_ words: [Word], _ t: Track) -> [Word] {
    let db = t.db
    guard db.count > 50 else { return words }
    let voiced: (Int) -> Float?
    if let sp = t.speech {
      voiced = { sp[$0] >= 0.5 ? sp[$0] : nil }
    } else {
      let sorted = db.sorted()
      let quiet = sorted[(sorted.count - 1) / 10], loud = sorted[(sorted.count - 1) * 95 / 100]
      guard loud - quiet > 12 else { return words }
      let thr = quiet + 0.45 * (loud - quiet)
      voiced = { db[$0] >= thr ? db[$0] - thr : nil }
    }
    return words.map { w in
      let letters = w.w.filter { $0.isLetter || $0.isNumber }.count
      guard w.e - w.s > 0.3 + 0.09 * Double(max(1, letters)) else { return w }
      let a = max(0, Int(w.s * 100)), b = min(db.count, Int((w.e * 100).rounded(.up)))
      var best: (s: Int, e: Int, strength: Float)? = nil
      var i = a
      while i < b {
        guard voiced(i) != nil else { i += 1; continue }
        var j = i, end = i, gap = 0, strength: Float = 0
        while j < b && gap < 25 {
          if let v = voiced(j) { gap = 0; end = j + 1; strength += v } else { gap += 1 }
          j += 1
        }
        if best == nil || strength > best!.strength { best = (i, end, strength) }
        i = j
      }
      guard let r = best else { return w }
      var s = max(w.s, Double(r.s) / 100 - 0.05), e = min(w.e, Double(r.e) / 100 + 0.05)
      if e - s < 0.15 { let m = (s + e) / 2; s = max(w.s, m - 0.075); e = min(w.e, m + 0.075) }
      return Word(w: w.w, s: round3(s), e: round3(e))
    }
  }

  // How the captions are timed, a switch for Sankalp alone (19 Nov 2026), to compare the ways side by side: on the
  // transcriber's times, fitted to the loudness, or fitted to the speech the detector hears. It is read only when
  // settings.json has developer true, which is set by hand on his Mac; everyone else always gets speech.
  public enum Timing: String, CaseIterable, Sendable { case transcribed, loudness, speech }
  public static var developer: Bool { Rules.settings()["developer"] as? Bool == true }
  public static var timing: Timing {
    let s = Rules.settings()
    guard s["developer"] as? Bool == true else { return .speech }
    return (s["captionTiming"] as? String).flatMap(Timing.init) ?? .speech
  }
  public static func setTiming(_ t: Timing) throws {
    var s = Rules.settings()
    s["captionTiming"] = t == .speech ? nil : t.rawValue
    try Rules.saveSettings(s)
  }

  // The project's words and the added videos' and voice overs' words fitted to their voice, what the captions show.
  public static func captionWords(_ l: Loaded) -> (words: [Word], extra: ExtraWords) {
    let how = timing
    if how == .transcribed { return (l.words, l.extra) }
    func fitted(_ ws: [Word], _ path: String?) -> [Word] {
      path.flatMap { track($0) }.map { fit(ws, how == .loudness ? Track(db: $0.db, speech: nil) : $0) } ?? ws
    }
    var extra = l.extra
    for (id, ws) in extra.sources { extra.sources[id] = fitted(ws, l.project.edits.sources.first { $0.id == id }?.file) }
    for (file, ws) in extra.overlays { extra.overlays[file] = fitted(ws, file) }
    return (fitted(l.words, l.project.main.file), extra)
  }

  // Every file whose words the captions show, for warm.
  public static func files(_ l: Loaded) -> [String] {
    [l.project.main.file] + l.project.edits.sources.map(\.file) + (l.project.edits.audioOverlays ?? []).map(\.file)
  }
}
