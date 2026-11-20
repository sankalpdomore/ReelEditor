// The export in a modal (Sankalp, 4 Nov 2026): from the start of an export, from Export, Cmd E or an agent's export tool,
// a card in the middle of the window shows its progress, and the window behind it is dimmed and takes no clicks or keys,
// so nothing changes the reel while it renders. Once it is done the card says where the file is, with Show in Finder;
// when it stops, why. Close, Escape or Return closes it then, never while it runs.
import AppKit
import ReelCore
import SwiftUI

struct ExportModalHost: View {
  @ObservedObject var model: EditorModel
  var body: some View {
    if model.exportOpen {
      GeometryReader { g in
        ZStack {
          // Takes every click, so the editor behind does nothing while the modal is up.
          Color.black.opacity(0.24).contentShape(Rectangle()).onTapGesture {}
          ExportModal(model: model)
            .frame(width: min(480, g.size.width - 64))
            .cardChrome()
            .transition(.card(from: .center))
        }
        .frame(width: g.size.width, height: g.size.height)
      }
    }
  }
}

struct ExportModal: View {
  @ObservedObject var model: EditorModel

  var body: some View {
    let st = model.status, state = st["state"]?.string ?? ""
    let running = state == "exporting", failed = state == "error" && st["kind"]?.string == "export"
    let progress = running ? (st["progress"]?.double ?? 0) : failed ? (st["progress"]?.double ?? 0) : 1
    let file = st["result"]?["file"]?.string
    VStack(alignment: .leading, spacing: 16) {
      HStack(spacing: 8) {
        if running { Spinner(size: 16) } else { Icon(failed ? "warning-circle" : "check-circle", size: 16).foregroundStyle(failed ? Ink.red : Ink.green) }
        Text(running ? "Exporting" : failed ? "The export stopped" : "Exported").font(.inter(16, .semibold)).foregroundStyle(Ink.strong)
        Spacer()
        Text("\(Int(progress * 100))%").font(.inter(14, .medium)).foregroundStyle(Ink.secondary).monospacedDigit()
      }
      ProgressTrack(fraction: progress)
      if running {
        Note(st["message"]?.string ?? "Starting")
        Note("The editor waits until the export is done, so nothing changes the reel while it renders.")
      } else if failed {
        Text(st["message"]?.string ?? "").font(.inter(13)).foregroundStyle(Ink.red).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
      } else if let file {
        VStack(alignment: .leading, spacing: 4) {
          Text(URL(fileURLWithPath: file).lastPathComponent).font(.inter(14, .medium)).foregroundStyle(Ink.text).lineLimit(1).truncationMode(.middle)
          Text(file.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.inter(12)).foregroundStyle(Ink.faint).lineLimit(1).truncationMode(.middle).help(file)
          if let s = st["result"]?["seconds"]?.double { Note("\(timecode(s).components(separatedBy: ".")[0]) long") }
        }
      }
      if !running {
        HStack(spacing: 8) {
          Spacer()
          if let file, !failed {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: file)]) } label: { IconLabel("Show in Finder", icon: "folder-open", size: 14) }.pill(.outline, .md)
          }
          Button { model.closeExport() } label: { Text("Close") }.pill(.primary, .md).keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(24)
    .font(.inter())
  }
}
