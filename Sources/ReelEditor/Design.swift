// The design language of the ContentApp web app, ported to SwiftUI so the Mac app looks like the main app instead of
// stock macOS: Inter type, Phosphor Bold and Fill icons, the clean grey stops (#111 to #eee), #ddd borders, pill
// buttons (the black gradient primary, the white outline, the ghost, the white to grey gradient), the grey segmented
// tabs with a white active tab, uppercase panel labels, the Draft and Live pills and the inset card (a grey shell with
// a white card inside, each level 4 points less rounded). Spacing is in multiples of 4. Source of truth:
// NextDoorCompanyCode/DESIGN.md, components/ui/button/button.css, components/ui/tabs/tabs.css and
// components/reel-editor/reel-editor.css in the web app. Every view in this app takes its look from here.
import AppKit
import CoreText
import SwiftUI

// ---------------------------------------------------------------------------------------------------------------------
// Fonts

enum DesignFonts {
  // Inter and Phosphor ship in Resources/Fonts, copied into the app by build.sh. A debug build run from .build reads
  // them from the source folder instead.
  static func register() {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("Fonts")
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Fonts").standardized
    let dir = [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }
    guard let dir, let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
    for f in files where f.pathExtension == "ttf" { CTFontManagerRegisterFontsForURL(f as CFURL, .process, nil) }
  }
}

extension Font {
  // Inter at a size and weight, the app's only typeface. 14 is the default, as in the web app.
  static func inter(_ size: CGFloat = 14, _ weight: Font.Weight = .regular, italic: Bool = false) -> Font {
    if italic { return .custom("Inter-Italic", size: size) }
    switch weight {
    case .bold, .heavy, .black: return .custom("Inter-Bold", size: size)
    case .semibold: return .custom("Inter-SemiBold", size: size)
    case .medium: return .custom("Inter-Medium", size: size)
    default: return .custom("Inter-Regular", size: size)
    }
  }
}

// A brand mark from Resources/Brand (an SVG, drawn by AppKit), for example the Claude logo on the MCP pill.
struct BrandMark: View {
  let name: String
  var size: CGFloat = 14
  static func image(_ name: String) -> NSImage? {
    let bundled = Bundle.main.resourceURL?.appendingPathComponent("Brand/\(name).svg")
    let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../Resources/Brand/\(name).svg").standardized
    return [bundled, source].compactMap { $0 }.first { FileManager.default.fileExists(atPath: $0.path) }.flatMap { NSImage(contentsOf: $0) }
  }
  var body: some View {
    if let img = Self.image(name) { Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size) }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Colours: the grey stops, light and dark. The web app is light only; dark mirrors each stop so the Theme setting
// still works.

extension NSColor {
  convenience init(hex: UInt32, alpha: CGFloat = 1) {
    self.init(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
  }
}

private func tone(_ light: UInt32, _ dark: UInt32) -> Color {
  Color(nsColor: NSColor(name: nil) { a in
    a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
  })
}

enum Ink {
  static let page = tone(0xffffff, 0x111111) // the window
  static let sunken = tone(0xf7f7f7, 0x1c1c1c) // the tab row, the player's backdrop
  static let shell = tone(0xeeeeee, 0x222222) // an inset card's grey shell, a chip
  static let segment = tone(0xf0f0f0, 0x222222) // the tabs container
  static let raised = tone(0xffffff, 0x333333) // the active tab, a card on a shell
  static let hover = tone(0xf5f5f5, 0x2a2a2a) // a ghost or outline button under the pointer
  static let border = tone(0xdddddd, 0x333333) // every resting border
  static let borderHover = tone(0xcccccc, 0x444444)
  static let hairline = tone(0xdddddd, 0x333333) // the lines between the window's zones, #ddd like every border (Sankalp, 2 Nov 2026)
  static let strong = tone(0x111111, 0xeeeeee) // titles
  static let text = tone(0x333333, 0xdddddd) // body text
  static let secondary = tone(0x666666, 0xaaaaaa)
  static let muted = tone(0x777777, 0x999999) // panel labels, icons
  static let faint = tone(0x999999, 0x777777) // timecodes, meta lines
  static let ghost = tone(0xbbbbbb, 0x555555) // placeholders, cut words
  static let primaryTop = tone(0x333333, 0xffffff)
  static let primaryBottom = tone(0x111111, 0xdddddd)
  static let primaryHoverTop = tone(0x555555, 0xffffff)
  static let primaryHoverBottom = tone(0x333333, 0xeeeeee)
  static let onPrimary = tone(0xffffff, 0x111111)
  static let focus = Color(nsColor: NSColor(hex: 0x007bff)) // the blue hover ring of the gradient button
  static let select = Color(nsColor: NSColor(hex: 0x007bff, alpha: 0.18)) // selected words and ranges
  static let red = Color(nsColor: NSColor(hex: 0xef4444))
  static let green = Color(nsColor: NSColor(hex: 0x2f7d3b))
  static let amber = Color(nsColor: NSColor(hex: 0xb45309)) // a cut waiting for approval
  static let yellow = Color(nsColor: NSColor(hex: 0xeab308)) // the wash on a paragraph whose cuts wait for review
}

// ---------------------------------------------------------------------------------------------------------------------
// Icons: Phosphor, the web app's icon set. Icon("scissors") is <i class="ph-bold ph-scissors">, fill: true is ph-fill.
// The codes live in PhosphorCodes.swift, made by tools/reel-editor-mac/phosphor-codes.sh from the names used here.

struct Icon: View {
  let name: String
  var size: CGFloat = 14
  var fill = false
  init(_ name: String, size: CGFloat = 14, fill: Bool = false) { self.name = name; self.size = size; self.fill = fill }
  var body: some View {
    Text(PhosphorCodes.map[name].map { String(Character(UnicodeScalar($0)!)) } ?? "?")
      .font(.custom(fill ? "Phosphor-Fill" : "Phosphor-Bold", size: size))
      .frame(minWidth: size, minHeight: size)
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Buttons: the web Button component's variants and sizes, fully round.

enum PillVariant { case primary, outline, secondary, ghost, gradient, destructive }
enum PillSize {
  case xs, sm, md, icon, iconSm
  var height: CGFloat { switch self { case .xs, .iconSm: return 28; case .sm: return 32; case .md: return 40; case .icon: return 36 } }
  var padding: CGFloat { switch self { case .xs: return 12; case .sm: return 12; case .md: return 16; case .icon, .iconSm: return 0 } }
  var font: CGFloat { self == .xs || self == .iconSm ? 12 : 14 }
}

struct PillButtonStyle: ButtonStyle {
  var variant: PillVariant = .outline
  var size: PillSize = .sm
  var active = false // a ghost button that is switched on (Follow, a layout), drawn like a hovered one
  func makeBody(configuration: Configuration) -> some View { PillBody(configuration: configuration, variant: variant, size: size, active: active) }
}

private struct PillBody: View {
  let configuration: ButtonStyle.Configuration
  let variant: PillVariant
  let size: PillSize
  let active: Bool
  @State private var hover = false
  @Environment(\.isEnabled) private var enabled

  var body: some View {
    let round = size == .icon || size == .iconSm
    configuration.label
      .font(.inter(size.font, .medium))
      .lineLimit(1)
      .foregroundStyle(foreground)
      .padding(.horizontal, size.padding)
      .frame(width: round ? size.height : nil, height: size.height)
      .background { Capsule().fill(fill) }
      .overlay { Capsule().strokeBorder(stroke, lineWidth: 1) }
      .overlay { if variant == .gradient && hover { Capsule().stroke(Ink.focus.opacity(0.1), lineWidth: 4).padding(-1) } }
      .shadow(color: .black.opacity(variant == .ghost ? 0 : 0.06), radius: 1, y: 1)
      .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
      .contentShape(Capsule())
      .onHover { hover = $0 && enabled }
      .animation(.easeOut(duration: 0.15), value: hover)
  }

  var foreground: Color {
    switch variant {
    case .primary, .destructive: return Ink.onPrimary
    case .secondary: return Ink.strong
    default: return Ink.text
    }
  }

  var fill: AnyShapeStyle {
    switch variant {
    case .primary:
      return AnyShapeStyle(LinearGradient(colors: hover ? [Ink.primaryHoverTop, Ink.primaryHoverBottom] : [Ink.primaryTop, Ink.primaryBottom], startPoint: .top, endPoint: .bottom))
    case .destructive: return AnyShapeStyle(Ink.red.opacity(hover ? 0.9 : 1))
    case .outline: return AnyShapeStyle(hover ? Ink.hover : Ink.raised)
    case .secondary: return AnyShapeStyle(hover ? Ink.shell : Ink.hover)
    case .ghost: return AnyShapeStyle(hover || active ? Ink.hover : Color.clear)
    case .gradient: return AnyShapeStyle(LinearGradient(stops: [.init(color: Ink.raised, location: 0), .init(color: Ink.sunken, location: 0.68), .init(color: Ink.shell, location: 1)], startPoint: .top, endPoint: .bottom))
    }
  }

  var stroke: Color {
    switch variant {
    case .primary: return Ink.primaryBottom
    case .destructive: return Ink.red
    case .ghost: return active ? Ink.border : .clear
    case .gradient: return hover ? Ink.focus : Ink.border
    default: return hover ? Ink.borderHover : Ink.border
    }
  }
}

extension View {
  func pill(_ variant: PillVariant = .outline, _ size: PillSize = .sm, active: Bool = false) -> some View {
    buttonStyle(PillButtonStyle(variant: variant, size: size, active: active))
  }
}

// An icon and a label side by side in a button, 8 apart, as the web buttons lay them out.
struct IconLabel: View {
  let icon: String
  let text: String
  var size: CGFloat = 14
  init(_ text: String, icon: String, size: CGFloat = 14) { self.text = text; self.icon = icon; self.size = size }
  var body: some View { HStack(spacing: 8) { Icon(icon, size: size); Text(text) } }
}

// ---------------------------------------------------------------------------------------------------------------------
// Tabs: the web Tabs component. A grey container, the active tab white with a soft shadow, the others grey text.

struct SegmentItem<T: Hashable>: Identifiable {
  let value: T
  let label: String
  var icon: String? = nil
  var id: T { value }
}

struct SegmentTabs<T: Hashable>: View {
  let items: [SegmentItem<T>]
  @Binding var selection: T
  var iconOnly = false
  var fullWidth = false
  var height: Double = 40 // the whole bar; 32 sits level with a Dropdown beside it
  @Namespace private var ns

  var body: some View {
    HStack(spacing: 4) {
      ForEach(items) { item in
        let on = item.value == selection
        Button { withAnimation(.easeOut(duration: 0.18)) { selection = item.value } } label: {
          HStack(spacing: 6) {
            if let i = item.icon { Icon(i, size: 14) }
            if !iconOnly || item.icon == nil { Text(item.label).lineLimit(1) }
          }
          .font(.inter(13, .medium))
          .foregroundStyle(on ? Ink.text : Ink.faint)
          .padding(.horizontal, iconOnly ? 8 : 12)
          .frame(maxWidth: fullWidth ? .infinity : nil)
          .frame(height: height - 8)
          .background {
            if on {
              RoundedRectangle(cornerRadius: 8).fill(Ink.raised)
                .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                .matchedGeometryEffect(id: "active", in: ns)
            }
          }
          .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help(item.label)
      }
    }
    .padding(4)
    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.segment))
    .fixedSize(horizontal: !fullWidth, vertical: true)
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Labels, pills and lines

// The uppercase label at the head of a panel: "TRANSCRIPT", an icon before it.
struct PanelLabel: View {
  let icon: String
  let text: String
  init(_ text: String, icon: String) { self.text = text; self.icon = icon }
  var body: some View {
    HStack(spacing: 8) {
      Icon(icon, size: 16).foregroundStyle(Ink.muted)
      Text(text.uppercased()).font(.inter(12, .semibold)).tracking(0.96).foregroundStyle(Ink.muted)
    }
  }
}

// A small fact beside a panel label, an icon and grey text: "16 cuts, 17 s saved".
struct MetaLabel: View {
  let icon: String
  let text: String
  init(_ text: String, icon: String) { self.text = text; self.icon = icon }
  var body: some View {
    HStack(spacing: 4) { Icon(icon, size: 12); Text(text).lineLimit(1) }
      .font(.inter(12)).foregroundStyle(Ink.faint)
  }
}

// The reel status pill: Draft in purple, Live in green with a tick.
struct StatusPill: View {
  enum Kind { case draft, live }
  let kind: Kind
  var body: some View {
    let (fg, bg, line): (UInt32, UInt32, UInt32) = kind == .draft ? (0x5b3fa0, 0xf4f0fb, 0xddd2f3) : (0x2f7d3b, 0xeef8f0, 0xcfe8d4)
    HStack(spacing: 4) {
      Icon(kind == .draft ? "note-pencil" : "check", size: 12)
      Text(kind == .draft ? "Draft" : "Live")
    }
    .font(.inter(12, .medium))
    .foregroundStyle(Color(nsColor: NSColor(hex: fg)))
    .padding(.horizontal, 8).frame(height: 18)
    .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: NSColor(hex: bg))))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: NSColor(hex: line)), lineWidth: 1))
    .fixedSize()
  }
}

// A count or a short word in a small grey chip.
struct Chip: View {
  let text: String
  var body: some View {
    Text(text).font(.inter(11, .semibold)).foregroundStyle(Ink.secondary)
      .padding(.horizontal, 6).frame(height: 18)
      .background(RoundedRectangle(cornerRadius: 8).fill(Ink.shell))
  }
}

struct Hairline: View {
  var vertical = false
  var body: some View { Rectangle().fill(Ink.hairline).frame(width: vertical ? 1 : nil, height: vertical ? nil : 1) }
}

// ---------------------------------------------------------------------------------------------------------------------
// Cards

// The inset card: the header text on a grey shell, the body a white card inset 4 from the shell's sides and bottom.
// A progress bar: a rounded grey track filled in the ink colour to the fraction done, 0 to 1.
struct ProgressTrack: View {
  let fraction: Double
  var height: CGFloat = 8
  var body: some View {
    GeometryReader { g in
      ZStack(alignment: .leading) {
        Capsule().fill(Ink.sunken)
        Capsule().fill(Ink.strong).frame(width: max(height, g.size.width * min(1, max(0, fraction))))
      }
    }
    .frame(height: height)
    .animation(.easeOut(duration: 0.4), value: fraction)
  }
}

struct InsetCard<Content: View>: View {
  let title: String
  var icon: String? = nil
  var radius: CGFloat = 16
  @ViewBuilder var content: Content

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        if let icon { Icon(icon, size: 14).foregroundStyle(Ink.muted) }
        Text(title).font(.inter(13, .semibold)).foregroundStyle(Ink.text)
      }
      .padding(.horizontal, 12).frame(height: 36)
      VStack(alignment: .leading, spacing: 12) { content }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: radius - 4).fill(Ink.raised))
        .overlay(RoundedRectangle(cornerRadius: radius - 4).strokeBorder(Ink.border, lineWidth: 1))
        .padding([.horizontal, .bottom], 4)
    }
    .background(RoundedRectangle(cornerRadius: radius).fill(Ink.shell))
  }
}

// A row of an inset card: a grey label on the left, its value or control on the right.
struct FieldRow<Content: View>: View {
  let label: String
  @ViewBuilder var content: Content
  init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
  var body: some View {
    HStack(spacing: 12) {
      Text(label).font(.inter(13)).foregroundStyle(Ink.secondary)
      Spacer(minLength: 8)
      content.font(.inter(13)).foregroundStyle(Ink.text)
    }
    .frame(minHeight: 28)
  }
}

// Help text under a control: 12 points, grey.
struct Note: View {
  let text: String
  init(_ text: String) { self.text = text }
  var body: some View { Text(text).font(.inter(12)).foregroundStyle(Ink.faint).fixedSize(horizontal: false, vertical: true) }
}

// ---------------------------------------------------------------------------------------------------------------------
// Form controls: the web Field, TextInput, Stepper and switch.

struct FieldStyle: TextFieldStyle {
  var height: CGFloat = 32
  func _body(configuration: TextField<Self._Label>) -> some View {
    configuration
      .textFieldStyle(.plain)
      .font(.inter(14))
      .foregroundStyle(Ink.text)
      .padding(.horizontal, 12)
      .frame(minHeight: height)
      .background(RoundedRectangle(cornerRadius: 8).fill(Ink.raised))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.border, lineWidth: 1))
  }
}

extension TextFieldStyle where Self == FieldStyle { static var field: FieldStyle { FieldStyle() } }

// A labelled field: the label 12 points grey above the control.
struct Field<Content: View>: View {
  let label: String
  @ViewBuilder var content: Content
  init(_ label: String, @ViewBuilder content: () -> Content) { self.label = label; self.content = content() }
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label).font(.inter(12, .medium)).foregroundStyle(Ink.muted)
      content
    }
  }
}

// The switch: a #ddd track that turns #111 when on, a white knob.
struct SwitchStyle: ToggleStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 8) {
      configuration.label.font(.inter(13)).foregroundStyle(Ink.text)
      Spacer(minLength: 0)
      ZStack(alignment: configuration.isOn ? .trailing : .leading) {
        Capsule().fill(configuration.isOn ? Ink.strong : Ink.border).frame(width: 32, height: 20)
        Circle().fill(Ink.page).frame(width: 16, height: 16).padding(2).shadow(color: .black.opacity(0.15), radius: 1, y: 1)
      }
      .animation(.easeOut(duration: 0.15), value: configuration.isOn)
      .onTapGesture { configuration.isOn.toggle() }
    }
    .contentShape(Rectangle())
  }
}

extension ToggleStyle where Self == SwitchStyle { static var pillSwitch: SwitchStyle { SwitchStyle() } }

// A minus, a value and a plus in one bordered pill: the timeline's speed and zoom controls. Anything given as the
// accessory sits at its right end after a hairline, in the same container (the zoom's Follow toggle).
struct StepperPill<Accessory: View>: View {
  let icon: String
  let value: String
  let help: String
  let minus: () -> Void
  let plus: () -> Void
  @ViewBuilder var accessory: Accessory
  var body: some View {
    HStack(spacing: 0) {
      Button(action: minus) { Icon("minus", size: 14).frame(width: 28, height: 28) }.buttonStyle(.plain)
      HStack(spacing: 4) { Icon(icon, size: 14); Text(value).monospacedDigit().lineLimit(1).fixedSize() }
        .font(.inter(13, .medium)).frame(minWidth: 52)
        .help(help)
      Button(action: plus) { Icon("plus", size: 14).frame(width: 28, height: 28) }.buttonStyle(.plain)
      if Accessory.self != EmptyView.self {
        Rectangle().fill(Ink.border).frame(width: 1, height: 16).padding(.horizontal, 4)
        accessory
      }
    }
    .foregroundStyle(Ink.text)
    .padding(.horizontal, 4).frame(height: 32)
    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.raised))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.border, lineWidth: 1))
  }
}

extension StepperPill where Accessory == EmptyView {
  init(icon: String, value: String, help: String, minus: @escaping () -> Void, plus: @escaping () -> Void) {
    self.init(icon: icon, value: value, help: help, minus: minus, plus: plus) { EmptyView() }
  }
}

// The bordered container the speed and zoom steppers sit in, for a control of its own beside them.
struct PillBox<Content: View>: View {
  @ViewBuilder var content: Content
  var body: some View {
    HStack(spacing: 0) { content }
      .padding(.horizontal, 4).frame(height: 32)
      .background(RoundedRectangle(cornerRadius: 12).fill(Ink.raised))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.border, lineWidth: 1))
  }
}

// A toggle inside a pill: an icon and its word, filled #111 with white text when on, grey text when off.
struct InlineToggle: View {
  let label: String
  let icon: String
  @Binding var on: Bool
  var help: String = ""
  @State private var hover = false
  var body: some View {
    Button { withAnimation(.easeOut(duration: 0.15)) { on.toggle() } } label: {
      HStack(spacing: 4) { Icon(icon, size: 14, fill: on); Text(label) }
        .font(.inter(13, .medium))
        .foregroundStyle(on ? Ink.onPrimary : hover ? Ink.text : Ink.faint)
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 8).fill(on ? Ink.strong : hover ? Ink.hover : .clear))
        .contentShape(RoundedRectangle(cornerRadius: 8))
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(help)
  }
}

// The app's loading ring: a light track with a darker arc going round, the web Spinner.
struct Spinner: View {
  var size: CGFloat = 16
  @State private var turning = false
  var body: some View {
    ZStack {
      Circle().stroke(Ink.shell, lineWidth: max(2, size / 8))
      Circle().trim(from: 0, to: 0.28).stroke(Ink.text, style: StrokeStyle(lineWidth: max(2, size / 8), lineCap: .round))
        .rotationEffect(.degrees(turning ? 360 : 0))
        .animation(.linear(duration: 1).repeatForever(autoreverses: false), value: turning)
    }
    .frame(width: size, height: size)
    .onAppear { turning = true }
  }
}

extension PhosphorCodes {
  // The icon as a string, for drawing in a Canvas with the Phosphor font.
  static func glyph(_ name: String) -> String { map[name].flatMap { UnicodeScalar($0) }.map { String(Character($0)) } ?? "" }
}

// The web Slider: a label and its value on one line, a #eee track with a #111 fill and a white knob under it. It shows
// the value while dragging and calls commit once, when the knob is let go, so a drag is one tool call.
struct ValueSlider: View {
  let label: String
  let range: ClosedRange<Double>
  var step: Double = 1
  var format: (Double) -> String = { String(format: "%.0f", $0) }
  let value: Double
  let commit: (Double) -> Void
  @State private var dragging: Double? = nil

  var body: some View {
    let v = dragging ?? value
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        Text(label).font(.inter(13)).foregroundStyle(Ink.secondary)
        Spacer()
        Text(format(v)).font(.inter(13, .medium)).foregroundStyle(Ink.text).monospacedDigit()
      }
      GeometryReader { g in
        let w = g.size.width
        let f = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
        ZStack(alignment: .leading) {
          Capsule().fill(Ink.shell).frame(height: 4)
          Capsule().fill(Ink.strong).frame(width: max(0, w * f), height: 4)
          Circle().fill(Ink.page).frame(width: 16, height: 16)
            .overlay(Circle().strokeBorder(Ink.border, lineWidth: 1))
            .shadow(color: .black.opacity(0.12), radius: 2, y: 1)
            .offset(x: max(0, min(w - 16, w * f - 8)))
        }
        .frame(height: 16)
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
          let raw = range.lowerBound + max(0, min(1, g.location.x / max(1, w))) * (range.upperBound - range.lowerBound)
          dragging = (raw / step).rounded() * step
        }.onEnded { _ in
          if let d = dragging, abs(d - value) > step / 2 { commit(d) }
          dragging = nil
        })
      }
      .frame(height: 16)
    }
  }
}

// The menu that floats at a selection, the web reel-selection-menu: a white pill with a soft shadow holding Cut, Uncut,
// Correct and Comment for Claude. Correct turns it into a field with the selected words to retype; Comment turns it into
// a comment box whose text is left on the selection (add_comment) and sent to the chat's Claude at once.
struct SelectionMenu: View {
  enum Mode { case buttons, correct, comment }
  var canCut = true
  var canUncut = false
  var words: String? = nil // the selected words, when they can be corrected
  let cut: () -> Void
  let uncut: () -> Void
  var correct: (String) -> String? = { _ in nil } // the error to show, or nil when it was saved
  let comment: (String) -> Void
  @State private var mode = Mode.buttons
  @State private var text = ""
  @State private var problem: String? = nil
  @FocusState private var typing: Bool

  var body: some View {
    Group {
      switch mode {
      case .buttons:
        HStack(spacing: 4) {
          if canCut { Button(action: cut) { IconLabel("Cut", icon: "scissors", size: 14) }.pill(.outline, .sm) }
          if canUncut { Button(action: uncut) { IconLabel("Uncut", icon: "arrow-counter-clockwise", size: 14) }.pill(.outline, .sm) }
          if let words { Button { text = words; problem = nil; mode = .correct } label: { IconLabel("Correct", icon: "pencil-simple", size: 14) }.pill(.outline, .sm) }
          Button { text = ""; mode = .comment } label: { IconLabel("Comment for Claude", icon: "chat-text", size: 14) }.pill(.outline, .sm)
        }
        .padding(4)
        .background(Capsule().fill(Ink.page))
        .overlay(Capsule().strokeBorder(Ink.hairline, lineWidth: 1))
      case .correct:
        VStack(alignment: .leading, spacing: 8) {
          HStack(spacing: 4) {
            TextField("Corrected words", text: $text).textFieldStyle(.field).frame(width: 260).focused($typing)
              .onSubmit { save() }.onExitCommand { mode = .buttons }
            Button("Cancel") { mode = .buttons }.pill(.ghost, .sm)
            Button("Save") { save() }.pill(.primary, .sm)
          }
          if let problem { Text(problem).font(.inter(12)).foregroundStyle(Ink.red).padding(.horizontal, 4) }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: 16).fill(Ink.page))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.hairline, lineWidth: 1))
      case .comment:
        VStack(alignment: .trailing, spacing: 8) {
          TextField("Your feedback for Claude on this", text: $text, axis: .vertical)
            .textFieldStyle(.plain).font(.inter(14)).lineLimit(3...6).focused($typing)
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 12).fill(Ink.raised))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.border, lineWidth: 1))
            .onExitCommand { mode = .buttons }
          HStack(spacing: 4) {
            Button("Cancel") { mode = .buttons }.pill(.ghost, .sm)
            Button("Save") { let t = text.trimmingCharacters(in: .whitespacesAndNewlines); if !t.isEmpty { comment(t); mode = .buttons } }
              .pill(.primary, .sm).keyboardShortcut(.return, modifiers: .command)
              .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
          }
        }
        .frame(width: 320)
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 16).fill(Ink.page))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.hairline, lineWidth: 1))
      }
    }
    .compositingGroup()
    .shadow(color: .black.opacity(0.2), radius: 8, y: 4)
    .fixedSize()
    .onChange(of: mode) { _, m in if m != .buttons { DispatchQueue.main.async { typing = true } } }
  }

  func save() {
    if let p = correct(text) { problem = p } else { mode = .buttons }
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Motion: SwiftUI's own spring, Apple's animation system, for every card and panel that opens off a button or a click:
// a quick, lightly damped spring in, a shorter one out, the card growing out of where it was opened from.
extension Animation {
  static let cardOpen = Animation.spring(response: 0.32, dampingFraction: 0.8)
  static let cardClose = Animation.spring(response: 0.22, dampingFraction: 1)
}

extension AnyTransition {
  // Grows from the edge that touches what opened it, fading in, and shrinks back into it.
  static func card(from anchor: UnitPoint) -> AnyTransition {
    .scale(scale: 0.9, anchor: anchor).combined(with: .opacity)
  }
}

// A floating card's frame: white, 16 rounded, a #ddd border and a soft shadow under it. The content is clipped to the
// corners, the shadow is not, so it shows all round.
struct CardChrome: ViewModifier {
  func body(content: Content) -> some View {
    content
      .clipShape(RoundedRectangle(cornerRadius: 16))
      .background {
        RoundedRectangle(cornerRadius: 16).fill(Ink.page)
          .shadow(color: .black.opacity(0.10), radius: 4, y: 2)
          .shadow(color: .black.opacity(0.14), radius: 24, y: 12)
      }
      .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.border, lineWidth: 1))
  }
}
extension View { func cardChrome() -> some View { modifier(CardChrome()) } }

// ---------------------------------------------------------------------------------------------------------------------
// Tree: the LiveAssistant app's account tree (its TreeConnector), a parent on top and a line down its left with a
// branch to each child row, the last one ending in a rounded corner.

let TREE_ROW: CGFloat = 24 // the height of a tree row's first line, which its branch meets in the middle

enum TreeBranch { case only, first, middle, last
  static func at(_ i: Int, of n: Int) -> TreeBranch { n <= 1 ? .only : i == 0 ? .first : i == n - 1 ? .last : .middle }
}

struct TreeConnector: Shape {
  let branch: TreeBranch
  var lineX: CGFloat = 8 // under the middle of the parent's icon
  var branchEndX: CGFloat = 20 // just before the row's content
  var reachUp: CGFloat = 4 // the first row's line reaches up to the parent
  var cornerRadius: CGFloat = 4
  var branchY: CGFloat? = nil // where the branch meets the row: the middle of its first line, or the row's middle
  func path(in rect: CGRect) -> Path {
    var path = Path()
    let midY = branchY.map { rect.minY + $0 } ?? rect.midY
    let top = branch == .first || branch == .only ? rect.minY - reachUp : rect.minY
    if branch == .last || branch == .only {
      let r = min(cornerRadius, branchEndX - lineX, midY - top)
      path.move(to: CGPoint(x: lineX, y: top))
      path.addLine(to: CGPoint(x: lineX, y: midY - r))
      path.addQuadCurve(to: CGPoint(x: lineX + r, y: midY), control: CGPoint(x: lineX, y: midY))
      path.addLine(to: CGPoint(x: branchEndX, y: midY))
    } else {
      path.move(to: CGPoint(x: lineX, y: top))
      path.addLine(to: CGPoint(x: lineX, y: rect.maxY))
      path.move(to: CGPoint(x: lineX, y: midY))
      path.addLine(to: CGPoint(x: branchEndX, y: midY))
    }
    return path
  }
}

extension View {
  // A child row of a tree: the connector drawn behind it and the row inset past the branch. The branch meets the row
  // at the middle of its first line (TREE_ROW high), so a row with a second line under it still lines up.
  func treeChild(_ i: Int, of n: Int, inset: CGFloat = 28) -> some View {
    self.padding(.leading, inset)
      .frame(maxWidth: .infinity, alignment: .leading)
      .background(alignment: .leading) {
        TreeConnector(branch: .at(i, of: n), branchEndX: inset - 6, branchY: TREE_ROW / 2).stroke(Ink.borderHover, style: StrokeStyle(lineWidth: 1, lineCap: .round))
      }
  }
}

// A usage meter in a tree row: its name, a thin bar of what the limit has used, in two parts, green for what this
// editor's sessions used and blue for the rest of the account, the percent used and when it resets; under it, the
// same split in words. Without a split the whole use is blue.
struct UsageMeterRow: View {
  let title: String
  let fraction: Double?
  var reset = ""
  var app: Double? = nil // the part of the whole limit this editor's sessions used
  static let appColor = Color(nsColor: NSColor(hex: 0x22c55e))
  static let restColor = Color(nsColor: NSColor(hex: 0x3b82f6))
  static func pct(_ f: Double) -> String { let v = f * 100; return v > 0 && v < 10 ? String(format: "%.1f%%", v) : "\(Int(v.rounded()))%" }
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 8) {
        Text(title).frame(width: 52, alignment: .leading)
        GeometryReader { g in
          let used = min(max(fraction ?? 0, 0), 1), mine = min(app ?? 0, used)
          ZStack(alignment: .leading) {
            Capsule().fill(Ink.shell)
            if fraction != nil {
              HStack(spacing: 0) {
                Rectangle().fill(Self.appColor).frame(width: g.size.width * mine)
                Rectangle().fill(Self.restColor).frame(width: max(0, g.size.width * (used - mine)))
              }
              .frame(width: max(5, g.size.width * used), alignment: .leading)
              .clipShape(Capsule())
            }
          }
        }
        .frame(height: 6)
        Text(fraction.map { Self.pct($0) } ?? "").monospacedDigit().foregroundStyle(Ink.strong).frame(width: 40, alignment: .trailing)
        Group { if fraction == nil { Text("not reported").italic() } else { Text(reset) } }
          .font(.inter(11)).lineLimit(1).frame(width: 104, alignment: .leading)
      }
      .frame(height: TREE_ROW)
      if let f = fraction {
        HStack(spacing: 12) {
          if let app { legend(Self.appColor, "This editor \(Self.pct(app))"); legend(Self.restColor, "Others \(Self.pct(max(0, f - app)))") }
          else { legend(Self.restColor, "Used \(Self.pct(f))") }
          Text("\(Self.pct(max(0, 1 - f))) left")
        }
        .font(.inter(11)).padding(.leading, 60).padding(.bottom, 4)
      }
    }
    .font(.inter(12)).foregroundStyle(Ink.faint)
  }
  func legend(_ c: Color, _ t: String) -> some View { HStack(spacing: 4) { Circle().fill(c).frame(width: 6, height: 6); Text(t).monospacedDigit() } }
}

// A code block of markdown with a Copy button at its top right, so a caption or anything else Claude writes in one goes to
// the clipboard in one click (Sankalp, 5 Nov 2026). The button says Copied for a moment after.
struct CodeBlock: View {
  let text: String
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Spacer()
        Button {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
          copied = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        } label: { IconLabel(copied ? "Copied" : "Copy", icon: copied ? "check" : "copy", size: 12) }
          .pill(.ghost, .xs).fixedSize()
          .help("Copy to the clipboard")
      }
      .padding(.horizontal, 4).padding(.top, 4)
      Text(text).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.text).textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 12).padding(.bottom, 12).frame(maxWidth: .infinity, alignment: .leading)
    }
    .background(RoundedRectangle(cornerRadius: 8).fill(Ink.sunken))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Ink.border, lineWidth: 1))
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Markdown: a document's text laid out as the web app's prose, block by block. Headings, bullet and numbered lists
// (nested by their indent), quotes, code blocks, rules and paragraphs; bold, italic, code and links inside a line.

struct MarkdownBlocks: View {
  let text: String

  enum Block {
    case heading(Int, String)
    case item(Int, String, String) // depth, marker, text
    case quote(String)
    case code(String)
    case rule
    case para(String)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      ForEach(Array(Self.blocks(text).enumerated()), id: \.offset) { i, b in view(b, first: i == 0) }
    }
  }

  @ViewBuilder func view(_ b: Block, first: Bool) -> some View {
    switch b {
    case .heading(let level, let s):
      Self.inline(s)
        .font(.inter(level == 1 ? 20 : level == 2 ? 16 : 14, .semibold)).foregroundStyle(Ink.strong)
        .padding(.top, first ? 0 : level <= 2 ? 16 : 8)
    case .item(let depth, let marker, let s):
      HStack(alignment: .firstTextBaseline, spacing: 8) {
        Text(marker).font(.inter(14)).foregroundStyle(Ink.muted).frame(minWidth: 12, alignment: .trailing)
        Self.inline(s).font(.inter(14)).foregroundStyle(Ink.text).lineSpacing(4)
      }
      .padding(.leading, Double(depth) * 20)
    case .quote(let s):
      Self.inline(s).font(.inter(14)).foregroundStyle(Ink.secondary).lineSpacing(4)
        .padding(.leading, 12)
        .overlay(alignment: .leading) { Rectangle().fill(Ink.border).frame(width: 2) }
    case .code(let s):
      CodeBlock(text: s)
    case .rule:
      Hairline().padding(.vertical, 8)
    case .para(let s):
      Self.inline(s).font(.inter(14)).foregroundStyle(Ink.text).lineSpacing(4)
    }
  }

  // Bold, italic, code and links inside a line, or the line as it is when it is not valid markdown.
  static func inline(_ s: String) -> Text {
    if let a = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) { return Text(a) }
    return Text(s)
  }

  // The groups of a whole line matched by a pattern, or nil.
  static func match(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern), let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (1..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
  }

  static func blocks(_ text: String) -> [Block] {
    var out: [Block] = []
    var para: [String] = []
    var code: [String]? = nil
    func flush() { if !para.isEmpty { out.append(.para(para.joined(separator: " "))); para = [] } }
    for raw in text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
      let line = raw.trimmingCharacters(in: .whitespaces)
      if line.hasPrefix("```") {
        if let c = code { out.append(.code(c.joined(separator: "\n"))); code = nil } else { flush(); code = [] }
        continue
      }
      if code != nil { code!.append(raw); continue }
      if line.isEmpty { flush(); continue }
      if let m = match(#"^(#{1,6})\s+(.*)$"#, line) { flush(); out.append(.heading(m[0].count, m[1])); continue }
      if match(#"^([-*_])\s*(\1\s*){2,}$"#, line) != nil { flush(); out.append(.rule); continue }
      if let m = match(#"^(\s*)([-*+]|\d+[.)])\s+(.*)$"#, raw) {
        flush()
        let indent = m[0].replacingOccurrences(of: "\t", with: "  ").count
        let marker = "-*+".contains(m[1]) ? "•" : m[1]
        out.append(.item(min(4, indent / 2), marker, m[2]))
        continue
      }
      if line.hasPrefix(">") { flush(); out.append(.quote(String(line.dropFirst()).trimmingCharacters(in: .whitespaces))); continue }
      para.append(line)
    }
    if let c = code { out.append(.code(c.joined(separator: "\n"))) }
    flush()
    return out
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// At most a share of the width

// Gives its one view at most a share of the width offered, as narrow as the view wants inside that, placed at the
// leading or trailing edge: a chat bubble up to 80% of the chat's width (Sankalp, 2 Nov 2026).
struct WidthShare: Layout {
  var share: Double = 0.8
  var trailing = false

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let v = subviews.first else { return .zero }
    let s = v.sizeThatFits(ProposedViewSize(width: proposal.width.map { $0 * share }, height: nil))
    return CGSize(width: proposal.width ?? s.width, height: s.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let v = subviews.first else { return }
    let p = ProposedViewSize(width: bounds.width * share, height: nil)
    let s = v.sizeThatFits(p)
    v.place(at: CGPoint(x: trailing ? bounds.maxX - s.width : bounds.minX, y: bounds.minY), proposal: ProposedViewSize(width: s.width, height: s.height))
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// Shimmer

// A light band that sweeps across text again and again, on the glyphs only: the words Claude is reading or changing
// now (Sankalp, 2 Nov 2026). Every shimmer runs on the same clock, so paragraphs shimmer together.
struct Shimmer: ViewModifier {
  var active: Bool
  var onGlyphs = true // false sweeps the whole shape, clipped to it, as on the timeline's band
  static let period = 1.6

  func body(content: Content) -> some View {
    if active {
      content.overlay {
        SwiftUI.TimelineView(.animation(minimumInterval: 1.0 / 30)) { t in
          let phase = t.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: Self.period) / Self.period
          GeometryReader { g in
            LinearGradient(colors: [Ink.page.opacity(0), Ink.page.opacity(0.75), Ink.page.opacity(0)], startPoint: .leading, endPoint: .trailing)
              .frame(width: max(120, g.size.width * 0.4))
              .offset(x: -max(120, g.size.width * 0.4) + phase * (g.size.width + max(120, g.size.width * 0.4)))
          }
        }
        .mask { if onGlyphs { content } else { Rectangle() } }
        .allowsHitTesting(false)
      }
    } else { content }
  }
}

extension View { func shimmer(_ active: Bool, onGlyphs: Bool = true) -> some View { modifier(Shimmer(active: active, onGlyphs: onGlyphs)) } }

// ---------------------------------------------------------------------------------------------------------------------
// Capped height

// Content as tall as it needs up to maxHeight, scrolling past it: how every card and panel keeps to 60% of the window's
// height (Sankalp, 2 Nov 2026).
struct CappedScroll<Content: View>: View {
  let maxHeight: CGFloat
  @ViewBuilder var content: Content
  @State private var height: CGFloat = 120
  var body: some View {
    ScrollView { content.onGeometryChange(for: CGFloat.self, of: { $0.size.height }) { height = $0 } }
      .frame(height: max(80, min(height, maxHeight)))
  }
}

// The share of the window's height a card, panel or modal may take.
let CARD_SHARE: CGFloat = 0.6
