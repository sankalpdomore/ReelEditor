// What AVFoundation's audio mix cannot do on its own: a volume above 100 percent, the bass and treble shelves of a voice
// and a limiter on its peaks (set_voice_gain, set_voice_eq, update_audio_overlay's gain, bass and treble). Each track that
// needs one gets an MTAudioProcessingTap on its audio mix input, which the preview's player and the export both run, so the
// two sound alike. The shelves are the RBJ cookbook's low shelf at 120 Hz and high shelf at 6 kHz; the limiter holds the
// peaks under 0.89 (the web export's alimiter limit) with an instant attack and a 120 ms release.
import AVFoundation
import Foundation
import MediaToolbox

final class TapParams: @unchecked Sendable {
  let gain: Float
  let eqs: [AudioEq]
  let limit: Bool
  var rate: Double = 44100
  var flags: AudioFormatFlags = 0
  var bytesPerFrame: UInt32 = 4
  // One biquad per shelf per channel: coefficients and the two state values of the transposed direct form II.
  struct Biquad { var b0: Float = 1, b1: Float = 0, b2: Float = 0, a1: Float = 0, a2: Float = 0; var z1: [Float] = [], z2: [Float] = [] }
  var filters: [Biquad] = []
  var env: Float = 0
  var release: Float = 0.9995

  init(gain: Double, eqs: [AudioEq], limit: Bool) { self.gain = Float(gain); self.eqs = eqs; self.limit = limit }

  func prepare(rate: Double, channels: Int, flags: AudioFormatFlags, bytesPerFrame: UInt32) {
    self.rate = rate; self.flags = flags; self.bytesPerFrame = bytesPerFrame
    release = Float(exp(-1 / (0.12 * rate)))
    filters = []
    for eq in eqs {
      if eq.bass != 0 { filters.append(shelf(low: true, f0: EQ_BASS_HZ, db: eq.bass, channels: channels)) }
      if eq.treble != 0 { filters.append(shelf(low: false, f0: EQ_TREBLE_HZ, db: eq.treble, channels: channels)) }
    }
  }

  func shelf(low: Bool, f0: Double, db: Double, channels: Int) -> Biquad {
    let A = pow(10, db / 40), w0 = 2 * Double.pi * min(f0, rate * 0.45) / rate
    let cosw = cos(w0), alpha = sin(w0) / 2 * sqrt(2) // shelf slope S = 1
    let sq = 2 * sqrt(A) * alpha
    var b0, b1, b2, a0, a1, a2: Double
    if low {
      b0 = A * ((A + 1) - (A - 1) * cosw + sq); b1 = 2 * A * ((A - 1) - (A + 1) * cosw); b2 = A * ((A + 1) - (A - 1) * cosw - sq)
      a0 = (A + 1) + (A - 1) * cosw + sq; a1 = -2 * ((A - 1) + (A + 1) * cosw); a2 = (A + 1) + (A - 1) * cosw - sq
    } else {
      b0 = A * ((A + 1) + (A - 1) * cosw + sq); b1 = -2 * A * ((A - 1) + (A + 1) * cosw); b2 = A * ((A + 1) + (A - 1) * cosw - sq)
      a0 = (A + 1) - (A - 1) * cosw + sq; a1 = 2 * ((A - 1) - (A + 1) * cosw); a2 = (A + 1) - (A - 1) * cosw - sq
    }
    return Biquad(b0: Float(b0 / a0), b1: Float(b1 / a0), b2: Float(b2 / a0), a1: Float(a1 / a0), a2: Float(a2 / a0), z1: Array(repeating: 0, count: channels), z2: Array(repeating: 0, count: channels))
  }

  // Float samples only (what AVFoundation hands a tap); anything else passes through untouched.
  func process(_ list: UnsafeMutableAudioBufferListPointer, frames: Int) {
    guard flags & kAudioFormatFlagIsFloat != 0, frames > 0 else { return }
    let interleaved = flags & kAudioFormatFlagIsNonInterleaved == 0
    // Every channel as a strided pointer: one buffer per channel, or one buffer with the channels interleaved.
    var chans: [(UnsafeMutablePointer<Float>, Int)] = []
    if interleaved, let b = list.first, let d = b.mData {
      let n = Int(b.mNumberChannels)
      for c in 0..<n { chans.append((d.assumingMemoryBound(to: Float.self) + c, n)) }
    } else {
      for b in list { if let d = b.mData { chans.append((d.assumingMemoryBound(to: Float.self), 1)) } }
    }
    let nf = filters.count
    for k in 0..<nf { if filters[k].z1.count < chans.count { filters[k].z1 = Array(repeating: 0, count: chans.count); filters[k].z2 = Array(repeating: 0, count: chans.count) } }
    for i in 0..<frames {
      var peak: Float = 0
      for (c, ch) in chans.enumerated() {
        var x = ch.0[i * ch.1] * gain
        for k in 0..<nf {
          let f = filters[k]
          let y = f.b0 * x + f.z1[c]
          filters[k].z1[c] = f.b1 * x - f.a1 * y + f.z2[c]
          filters[k].z2[c] = f.b2 * x - f.a2 * y
          x = y
        }
        ch.0[i * ch.1] = x
        peak = max(peak, abs(x))
      }
      if limit {
        env = max(peak, env * release)
        if env > 0.89 { let g = 0.89 / env; for ch in chans { ch.0[i * ch.1] *= g } }
      }
    }
  }
}

enum AudioFX {
  // An audio mix input for a track: its volume when that is all it needs (0 to 1), else a tap with the gain, the shelves and
  // the limiter, the limiter only when the gain is above 1 or a shelf is set, as in the web export.
  static func input(_ track: AVAssetTrack, gain: Double, eqs: [AudioEq]) -> AVMutableAudioMixInputParameters {
    let p = AVMutableAudioMixInputParameters(track: track)
    let eqs = eqs.filter { $0.bass != 0 || $0.treble != 0 }
    if gain <= 1 && eqs.isEmpty { p.setVolume(Float(max(0, gain)), at: .zero); return p }
    if let tap = makeTap(TapParams(gain: gain, eqs: eqs, limit: gain > 1 || !eqs.isEmpty)) { p.audioTapProcessor = tap; p.setVolume(1, at: .zero) }
    else { p.setVolume(Float(min(1, max(0, gain))), at: .zero) }
    return p
  }

  static func makeTap(_ params: TapParams) -> MTAudioProcessingTap? {
    var callbacks = MTAudioProcessingTapCallbacks(
      version: kMTAudioProcessingTapCallbacksVersion_0,
      clientInfo: UnsafeMutableRawPointer(Unmanaged.passRetained(params).toOpaque()),
      init: { _, clientInfo, storage in storage.pointee = clientInfo },
      finalize: { tap in Unmanaged<TapParams>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).release() },
      prepare: { tap, _, format in
        let f = format.pointee
        Unmanaged<TapParams>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
          .prepare(rate: f.mSampleRate, channels: Int(f.mChannelsPerFrame), flags: f.mFormatFlags, bytesPerFrame: f.mBytesPerFrame)
      },
      unprepare: nil,
      process: { tap, frames, _, list, framesOut, flagsOut in
        guard MTAudioProcessingTapGetSourceAudio(tap, frames, list, flagsOut, nil, framesOut) == noErr else { return }
        Unmanaged<TapParams>.fromOpaque(MTAudioProcessingTapGetStorage(tap)).takeUnretainedValue()
          .process(UnsafeMutableAudioBufferListPointer(list), frames: Int(framesOut.pointee))
      })
    var tap: MTAudioProcessingTap?
    let status = MTAudioProcessingTapCreate(kCFAllocatorDefault, &callbacks, kMTAudioProcessingTapCreationFlag_PreEffects, &tap)
    if status != noErr { Unmanaged<TapParams>.fromOpaque(callbacks.clientInfo!).release(); return nil }
    return tap
  }
}
