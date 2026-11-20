// The rule books, read in the app (Sankalp, 2 Nov 2026): clicking the rule book count in the chat opens a modal over
// the window with every rule book of the project in front listed on the left and the one picked shown on the right,
// its markdown laid out as headings, lists and paragraphs. The up and down arrows move between them, Escape or a click
// outside closes it. It reads the folder again each time it opens, so a file just added in Finder shows.
// REEL_EDITOR_RULES=1 opens it at launch, for a snapshot.
import AppKit
import ReelCore
import SwiftUI

struct RuleBooksModal: View {
  @ObservedObject var app: AppModel
  @ObservedObject private var direct = DirectChat.shared

  var body: some View {
    GeometryReader { g in
      ZStack {
        Color.black.opacity(0.24).onTapGesture { app.closeRules() }
        card
          .frame(width: min(960, g.size.width - 64), height: max(320, min(g.size.height * CARD_SHARE, g.size.height - 64)))
          .cardChrome()
          .transition(.card(from: .center))
      }
      .frame(width: g.size.width, height: g.size.height)
    }
    .onAppear { direct.reloadRules(); app.pickRuleBook(nil) }
  }

  var books: [Rules.Book] { direct.rules }
  var current: Rules.Book? { books.first { $0.name == app.ruleBook } ?? books.first }

  var card: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        Icon("book-open-text", size: 16).foregroundStyle(Ink.muted)
        Text("Rule books").font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
        Text("\(books.count) in \(direct.rulesDir.replacingOccurrences(of: NSHomeDirectory(), with: "~"))")
          .font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(1).truncationMode(.middle)
          .help(direct.rulesDir)
        Spacer(minLength: 8)
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: direct.rulesDir)) } label: { IconLabel("Show folder", icon: "folder-open", size: 12) }
          .pill(.ghost, .xs).help("Show the rules folder in Finder")
        Button { app.closeRules() } label: { Icon("x", size: 14) }.pill(.ghost, .iconSm).help("Close (Escape)")
      }
      .padding(.horizontal, 16).frame(height: 56)
      Hairline()
      if books.isEmpty {
        VStack(spacing: 8) {
          Icon("book-open-text", size: 32).foregroundStyle(Ink.muted)
          Text("No rule books in this folder yet").font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
          Text("Drop .md or .txt files on the chat, or add them to the folder in Finder.").font(.inter(14)).foregroundStyle(Ink.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        HStack(spacing: 0) {
          list
          Hairline(vertical: true)
          if let b = current { BookPage(book: b).id(b.name) }
        }
      }
    }
  }

  // Every rule book, by its name inside the folder, with its subfolder and length under it.
  var list: some View {
    ScrollViewReader { proxy in
      ScrollView {
        VStack(alignment: .leading, spacing: 4) {
          ForEach(books, id: \.name) { b in
            let on = b.name == current?.name
            Button { app.pickRuleBook(b.name) } label: {
              VStack(alignment: .leading, spacing: 4) {
                Text(Self.title(b)).font(.inter(14, .medium)).foregroundStyle(on ? Ink.strong : Ink.text).lineLimit(2)
                Text(Self.meta(b)).font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(1)
              }
              .padding(.horizontal, 12).padding(.vertical, 8)
              .frame(maxWidth: .infinity, alignment: .leading)
              .background {
                if on {
                  RoundedRectangle(cornerRadius: 8).fill(Ink.raised)
                    .shadow(color: .black.opacity(0.08), radius: 4, y: 2)
                }
              }
              .contentShape(RoundedRectangle(cornerRadius: 8))
            }
            .buttonStyle(.plain)
            .id(b.name)
          }
        }
        .padding(8)
      }
      .onChange(of: app.ruleBook) { _, n in if let n { withAnimation { proxy.scrollTo(n) } } }
    }
    .frame(width: 256)
    .background(Ink.sunken)
  }

  // The file's name without its extension, as a title.
  static func title(_ b: Rules.Book) -> String { ((b.name as NSString).lastPathComponent as NSString).deletingPathExtension }
  static func meta(_ b: Rules.Book) -> String {
    let folder = (b.name as NSString).deletingLastPathComponent
    let lines = b.text.split(separator: "\n", omittingEmptySubsequences: false).count
    return (folder.isEmpty ? "" : folder + ", ") + "\(lines) \(lines == 1 ? "line" : "lines")"
  }
}

// One rule book: its name and file, Open and Show in Finder, then its text.
private struct BookPage: View {
  let book: Rules.Book
  var body: some View {
    VStack(spacing: 0) {
      HStack(spacing: 8) {
        VStack(alignment: .leading, spacing: 4) {
          Text(RuleBooksModal.title(book)).font(.inter(20, .semibold)).foregroundStyle(Ink.strong).lineLimit(1)
          Text(book.file.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.inter(12)).foregroundStyle(Ink.faint)
            .lineLimit(1).truncationMode(.middle).help(book.file)
        }
        Spacer(minLength: 8)
        Button { NSWorkspace.shared.open(URL(fileURLWithPath: book.file)) } label: { IconLabel("Open", icon: "arrow-square-out", size: 12) }
          .pill(.outline, .xs).help("Open this rule book in its own app to edit it")
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: book.file)]) } label: { Icon("folder-open", size: 12) }
          .pill(.ghost, .iconSm).help("Show this rule book in Finder")
      }
      .padding(.horizontal, 24).padding(.vertical, 16)
      Hairline()
      ScrollView {
        Group {
          if ["md", "markdown"].contains((book.file as NSString).pathExtension.lowercased()) { MarkdownBlocks(text: book.text) }
          else { Text(book.text).font(.inter(14)).foregroundStyle(Ink.text).lineSpacing(4) }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(24)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
