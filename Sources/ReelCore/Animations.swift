// The coded animation layer: animations laid over the video at their own timestamps, kept in a file of their own
// (animations.json) beside the project's edits. Like the web editor's "Animation coded" layer, an animation is placed in
// edit time and plays in output time, so a cut inside its span shortens the time it is up without a jump.
import Foundation

public struct ReelAnimation: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var start: Double // edit time, seconds
  public var end: Double
  public var side: String = "right" // left, right or center
  public var position: String = "middle" // top, middle or bottom
  public var text: String? = nil
  public var subtitle: String? = nil
  public var color: String? = nil // accent colour, #rrggbb
  public var emoji: String? = nil
  public var from: Double? = nil
  public var to: Double? = nil
  public var prefix: String? = nil
  public var suffix: String? = nil
  // A text layer's own look and its motions in and out (kind text, Captions.swift).
  public var style: TextStyle? = nil
  public var enter: String? = nil
  public var exit: String? = nil

  public init(id: String = "", kind: String, start: Double, end: Double, side: String = "right", position: String = "middle") {
    self.id = id; self.kind = kind; self.start = start; self.end = end; self.side = side; self.position = position
  }
}

public struct AnimationFile: Codable, Equatable, Sendable {
  public var app = "reel-editor-mac"
  public var version = 1
  public var rev = 0
  public var animations: [ReelAnimation] = []
  public init() {}
}

public struct AnimationKind: Sendable {
  public let id: String
  public let title: String
  public let description: String
  public let fields: [String]
  public let defaultLength: Double
}

public let ANIMATION_KINDS: [AnimationKind] = [
  AnimationKind(id: "text-pop", title: "Text pop", description: "A bold card with a line of text that springs in and fades out. text is the line, color the card (default yellow).", fields: ["text", "color"], defaultLength: 2.5),
  AnimationKind(id: "lower-third", title: "Lower third", description: "A name bar that slides in from its side: text is the name or headline, subtitle the line under it, color the accent bar.", fields: ["text", "subtitle", "color"], defaultLength: 4),
  AnimationKind(id: "counter", title: "Counter", description: "A big number that counts from `from` to `to` over the first part of its span, with prefix and suffix around it (for example prefix ₹, suffix L) and text as the label under it.", fields: ["from", "to", "prefix", "suffix", "text", "color"], defaultLength: 3),
  AnimationKind(id: "emoji-burst", title: "Emoji burst", description: "A handful of emoji that float up and fade, staggered. emoji is the character (default 🔥).", fields: ["emoji"], defaultLength: 2),
  AnimationKind(id: "progress-bar", title: "Progress bar", description: "A bar that fills over its span up to `to` percent (default 100), with text as its label.", fields: ["text", "to", "color"], defaultLength: 3),
  AnimationKind(id: "callout", title: "Callout", description: "A speech bubble with text, pointing toward the speaker, that pops in with a small bounce.", fields: ["text", "color"], defaultLength: 3),
  AnimationKind(id: "text", title: "Text", description: "A text layer: text is its words (on more than one line too), in its own style (font, weight, size, colour, outline, shadow, box, x and y, widest line, alignment, like the captions' style), coming in with enter (fade, pop, rise, drop, slide-left, slide-right, typewriter or none) and going out with exit (the same but typewriter). For a part of the reel or all of it. add_text_layer adds one.", fields: ["text", "style", "enter", "exit"], defaultLength: 3),
  AnimationKind(id: "checklist", title: "Checklist", description: "A list that ticks in one item at a time, evenly over the first two thirds of its span. text holds the items, one per line.", fields: ["text", "color"], defaultLength: 4),
]
public let ANIMATION_KIND_IDS = ANIMATION_KINDS.map(\.id)
public let ANIMATION_EXIT = 0.4 // seconds an animation takes to fade out at the end of its span

// The animations cleaned: a known kind, at least half a second long, a side and position, sorted by start, each with an id.
public func normalizeAnimations(_ list: [ReelAnimation]) -> [ReelAnimation] {
  var clean = list
    .filter { ANIMATION_KIND_IDS.contains($0.kind) && $0.start >= 0 && $0.end - $0.start >= 0.5 }
    .map { a -> ReelAnimation in
      var x = a
      x.start = round3(a.start); x.end = round3(a.end)
      if !["left", "right", "center"].contains(x.side) { x.side = "right" }
      if !["top", "middle", "bottom"].contains(x.position) { x.position = "middle" }
      return x
    }
    .sorted { $0.start < $1.start }
  var taken = Set(clean.map(\.id).filter { !$0.isEmpty })
  for i in clean.indices where clean[i].id.isEmpty {
    var n = 1
    while taken.contains("a\(n)") { n += 1 }
    clean[i].id = "a\(n)"; taken.insert("a\(n)")
  }
  return clean
}
