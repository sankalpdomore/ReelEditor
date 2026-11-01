// The pieces of the edit that came to the web editor after 23 Oct 2026, ported from lib/reel-look.ts, lib/reel-place.ts,
// lib/reel-eq.ts, lib/reel-cost.ts and the window of lib/reel-edl.ts, with the same JSON shapes so a project.json reads like
// the web editor's edits.json: the look of a picture, where a clip's picture sits in the frame, the bass and treble of a
// voice, the window of a face overlay and how it moves, the music bed, the caption position, the reel's links and the
// record of what its AI generations cost. Pure values and functions; Composition.swift and AudioFX.swift draw and play them.
import Foundation

// ---------------------------------------------------------------------------------------------------------------------
// The look of a picture: saturation, brightness, exposure, contrast, temperature (-100 to 100), sharpness and vignette (0 to
// 100), 0 is as recorded. name is the saved look it came from, shown on the Video layer.

public struct ReelLook: Codable, Equatable, Sendable {
  public var saturation: Double = 0
  public var brightness: Double = 0
  public var exposure: Double = 0
  public var contrast: Double = 0
  public var temperature: Double = 0
  public var sharpness: Double = 0
  public var vignette: Double = 0
  public var name: String? = nil
  public init(saturation: Double = 0, brightness: Double = 0, exposure: Double = 0, contrast: Double = 0, temperature: Double = 0, sharpness: Double = 0, vignette: Double = 0, name: String? = nil) {
    self.saturation = saturation; self.brightness = brightness; self.exposure = exposure; self.contrast = contrast
    self.temperature = temperature; self.sharpness = sharpness; self.vignette = vignette; self.name = name
  }
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    func v(_ k: CodingKeys) -> Double { (try? c.decodeIfPresent(Double.self, forKey: k)) ?? 0 }
    saturation = v(.saturation); brightness = v(.brightness); exposure = v(.exposure); contrast = v(.contrast)
    temperature = v(.temperature); sharpness = v(.sharpness); vignette = v(.vignette)
    name = try? c.decodeIfPresent(String.self, forKey: .name)
  }
  public var isNone: Bool { [saturation, brightness, exposure, contrast, temperature, sharpness, vignette].allSatisfy { $0 == 0 } }
  // The shared mapping of lib/reel-look.ts: brightness and exposure scale the light, contrast and saturation are factors.
  public var gain: Double { (1 + brightness / 200) * pow(2, exposure / 100) }
  public var contrastFactor: Double { 1 + contrast / 200 }
  public var saturationFactor: Double { 1 + saturation / 100 }
}

public let LOOK_KEYS = ["saturation", "brightness", "exposure", "contrast", "temperature", "sharpness", "vignette"]
public let LOOK_MIN: [String: Double] = ["saturation": -100, "brightness": -100, "exposure": -100, "contrast": -100, "temperature": -100, "sharpness": 0, "vignette": 0]

// A look from JSON: each value rounded and clamped to its range, nil when every one is 0.
public func normalizeLook(_ raw: JSON?) -> ReelLook? {
  guard let o = raw?.object else { return nil }
  var vals: [String: Double] = [:]
  for k in LOOK_KEYS { if let v = o[k]?.double, v.isFinite { vals[k] = max(LOOK_MIN[k]!, min(100, v)).rounded() } }
  let l = ReelLook(saturation: vals["saturation"] ?? 0, brightness: vals["brightness"] ?? 0, exposure: vals["exposure"] ?? 0, contrast: vals["contrast"] ?? 0,
                   temperature: vals["temperature"] ?? 0, sharpness: vals["sharpness"] ?? 0, vignette: vals["vignette"] ?? 0,
                   name: o["name"]?.string.map { String($0.trimmingCharacters(in: .whitespaces).prefix(60)) }.flatMap { $0.isEmpty ? nil : $0 })
  return l.isNone ? nil : l
}
public func normalizeLook(_ l: ReelLook?) -> ReelLook? { l.flatMap { normalizeLook(JSON.from($0)) } }

// ---------------------------------------------------------------------------------------------------------------------
// Where a picture sits in its frame: zoom 0.5 to 4 (1 as recorded), x and y how far its centre moves, as a share of the
// frame's width and height (y down), -1 to 1. What the picture no longer covers shows black.

public struct ReelPlace: Codable, Equatable, Sendable {
  public var zoom: Double
  public var x: Double
  public var y: Double
  public init(zoom: Double = 1, x: Double = 0, y: Double = 0) { self.zoom = zoom; self.x = x; self.y = y }
}

public func normalizePlace(_ raw: JSON?) -> ReelPlace? {
  guard let o = raw?.object else { return nil }
  func num(_ k: String, _ d: Double) -> Double { o[k]?.double.flatMap { $0.isFinite ? $0 : nil } ?? d }
  let p = ReelPlace(zoom: round3(max(0.5, min(4, num("zoom", 1)))), x: round3(max(-1, min(1, num("x", 0)))), y: round3(max(-1, min(1, num("y", 0)))))
  return p.zoom == 1 && p.x == 0 && p.y == 0 ? nil : p
}
public func normalizePlace(_ p: ReelPlace?) -> ReelPlace? { p.flatMap { normalizePlace(JSON.from($0)) } }

// ---------------------------------------------------------------------------------------------------------------------
// The bass and treble of a voice: two shelves in whole dB, -12 to 12, a low shelf at 120 Hz and a high shelf at 6 kHz. Left
// out (nil) when both are 0.

public let EQ_MIN = -12.0, EQ_MAX = 12.0, EQ_BASS_HZ = 120.0, EQ_TREBLE_HZ = 6000.0

public struct AudioEq: Codable, Equatable, Sendable {
  public var bass: Double
  public var treble: Double
  public init(bass: Double = 0, treble: Double = 0) { self.bass = bass; self.treble = treble }
}

public func normalizeEq(bass: Double?, treble: Double?) -> AudioEq? {
  func clamp(_ v: Double?) -> Double { guard let v, v.isFinite else { return 0 }; return max(EQ_MIN, min(EQ_MAX, v)).rounded() }
  let e = AudioEq(bass: clamp(bass), treble: clamp(treble))
  return e.bass == 0 && e.treble == 0 ? nil : e
}
public func normalizeEq(_ e: AudioEq?) -> AudioEq? { e.flatMap { normalizeEq(bass: $0.bass, treble: $0.treble) } }

// ---------------------------------------------------------------------------------------------------------------------
// The window of a face (or video) overlay: x the share of the frame's width its left edge is at, y the share of the height
// its middle is at, w the share of the width it is wide. ratio fixes its height over its width (the picture cropped to fill
// it), radius its corners in px of a 1080 wide frame (default 40), place zooms and moves the picture inside it. Each move
// eases (smoothstep) to a new x and y at `at` seconds into the overlay, over dur seconds.

public struct WindowMove: Codable, Equatable, Sendable {
  public var at: Double
  public var x: Double
  public var y: Double
  public var dur: Double
  public init(at: Double, x: Double, y: Double, dur: Double = 0.35) { self.at = at; self.x = x; self.y = y; self.dur = dur }
}

public struct FaceWindow: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public var w: Double
  public var ratio: Double? = nil
  public var radius: Double? = nil
  public var place: ReelPlace? = nil
  public var moves: [WindowMove]? = nil
  public init(x: Double, y: Double, w: Double, ratio: Double? = nil, radius: Double? = nil, place: ReelPlace? = nil, moves: [WindowMove]? = nil) {
    self.x = x; self.y = y; self.w = w; self.ratio = ratio; self.radius = radius; self.place = place; self.moves = moves
  }
}

public func normalizeWindow(_ raw: JSON?) -> FaceWindow? {
  guard let o = raw?.object, let x = o["x"]?.double, let y = o["y"]?.double, let w = o["w"]?.double, x.isFinite, y.isFinite, w.isFinite else { return nil }
  func clamp(_ n: Double, _ lo: Double, _ hi: Double) -> Double { round3(max(lo, min(hi, n))) }
  let moves = (o["moves"]?.array ?? []).compactMap { m -> WindowMove? in
    guard let at = m["at"]?.double, let mx = m["x"]?.double, let my = m["y"]?.double else { return nil }
    return WindowMove(at: round3(max(0, at)), x: clamp(mx, -1, 2), y: clamp(my, -1, 2), dur: m["dur"]?.double.map { clamp($0, 0, 10) } ?? 0.35)
  }.sorted { $0.at < $1.at }.prefix(30)
  return FaceWindow(x: clamp(x, -1, 2), y: clamp(y, -1, 2), w: clamp(w, 0.05, 1),
                    ratio: o["ratio"]?.double.map { clamp($0, 0.2, 3) }, radius: o["radius"]?.double.map { clamp($0, 0, 540) },
                    place: normalizePlace(o["place"]), moves: moves.isEmpty ? nil : Array(moves))
}
public func normalizeWindow(_ w: FaceWindow?) -> FaceWindow? { w.flatMap { normalizeWindow(JSON.from($0)) } }

// Where a window is at `local` seconds into its overlay: its place, then each move eases to its own place over its duration.
public func windowAt(_ win: FaceWindow, _ local: Double) -> (x: Double, y: Double) {
  var x = win.x, y = win.y
  for m in win.moves ?? [] {
    let u = m.dur > 0 ? max(0, min(1, (local - m.at) / m.dur)) : (local >= m.at ? 1 : 0)
    let k = u * u * (3 - 2 * u)
    x += (m.x - x) * k; y += (m.y - y) * k
    if u < 1 { break }
  }
  return (x, y)
}

// ---------------------------------------------------------------------------------------------------------------------
// The music bed: its volume (0 to 1), fades, mute, the track and the clip of it that plays (start, end, end 0 is the track's
// end, repeated from start where it ends). none removes the music completely. duck is kept for older files and ignored, as
// in the web editor. track is an absolute path to an audio file, or the name of a file in the projects folder's _music.

public struct MusicSettings: Codable, Equatable, Sendable {
  public var gain: Double = 0.55
  public var fadeIn: Double = 1
  public var fadeOut: Double = 2.5
  public var duck: Bool = true
  public var mute: Bool = false
  public var track: String? = nil
  public var start: Double? = nil
  public var end: Double? = nil
  public var none: Bool? = nil
  public init() {}
  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    gain = (try? c.decodeIfPresent(Double.self, forKey: .gain)) ?? 0.55
    fadeIn = (try? c.decodeIfPresent(Double.self, forKey: .fadeIn)) ?? 1
    fadeOut = (try? c.decodeIfPresent(Double.self, forKey: .fadeOut)) ?? 2.5
    duck = (try? c.decodeIfPresent(Bool.self, forKey: .duck)) ?? true
    mute = (try? c.decodeIfPresent(Bool.self, forKey: .mute)) ?? false
    track = try? c.decodeIfPresent(String.self, forKey: .track)
    start = try? c.decodeIfPresent(Double.self, forKey: .start)
    end = try? c.decodeIfPresent(Double.self, forKey: .end)
    none = try? c.decodeIfPresent(Bool.self, forKey: .none)
  }
}

// Where a reel's captions sit: x the middle's offset from the frame's centre and y the middle down from the top, in px of the
// 1080 by 1920 frame (1920 by 1080 for a landscape video).
public struct CaptionPos: Codable, Equatable, Sendable {
  public var x: Double
  public var y: Double
  public init(x: Double, y: Double) { self.x = x; self.y = y }
}

// A document or file a reel is made from, shown beside its transcript: a format doc (a path inside content/documents, no .md)
// or a JSON file.
public struct ReelReference: Codable, Equatable, Sendable {
  public var kind: String // format or json
  public var title: String
  public var path: String
  public init(kind: String, title: String, path: String) { self.kind = kind; self.title = title; self.path = path }
}

public func normalizeReferences(_ raw: JSON?) -> [ReelReference] {
  (raw?.array ?? []).compactMap { x in
    guard let kind = x["kind"]?.string, kind == "format" || kind == "json",
          let t = x["title"]?.string?.trimmingCharacters(in: .whitespaces), !t.isEmpty,
          let p = x["path"]?.string?.trimmingCharacters(in: .whitespaces), !p.isEmpty, !p.contains("..") else { return nil }
    return ReelReference(kind: kind, title: String(t.prefix(120)), path: String(p.prefix(300)))
  }
}

// ---------------------------------------------------------------------------------------------------------------------
// What a reel's AI generations cost (lib/reel-cost.ts): a line per generation, its cost filled from the published rates when
// it is not given, and the totals per currency and in rupees at lib/currency.ts's fixed rates.

public let ARGON_INR_PER_VIDEO = 16.25
public let HEYGEN_USD_PER_CREDIT = 0.049
public let HEYGEN_CREDITS_PER_SECOND = 1.0 / 60
public let INR_PER_UNIT: [String: Double] = ["INR": 1, "USD": 96.3, "EUR": 107.89, "GBP": 127.36, "CAD": 67.57, "AUD": 67.03, "BRL": 19.32, "CNY": 14.36, "SGD": 75.22, "CZK": 4.41, "AED": 26.22, "BDT": 0.79, "CRC": 0.19]
public func toInr(_ amount: Double, _ currency: String) -> Double { amount * (INR_PER_UNIT[currency] ?? 0) }

public struct CostItem: Codable, Equatable, Sendable {
  public var id: String
  public var kind: String
  public var part: String
  public var count: Int
  public var cost: Double
  public var currency: String
  public var date: String
  public var basis: String // measured, rate or estimate
  public var seconds: Double? = nil
  public var credits: Double? = nil
  public var account: String? = nil
  public var failed: Bool? = nil
  public var note: String? = nil
}
public struct CostTotal: Codable, Equatable, Sendable { public var byCurrency: [String: Double]; public var inr: Double; public var generations: Int; public var failed: Int }
public struct ReelCost: Codable, Equatable, Sendable { public var items: [CostItem]; public var total: CostTotal }

private func roundTo(_ n: Double, _ d: Int) -> Double { let p = pow(10, Double(d)); return (n * p).rounded() / p }

public func costItem(_ raw: JSON, id: String) -> CostItem? {
  func str(_ k: String, _ max: Int) -> String? { raw[k]?.string.map { String($0.trimmingCharacters(in: .whitespaces).prefix(max)) }.flatMap { $0.isEmpty ? nil : $0 } }
  func num(_ k: String) -> Double? { raw[k]?.double.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
  guard let kind = str("kind", 40)?.lowercased(), kind.range(of: "^[a-z0-9-]+$", options: .regularExpression) != nil, let part = str("part", 60) else { return nil }
  let count = raw["count"]?.int.flatMap { $0 > 0 ? min($0, 999) : nil } ?? 1
  let failed = raw["failed"]?.bool == true
  let seconds = num("seconds")
  var credits = num("credits")
  if credits == nil && kind == "heygen-voice", let s = seconds { credits = roundTo(s * HEYGEN_CREDITS_PER_SECOND, 4) }
  var cost = num("cost")
  var currency = str("currency", 3)?.uppercased()
  var basis = raw["basis"]?.string.flatMap { ["measured", "rate", "estimate"].contains($0) ? $0 : nil }
  if failed { cost = 0; if currency == nil { currency = kind == "heygen-voice" ? "USD" : "INR" } }
  else if cost == nil && kind == "argon-video" { cost = ARGON_INR_PER_VIDEO * Double(count); currency = "INR"; if basis == nil { basis = "estimate" } }
  else if cost == nil && kind == "heygen-voice", let c = credits { cost = c * HEYGEN_USD_PER_CREDIT; currency = "USD"; if basis == nil { basis = seconds != nil && raw["credits"] == nil ? "rate" : "measured" } }
  guard let cost, let currency, currency.range(of: "^[A-Z]{3}$", options: .regularExpression) != nil else { return nil }
  let df = DateFormatter(); df.dateFormat = "yyyy-MM-dd"
  let date = raw["date"]?.string.flatMap { $0.range(of: "^\\d{4}-\\d{2}-\\d{2}$", options: .regularExpression) != nil ? $0 : nil } ?? df.string(from: Date())
  return CostItem(id: id, kind: kind, part: part, count: count, cost: roundTo(cost, 4), currency: currency, date: date, basis: basis ?? "estimate",
                  seconds: seconds.map { roundTo($0, 2) }, credits: credits, account: str("account", 60), failed: failed ? true : nil, note: str("note", 300))
}

public func costTotal(_ items: [CostItem]) -> CostTotal {
  var by: [String: Double] = [:]
  for x in items { by[x.currency] = roundTo((by[x.currency] ?? 0) + x.cost, 4) }
  for k in by.keys { by[k] = roundTo(by[k]!, 2) }
  return CostTotal(byCurrency: by, inr: roundTo(items.reduce(0) { $0 + toInr($1.cost, $1.currency) }, 2),
                   generations: items.filter { $0.failed != true }.reduce(0) { $0 + $1.count }, failed: items.filter { $0.failed == true }.reduce(0) { $0 + $1.count })
}

// Lines cleaned, each with an id (g1, g2 and so on, a new line the next free one), and the totals worked out again.
public func normalizeCost(_ raw: [JSON]) -> ReelCost? {
  var taken = Set<String>()
  let given = Set(raw.compactMap { $0["id"]?.string })
  var items: [CostItem] = []
  for x in raw {
    var id = x["id"]?.string.flatMap { $0.range(of: "^g\\d+$", options: .regularExpression) != nil && !taken.contains($0) ? $0 : nil } ?? ""
    if id.isEmpty { var n = 1; while taken.contains("g\(n)") || given.contains("g\(n)") { n += 1 }; id = "g\(n)" }
    if let item = costItem(x, id: id) { items.append(item); taken.insert(id) }
  }
  return items.isEmpty ? nil : ReelCost(items: items, total: costTotal(items))
}
