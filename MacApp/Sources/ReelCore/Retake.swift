// Record new audio (Sankalp, 21 Nov 2026): when the words are right on camera but the sound is not clear, Sankalp says them
// again into any microphone and the take is laid over those words, matched to the voice around them so it sounds like
// the same recording:
//   1. Trimmed to its speech, with a little air before and after.
//   2. Its tone (the balance of low, middle and high) matched to the voice in the video just before and after the words,
//      by third octave bands, at most 9 dB either way.
//   3. Its loudness matched to that voice, measured over the speech only.
//   4. The room's own sound from the pauses of the video laid under it, so the background never drops out.
//   5. Sped up a little (at most MAX_RATE, the pitch kept) when it runs longer than the gap before the next word.
// The result is a new file in the projects folder's _takes, laid out in edit time with silence where cuts are, and the
// overlay (AudioOverlay.replaces) silences the clips' own sound under it with short fades (Composition.swift). The take
// plays with the voice volume and bass and treble like every voice, so the matching compares the raw recordings.
import Accelerate
import AVFoundation
import Foundation

public enum Retake {
  static let RATE = 48000.0
  static let FRAME = 960 // 20 ms
  static let FFT = 2048
  static let MAX_RATE = 1.2
  static let LEAD = 0.08 // air kept before the speech
  static let TAIL = 0.15 // and after it
  static let AROUND = 10.0 // seconds of the video read on each side for its voice and its room

  public struct Placed: Sendable { public var file: URL; public var start: Double; public var length: Double; public var report: [String: JSON] }

  // Where the takes of a project are kept.
  public static func folder(_ project: String) -> URL { Store.root.appendingPathComponent("_takes", isDirectory: true).appendingPathComponent(project, isDirectory: true) }

  // ---------------------------------------------------------------------------------------------------------------------
  // Reading and writing

  // Mono samples at 48 kHz of a file from one second to another (to nil: its end).
  static func read(_ url: URL, from: Double = 0, to: Double? = nil) async throws -> [Float] {
    let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
    let reader = try AVAssetReader(asset: asset)
    let a = CMTime(seconds: max(0, from), preferredTimescale: 48000)
    if let to { reader.timeRange = CMTimeRange(start: a, end: CMTime(seconds: max(from, to), preferredTimescale: 48000)) }
    else if from > 0 { reader.timeRange = CMTimeRange(start: a, duration: .positiveInfinity) }
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: RATE, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    guard reader.startReading() else { throw ToolError("invalid_audio", "Could not read the sound of \(url.lastPathComponent): \(reader.error?.localizedDescription ?? "unknown")") }
    var out: [Float] = []
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
      let length = CMBlockBufferGetDataLength(block)
      var chunk = [Float](repeating: 0, count: length / 4)
      chunk.withUnsafeMutableBytes { _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
      out += chunk
    }
    return out
  }

  static func write(_ x: [Float], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RATE, channels: 1, interleaved: false)!
    let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: RATE, AVNumberOfChannelsKey: 1,
                                                          AVLinearPCMBitDepthKey: 24, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false],
                               commonFormat: .pcmFormatFloat32, interleaved: false)
    guard let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(max(1, x.count))) else { throw ToolError("write_failed", "Could not make a sound buffer") }
    buf.frameLength = AVAudioFrameCount(x.count)
    x.withUnsafeBufferPointer { buf.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
    try file.write(from: buf)
  }

  // ---------------------------------------------------------------------------------------------------------------------
  // Measuring

  // Loudness in dB every 20 ms.
  static func frames(_ x: [Float]) -> [Float] {
    guard x.count >= FRAME else { return [] }
    return x.withUnsafeBufferPointer { p in
      stride(from: 0, to: x.count - FRAME + 1, by: FRAME).map { i in var ms: Float = 0; vDSP_measqv(p.baseAddress! + i, 1, &ms, vDSP_Length(FRAME)); return 10 * log10(ms + 1e-12) }
    }
  }

  // Which 20 ms frames are speech, the level of the speech and of the quiet between it, all in dB.
  struct Profile { var db: [Float]; var voiced: [Bool]; var level: Float; var noise: Float; var quiet: Float; var loud: Float }
  static func profile(_ x: [Float]) -> Profile {
    let db = frames(x)
    guard !db.isEmpty else { return Profile(db: [], voiced: [], level: -120, noise: -120, quiet: -120, loud: -120) }
    let s = db.sorted()
    let quiet = s[Int(Double(s.count - 1) * 0.1)], loud = s[Int(Double(s.count - 1) * 0.95)]
    // With little between the quietest and the loudest (all speech, or all room) every frame counts as speech.
    let thr = loud - quiet > 12 ? quiet + 0.45 * (loud - quiet) : -.infinity
    let voiced = db.map { $0 >= thr }
    func mean(_ v: [Float]) -> Float { v.isEmpty ? -120 : 10 * log10(v.map { pow(10, $0 / 10) }.reduce(0, +) / Float(v.count)) }
    let level = mean(zip(db, voiced).filter(\.1).map(\.0))
    let noise = mean(db.filter { $0 <= quiet + 3 })
    return Profile(db: db, voiced: voiced, level: level, noise: noise, quiet: quiet, loud: loud)
  }

  // The third octave bands the tone is matched in, 100 Hz to 12.5 kHz.
  static let BANDS: [Double] = (0...21).map { 100 * pow(2, Double($0) / 3) }

  static func window() -> [Float] { (0..<FFT).map { Float(sqrt(0.5 - 0.5 * cos(2 * .pi * Double($0) / Double(FFT)))) } } // square root Hann

  // The average power of each band over the speech frames.
  static func spectrum(_ x: [Float], _ p: Profile) -> [Double]? {
    guard let dft = vDSP.DFT(count: FFT, direction: .forward, transformType: .complexComplex, ofType: Float.self), x.count > FFT else { return nil }
    let w = window(), zeros = [Float](repeating: 0, count: FFT)
    var power = [Double](repeating: 0, count: FFT / 2 + 1), n = 0
    for start in stride(from: 0, to: x.count - FFT, by: FFT / 2) {
      let f = (start + FFT / 2) / FRAME
      guard f < p.voiced.count, p.voiced[f] else { continue }
      let seg = vDSP.multiply(Array(x[start..<(start + FFT)]), w)
      let (re, im) = dft.transform(inputReal: seg, inputImaginary: zeros)
      for k in 0...(FFT / 2) { power[k] += Double(re[k] * re[k] + im[k] * im[k]) }
      n += 1
    }
    guard n >= 4 else { return nil }
    let hz = RATE / Double(FFT)
    return BANDS.map { c in
      let lo = Int((c * pow(2, -1 / 6.0) / hz).rounded(.down)), hi = max(lo + 1, Int((c * pow(2, 1 / 6.0) / hz).rounded(.up)))
      let slice = power[max(1, lo)...min(FFT / 2, hi)]
      return slice.reduce(0, +) / Double(slice.count) / Double(n)
    }
  }

  // The gain of each band, in dB, that brings the take's tone to the video's: the level of the middle of speech (300 Hz to
  // 3 kHz) left to the loudness match, at most 9 dB either way, smoothed across neighbouring bands.
  static func toneGains(ref: [Double], take: [Double]) -> [Double] {
    let raw = zip(ref, take).map { 10 * log10(($0 + 1e-20) / ($1 + 1e-20)) }
    let mid = BANDS.indices.filter { BANDS[$0] >= 300 && BANDS[$0] <= 3000 }
    let offset = mid.map { raw[$0] }.reduce(0, +) / Double(mid.count)
    let clamped = raw.map { max(-9, min(9, $0 - offset)) }
    return clamped.indices.map { i in
      let a = clamped[max(0, i - 1)], b = clamped[i], c = clamped[min(clamped.count - 1, i + 1)]
      return 0.25 * a + 0.5 * b + 0.25 * c
    }
  }

  // The take filtered by the band gains, by overlap and add of short spectra.
  static func applyTone(_ x: [Float], _ gains: [Double]) -> [Float] {
    guard let fwd = vDSP.DFT(count: FFT, direction: .forward, transformType: .complexComplex, ofType: Float.self),
          let inv = vDSP.DFT(count: FFT, direction: .inverse, transformType: .complexComplex, ofType: Float.self) else { return x }
    let hz = RATE / Double(FFT)
    let logs = BANDS.map { log2($0) }
    // Each bin's gain, between the bands' in log frequency.
    let bin: [Float] = (0...(FFT / 2)).map { k in
      let f = max(1, Double(k) * hz), lf = log2(f)
      let db: Double
      if lf <= logs.first! { db = gains.first! } else if lf >= logs.last! { db = gains.last! }
      else { let j = logs.lastIndex { $0 <= lf }!; let t = (lf - logs[j]) / (logs[j + 1] - logs[j]); db = gains[j] * (1 - t) + gains[j + 1] * t }
      return Float(pow(10, db / 20))
    }
    let full: [Float] = (0..<FFT).map { bin[$0 <= FFT / 2 ? $0 : FFT - $0] }
    let w = window(), hop = FFT / 4, zeros = [Float](repeating: 0, count: FFT)
    let padded = [Float](repeating: 0, count: FFT) + x + [Float](repeating: 0, count: FFT)
    var out = [Float](repeating: 0, count: padded.count), norm = [Float](repeating: 0, count: padded.count)
    let w2 = vDSP.multiply(w, w)
    for start in stride(from: 0, through: padded.count - FFT, by: hop) {
      let seg = vDSP.multiply(Array(padded[start..<(start + FFT)]), w)
      let (re, im) = fwd.transform(inputReal: seg, inputImaginary: zeros)
      let (r2, _) = inv.transform(inputReal: vDSP.multiply(re, full), inputImaginary: vDSP.multiply(im, full))
      let y = vDSP.multiply(vDSP.multiply(1 / Float(FFT), r2), w)
      for k in 0..<FFT { out[start + k] += y[k]; norm[start + k] += w2[k] }
    }
    return (0..<x.count).map { i in out[i + FFT] / max(norm[i + FFT], 1e-3) }
  }

  // The room: the quiet stretches of the video between its words, at least 60 ms each, joined with short crossfades and
  // repeated until n samples long. Nil when the video has no quiet to take.
  static func roomTone(_ x: [Float], _ p: Profile, _ n: Int) -> [Float]? {
    var runs: [(Int, Int)] = []
    var i = 0
    while i < p.db.count {
      guard p.db[i] <= p.quiet + 3 else { i += 1; continue }
      var j = i
      while j + 1 < p.db.count && p.db[j + 1] <= p.quiet + 3 { j += 1 }
      if j - i + 1 >= 3 { runs.append((i * FRAME, (j + 1) * FRAME)) }
      i = j + 1
    }
    guard !runs.isEmpty, n > 0 else { return nil }
    let xf = 480 // 10 ms
    var bed: [Float] = []
    var k = 0
    while bed.count < n + xf {
      let (a, b) = runs[k % runs.count]; k += 1
      let piece = Array(x[a..<min(b, x.count)])
      guard piece.count > 2 * xf else { if k > runs.count * 50 { break }; continue }
      if bed.count >= xf {
        for t in 0..<xf { let g = Float(t) / Float(xf); bed[bed.count - xf + t] = bed[bed.count - xf + t] * sqrt(1 - g) + piece[t] * sqrt(g) }
        bed += piece[xf...]
      } else { bed += piece }
    }
    guard bed.count >= n else { return nil }
    return Array(bed.prefix(n))
  }

  // The take played faster by rate, its pitch kept.
  static func faster(_ x: [Float], rate: Double) throws -> [Float] {
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: RATE, channels: 1, interleaved: false)!
    let engine = AVAudioEngine(), player = AVAudioPlayerNode(), pitch = AVAudioUnitTimePitch()
    pitch.rate = Float(rate)
    engine.attach(player); engine.attach(pitch)
    engine.connect(player, to: pitch, format: fmt)
    engine.connect(pitch, to: engine.mainMixerNode, format: fmt)
    try engine.enableManualRenderingMode(.offline, format: fmt, maximumFrameCount: 4096)
    try engine.start()
    let input = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(x.count))!
    input.frameLength = AVAudioFrameCount(x.count)
    x.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: x.count) }
    player.scheduleBuffer(input)
    player.play()
    let want = Int(Double(x.count) / rate)
    let chunk = AVAudioPCMBuffer(pcmFormat: engine.manualRenderingFormat, frameCapacity: 4096)!
    var out: [Float] = []
    while out.count < want + 4096 {
      let status = try engine.renderOffline(min(4096, AVAudioFrameCount(want + 4096 - out.count)), to: chunk)
      guard status == .success else { break }
      out += UnsafeBufferPointer(start: chunk.floatChannelData![0], count: Int(chunk.frameLength))
    }
    player.stop(); engine.stop()
    // The time pitch unit starts a little late; its first samples are its own latency.
    let lag = Int(pitch.latency * RATE)
    return Array(out.dropFirst(lag).prefix(want))
  }

  static func fade(_ x: inout [Float], at: Int, length: Int, in fadeIn: Bool) {
    for t in 0..<length where at + t >= 0 && at + t < x.count {
      let g = Float(t) / Float(length)
      x[at + t] *= fadeIn ? g : 1 - g
    }
  }

  // ---------------------------------------------------------------------------------------------------------------------
  // Placing

  // The take at take laid over the words from start to end (edit seconds), matched to the voice around them.
  public static func place(_ l: Loaded, take: URL, start: Double, end: Double) async throws -> Placed {
    let plan = l.plan, edl = l.project.edits
    let oS = outputOf(plan, start), oE = outputOf(plan, end)
    guard oE - oS > 0.1 else { throw ToolError("invalid_range", "Those words are cut, so there is nothing to record over. Pick words that play") }

    // The words before and after, in output time, to fit the take between.
    let heard = outputWords(plan, edl, l.words, l.extra)
    let prevEnd = heard.filter { $0.e <= oS + 0.02 && $0.s < oS - 0.01 }.map(\.e).max()
    let nextStart = heard.filter { $0.s >= oE - 0.02 && $0.e > oE + 0.01 }.map(\.s).min()

    // The video's voice and room: its own file around the words, the words themselves left out.
    guard let at = locate(plan, start) else { throw ToolError("invalid_range", "No clip plays at \(round3(start)) s") }
    let atEnd = locate(plan, end)
    let file = at.clip.source == MAIN ? l.project.main.file : edl.sources.first { $0.id == at.clip.source }?.file ?? ""
    guard FileManager.default.fileExists(atPath: file) else { throw ToolError("missing_video", "The video \(file) is not there any more. check_sources lists the missing files") }
    let wordsFrom = at.sourceTime, wordsTo = atEnd?.clip.id == at.clip.id ? atEnd!.sourceTime : at.clip.out
    var ref = try await read(URL(fileURLWithPath: file), from: max(0, wordsFrom - AROUND), to: wordsFrom)
    ref += try await read(URL(fileURLWithPath: file), from: wordsTo, to: wordsTo + AROUND)
    if ref.count < Int(RATE) { ref = try await read(URL(fileURLWithPath: file), from: max(0, wordsFrom - 1), to: wordsTo + 1) }
    let refP = profile(ref)

    // 1. The take trimmed to its speech.
    let raw = try await read(take)
    guard raw.count > Int(RATE * 0.2) else { throw ToolError("invalid_audio", "The recording is too short") }
    let rawP = profile(raw)
    guard rawP.loud > -55, let first = rawP.voiced.firstIndex(of: true), let last = rawP.voiced.lastIndex(of: true) else {
      throw ToolError("no_speech", "Nothing was heard in the recording. Check the microphone and record again")
    }
    let a = max(0, first * FRAME - Int(LEAD * RATE)), b = min(raw.count, (last + 1) * FRAME + Int(TAIL * RATE))
    var x = Array(raw[a..<b])

    // 2. Its tone.
    var tone: [Double] = []
    if let rs = spectrum(ref, refP), let ts = spectrum(x, profile(x)) {
      tone = toneGains(ref: rs, take: ts)
      x = applyTone(x, tone)
    }

    // 3. Its loudness, kept under full scale.
    let xP = profile(x)
    var gainDb = Double(max(-24, min(30, refP.level - xP.level)))
    let peak = x.map(abs).max() ?? 0
    if peak > 0, Float(pow(10, gainDb / 20)) * peak > 0.98 { gainDb = 20 * log10(0.98 / Double(peak)) }
    x = vDSP.multiply(Float(pow(10, gainDb / 20)), x)

    // 5. Fitted before the next word.
    let placeAt = max(0, oS - LEAD)
    let limit = nextStart.map { $0 - 0.03 } ?? plan.duration
    var rate = 1.0
    let length = Double(x.count) / RATE
    if length > limit - placeAt + 0.02, limit - placeAt > 0.2 {
      rate = min(MAX_RATE, length / (limit - placeAt))
      if rate > 1.01 { x = try faster(x, rate: rate) } else { rate = 1 }
    }
    let takeEnd = placeAt + Double(x.count) / RATE
    let overrun = nextStart.map { max(0, takeEnd - $0) } ?? 0

    // The stretch the clips' sound gives way over: from just after the word before to past the last word picked and the
    // take, and never past the reel.
    // A take beside another stops at its edge: takes never overlap.
    let near = takeRanges(plan, edl).map(\.range)
    let before = near.filter { $0.e <= oS + 0.05 }.map(\.e).max() ?? 0
    let after = near.filter { $0.s >= oE - 0.05 }.map(\.s).min() ?? plan.duration
    let oa = max(0, before, min(placeAt, max(prevEnd ?? 0, oS - 0.12)))
    let ob = min(plan.duration, after, max(takeEnd, max(oE, min(oE + 0.12, limit))))
    let n = Int((ob - oa) * RATE)

    // 4. The room under it, at the level the take's own background lacks.
    var bed = [Float](repeating: 0, count: n)
    var room = false
    let takeNoise = profile(x).noise
    if refP.loud - refP.quiet > 12, refP.noise > takeNoise + 1, let tone = roomTone(ref, refP, n) {
      let g = Float(sqrt(max(0, 1 - pow(10, Double(takeNoise - refP.noise) / 10))))
      bed = vDSP.multiply(g, tone)
      room = true
    }
    fade(&x, at: 0, length: Int(0.01 * RATE), in: true)
    fade(&x, at: x.count - Int(0.01 * RATE), length: Int(0.01 * RATE), in: false)
    let offset = Int((placeAt - oa) * RATE)
    for i in 0..<x.count where offset + i >= 0 && offset + i < n { bed[offset + i] += x[i] }
    let tf = Int(TAKE_FADE * RATE)
    fade(&bed, at: 0, length: tf, in: true)
    fade(&bed, at: n - tf, length: tf, in: false)

    // Laid out in edit time: the parts of oa to ob each at their edit second, silence where cuts are.
    var pieces: [(o0: Double, o1: Double, e0: Double)] = []
    var acc = 0.0
    for k in plan.keep {
      let len = k.e - k.s
      let p0 = max(oa, acc), p1 = min(ob, acc + len)
      if p1 - p0 > 0.0005 { pieces.append((p0, p1, k.s + p0 - acc)) }
      acc += len
    }
    guard let fp = pieces.first, let lp = pieces.last else { throw ToolError("invalid_range", "Those words are cut") }
    let editStart = fp.e0, editEnd = lp.e0 + lp.o1 - lp.o0
    var laid = [Float](repeating: 0, count: Int((editEnd - editStart) * RATE) + 1)
    for p in pieces {
      let from = Int((p.o0 - oa) * RATE), count = min(Int((p.o1 - p.o0) * RATE), n - from), to = Int((p.e0 - editStart) * RATE)
      for i in 0..<max(0, count) where to + i < laid.count { laid[to + i] = bed[from + i] }
    }

    let stamp = Int(Date().timeIntervalSince1970 * 1000)
    let out = folder(l.project.name).appendingPathComponent("\(take.deletingPathExtension().lastPathComponent)-matched-\(stamp).wav")
    try write(laid, to: out)

    var report: [String: JSON] = [
      "gainDb": .number(round3(gainDb)),
      "toneDb": .array(zip(BANDS, tone).filter { abs($0.1) >= 1 }.map { .object(["hz": .number($0.0.rounded()), "db": .number((($0.1) * 10).rounded() / 10)]) }),
      "roomTone": .bool(room),
      "rate": .number(round3(rate)),
      "speech": .number(round3(length)),
      "videoLevelDb": .number(round3(Double(refP.level))), "takeLevelDb": .number(round3(Double(xP.level))),
    ]
    if overrun > 0.02 { report["overrun"] = .number(round3(overrun)) }
    return Placed(file: out, start: round3(editStart), length: round3(Double(laid.count) / RATE), report: report)
  }
}
