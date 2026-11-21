// Record new audio (Sankalp, 21 Nov 2026): select words in the transcript whose sound is not clear, Record new audio, pick
// the microphone (the Mac's own, AirPods, any other the Mac has), and say them again. A count of three, then the words'
// picture plays with no sound from a second before them, at the pace they were said, while the take records; Stop ends
// it. replace_audio then matches the take to the voice around the words (Retake.swift) and lays it over them, and the
// card says what was matched, with Listen to hear it in place and Record again. Undo takes it off like any edit.
import AppKit
import AVFoundation
import ReelCore
import SwiftUI

// The microphones and a recording from one of them, through an AVCaptureSession: the level is read while the card is open,
// so the meter shows the microphone works before Record.
@MainActor final class MicRecorder: NSObject, ObservableObject, AVCaptureFileOutputRecordingDelegate {
  struct Mic: Identifiable, Equatable { let id: String; let name: String }
  @Published private(set) var mics: [Mic] = []
  @Published private(set) var micId: String? = nil
  @Published private(set) var level: Double = 0 // 0 to 1
  @Published private(set) var recording = false
  @Published var problem: String? = nil
  private let session = AVCaptureSession()
  private let output = AVCaptureAudioFileOutput()
  private var input: AVCaptureDeviceInput?
  private var meter: Timer?
  private var watchers: [NSObjectProtocol] = []
  private var finished: ((URL?) -> Void)?
  static let savedMic = "retakeMic"

  func open() async {
    let granted = await AVCaptureDevice.requestAccess(for: .audio)
    guard granted else { problem = "Reel Editor may not use the microphone. Allow it in System Settings, Privacy and Security, Microphone"; return }
    if session.canAddOutput(output) { session.addOutput(output) }
    refresh()
    let saved = UserDefaults.standard.string(forKey: Self.savedMic)
    select(mics.first { $0.id == saved }?.id ?? AVCaptureDevice.default(for: .audio)?.uniqueID ?? mics.first?.id)
    // AirPods put in or taken out while the card is open show up or leave the list.
    for n in [AVCaptureDevice.wasConnectedNotification, AVCaptureDevice.wasDisconnectedNotification] {
      watchers.append(NotificationCenter.default.addObserver(forName: n, object: nil, queue: .main) { [weak self] _ in
        MainActor.assumeIsolated { guard let self else { return }; self.refresh(); if let id = self.micId, !self.mics.contains(where: { $0.id == id }) { self.select(AVCaptureDevice.default(for: .audio)?.uniqueID) } }
      })
    }
    let s = session
    await Task.detached { s.startRunning() }.value
    meter = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.readLevel() } }
  }

  func refresh() {
    let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio, position: .unspecified).devices
    mics = found.map { Mic(id: $0.uniqueID, name: $0.localizedName) }
  }

  func select(_ id: String?) {
    guard let id, let device = AVCaptureDevice(uniqueID: id), !recording else { return }
    session.beginConfiguration()
    if let input { session.removeInput(input) }
    if let next = try? AVCaptureDeviceInput(device: device), session.canAddInput(next) { session.addInput(next); input = next; micId = id; problem = nil }
    else { problem = "\(device.localizedName) could not be opened" }
    session.commitConfiguration()
    UserDefaults.standard.set(id, forKey: Self.savedMic)
  }

  private func readLevel() {
    let db = output.connections.first?.audioChannels.map(\.averagePowerLevel).max() ?? -160
    level = Double(max(0, min(1, (db + 60) / 60)))
  }

  func record(to url: URL, done: @escaping (URL?) -> Void) {
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    finished = done
    output.startRecording(to: url, outputFileType: .m4a, recordingDelegate: self)
    recording = true
  }

  func stop() { if output.isRecording { output.stopRecording() } }

  func close() {
    stop()
    meter?.invalidate(); meter = nil
    for w in watchers { NotificationCenter.default.removeObserver(w) }
    watchers = []
    let s = session
    Task.detached { s.stopRunning() }
  }

  nonisolated func fileOutput(_ output: AVCaptureFileOutput, didFinishRecordingTo url: URL, from connections: [AVCaptureConnection], error: Error?) {
    // An error can still mean the file was written in full (AVErrorRecordingSuccessfullyFinishedKey).
    let saved = error == nil || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
    let message = error?.localizedDescription
    Task { @MainActor in
      self.recording = false
      if !saved { self.problem = "The recording stopped: \(message ?? "unknown")" }
      self.finished?(saved ? url : nil)
      self.finished = nil
    }
  }
}

struct RetakeModalHost: View {
  @ObservedObject var model: EditorModel
  var body: some View {
    if let r = model.retake {
      GeometryReader { g in
        ZStack {
          Color.black.opacity(0.24).contentShape(Rectangle()).onTapGesture {}
          RetakeCard(model: model, request: r)
            .frame(width: min(480, g.size.width - 64))
            .cardChrome()
            .transition(.card(from: .center))
        }
        .frame(width: g.size.width, height: g.size.height)
      }
    }
  }
}

struct RetakeCard: View {
  @ObservedObject var model: EditorModel
  let request: RetakeRequest
  @StateObject private var mic = MicRecorder()
  enum Stage: Equatable { case ready, counting(Int), recording, matching, done(JSON), failed(String) }
  @State private var stage = Stage.ready
  @State private var started = Date()
  @State private var file: URL? = nil

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        Icon("microphone", size: 16).foregroundStyle(stage == .recording ? Ink.red : Ink.strong)
        Text("Record new audio").font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
        Spacer()
        if stage == .recording { RecordingClock(since: started) }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Say these words again").font(.inter(12, .semibold)).foregroundStyle(Ink.secondary)
        Text(request.words).font(.inter(16)).foregroundStyle(Ink.text).fixedSize(horizontal: false, vertical: true)
      }
      switch stage {
      case .ready, .counting, .recording: recorder
      case .matching:
        HStack(spacing: 8) { Spinner(size: 16); Text("Matching the take to the voice around it").font(.inter(14)).foregroundStyle(Ink.text) }
      case .done(let r): result(r)
      case .failed(let m): Text(m).font(.inter(13)).foregroundStyle(Ink.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      }
      if let p = mic.problem { Text(p).font(.inter(13)).foregroundStyle(Ink.red).fixedSize(horizontal: false, vertical: true) }
      buttons
    }
    .padding(24)
    .font(.inter())
    .task { await mic.open() }
    .onDisappear { mic.close(); model.stopPlaying() }
    .onExitCommand { if stage != .recording && stage != .matching { close() } }
  }

  // The microphones to pick from and the level of the one picked.
  @ViewBuilder var recorder: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("Microphone").font(.inter(12, .semibold)).foregroundStyle(Ink.secondary)
      VStack(spacing: 4) {
        ForEach(mic.mics) { m in
          let on = m.id == mic.micId
          Button { mic.select(m.id) } label: {
            HStack(spacing: 8) {
              Icon(Self.icon(m.name), size: 14).foregroundStyle(on ? Ink.strong : Ink.muted)
              Text(m.name).font(.inter(14)).foregroundStyle(on ? Ink.strong : Ink.text).lineLimit(1)
              Spacer()
              if on { Icon("check", size: 14).foregroundStyle(Ink.strong) }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 8).fill(on ? Ink.raised : .clear))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(on ? Ink.border : .clear, lineWidth: 1))
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .disabled(stage != .ready)
        }
        if mic.mics.isEmpty { Note("No microphone found. Connect one, or put in your AirPods") }
      }
      .padding(4)
      .background(RoundedRectangle(cornerRadius: 12).fill(Ink.shell))
      LevelMeter(level: mic.level, live: stage == .recording)
      switch stage {
      case .counting(let n): Text("Starting in \(n)").font(.inter(14, .medium)).foregroundStyle(Ink.strong)
      case .recording: Note("The words play with no sound, from a second before them. Say them as the lips move, then Stop.")
      default: Note("After a count of three the words play with no sound so you can follow the lips. The take is matched to the voice around them.")
      }
    }
  }

  static func icon(_ name: String) -> String {
    let n = name.lowercased()
    return n.contains("airpods") || n.contains("headphone") || n.contains("buds") || n.contains("beats") ? "headphones" : "microphone"
  }

  @ViewBuilder func result(_ r: JSON) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) { Icon("check-circle", size: 16).foregroundStyle(Ink.green); Text("The take is in, over these words").font(.inter(14, .medium)).foregroundStyle(Ink.strong) }
      ForEach(Self.summary(r), id: \.self) { Note($0) }
      if let o = r["overrun"]?.double {
        Text("It still runs \(String(format: "%.1f", o)) s into the next words. Say it a little faster and record again, or select more words.")
          .font(.inter(13)).foregroundStyle(Ink.amber).fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  // What was matched, in words.
  static func summary(_ r: JSON) -> [String] {
    var out: [String] = []
    let g = r["gainDb"]?.double ?? 0
    out.append(abs(g) < 1 ? "Loudness: already the same as the video." : "Loudness: \(g > 0 ? "raised" : "lowered") \(Int(abs(g).rounded())) dB to the video's voice.")
    let bands = r["toneDb"]?.array ?? []
    out.append(bands.isEmpty ? "Tone: already close to the video's." : "Tone: \(bands.count) of 22 bands moved toward the video's voice.")
    out.append(r["roomTone"]?.bool == true ? "Room: the video's background laid under it." : "Room: the take's own background kept.")
    if let rate = r["rate"]?.double, rate > 1.001 { out.append("Pace: \(String(format: "%.2f", rate))x, to end before the next words.") }
    return out
  }

  @ViewBuilder var buttons: some View {
    HStack(spacing: 8) {
      Spacer()
      switch stage {
      case .ready:
        Button("Cancel") { close() }.pill(.ghost, .md)
        Button { count() } label: { IconLabel("Record", icon: "record", size: 14) }.pill(.primary, .md).keyboardShortcut(.defaultAction)
          .disabled(mic.micId == nil)
      case .counting:
        Button("Cancel") { stage = .ready }.pill(.ghost, .md)
      case .recording:
        Button { stop() } label: { IconLabel("Stop", icon: "stop", size: 14) }.pill(.destructive, .md).keyboardShortcut(.defaultAction)
      case .matching:
        EmptyView()
      case .done(let r):
        Button { model.playFrom(request.start) } label: { IconLabel("Listen", icon: "play", size: 14) }.pill(.outline, .md)
        // The take just made comes off first: a take never goes over another.
        Button { recordAgain(r) } label: { IconLabel("Record again", icon: "arrow-counter-clockwise", size: 14) }.pill(.outline, .md)
        Button("Done") { close() }.pill(.primary, .md).keyboardShortcut(.defaultAction)
      case .failed:
        Button("Close") { close() }.pill(.ghost, .md)
        Button { stage = .ready; mic.problem = nil } label: { IconLabel("Record again", icon: "arrow-counter-clockwise", size: 14) }.pill(.primary, .md).keyboardShortcut(.defaultAction)
      }
    }
  }

  func close() { mic.close(); model.stopPlaying(); withAnimation(.cardClose) { model.retake = nil } }

  func count() {
    Task { @MainActor in
      for n in [3, 2, 1] {
        stage = .counting(n)
        try? await Task.sleep(for: .seconds(1))
        guard stage == .counting(n) else { return } // Cancel
      }
      let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
      let url = Retake.folder(model.name).appendingPathComponent("take-\(stamp).m4a")
      file = url
      started = Date()
      stage = .recording
      mic.record(to: url) { saved in finish(saved) }
      model.playAlong(from: request.start)
    }
  }

  func stop() { model.stopPlaying(); mic.stop() }

  func recordAgain(_ r: JSON) {
    model.stopPlaying()
    guard let id = r["created"]?.string else { stage = .ready; return }
    model.run("delete_audio_overlay", ["id": .string(id)]) { _ in stage = .ready }
  }

  func finish(_ url: URL?) {
    guard let url else { stage = .failed(mic.problem ?? "The recording was not saved"); return }
    stage = .matching
    model.error = nil
    model.run("replace_audio", ["path": .string(url.path), "start": .number(round3(request.start)), "end": .number(round3(request.end))]) { r in
      stage = .done(r)
    }
    // A failure lands in model.error; the card says so instead of spinning.
    Task { @MainActor in
      while stage == .matching { try? await Task.sleep(for: .milliseconds(200)); if !model.busy, stage == .matching, let e = model.error { stage = .failed(e) } }
    }
  }
}

// The level of the microphone, a bar that is red while recording.
struct LevelMeter: View {
  let level: Double
  var live = false
  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Ink.sunken)
        Capsule().fill(live ? Ink.red : Ink.green).frame(width: max(8, g.size.width * level))
      }
    }
    .frame(height: 8)
    .animation(.linear(duration: 0.05), value: level)
  }
}

// How long the take has been recording.
struct RecordingClock: View {
  let since: Date
  var body: some View {
    SwiftUI.TimelineView(.periodic(from: since, by: 0.1)) { ctx in
      Text(String(format: "%.1f s", ctx.date.timeIntervalSince(since))).font(.inter(14, .medium)).foregroundStyle(Ink.red).monospacedDigit()
    }
  }
}
