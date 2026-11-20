// The picture of a reel that needs more than AVFoundation's own compositor can draw: the look of the picture (set_video_look,
// set_clip_look), a clip's picture zoomed and moved in the frame (set_clip_placement) and the face overlays, each a video in a
// small rounded window with a #333 border and a soft shadow that eases to new places (add_face_overlay, set_face_window). It
// is a custom AVVideoCompositing drawn with Core Image, used only when a reel has one of those, and the same composition is
// what the preview plays and the export renders, so what is previewed is what is exported. Sizes follow the web editor's
// export (lib/reel-tools/faces.ts and lib/reel-look.ts), in px of a 1080 wide frame scaled to this one.
import AVFoundation
import CoreImage
import Foundation

// Everything one frame needs, worked out once per composition. Times are output seconds, after the speed.
final class ReelScene: @unchecked Sendable {
  struct MainPiece { var t0: Double; var t1: Double; var transform: CGAffineTransform; var look: ReelLook?; var lookOff: Bool; var place: ReelPlace? }
  struct FacePiece { var t0: Double; var t1: Double; var local0: Double } // local0: seconds into the overlay at t0
  struct Face { var track: CMPersistentTrackID; var orient: CGAffineTransform; var natural: CGSize; var window: FaceWindow; var pieces: [FacePiece] }
  let render: CGSize
  let speed: Double
  let mainTrack: CMPersistentTrackID
  let main: [MainPiece]
  let faces: [Face]
  let reelLook: ReelLook?
  let perLayerLook: Bool // a clip has a look of its own or none: each layer gets its own, else the reel's look covers the frame
  init(render: CGSize, speed: Double, mainTrack: CMPersistentTrackID, main: [MainPiece], faces: [Face], reelLook: ReelLook?, perLayerLook: Bool) {
    self.render = render; self.speed = speed; self.mainTrack = mainTrack; self.main = main; self.faces = faces; self.reelLook = reelLook; self.perLayerLook = perLayerLook
  }
}

final class ReelInstruction: NSObject, AVVideoCompositionInstructionProtocol, @unchecked Sendable {
  let timeRange: CMTimeRange
  let enablePostProcessing = true // the captions, title and animations are laid on after, by the export's animation tool
  let containsTweening = true
  let requiredSourceTrackIDs: [NSValue]?
  let passthroughTrackID = kCMPersistentTrackID_Invalid
  let scene: ReelScene
  init(timeRange: CMTimeRange, scene: ReelScene) {
    self.timeRange = timeRange; self.scene = scene
    requiredSourceTrackIDs = ([scene.mainTrack] + scene.faces.map(\.track)).map { NSNumber(value: $0) }
  }
}

// A transform in AVFoundation's top left space (a track's preferredTransform, a layer instruction's fit) as one in Core
// Image's bottom left space, for an image `inH` high drawn into a space `outH` high.
func ciTransform(_ t: CGAffineTransform, inH: CGFloat, outH: CGFloat) -> CGAffineTransform {
  CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: inH).concatenating(t).concatenating(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: outH))
}

enum LookFilter {
  // The look on an image, cropped back to `rect`. The same mapping as lib/reel-look.ts: the light scaled by brightness and
  // exposure, contrast and saturation as factors, the temperature tinted warm or cool, an unsharp mask and a vignette.
  static func apply(_ img: CIImage, _ l: ReelLook, rect: CGRect, unit: CGFloat) -> CIImage {
    var out = img
    let g = CGFloat(l.gain)
    if abs(g - 1) > 0.001 {
      out = out.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: g, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: g, w: 0)])
    }
    if l.contrast != 0 || l.saturation != 0 {
      out = out.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: l.saturationFactor, kCIInputContrastKey: l.contrastFactor, kCIInputBrightnessKey: 0])
    }
    if l.temperature != 0 {
      // Plus is warmer, as ffmpeg's colortemperature at 6500 - 30 K per step: Core Image warms the picture as the target
      // neutral goes below 6500 K (checked on an export: +100 raises red and lowers blue).
      out = out.applyingFilter("CITemperatureAndTint", parameters: ["inputNeutral": CIVector(x: 6500, y: 0), "inputTargetNeutral": CIVector(x: 6500 - CGFloat(l.temperature) * 30, y: 0)])
    }
    if l.sharpness != 0 {
      out = out.clampedToExtent().applyingFilter("CIUnsharpMask", parameters: [kCIInputRadiusKey: 2.5 * unit, kCIInputIntensityKey: l.sharpness / 100 * 1.5]).cropped(to: rect)
    }
    if l.vignette != 0 {
      let r = hypot(rect.width, rect.height) / 2
      out = out.applyingFilter("CIVignetteEffect", parameters: [kCIInputCenterKey: CIVector(x: rect.midX, y: rect.midY), kCIInputRadiusKey: r * (1.05 - CGFloat(l.vignette) / 100 * 0.35),
                                                                kCIInputIntensityKey: l.vignette / 100, "inputFalloff": 0.6])
    }
    return out.cropped(to: rect)
  }
}

final class ReelCompositor: NSObject, AVVideoCompositing, @unchecked Sendable {
  // No colour management: the pixels pass through as AVFoundation's own compositor passes them, so a reel with no look reads
  // the same either way.
  static let context = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull(), .cacheIntermediates: false])
  private let queue = DispatchQueue(label: "reel.compositor")
  private var renderContext: AVVideoCompositionRenderContext?

  let sourcePixelBufferAttributes: [String: any Sendable]? = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA), kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()]
  let requiredPixelBufferAttributesForRenderContext: [String: any Sendable] = [kCVPixelBufferPixelFormatTypeKey as String: Int(kCVPixelFormatType_32BGRA), kCVPixelBufferIOSurfacePropertiesKey as String: [String: Int]()]

  func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) { queue.sync { renderContext = newRenderContext } }

  func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
    queue.async {
      guard let ins = request.videoCompositionInstruction as? ReelInstruction, let buffer = request.renderContext.newPixelBuffer() else {
        request.finish(with: NSError(domain: "ReelCompositor", code: 1, userInfo: [NSLocalizedDescriptionKey: "No instruction or buffer"])); return
      }
      let image = ReelCompositor.frame(ins.scene, at: request.compositionTime.seconds) { id in
        request.sourceFrame(byTrackID: id).map { CIImage(cvPixelBuffer: $0, options: [.colorSpace: NSNull()]) }
      }
      ReelCompositor.context.render(image, to: buffer, bounds: CGRect(origin: .zero, size: ins.scene.render), colorSpace: nil)
      request.finish(withComposedVideoFrame: buffer)
    }
  }

  func cancelAllPendingVideoCompositionRequests() {}

  // One frame of the scene at output time t.
  static func frame(_ s: ReelScene, at t: Double, source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
    let rect = CGRect(origin: .zero, size: s.render)
    let unit = s.render.width / 1080
    var frame = CIImage(color: .black).cropped(to: rect)
    if let src = source(s.mainTrack) {
      let piece = s.main.last { t >= $0.t0 - 0.0005 } ?? s.main.first
      var img = src.transformed(by: piece?.transform ?? .identity)
      if let p = piece?.place {
        let W = s.render.width, H = s.render.height
        img = img.transformed(by: CGAffineTransform(translationX: -W / 2, y: -H / 2).concatenating(CGAffineTransform(scaleX: p.zoom, y: p.zoom))
          .concatenating(CGAffineTransform(translationX: W / 2 + p.x * W, y: H / 2 - p.y * H)))
      }
      img = img.cropped(to: rect)
      if s.perLayerLook, let piece, !piece.lookOff, let look = piece.look ?? s.reelLook { img = LookFilter.apply(img, look, rect: rect, unit: unit) }
      frame = img.composited(over: frame)
    }
    for f in s.faces {
      guard let piece = f.pieces.first(where: { t >= $0.t0 - 0.0005 && t < $0.t1 + 0.0005 }), let src = source(f.track) else { continue }
      let local = piece.local0 + max(0, t - piece.t0) * s.speed
      frame = face(f, src, local: local, scene: s, unit: unit).composited(over: frame)
    }
    if !s.perLayerLook, let look = s.reelLook { frame = LookFilter.apply(frame, look, rect: rect, unit: unit) }
    return frame.cropped(to: rect)
  }

  // A face window: the picture fitted (or cropped to the window's ratio), zoomed and moved inside it, rounded, with its border
  // and its shadow, at its place at `local` seconds into the overlay.
  static func face(_ f: ReelScene.Face, _ src: CIImage, local: Double, scene s: ReelScene, unit k: CGFloat) -> CIImage {
    let W = s.render.width, H = s.render.height
    var pic = src.transformed(by: f.orient)
    pic = pic.transformed(by: CGAffineTransform(translationX: -pic.extent.minX, y: -pic.extent.minY))
    let dW = max(1, pic.extent.width), dH = max(1, pic.extent.height)
    let win = f.window
    let winW = max(2, (CGFloat(win.w) * W / 2).rounded() * 2)
    let winH = max(2, ((win.ratio.map { winW * CGFloat($0) } ?? winW * dH / dW) / 2).rounded() * 2)
    let box = CGRect(x: 0, y: 0, width: winW, height: winH)
    let cover = max(winW / dW, winH / dH)
    pic = pic.transformed(by: CGAffineTransform(scaleX: cover, y: cover).concatenating(CGAffineTransform(translationX: (winW - dW * cover) / 2, y: (winH - dH * cover) / 2)))
    if let p = win.place {
      pic = pic.transformed(by: CGAffineTransform(translationX: -winW / 2, y: -winH / 2).concatenating(CGAffineTransform(scaleX: p.zoom, y: p.zoom))
        .concatenating(CGAffineTransform(translationX: winW / 2 + p.x * winW, y: winH / 2 - p.y * winH)))
    }
    pic = pic.cropped(to: box)
    if s.perLayerLook, let look = s.reelLook { pic = LookFilter.apply(pic, look, rect: box, unit: k) }
    let B = max(2, (3 * k).rounded()), P = (30 * k).rounded(), dy = (6 * k).rounded()
    let R = min(((win.radius ?? 40) * k).rounded(), min(winW, winH) / 2)
    func rounded(_ r: CGRect, _ radius: CGFloat, _ color: CIColor) -> CIImage {
      CIFilter(name: "CIRoundedRectangleGenerator", parameters: ["inputExtent": CIVector(cgRect: r), kCIInputRadiusKey: radius, kCIInputColorKey: color])?.outputImage?.cropped(to: r) ?? CIImage.empty()
    }
    let inner = box.insetBy(dx: B, dy: B)
    let mask = rounded(inner, max(0, R - B), CIColor(red: 1, green: 1, blue: 1))
    let masked = pic.applyingFilter("CIBlendWithAlphaMask", parameters: [kCIInputBackgroundImageKey: CIImage.empty(), kCIInputMaskImageKey: mask])
    let border = rounded(box, R, CIColor(red: 0.2, green: 0.2, blue: 0.2))
    let shadow = rounded(box, R, CIColor(red: 0, green: 0, blue: 0, alpha: 0.35)).applyingGaussianBlur(sigma: Double(P) / 4)
      .cropped(to: box.insetBy(dx: -P, dy: -P)).transformed(by: CGAffineTransform(translationX: 0, y: -dy))
    let at = windowAt(win, local)
    let left = CGFloat(at.x) * W, bottom = H - CGFloat(at.y) * H - winH / 2
    return masked.composited(over: border).composited(over: shadow).transformed(by: CGAffineTransform(translationX: left.rounded(), y: bottom.rounded()))
  }
}
