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
                    selection: Binding(get: { dock }, set: { setDock($0) }), iconOnly: true, height: 32) // level with the account beside it
      }
      Hairline()
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if direct.messages.isEmpty {
              empty("Ask Claude to edit this reel. It runs on the account above with the editor's tools. Each message goes with the project, the playhead and what is selected. Drop .md rule books here to add them to this project's rules.")
            }
            // The conversation as one timeline (Sankalp, 2 Nov 2026): every row's icon in one column joined by a line, the
            // time on the right, and a run of the same tool folded into one row with what each call worked on.
            let items = ChatItem.group(direct.messages)
            ForEach(items) { item in ChatItemRow(item: item, last: item.id == items.last?.id && direct.state != "thinking").id(item.id) }
            if direct.state == "thinking" {
              TimelineRow(last: true, time: nil) {
                Spinner(size: 12)
              } content: {
                Text(model?.agentFocus.map { TranscriptView.label($0) + ", " + TranscriptView.span($0) } ?? "Claude is working")
                  .font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(2)
              }
              .id("thinking")
            }
          }
          .padding(.horizontal, 16).padding(.vertical, 16)
        }
        .onAppear { scrollToEnd(proxy) }
        .onChange(of: direct.messages.count) { _, _ in withAnimation { scrollToEnd(proxy) } }
      }
      Hairline()
      ChatUsageRow(direct: direct).padding(.horizontal, 16).padding(.top, 12)
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
        // While Claude works the button stops it, so a new message can be given (Sankalp, 2 Nov 2026).
        if direct.state == "thinking" {
          Button { direct.interrupt() } label: { Icon("stop", size: 14, fill: true) }
            .pill(.primary, .icon)
            .help("Stop Claude, keeping the conversation, to give it a new message")
        } else {
          Button { send() } label: { Icon("arrow-up", size: 16) }
            .pill(.primary, .icon)
            .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .keyboardShortcut(.return, modifiers: .command)
            .help("Send (Return, or Cmd Return)")
        }
      }
      .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
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
      Hairline().padding(.horizontal, -16)
      RulesRow(direct: direct, app: AppModel.shared)
    }
    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
    .onAppear { if accounts.first(where: { $0.profile == direct.profile }) == nil, let f = accounts.first { direct.profile = f.profile } }
  }
}

// The rule books Claude starts each conversation with: how many, which opens them to read in a modal, from which
// folder, a folder picked in Finder or the default again, and the folder shown in Finder.
struct RulesRow: View {
  @ObservedObject var direct: DirectChat
  @ObservedObject var app: AppModel // the project in front: each project keeps its own rules folder
  var body: some View {
    HStack(spacing: 8) {
      // The count opens the rule books in a modal, to read each one.
      Button { app.openRules() } label: {
        IconLabel("\(direct.rules.count) rule \(direct.rules.count == 1 ? "book" : "books")", icon: "book-open-text", size: 14).fixedSize()
      }
      .pill(.ghost, .xs).padding(.leading, -12)
      .help("Read this project's rule books")
      Text(direct.rulesDir.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.inter(12)).foregroundStyle(Ink.faint)
        .lineLimit(1).truncationMode(.middle).layoutPriority(-1)
        .help(direct.rulesDir)
      Spacer(minLength: 4)
      Button("Change") { choose() }.pill(.ghost, .xs).fixedSize().help("Read this project's rule books from another folder. New projects start with it too.")
      if !Rules.isDefault(URL(fileURLWithPath: direct.rulesDir)) { Button("Default") { direct.setRulesFolder(nil) }.pill(.ghost, .xs).fixedSize().help("Read this project's rule books from the Reel Editor folder's _rules") }
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

// A row of the chat's timeline: its icon in the left column, centred on the column the Claude mark sits in, with the line
// down to the next row; then the row itself; then the time it happened.
struct TimelineRow<Mark: View, Content: View>: View {
  var last: Bool
  var time: Date?
  var markTop: CGFloat = 2 // where the icon sits, to line up with the row's first line
  var hasMark = true // false for Sankalp's own messages, whose icon is on the right with them; the line runs past
  @ViewBuilder var mark: () -> Mark
  @ViewBuilder var content: () -> Content

  var body: some View {
    HStack(alignment: .top, spacing: 8) {
      ZStack(alignment: .top) {
        if !last { Rectangle().fill(Ink.border).frame(width: 1).frame(maxHeight: .infinity).padding(.top, markTop + 8).padding(.bottom, -12) }
        if hasMark { mark().frame(width: 16, height: 16).background(Circle().fill(Ink.page)).padding(.top, markTop) }
      }
      .frame(width: 16).frame(maxHeight: .infinity, alignment: .top)
      content()
      if let time {
        Text(time.formatted(date: .omitted, time: .shortened)).font(.inter(11)).foregroundStyle(Ink.faint).monospacedDigit()
          .fixedSize().padding(.top, markTop + 1)
      }
    }
  }
}

// One item of the timeline: a message, or a run of calls of the same tool in a row.
struct ChatItem: Identifiable {
  let messages: [DirectMessage]
  var id: UUID { messages[0].id }
  var first: DirectMessage { messages[0] }

  static func group(_ all: [DirectMessage]) -> [ChatItem] {
    var out: [ChatItem] = []
    for m in all {
      if m.role == "activity", let last = out.last, last.first.role == "activity", (last.first.tool ?? last.first.text) == (m.tool ?? m.text) {
        out[out.count - 1] = ChatItem(messages: last.messages + [m])
      } else { out.append(ChatItem(messages: [m])) }
    }
    return out
  }
}

struct ChatItemRow: View {
  let item: ChatItem
  let last: Bool
  @State private var open = false

  var body: some View {
    let m = item.first
    switch m.role {
    case "activity":
      let n = item.messages.count
      TimelineRow(last: last, time: item.messages.last?.t) {
        Icon(Self.icon(m.tool), size: 12).foregroundStyle(Ink.muted)
      } content: {
        VStack(alignment: .leading, spacing: 4) {
          Button { if n > 1 { withAnimation(.cardOpen) { open.toggle() } } } label: {
            HStack(spacing: 6) {
              Text(m.text).font(.inter(12, .medium)).foregroundStyle(Ink.secondary)
              if n > 1 { Text("\(n) times").font(.inter(12)).foregroundStyle(Ink.faint) }
              if let d = item.messages.last?.detail { Text(n > 1 ? "last \(d)" : d).font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(1) }
              if n > 1 { Icon(open ? "caret-up" : "caret-down", size: 10).foregroundStyle(Ink.faint) }
            }
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          if open {
            VStack(alignment: .leading, spacing: 2) {
              ForEach(item.messages) { c in
                HStack(spacing: 8) {
                  Text(c.detail ?? c.text).font(.inter(12)).foregroundStyle(Ink.faint)
                  Spacer(minLength: 8)
                  Text(c.t.formatted(date: .omitted, time: .standard)).font(.inter(11)).foregroundStyle(Ink.ghost).monospacedDigit()
                }
              }
            }
            .transition(.opacity)
          }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    case "rules":
      TimelineRow(last: last, time: m.t) { Icon("book-open-text", size: 12).foregroundStyle(Ink.muted) } content: {
        Text(m.text).font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(3).frame(maxWidth: .infinity, alignment: .leading)
          .contentShape(Rectangle()).onTapGesture { AppModel.shared.openRules() }
          .help("Read the rule books")
      }
    case "error":
      TimelineRow(last: last, time: m.t) { Icon("warning-circle", size: 12).foregroundStyle(Ink.red) } content: {
        Text(m.text).font(.inter(12)).foregroundStyle(Ink.red).frame(maxWidth: .infinity, alignment: .leading)
      }
    // Sankalp's messages on the right with his icon beside them, and Claude's on the left; the time of each under its
    // bubble (Sankalp, 2 Nov 2026).
    case "you":
      TimelineRow(last: last, time: nil, markTop: 12, hasMark: false) { EmptyView() } content: {
        // Each bubble is at most 80% of the chat's width (Sankalp, 2 Nov 2026).
        VStack(alignment: .trailing, spacing: 4) {
          HStack(alignment: .top, spacing: 8) {
            WidthShare(share: 0.8, trailing: true) {
              Text(m.text).font(.inter(14)).textSelection(.enabled)
                .padding(.horizontal, 16).padding(.vertical, 10)
                .foregroundStyle(Ink.onPrimary)
                .background(RoundedRectangle(cornerRadius: 16).fill(Ink.strong))
            }
            Icon("user", size: 12).foregroundStyle(Ink.muted).frame(width: 16, height: 16).padding(.top, 12)
          }
          Self.time(m.t).padding(.trailing, 24)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
      }
    default:
      TimelineRow(last: last, time: nil, markTop: 12) { BrandMark(name: "claude", size: 16) } content: {
        VStack(alignment: .leading, spacing: 4) {
          WidthShare(share: 0.8) {
            MarkdownBlocks(text: m.text).textSelection(.enabled)
              .padding(.horizontal, 16).padding(.vertical, 10)
              .background(RoundedRectangle(cornerRadius: 16).fill(Ink.sunken))
              .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.border, lineWidth: 1))
          }
          Self.time(m.t).padding(.leading, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
  }

  static func time(_ t: Date) -> some View {
    Text(t.formatted(date: .omitted, time: .shortened)).font(.inter(11)).foregroundStyle(Ink.faint).monospacedDigit()
  }

  // The icon of each kind of tool call; the wrench for the rest.
  static func icon(_ tool: String?) -> String {
    switch tool ?? "" {
    case "cut_range", "delete_words", "split_clip", "trim_clip": return "scissors"
    case "restore_range", "restore_words", "undo", "redo": return "arrow-counter-clockwise"
    case "get_words", "get_paragraphs", "get_project", "get_timeline", "get_rules": return "article"
    case "write_rule_book", "edit_rule_book", "delete_rule_book", "make_project_rules_folder": return "book-open-text"
    case "audit_audio", "transcribe", "transcribe_source": return "waveform"
    case "list_comments", "add_comment", "resolve_comment": return "chat-text"
    case "approve_cuts": return "check-circle"
    case "set_focus": return "crosshair"
    case "correct_word": return "pencil-simple"
    case "add_animation", "update_animation", "remove_animation", "set_animations": return "magic-wand"
    case "open_in_app", "get_app_state": return "app-window"
    default: return "wrench"
    }
  }
}

// What this chat has used since it was last cleared, right above the input (Sankalp, 2 Nov 2026): its cost, its tokens,
// the turns and the tools Claude ran; the tokens by kind on hover.
struct ChatUsageRow: View {
  @ObservedObject var direct: DirectChat
  var body: some View {
    let u = direct.usage
    // Two rows, so nothing is cut off in a narrow chat (Sankalp, 2 Nov 2026): the tokens first, then the share of the
    // 5 hour limit with the turns and tools under them.
    HStack(alignment: .top, spacing: 8) {
      Icon("coins", size: 14).foregroundStyle(Ink.muted).padding(.top, 1)
      VStack(alignment: .leading, spacing: 4) {
        HStack(spacing: 8) {
          Text("This chat").font(.inter(12, .medium)).foregroundStyle(Ink.secondary)
          Text(u.turns == 0 ? "nothing used yet" : "\(Self.count(u.tokens)) tokens").font(.inter(12, u.turns == 0 ? .regular : .semibold))
            .foregroundStyle(u.turns == 0 ? Ink.faint : Ink.strong)
        }
        if u.turns > 0 {
          HStack(spacing: 8) {
            if let f = direct.fiveHour { Text("\(Self.percent(f.chat)) of the 5 hour limit").font(.inter(12, .semibold)).foregroundStyle(Ink.strong) }
            Text("\(u.turns) \(u.turns == 1 ? "turn" : "turns"), \(u.tools) \(u.tools == 1 ? "tool" : "tools")").font(.inter(12)).foregroundStyle(Ink.faint)
          }
          .lineLimit(1)
        }
      }
      Spacer(minLength: 0)
    }
    .help(help(u))
    .task(id: direct.profile) { await direct.updateShare() }
  }

  func help(_ u: ChatUsage) -> String {
    var s = "Since the chat was last cleared: \(Self.count(u.input)) new input, \(Self.count(u.cacheRead)) read from cache, \(Self.count(u.cacheWrite)) written to cache, \(Self.count(u.output)) output tokens."
    if let f = direct.fiveHour {
      s += " The account has used \(Self.percent(f.account)) of its 5 hour limit\(f.resets.map { ", \(AccountLimits.resetText($0))" } ?? ""); this chat's part is estimated from its share of the account's tokens in the window."
    }
    return s + " Clear starts the count again."
  }

  static func percent(_ f: Double) -> String {
    let p = f * 100
    return p > 0 && p < 1 ? "under 1%" : "\(Int(p.rounded()))%"
  }

  static func count(_ n: Double) -> String {
    if n >= 1_000_000 { return String(format: "%.1fM", n / 1_000_000) }
    if n >= 1_000 { return String(format: "%.0fk", n / 1_000) }
    return String(Int(n))
  }
}
