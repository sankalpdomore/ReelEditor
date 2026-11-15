// Where the voice is in a video (Sankalp, 15 Nov 2026): its loudness every 10 ms, kept in the cache, so a caption shows
// only while its word is heard. The transcriber sometimes stretches a word over the silence before or after it ("Lots"
// held for six seconds while the camera pans, then said at the end), and the caption then sat on screen through the
// silence. Captions.lines fits each such word to the loudest stretch of voice inside its time before drawing it; the
// transcript, the cuts and the sound keep the transcriber's times.
import AVFoundation
import Foundation

public enum Voice {
  static let RATE = 8000
  static let STEP = 80 // samples in 10 ms

  // False in the app, which reads the levels in the background and draws again when they are in: a caption is then
  // drawn from the transcriber's times until the video's levels are read. The MCP server and the export read them at once.
  nonisolated(unsafe) public static var onDemand = true
  nonisolated(unsafe) static var memory: [String: [Float]] = [:]
  static let lock = NSLock()

  // A file's loudness in dB every 10 ms, from memory, the cache folder or the file itself (when onDemand); nil when the
  // file is missing or has no sound.
  public static func levels(_ path: String, compute: Bool? = nil) -> [Float]? {
    guard let key = key(path) else { return nil }
    lock.lock(); let m = memory[key]; lock.unlock()
    if let m { return m.isEmpty ? nil : m }
    let cache = Store.cacheRoot.appendingPathComponent("voice/\(key).f32")
    var levels: [Float]? = nil
    if let d = try? Data(contentsOf: cache) { levels = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    else if compute ?? onDemand {
      levels = read(URL(fileURLWithPath: path)) ?? []
      try? FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
      try? levels!.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: cache, options: .atomic)
    } else { return nil }
    lock.lock(); memory[key] = levels; lock.unlock()
    return levels!.isEmpty ? nil : levels
  }

  // The files' levels read now, for the app to call off the main thread.
  public static func warm(_ paths: [String]) { for p in Set(paths) { _ = levels(p, compute: true) } }

  // The cache key: the path, the size and the time the file last changed.
  static func key(_ path: String) -> String? {
    guard let a = try? FileManager.default.attributesOfItem(atPath: path), let size = a[.size] as? NSNumber, let date = a[.modificationDate] as? Date else { return nil }
    var h: UInt64 = 0xcbf29ce484222325
    for b in "\(path)|\(size)|\(date.timeIntervalSince1970)".utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return String(format: "%016llx", h)
  }

  static func read(_ url: URL) -> [Float]? {
    let asset = AVURLAsset(url: url)
    guard let track = asset.tracks(withMediaType: .audio).first, let reader = try? AVAssetReader(asset: asset) else { return nil }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: RATE, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { return nil }
    var out: [Float] = []
    var sum = 0.0, count = 0
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
      var length = 0
      var ptr: UnsafeMutablePointer<Int8>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
      guard let p = ptr else { continue }
      p.withMemoryRebound(to: Int16.self, capacity: length / 2) { s in
        for i in 0..<(length / 2) {
          let v = Double(s[i]) / 32768
          sum += v * v; count += 1
          if count == STEP { out.append(Float(10 * log10(sum / Double(STEP) + 1e-12))); sum = 0; count = 0 }
        }
      }
    }
    return out
  }

  // The words with each one held far longer than it takes to say fitted to the loudest stretch of voice inside its time,
  // a twentieth of a second either side. A word is held too long past 0.3 s and 0.09 s a letter; the voice is what is
  // louder than the room by nearly half the way from its quiet (the tenth percentile) to its loud (the 95th), stretches
  // of it joined across gaps under a quarter of a second. A video with no clear voice above its room is left as it is.
  public static func fit(_ words: [Word], _ db: [Float]) -> [Word] {
    guard db.count > 50 else { return words }
    let sorted = db.sorted()
    let quiet = sorted[(sorted.count - 1) / 10], loud = sorted[(sorted.count - 1) * 95 / 100]
    guard loud - quiet > 12 else { return words }
    let thr = quiet + 0.45 * (loud - quiet)
    return words.map { w in
      let letters = w.w.filter { $0.isLetter || $0.isNumber }.count
      guard w.e - w.s > 0.3 + 0.09 * Double(max(1, letters)) else { return w }
      let a = max(0, Int(w.s * 100)), b = min(db.count, Int((w.e * 100).rounded(.up)))
      var best: (s: Int, e: Int, energy: Float)? = nil
      var i = a
      while i < b {
        guard db[i] >= thr else { i += 1; continue }
        var j = i, end = i, gap = 0, energy: Float = 0
        while j < b && gap < 25 {
          if db[j] >= thr { gap = 0; end = j + 1; energy += db[j] - thr } else { gap += 1 }
          j += 1
        }
        if best == nil || energy > best!.energy { best = (i, end, energy) }
        i = j
      }
      guard let r = best else { return w }
      var s = max(w.s, Double(r.s) / 100 - 0.05), e = min(w.e, Double(r.e) / 100 + 0.05)
      if e - s < 0.15 { let m = (s + e) / 2; s = max(w.s, m - 0.075); e = min(w.e, m + 0.075) }
      return Word(w: w.w, s: round3(s), e: round3(e))
    }
  }

  // The project's words and the added videos' and voice overs' words fitted to their voice, what the captions show.
  public static func captionWords(_ l: Loaded) -> (words: [Word], extra: ExtraWords) {
    func fitted(_ ws: [Word], _ path: String?) -> [Word] { path.flatMap { levels($0) }.map { fit(ws, $0) } ?? ws }
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
