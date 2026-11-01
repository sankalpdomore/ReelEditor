// The reel as an AVFoundation composition: the kept segments of the plan joined from their source videos, each fitted
// into the main video's frame, short fades at every join so a cut never clicks, and the speed laid over the whole. The
// voice overs and face overlays are tracks of their own, the music bed one more laid after the speed (it never speeds up),
// and the voice volume and bass and treble are taps on the audio mix (AudioFX.swift). A reel with a look, a placed clip or a
// face window is drawn by ReelCompositor (Compositor.swift), any other by AVFoundation's own compositor. The preview plays
// this composition and the export renders it, so what is previewed is what is exported.
import AVFoundation
import Foundation

public final class ReelComposition: @unchecked Sendable {
  public let composition: AVMutableComposition
  public let videoComposition: AVMutableVideoComposition
  public let audioMix: AVMutableAudioMix?
  public let renderSize: CGSize
  public let duration: Double // output seconds, after the speed
  public let speed: Double
  public let plan: Plan
  public let music: Bool // a music bed plays
  public let faces: Int // face (and video layer) windows drawn
  public let customCompositor: Bool // drawn by ReelCompositor (a look, a placed clip or a face window)

  init(composition: AVMutableComposition, videoComposition: AVMutableVideoComposition, audioMix: AVMutableAudioMix?, renderSize: CGSize, duration: Double, speed: Double, plan: Plan,
       music: Bool = false, faces: Int = 0, customCompositor: Bool = false) {
    self.composition = composition; self.videoComposition = videoComposition; self.audioMix = audioMix
    self.renderSize = renderSize; self.duration = duration; self.speed = speed; self.plan = plan
    self.music = music; self.faces = faces; self.customCompositor = customCompositor
  }

  public func playerItem() -> AVPlayerItem {
    let item = AVPlayerItem(asset: composition)
    item.videoComposition = videoComposition
    item.audioMix = audioMix
    item.audioTimePitchAlgorithm = .spectral
    return item
  }
}

private let TS: CMTimeScale = 600
private func ct(_ s: Double) -> CMTime { CMTime(seconds: s, preferredTimescale: TS) }
private let JOIN_FADE = 0.015

public enum Compose {
  public static func speedOf(_ edl: Edl) -> Double { let s = edl.export.speed ?? 1; return s >= 0.1 && s <= 4 ? s : 1 }

  // The music bed's file: an absolute path, or the name of a file in the projects folder's _music (with or without its
  // extension). Nil when there is no track, it is muted or removed, or the file is not there.
  public static func musicFile(_ edl: Edl) -> URL? {
    guard let m = edl.music, m.none != true, !m.mute, let track = m.track, !track.isEmpty else { return nil }
    let fm = FileManager.default
    let direct = URL(fileURLWithPath: (track as NSString).expandingTildeInPath)
    if track.hasPrefix("/") || track.hasPrefix("~") { return fm.fileExists(atPath: direct.path) ? direct : nil }
    let lib = Store.root.appendingPathComponent("_music", isDirectory: true)
    if fm.fileExists(atPath: lib.appendingPathComponent(track).path) { return lib.appendingPathComponent(track) }
    let hit = ((try? fm.contentsOfDirectory(atPath: lib.path)) ?? []).first { ($0 as NSString).deletingPathExtension == track }
    return hit.map { lib.appendingPathComponent($0) }
  }

  public static func build(_ l: Loaded) async throws -> ReelComposition {
    let plan = l.plan
    let edl = l.project.edits
    let speed = speedOf(edl)
    func fileOf(_ id: String) -> String { id == MAIN ? l.project.main.file : edl.sources.first { $0.id == id }?.file ?? "" }

    struct Src { var asset: AVURLAsset; var video: AVAssetTrack; var audio: AVAssetTrack?; var transform: CGAffineTransform; var size: CGSize; var natural: CGSize }
    var srcs: [String: Src] = [:]
    for id in Set([MAIN] + plan.segments.map(\.source)) {
      let path = fileOf(id)
      guard FileManager.default.fileExists(atPath: path) else { throw ToolError("missing_video", "The video \(path) is not there any more. check_sources lists the missing files, relink_source links one again") }
      let asset = AVURLAsset(url: URL(fileURLWithPath: path), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      guard let v = try await asset.loadTracks(withMediaType: .video).first else { throw ToolError("invalid_video", "\(path) has no video track") }
      let a = try await asset.loadTracks(withMediaType: .audio).first
      srcs[id] = Src(asset: asset, video: v, audio: a, transform: try await v.load(.preferredTransform), size: try await Media.orientedSize(v), natural: try await v.load(.naturalSize))
    }
    let mainSize = srcs[MAIN]!.size
    let render = CGSize(width: max(2, (mainSize.width / 2).rounded() * 2), height: max(2, (mainSize.height / 2).rounded() * 2))

    let comp = AVMutableComposition()
    guard let vTrack = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw ToolError("compose_failed", "Could not make a video track") }
    let overlays = edl.audioOverlays ?? []
    // An audio overlay needs a sound track to sit beside, so a project whose clips have no sound still gets one.
    let anyAudio = plan.segments.contains { srcs[$0.source]?.audio != nil && $0.mute != true } || !overlays.isEmpty
    let aTrack = anyAudio ? comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) : nil

    var cursor = CMTime.zero
    var placed: [(start: CMTime, duration: CMTime, transform: CGAffineTransform, natural: CGSize, seg: PlanSegment)] = []
    for seg in plan.segments {
      let src = srcs[seg.source]!
      let range = CMTimeRange(start: ct(seg.inn), duration: ct(seg.out - seg.inn))
      do { try vTrack.insertTimeRange(range, of: src.video, at: cursor) } catch { throw ToolError("compose_failed", "Could not place \(seg.source) \(seg.inn) to \(seg.out): \(error.localizedDescription) \((error as NSError).userInfo)") }
      if let aTrack {
        // A muted clip's own sound is silence; the picture and the timing stay, an audio overlay carries the sound instead.
        if let a = src.audio, seg.mute != true { do { try aTrack.insertTimeRange(range, of: a, at: cursor) } catch { aTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration)) } }
        else { aTrack.insertEmptyTimeRange(CMTimeRange(start: cursor, duration: range.duration)) }
      }
      // Turned upright by the track's own transform, then fitted and centred in the frame.
      let s = min(render.width / src.size.width, render.height / src.size.height)
      let fit = src.transform
        .concatenating(CGAffineTransform(scaleX: s, y: s))
        .concatenating(CGAffineTransform(translationX: (render.width - src.size.width * s) / 2, y: (render.height - src.size.height * s) / 2))
      placed.append((cursor, range.duration, fit, src.natural, seg))
      cursor = cursor + range.duration
    }
    if plan.segments.isEmpty { throw ToolError("empty", "Everything is cut, there is nothing to play") }

    // The audio overlays: each part the cuts leave, from its file, at its place in the output, on a track of its own. A face
    // overlay's picture goes on a video track of its own the same way, drawn in its window by the compositor.
    var overlayTracks: [(track: AVMutableCompositionTrack, overlay: AudioOverlay)] = []
    var faceTracks: [(track: AVMutableCompositionTrack, overlay: AudioOverlay, transform: CGAffineTransform, natural: CGSize, size: CGSize, pieces: [(outStart: Double, len: Double, fileIn: Double)])] = []
    for o in overlays {
      guard FileManager.default.fileExists(atPath: o.file) else { throw ToolError("missing_audio", "The file \(o.file) of \(o.id) is not there any more. check_sources lists the missing files, relink_source links one again") }
      let asset = AVURLAsset(url: URL(fileURLWithPath: o.file), options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      let pieces = overlayPieces(plan, o).filter { $0.outStart < cursor.seconds }.map { p in (outStart: p.outStart, len: min(p.fileOut - p.fileIn, cursor.seconds - p.outStart), fileIn: p.fileIn) }.filter { $0.len > 0.01 }
      if let a = try await asset.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        for p in pieces { try? t.insertTimeRange(CMTimeRange(start: ct(p.fileIn), duration: ct(p.len)), of: a, at: ct(p.outStart)) }
        overlayTracks.append((t, o))
      }
      if o.window != nil, let v = try await asset.loadTracks(withMediaType: .video).first, let t = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) {
        var end = 0.0
        for p in pieces {
          if p.outStart > end + 0.001 { t.insertEmptyTimeRange(CMTimeRange(start: ct(end), duration: ct(p.outStart - end))) }
          try? t.insertTimeRange(CMTimeRange(start: ct(p.fileIn), duration: ct(p.len)), of: v, at: ct(p.outStart))
          end = p.outStart + p.len
        }
        faceTracks.append((t, o, try await v.load(.preferredTransform), try await v.load(.naturalSize), try await Media.orientedSize(v), pieces))
      }
    }

    let total = cursor
    let scaled = CMTimeMultiplyByFloat64(total, multiplier: 1 / speed)
    if abs(speed - 1) > 1e-6 { comp.scaleTimeRange(CMTimeRange(start: .zero, duration: total), toDuration: scaled) }
    let sc = { (t: CMTime) in CMTimeMultiplyByFloat64(t, multiplier: 1 / speed) }

    // The music bed, laid after the speed so it plays at its own pace: the clip of the track from start to end, repeated
    // from its start where it ends, until the reel ends.
    var musicTrack: AVMutableCompositionTrack?
    let ms = edl.music ?? MusicSettings()
    if let url = musicFile(edl) {
      let asset = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
      if let a = try await asset.loadTracks(withMediaType: .audio).first, let t = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) {
        let fileLen = try await asset.load(.duration).seconds
        let from = max(0, min(ms.start ?? 0, fileLen - 0.1)), to = (ms.end ?? 0) > from + 0.1 ? min(ms.end!, fileLen) : fileLen
        var at = 0.0
        let want = scaled.seconds
        while at < want - 0.01 && to - from > 0.1 {
          let len = min(to - from, want - at)
          try? t.insertTimeRange(CMTimeRange(start: ct(from), duration: ct(len)), of: a, at: ct(at))
          at += len
        }
        musicTrack = t
      }
    }

    // The picture: AVFoundation's own compositor when nothing needs drawing, else ReelCompositor.
    let vc = AVMutableVideoComposition()
    vc.renderSize = render
    vc.frameDuration = CMTime(value: 1, timescale: 30)
    let reelLook = normalizeLook(edl.look)
    let perLayer = plan.segments.contains { $0.look != nil || $0.lookOff == true }
    let custom = reelLook != nil || perLayer || plan.segments.contains { $0.place != nil } || !faceTracks.isEmpty
    if custom {
      let main = placed.map { p in
        ReelScene.MainPiece(t0: sc(p.start).seconds, t1: sc(p.start + p.duration).seconds, transform: ciTransform(p.transform, inH: p.natural.height, outH: render.height),
                            look: normalizeLook(p.seg.look), lookOff: p.seg.lookOff == true, place: p.seg.place)
      }
      let faces = faceTracks.map { f in
        ReelScene.Face(track: f.track.trackID, orient: ciTransform(f.transform, inH: f.natural.height, outH: f.size.height), natural: f.natural, window: f.overlay.window!,
                       pieces: f.pieces.map { ReelScene.FacePiece(t0: $0.outStart / speed, t1: ($0.outStart + $0.len) / speed, local0: $0.fileIn - f.overlay.inn) })
      }
      let scene = ReelScene(render: render, speed: speed, mainTrack: vTrack.trackID, main: main, faces: faces, reelLook: reelLook, perLayerLook: perLayer)
      vc.customVideoCompositorClass = ReelCompositor.self
      vc.instructions = [ReelInstruction(timeRange: CMTimeRange(start: .zero, duration: scaled), scene: scene)]
    } else {
      let instruction = AVMutableVideoCompositionInstruction()
      instruction.timeRange = CMTimeRange(start: .zero, duration: scaled)
      let layer = AVMutableVideoCompositionLayerInstruction(assetTrack: vTrack)
      for p in placed { layer.setTransform(p.transform, at: sc(p.start)) }
      instruction.layerInstructions = [layer]
      vc.instructions = [instruction]
    }

    // The sound: every voice (the clips' own sound and each voice over or face overlay) at the voice volume with the voice's
    // bass and treble, an overlay at its own gain and with its own bass and treble too, a sound effect at exactly its own
    // gain, and the music at its volume with its fades.
    var inputs: [AVMutableAudioMixInputParameters] = []
    let voiceGain = max(0, min(10, edl.voiceGain ?? 1))
    let voiceEq = normalizeEq(edl.voiceEq).map { [$0] } ?? []
    for (t, o) in overlayTracks {
      let gain = o.gain * (o.isVoice ? voiceGain : 1)
      inputs.append(AudioFX.input(t, gain: gain, eqs: [o.eq].compactMap { $0 } + (o.isVoice ? voiceEq : [])))
    }
    if let aTrack {
      let params = AudioFX.input(aTrack, gain: voiceGain, eqs: voiceEq)
      let level: Float = params.audioTapProcessor != nil ? 1 : Float(min(1, voiceGain))
      if placed.count > 1 {
        let fade = ct(JOIN_FADE / speed)
        for p in placed where p.duration.seconds > 0.1 {
          let a = sc(p.start), b = sc(p.start + p.duration)
          params.setVolumeRamp(fromStartVolume: 0, toEndVolume: level, timeRange: CMTimeRange(start: a, duration: fade))
          params.setVolumeRamp(fromStartVolume: level, toEndVolume: 0, timeRange: CMTimeRange(start: b - fade, duration: fade))
        }
      }
      inputs.append(params)
    }
    if let musicTrack {
      let p = AVMutableAudioMixInputParameters(track: musicTrack)
      let g = Float(min(1, max(0, ms.gain))), len = scaled.seconds
      let fi = min(max(0, ms.fadeIn), len / 2), fo = min(max(0, ms.fadeOut), len / 2)
      p.setVolume(g, at: .zero)
      if fi > 0.01 { p.setVolumeRamp(fromStartVolume: 0, toEndVolume: g, timeRange: CMTimeRange(start: .zero, duration: ct(fi))) }
      if fo > 0.01 { p.setVolumeRamp(fromStartVolume: g, toEndVolume: 0, timeRange: CMTimeRange(start: ct(len - fo), duration: ct(fo))) }
      inputs.append(p)
    }
    var mix: AVMutableAudioMix?
    if !inputs.isEmpty { mix = AVMutableAudioMix(); mix!.inputParameters = inputs }
    return ReelComposition(composition: comp, videoComposition: vc, audioMix: mix, renderSize: render, duration: scaled.seconds, speed: speed, plan: plan,
                           music: musicTrack != nil, faces: faceTracks.count, customCompositor: custom)
  }
}
