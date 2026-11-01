// The preview: the composition in an AVPlayerLayer, with the overlay (title and coded animations) on an
// AVSynchronizedLayer so it runs on the player's clock, the same layer tree the export renders. The captions are drawn by
// SwiftUI on top, from the same caption groups the export uses.
import AVFoundation
import AppKit
import ReelCore
import SwiftUI

final class PlayerNSView: NSView {
  let playerLayer = AVPlayerLayer()
  var sync: AVSynchronizedLayer?
  var overlay: CALayer?
  var renderSize = CGSize(width: 1920, height: 1080)

  override init(frame: NSRect) {
    super.init(frame: frame)
    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    playerLayer.videoGravity = .resizeAspect
    layer?.addSublayer(playerLayer)
  }
  required init?(coder: NSCoder) { fatalError() }

  var videoRect: CGRect { AVMakeRect(aspectRatio: renderSize, insideRect: bounds) }

  override func layout() {
    super.layout()
    CATransaction.begin(); CATransaction.setDisableActions(true)
    playerLayer.frame = bounds
    if let sync, let overlay {
      let r = videoRect
      sync.frame = r
      let k = r.width / max(1, renderSize.width)
      overlay.anchorPoint = .zero
      overlay.position = .zero
      overlay.setAffineTransform(CGAffineTransform(scaleX: k, y: k))
    }
    CATransaction.commit()
  }

  func install(item: AVPlayerItem?, overlay: CALayer?, size: CGSize) {
    CATransaction.begin(); CATransaction.setDisableActions(true)
    sync?.removeFromSuperlayer()
    sync = nil; self.overlay = nil
    renderSize = size
    if let item, let overlay {
      let s = AVSynchronizedLayer(playerItem: item)
      s.addSublayer(overlay)
      s.masksToBounds = true
      layer?.addSublayer(s)
      sync = s; self.overlay = overlay
    }
    CATransaction.commit()
    needsLayout = true
  }
}

struct PlayerLayerView: NSViewRepresentable {
  @ObservedObject var model: EditorModel

  final class Coordinator { var version = -1 }
  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> PlayerNSView {
    let v = PlayerNSView()
    v.playerLayer.player = model.player
    return v
  }

  func updateNSView(_ v: PlayerNSView, context: Context) {
    guard context.coordinator.version != model.overlayVersion else { return }
    context.coordinator.version = model.overlayVersion
    if let rc = model.rc {
      v.install(item: model.player.currentItem, overlay: Overlay.layer(model.loaded, rc, contentsScale: 2, captions: false), size: rc.renderSize)
    } else { v.install(item: nil, overlay: nil, size: model.exportSize) }
  }
}

// The caption on screen at the playhead, styled like the export's.
struct CaptionOverlay: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var clock: Clock

  var body: some View {
    GeometryReader { geo in
      let size = model.exportSize
      let fit = AVMakeRect(aspectRatio: size, insideRect: CGRect(origin: .zero, size: geo.size))
      let k = fit.width / max(1, size.width)
      let u = min(size.width, size.height) / 1080 * k
      let landscape = size.width > size.height
      let out = outputOf(model.plan, clock.time) / model.speed
      if let g = model.captionGroups.first(where: { out >= $0.s && out < $0.e }) {
        Text(g.text)
          .font(.system(size: (landscape ? 72 : 78) * u, weight: .heavy))
          .foregroundStyle(.white)
          .multilineTextAlignment(.center)
          .padding(.horizontal, 22 * u).padding(.vertical, 14 * u)
          .background(RoundedRectangle(cornerRadius: 18 * u).fill(.black.opacity(0.82)))
          .frame(maxWidth: (landscape ? 0.62 : 0.8) * fit.width)
          .position(captionPoint(fit: fit, k: k))
      }
    }
    .allowsHitTesting(false)
  }

  // Where the export puts the captions (Overlay.captionCenter, set_caption_position), in the preview's points.
  func captionPoint(fit: CGRect, k: Double) -> CGPoint {
    let size = model.exportSize
    let c = Overlay.captionCenter(model.loaded.project.edits, size: size)
    return CGPoint(x: fit.minX + c.x * k, y: fit.minY + (size.height - c.y) * k)
  }
}

// The video on a light grey backdrop, its corners rounded, and under it the transport as in the web editor: the time, a
// step back, the big black play button, a step forward and the original length.
struct PreviewPane: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    VStack(spacing: 0) {
      ZStack {
        PlayerLayerView(model: model)
        CaptionOverlay(model: model, clock: model.clock)
        if model.rc == nil, let e = model.error {
          VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) { Icon("warning-circle", size: 16); Text(e).font(.inter(13)) }.foregroundStyle(Ink.red)
            if e.contains("not there") || e.contains("moved") {
              Button { model.relink("main") } label: { IconLabel("Find the video", icon: "magnifying-glass", size: 14) }.pill(.primary, .sm)
            }
          }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.page))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.red.opacity(0.3), lineWidth: 1))
            .padding(24)
        }
      }
      .contentShape(Rectangle())
      .onTapGesture { model.togglePlay() }
      .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 8)
      Transport(model: model, clock: model.clock)
    }
    .background(Ink.sunken)
  }
}

struct Transport: View {
  @ObservedObject var model: EditorModel
  @ObservedObject var clock: Clock

  var body: some View {
    let out = outputOf(model.plan, clock.time) / model.speed
    HStack(spacing: 24) {
      HStack(spacing: 4) {
        Text(timecode(out)).foregroundStyle(Ink.strong)
        Text("/ \(timecode(model.plan.duration / model.speed))").foregroundStyle(Ink.faint)
      }
      .font(.inter(16)).monospacedDigit().fixedSize()
      Button { model.step(-1.0 / 30) } label: { Icon("skip-back", size: 18) }.pill(.ghost, .icon).help("Back a frame (Left arrow, a second with Shift)")
      Button { model.togglePlay() } label: { Icon(clock.playing ? "pause" : "play", size: 22, fill: true).foregroundStyle(Ink.onPrimary) }
        .buttonStyle(.plain)
        .frame(width: 48, height: 48)
        .background(Circle().fill(Ink.strong))
        .contentShape(Circle())
        .help("Play or pause (Space)")
      Button { model.step(1.0 / 30) } label: { Icon("skip-forward", size: 18) }.pill(.ghost, .icon).help("Forward a frame (Right arrow, a second with Shift)")
      Text("Original \(timecode(model.plan.editDuration))").font(.inter(16)).foregroundStyle(Ink.faint).monospacedDigit().fixedSize()
    }
    .foregroundStyle(Ink.text)
    .frame(maxWidth: .infinity)
    .frame(height: 72)
  }
}
