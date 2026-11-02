// Thin scroll bars everywhere in the app (Sankalp, 2 Nov 2026): about half the width of the system's, 8 points, a rounded
// grey knob with no track, in every scroll area SwiftUI makes. NSScrollView's viewDidMoveToWindow is swapped once at
// launch for one that puts ThinScroller in its place, so each scroll area gets them as it appears.
import AppKit
import ObjectiveC

final class ThinScroller: NSScroller {
  static let width: CGFloat = 8
  override class var isCompatibleWithOverlayScrollers: Bool { true }
  override class func scrollerWidth(for controlSize: NSControl.ControlSize, scrollerStyle: NSScroller.Style) -> CGFloat { width }

  override func draw(_ dirtyRect: NSRect) { drawKnob() }
  override func drawKnobSlot(in slotRect: NSRect, highlight flag: Bool) {}
  override func drawKnob() {
    let r = rect(for: .knob)
    guard r.width > 0, r.height > 0 else { return }
    let vertical = bounds.height > bounds.width
    let k = vertical ? r.insetBy(dx: 2, dy: 2) : r.insetBy(dx: 2, dy: 2)
    let radius = min(k.width, k.height) / 2
    (NSColor.labelColor.withAlphaComponent(0.32)).setFill()
    NSBezierPath(roundedRect: k, xRadius: radius, yRadius: radius).fill()
  }
}

enum ThinScrollers {
  nonisolated(unsafe) static var installed = false

  static func install() {
    guard !installed else { return }
    installed = true
    let cls: AnyClass = NSScrollView.self
    let originalSel = #selector(NSView.viewDidMoveToWindow), swappedSel = #selector(NSScrollView.reel_viewDidMoveToWindow)
    guard let original = class_getInstanceMethod(cls, originalSel), let swapped = class_getInstanceMethod(cls, swappedSel) else { return }
    // NSScrollView inherits the method from NSView: it gets its own first, so only scroll views change, never every view.
    if class_addMethod(cls, originalSel, method_getImplementation(swapped), method_getTypeEncoding(swapped)) {
      class_replaceMethod(cls, swappedSel, method_getImplementation(original), method_getTypeEncoding(original))
    } else {
      method_exchangeImplementations(original, swapped)
    }
  }

  // A scroll area's scroll bars made thin, once.
  static func thin(_ v: NSScrollView) {
    if v.hasVerticalScroller, !(v.verticalScroller is ThinScroller) { v.verticalScroller = ThinScroller() }
    if v.hasHorizontalScroller, !(v.horizontalScroller is ThinScroller) { v.horizontalScroller = ThinScroller() }
  }
}

extension NSScrollView {
  @objc func reel_viewDidMoveToWindow() {
    reel_viewDidMoveToWindow() // the original, swapped in
    if window != nil { ThinScrollers.thin(self) }
  }
}
