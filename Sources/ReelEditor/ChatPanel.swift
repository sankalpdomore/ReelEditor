// The Chat tab: one conversation with the agent connected over MCP (Claude Code, Codex and so on), for every project.
// What Sankalp writes here goes to the agent with what he is looking at, and lands in the agent's own chat too; the
// agent's answers (reply_in_app) and the tools it runs show here. The agent has to be listening: asked once in its own
// chat to listen to the Reel Editor chat, it calls wait_for_app_message and keeps calling it.
import AppKit
import ReelCore
import SwiftUI

struct ChatPanel: View {
  @ObservedObject var app: AppModel
  var model: EditorModel? = nil
  @ObservedObject private var direct = DirectChat.shared
  @AppStorage("chatMode") private var mode = "direct" // direct: the app's own Claude; session: a listening Claude Code session
  @AppStorage("chatDock") private var dock = "floating" // side: a column on the right of the window; floating: a card
  @AppStorage("chatSide") private var sideOpen = false
  @State private var draft = ""
  @FocusState private var typing: Bool

  static let listenPrompt = "Listen to the Reel Editor chat: call wait_for_app_message, act on each message I send there with the reel editor tools, answer with reply_in_app, and keep listening."

  var body: some View {
    VStack(spacing: 0) {
      // Who answers (the app's own Claude, or a Claude Code session), and where the chat sits (a side panel or a card).
      HStack(spacing: 8) {
        SegmentTabs(items: [SegmentItem(value: "direct", label: "Direct", icon: "sparkle"), SegmentItem(value: "session", label: "Claude Code", icon: "terminal-window")], selection: $mode)
        Spacer(minLength: 4)
        SegmentTabs(items: [SegmentItem(value: "side", label: "Side panel", icon: "sidebar-simple"), SegmentItem(value: "floating", label: "Floating", icon: "app-window")],
                    selection: Binding(get: { dock }, set: { setDock($0) }), iconOnly: true)
      }
      .padding(.horizontal, 16).padding(.vertical, 12)
      Hairline()
      if mode == "direct" { DirectHeader(direct: direct) } else if app.listening.isEmpty { NotListening(app: app) }
      ScrollViewReader { proxy in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 12) {
            if mode == "direct" {
              if direct.messages.isEmpty {
                empty("Ask Claude to edit this reel. It runs on the account above with the editor's tools, no Claude Code session needed. Each message goes with the project, the playhead and what is selected.")
              }
              ForEach(direct.messages) { m in DirectRow(m: m).id(m.id) }
              if direct.state == "thinking" { HStack(spacing: 8) { Spinner(size: 12); Text("Claude is working").font(.inter(12)).foregroundStyle(Ink.faint) }.id("thinking") }
            } else {
              if app.chat.isEmpty {
                empty("Write to the Claude Code session listening here. Each message goes with the project, the playhead and what is selected, and shows in Claude's own chat too.")
              }
              ForEach(app.chat) { m in ChatRow(m: m).id(m.id) }
            }
          }
          .padding(.horizontal, 16).padding(.vertical, 16)
        }
        .onAppear { scrollToEnd(proxy) }
        .onChange(of: direct.messages.count) { _, _ in withAnimation { scrollToEnd(proxy) } }
        .onChange(of: app.chat.last?.id) { _, _ in withAnimation { scrollToEnd(proxy) } }
        .onChange(of: mode) { _, _ in scrollToEnd(proxy) }
      }
      Hairline()
      HStack(alignment: .bottom, spacing: 8) {
        TextField(mode == "direct" ? "Ask Claude to edit this reel" : "Message the listening session", text: $draft, axis: .vertical)
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
          .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (mode == "direct" && direct.state == "thinking"))
          .keyboardShortcut(.return, modifiers: .command)
          .help("Send (Return, or Cmd Return)")
      }
      .padding(16)
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
    if mode == "direct" { if direct.state == "thinking" { proxy.scrollTo("thinking", anchor: .bottom) } else if let l = direct.messages.last { proxy.scrollTo(l.id, anchor: .bottom) } }
    else if let l = app.chat.last { proxy.scrollTo(l.id, anchor: .bottom) }
  }

  // Moves the chat: into the column on the right of the window, or back into the floating card.
  func setDock(_ d: String) {
    guard d != dock else { return }
    dock = d
    if d == "side" { model?.closeFloating(); withAnimation(.cardOpen) { sideOpen = true } }
    else { withAnimation(.cardClose) { sideOpen = false }; model?.toggle(.chat) }
  }

  func send() {
    if mode == "direct" { direct.send(draft, context: app.screenContext()) } else { app.send(draft) }
    draft = ""
  }
}

// The direct chat's account and model, its state, and Restart or Stop.
struct DirectHeader: View {
  @ObservedObject var direct: DirectChat
  var body: some View {
    let accounts = DirectChat.accounts()
    VStack(alignment: .leading, spacing: 8) {
      Dropdown(options: accounts.map { ($0.profile, $0.email) }, selection: Binding(get: { direct.profile }, set: { direct.profile = $0; if direct.state != "off" { direct.restart() } }))
      HStack(spacing: 8) {
        Dropdown(options: [("sonnet", "Sonnet"), ("opus", "Opus"), ("haiku", "Haiku")], selection: Binding(get: { direct.model }, set: { direct.model = $0; if direct.state != "off" { direct.restart() } }))
        Dropdown(options: [("default", "Default effort"), ("low", "Low effort"), ("medium", "Medium effort"), ("high", "High effort"), ("xhigh", "Extra high effort"), ("max", "Max effort")],
                 selection: Binding(get: { direct.effort }, set: { direct.effort = $0; if direct.state != "off" { direct.restart() } }))
      }
      HStack(spacing: 8) {
        Circle().fill(direct.state == "off" ? Ink.ghost : Ink.green).frame(width: 6, height: 6)
        Text(["off": "Starts with your first message", "starting": "Starting Claude", "ready": "Ready", "thinking": "Working"][direct.state] ?? direct.state)
          .font(.inter(12)).foregroundStyle(Ink.faint)
        Spacer()
        if direct.state != "off" { Button("Stop") { direct.stop() }.pill(.ghost, .xs) }
        if !direct.messages.isEmpty { Button("Clear") { direct.clear() }.pill(.ghost, .xs) }
      }
    }
    .padding(.horizontal, 16).padding(.vertical, 12)
    .onAppear { if accounts.first(where: { $0.profile == direct.profile }) == nil, let f = accounts.first { direct.profile = f.profile } }
  }
}

struct DirectRow: View {
  let m: DirectMessage
  var body: some View {
    switch m.role {
    case "activity":
      HStack(spacing: 8) { Icon("wrench", size: 12); Text(m.text).font(.inter(12)).lineLimit(1) }.foregroundStyle(Ink.faint).padding(.horizontal, 8)
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

// Shown while no agent is listening: what to ask Claude once so it does.
struct NotListening: View {
  @ObservedObject var app: AppModel
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 8) {
        Icon("ear-slash", size: 14)
        Text(app.mcp.isEmpty ? "No agent is connected" : "\(app.mcp.first!.service) is connected but not listening").font(.inter(13, .semibold))
      }
      .foregroundStyle(Ink.strong)
      Note("Messages wait here until an agent listens. Ask Claude once, in its own chat:")
      HStack(alignment: .top, spacing: 8) {
        Text(ChatPanel.listenPrompt).font(.inter(12, italic: true)).foregroundStyle(Ink.secondary).lineLimit(3).textSelection(.enabled)
        Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(ChatPanel.listenPrompt, forType: .string) }
          .pill(.outline, .xs)
      }
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(RoundedRectangle(cornerRadius: 12).fill(Ink.sunken))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Ink.border, lineWidth: 1))
    .padding(.horizontal, 24).padding(.top, 16)
  }
}

struct ChatRow: View {
  let m: ChatMessage

  static func time(_ t: Double) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm"
    return f.string(from: Date(timeIntervalSince1970: t))
  }

  var body: some View {
    switch m.from {
    case "activity":
      HStack(spacing: 8) {
        Icon("wrench", size: 12)
        Text(m.text).font(.inter(12)).lineLimit(2)
        Spacer(minLength: 0)
        Text(Self.time(m.t)).font(.inter(11)).foregroundStyle(Ink.ghost)
      }
      .foregroundStyle(Ink.faint)
      .padding(.horizontal, 8)
    case "you":
      VStack(alignment: .trailing, spacing: 4) {
        Text(m.text).font(.inter(14)).textSelection(.enabled)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .foregroundStyle(Ink.onPrimary)
          .background(RoundedRectangle(cornerRadius: 16).fill(Ink.strong))
        Text("\(Self.time(m.t)), \(m.status == "delivered" ? "delivered to \(m.client ?? "the agent")" : "waiting for an agent")\(m.context?["playhead"]?.double.map { ", at \(timecode($0))" } ?? "")")
          .font(.inter(11)).foregroundStyle(Ink.faint)
      }
      .frame(maxWidth: .infinity, alignment: .trailing)
      .padding(.leading, 48)
    default:
      VStack(alignment: .leading, spacing: 4) {
        Text(m.text).font(.inter(14)).foregroundStyle(Ink.text).textSelection(.enabled)
          .padding(.horizontal, 16).padding(.vertical, 10)
          .background(RoundedRectangle(cornerRadius: 16).fill(Ink.sunken))
          .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Ink.border, lineWidth: 1))
        Text("\(m.client ?? "Agent"), \(Self.time(m.t))").font(.inter(11)).foregroundStyle(Ink.faint)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.trailing, 48)
    }
  }
}
