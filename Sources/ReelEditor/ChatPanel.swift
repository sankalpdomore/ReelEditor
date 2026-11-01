// The Chat: a conversation with the Claude the app starts itself (DirectChat), with the editor's tools. What Sankalp
// writes goes in with what he is looking at, and Claude's answers and the tools it runs show here. Since 1 Nov 2026 this
// is the only way to chat from the app: the Claude Code route, a session listening with wait_for_app_message, was
// removed (Sankalp), so no session sits in a listening loop spending tokens.
import AppKit
import ReelCore
import SwiftUI

struct ChatPanel: View {
  @ObservedObject var app: AppModel
  var model: EditorModel? = nil
  @ObservedObject private var direct = DirectChat.shared
  @AppStorage("chatDock") private var dock = "floating" // side: a column on the right of the window; floating: a card
  @AppStorage("chatSide") private var sideOpen = false
  @State private var draft = ""
  @State private var dropping = false // a file dragged over the chat
  @FocusState private var typing: Bool

  var body: some View {
    VStack(spacing: 0) {
      // The account, model and effort, with where the chat sits (a side panel or a card) beside the account.
      DirectHeader(direct: direct) {
        SegmentTabs(items: [SegmentItem(value: "side", label: "Side panel", icon: "sidebar-simple"), SegmentItem(value: "floating", label: "Floating", icon: "app-window")],
                    selection: Binding(get: { dock }, set: { setDock($0) }), iconOnly: true)
      }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if direct.messages.isEmpty {
              empty("Ask Claude to edit this reel. It runs on the account above with the editor's tools. Each message goes with the project, the playhead and what is selected. Drop .md rule books here to add them to this project's rules.")
            }
            ForEach(direct.messages) { m in DirectRow(m: m).id(m.id) }
            if direct.state == "thinking" { HStack(spacing: 8) { Spinner(size: 12); Text("Claude is working").font(.inter(12)).foregroundStyle(Ink.faint) }.id("thinking") }
          }
          .padding(.horizontal, 16).padding(.vertical, 16)
        }
        .onAppear { scrollToEnd(proxy) }
        .onChange(of: direct.messages.count) { _, _ in withAnimation { scrollToEnd(proxy) } }
      }
      Hairline()
      HStack(alignment: .bottom, spacing: 8) {
        TextField("Ask Claude to edit this reel", text: $draft, axis: .vertical)
          .textFieldStyle(.plain)
          .font(.inter(14))
          .lineLimit(1...6)
          .focused($typing)
          .onSubmit { send() }
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(RoundedRectangle(cornerRadius: 20).fill(Ink.raised))
          .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(typing ? Ink.borderHover : Ink.border, lineWidth: 1))
        Button { send() } label: { Icon("arrow-up", size: 16) }
          .pill(.primary, .icon)
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || direct.state == "thinking")
          .keyboardShortcut(.return, modifiers: .command)
          .help("Send (Return, or Cmd Return)")
      }
      .padding(16)
    }
    // Rule books dropped anywhere on the chat are saved into the project's rules folder.
    .onDrop(of: [.fileURL], isTargeted: $dropping) { providers in
      let group = DispatchGroup(); var urls: [URL] = []; let lock = NSLock()
      for p in providers {
        group.enter()
        _ = p.loadObject(ofClass: URL.self) { u, _ in if let u { lock.lock(); urls.append(u); lock.unlock() }; group.leave() }
      }
      group.notify(queue: .main) { direct.addRuleFiles(urls) }
      return true
    }
    .overlay {
      if dropping {
        RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.borderHover, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
          .background(RoundedRectangle(cornerRadius: 12).fill(Ink.page.opacity(0.92)))
          .overlay { VStack(spacing: 8) { Icon("book-open-text", size: 24).foregroundStyle(Ink.muted); Text("Drop .md files to add them to this project's rules").font(.inter(14)).foregroundStyle(Ink.secondary) } }
          .padding(8).allowsHitTesting(false)
      }
    }
  }

  func empty(_ text: String) -> some View {
    VStack(spacing: 8) {
      Icon("chat-circle-text", size: 32).foregroundStyle(Ink.muted)
      Text(text).font(.inter(14)).foregroundStyle(Ink.secondary).multilineTextAlignment(.center)
    }
    .padding(.top, 32).frame(maxWidth: .infinity)
  }

  func scrollToEnd(_ proxy: ScrollViewProxy) {
    if direct.state == "thinking" { proxy.scrollTo("thinking", anchor: .bottom) } else if let l = direct.messages.last { proxy.scrollTo(l.id, anchor: .bottom) }
  }

  // Moves the chat: into the column on the right of the window, or back into the floating card.
  func setDock(_ d: String) {
    guard d != dock else { return }
    dock = d
    if d == "side" { model?.closeFloating(); withAnimation(.cardOpen) { sideOpen = true } }
    else { withAnimation(.cardClose) { sideOpen = false }; model?.toggle(.chat) }
  }

  func send() {
    direct.send(draft, context: app.screenContext())
    draft = ""
  }
}

// The direct chat's account and model, its state, and Restart or Stop, with an accessory beside the account.
struct DirectHeader<Accessory: View>: View {
  @ObservedObject var direct: DirectChat
  @ViewBuilder var accessory: () -> Accessory
  var body: some View {
    let accounts = DirectChat.accounts()
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Dropdown(options: accounts.map { ($0.profile, $0.email) }, selection: Binding(get: { direct.profile }, set: { direct.profile = $0; if direct.state != "off" { direct.restart() } }), icon: "envelope-simple")
        accessory()
      }
      HStack(spacing: 8) {
        Dropdown(options: [("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")], selection: Binding(get: { direct.model }, set: { direct.model = $0; if direct.state != "off" { direct.restart() } }), icon: "cpu")
        Dropdown(options: [("default", "Default effort"), ("low", "Low effort"), ("medium", "Medium effort"), ("high", "High effort"), ("xhigh", "Extra high effort"), ("max", "Max effort")],
                 selection: Binding(get: { direct.effort }, set: { direct.effort = $0; if direct.state != "off" { direct.restart() } }), icon: "gauge")
      }
      HStack(spacing: 8) {
        Circle().fill(direct.state == "off" ? Ink.ghost : Ink.green).frame(width: 6, height: 6)
        Text(["off": "Starts with your first message", "starting": "Starting Claude", "ready": "Ready", "thinking": "Working"][direct.state] ?? direct.state)
          .font(.inter(12)).foregroundStyle(Ink.faint)
        Spacer()
        if direct.state != "off" { Button("Stop") { direct.stop() }.pill(.ghost, .xs) }
        if !direct.messages.isEmpty { Button("Clear") { direct.clear() }.pill(.ghost, .xs) }
      }
      RulesRow(direct: direct, app: AppModel.shared)
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .onAppear { if accounts.first(where: { $0.profile == direct.profile }) == nil, let f = accounts.first { direct.profile = f.profile } }
  }
}

// The rule books Claude starts each conversation with: how many, from which folder, a folder picked in Finder or the
// default again, and the folder shown in Finder.
struct RulesRow: View {
  @ObservedObject var direct: DirectChat
  @ObservedObject var app: AppModel // the project in front: each project keeps its own rules folder
  var body: some View {
    HStack(spacing: 8) {
      Icon("book-open-text", size: 14).foregroundStyle(Ink.muted)
      Text("\(direct.rules.count) rule \(direct.rules.count == 1 ? "book" : "books")").font(.inter(12, .medium)).foregroundStyle(Ink.secondary).fixedSize()
      Text(direct.rulesDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.inter(12)).foregroundStyle(Ink.faint)
        .lineLimit(1).truncationMode(.middle)
        .help(direct.rulesDir)
      Spacer(minLength: 4)
      Button("Change") { choose() }.pill(.ghost, .xs).help("Read this project's rule books from another folder. New projects start with it too.")
      if !Rules.isDefault(URL(fileURLWithPath: direct.rulesDir)) { Button("Default") { direct.setRulesFolder(nil) }.pill(.ghost, .xs).help("Read this project's rule books from the Reel Editor folder's _rules") }
      Button { NSWorkspace.shared.open(URL(fileURLWithPath: direct.rulesDir)) } label: { Icon("folder-open", size: 12) }.pill(.ghost, .iconSm)
        .help("Show the rules folder in Finder")
    }
    .onAppear { direct.reloadRules() }
    .onChange(of: app.selected) { _, _ in direct.reloadRules() }
  }

  func choose() {
    let panel = NSOpenPanel()
    panel.title = "Rules folder"
    panel.message = "Pick the folder of rule books (.md or .txt) for this project. Claude starts each chat with every one of them, and new projects start with this folder."
    panel.prompt = "Use Folder"
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.canCreateDirectories = true
    panel.directoryURL = URL(fileURLWithPath: direct.rulesDir)
    if panel.runModal() == .OK, let u = panel.url { direct.setRulesFolder(u) }
  }
}

struct DirectRow: View {
  let m: DirectMessage
  var body: some View {
    switch m.role {
    case "activity":
      HStack(spacing: 8) { Icon("wrench", size: 12); Text(m.text).font(.inter(12)).lineLimit(1) }.foregroundStyle(Ink.faint).padding(.horizontal, 8)
    case "rules":
      HStack(alignment: .top, spacing: 8) { Icon("book-open-text", size: 12).padding(.top, 2); Text(m.text).font(.inter(12)).lineLimit(3) }
        .foregroundStyle(Ink.faint).padding(.horizontal, 8)
    case "error":
      HStack(spacing: 8) { Icon("warning-circle", size: 12); Text(m.text).font(.inter(12)) }.foregroundStyle(Ink.red).padding(.horizontal, 8)
    case "you":
      Text(m.text).font(.inter(14)).textSelection(.enabled)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .foregroundStyle(Ink.onPrimary)
        .background(RoundedRectangle(cornerRadius: 16).fill(Ink.strong))
        .frame(maxWidth: .infinity, alignment: .trailing).padding(.leading, 48)
    default:
      HStack(alignment: .top, spacing: 8) {
        BrandMark(name: "claude", size: 16).padding(.top, 10)
        Text(m.text).font(.inter(14)).foregroundStyle(Ink.text).textSelection(.enabled)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(RoundedRectangle(cornerRadius: 16).fill(Ink.sunken))
          .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.border, lineWidth: 1))
      }
      .frame(maxWidth: .infinity, alignment: .leading).padding(.trailing, 32)
    }
  }
}
