// Reading a video with AVFoundation: its length, sound and picture size, its waveform, and its sound as a WAV for the
// transcriber. The video file is only ever read.
import AVFoundation
import Foundation

public enum Media {
  public struct Info: Sendable { public var duration: Double; public var hasAudio: Bool; public var width: Double; public var height: Double }

  public static func probe(_ url: URL) async throws -> Info {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    let videos = try await asset.loadTracks(withMediaType: .video)
    let audios = try await asset.loadTracks(withMediaType: .audio)
    guard let v = videos.first, duration.isFinite, duration > 0 else { throw ToolError("invalid_video", "\(url.lastPathComponent) has no video track AVFoundation can read") }
    let size = try await orientedSize(v)
    return Info(duration: round3(duration), hasAudio: !audios.isEmpty, width: size.width, height: size.height)
  }

  public static let AUDIO_EXTENSIONS = ["mp3", "wav", "m4a", "aac", "aif", "aiff", "caf", "mp4", "mov", "m4v"]

  // An audio file's length (or a video's sound), for an audio overlay.
  public static func probeAudio(_ url: URL) async throws -> Double {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration).seconds
    guard try await !asset.loadTracks(withMediaType: .audio).isEmpty, duration.isFinite, duration > MIN_CLIP else { throw ToolError("invalid_audio", "\(url.lastPathComponent) has no sound AVFoundation can read") }
    return round3(duration)
  }

  // The picture's size as it is shown, after the track's rotation (a phone video is stored landscape and turned).
  public static func orientedSize(_ track: AVAssetTrack) async throws -> CGSize {
    let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
    let r = CGRect(origin: .zero, size: natural).applying(transform)
    return CGSize(width: abs(r.width).rounded(), height: abs(r.height).rounded())
  }

  // The loudest sample in each 1/perSecond of a second, 0 to 1, for drawing the waveform.
  public static func peaks(_ url: URL, perSecond: Int = 20) async throws -> [Float] {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
    let rate = 8000
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ])
    reader.add(output)
    reader.startReading()
    let bin = rate / perSecond
    var out: [Float] = []
    var current: Int16 = 0, count = 0
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
      var length = 0
      var ptr: UnsafeMutablePointer<Int8>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
      guard let p = ptr else { continue }
      p.withMemoryRebound(to: Int16.self, capacity: length / 2) { s in
        for i in 0..<(length / 2) {
          let v = s[i] == Int16.min ? Int16.max : abs(s[i])
          if v > current { current = v }
          count += 1
          if count == bin { out.append(Float(current) / Float(Int16.max)); current = 0; count = 0 }
        }
      }
    }
    if count > 0 { out.append(Float(current) / Float(Int16.max)) }
    return out
  }

  // The sound as 16 kHz mono 16 bit WAV, what the transcriber reads.
  public static func writeWav(_ url: URL, to wav: URL) async throws {
    let asset = AVURLAsset(url: url)
    guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw ToolError("no_audio", "The video has no sound to transcribe") }
    let reader = try AVAssetReader(asset: asset)
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16000, AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false, AVLinearPCMIsBigEndianKey: false, AVLinearPCMIsNonInterleaved: false,
    ]
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
    reader.add(output)
    reader.startReading()
    var pcm = Data()
    while let buffer = output.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buffer) {
      var length = 0
      var ptr: UnsafeMutablePointer<Int8>?
      CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &length, dataPointerOut: &ptr)
      if let p = ptr { pcm.append(UnsafeBufferPointer(start: UnsafeRawPointer(p).assumingMemoryBound(to: UInt8.self), count: length)) }
    }
    var header = Data()
    func u32(_ v: UInt32) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 4)) }
    func u16(_ v: UInt16) { var x = v.littleEndian; header.append(Data(bytes: &x, count: 2)) }
    header.append(contentsOf: Array("RIFF".utf8)); u32(UInt32(36 + pcm.count)); header.append(contentsOf: Array("WAVE".utf8))
    header.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
    header.append(contentsOf: Array("data".utf8)); u32(UInt32(pcm.count))
    try (header + pcm).write(to: wav, options: .atomic)
  }
}
