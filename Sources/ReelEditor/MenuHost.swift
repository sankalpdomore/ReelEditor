// The window's menu layer: a dropdown's options open here, over everything, inside the window. The menu is right
// aligned under the field that opened it, with an arrow at its top right pointing at the field's caret, and springs out
// of that corner (Animation.cardOpen); a click elsewhere or Escape closes it. Coordinates are the window's own
// (.named("window"), set on MainView's content), so it works from any panel or card.
import SwiftUI

@MainActor final class MenuHost: ObservableObject {
  static let shared = MenuHost()
  struct Menu {
    let anchor: CGRect
    let options: [(id: String, label: String)]
    let selected: String?
    var icons: [String: String] = [:] // an icon before an option, for a menu of actions
    let pick: (String) -> Void
  }
  @Published private(set) var menu: Menu?
  func open(_ m: Menu) { withAnimation(.cardOpen) { menu = m } }
  func close() { withAnimation(.cardClose) { menu = nil } }
}

struct MenuLayer: View {
  @ObservedObject var host = MenuHost.shared
  var body: some View {
    if let m = host.menu {
      ZStack(alignment: .topLeading) {
        Color.black.opacity(0.001).onTapGesture { host.close() }
        HStack(spacing: 0) {
          Spacer(minLength: 8)
          OptionList(options: m.options, selected: m.selected, icons: m.icons) { id in m.pick(id); host.close() }
            .frame(minWidth: max(200, m.anchor.width))
            .fixedSize()
            .cardChrome()
            .overlay(alignment: .topTrailing) { MenuArrow().frame(width: 16, height: 8).offset(x: -14, y: -7) }
            .transition(.card(from: .topTrailing))
        }
        .frame(width: max(m.anchor.maxX, 216))
        .offset(y: m.anchor.maxY + 10)
      }
    }
  }
}

// The arrow on top of a menu or panel, pointing up at what opened it: white, with the card's #ddd border on its two
// slanted sides, so it reads as part of the card.
struct MenuArrow: View {
  var body: some View {
    ZStack {
      ArrowUp().fill(Ink.page)
      ArrowUp(open: true).stroke(Ink.border, lineWidth: 1)
    }
  }
}

struct ArrowUp: Shape {
  var open = false // the two slanted sides only, without the base
  func path(in r: CGRect) -> Path {
    Path { p in
      p.move(to: CGPoint(x: r.minX, y: r.maxY + (open ? 0.5 : 1)))
      p.addLine(to: CGPoint(x: r.midX, y: r.minY))
      p.addLine(to: CGPoint(x: r.maxX, y: r.maxY + (open ? 0.5 : 1)))
      if !open { p.closeSubpath() }
    }
  }
}
