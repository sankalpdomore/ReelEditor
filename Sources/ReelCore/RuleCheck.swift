// check_rules (Sankalp, 4 Nov 2026): the rules of the rule books that can be measured, checked in plain code on the reel as
// it plays, so the chat's Claude cannot report a pass done while one is broken. His comments on 2026-11-04-img-4842-v1
// were each a rule left undone: a sentence with no full stop and the next one with no capital, a lower case word that
// starts a sentence, three to four written as words, a phrase kept twice. Claude runs it after every pass and fixes all it
// lists. Only the kept words count: a cut word, waiting for approval or not, is not heard.
import Foundation

enum RuleCheck {
  static let fillers: Set<String> = ["uh", "um", "umm", "uhm", "uhh", "uhhh", "er", "erm", "ah", "ahh", "hmm", "mm", "mhm", "uums"]
  static let numberWords: Set<String> = ["two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve", "thirteen",
                                         "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty", "thirty", "forty",
                                         "fifty", "sixty", "seventy", "eighty", "ninety", "hundred", "thousand", "million", "billion",
                                         "third", "fourth", "fifth", "sixth", "seventh", "eighth", "ninth", "tenth", "percent"]
  static let lowerI: Set<String> = ["i", "i'm", "i've", "i'll", "i'd"]

  // The word as letters, for comparing: lower case, without the marks around it.
  static func bare(_ w: String) -> String {
    w.lowercased().replacingOccurrences(of: "\u{2019}", with: "'").trimmingCharacters(in: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
  }
  static func endsSentence(_ w: String) -> Bool { let t = w.trimmingCharacters(in: CharacterSet(charactersIn: "\"'\u{201D}\u{2019})")); return t.hasSuffix(".") || t.hasSuffix("?") || t.hasSuffix("!") }
  static func punctuated(_ w: String) -> Bool { endsSentence(w) || w.hasSuffix(",") || w.hasSuffix(";") || w.hasSuffix(":") || w.hasSuffix("\u{2026}") }

  static func run(_ l: Loaded, maxGap: Double) -> JSON {
    let plan = l.plan, speed = Compose.speedOf(l.project.edits)
    let paras = transcriptLayout(l)
    struct K { var w: LayoutWord; var label: String }
    let kept: [K] = paras.flatMap { p in p.words.filter { !$0.cut }.map { K(w: $0, label: p.label) } }
    // Seconds that play between two edit times: what the cuts leave of them, at the reel's speed.
    func plays(_ a: Double, _ b: Double) -> Double {
      guard b > a else { return 0 }
      return ((b - a) - plan.cuts.reduce(0) { $0 + max(0, min($1.e, b) - max($1.s, a)) }) / speed
    }
    var out: [JSON] = []
    var counts: [String: Int] = [:]
    func add(_ kind: String, _ k: K, _ end: Double? = nil, _ text: String, fix: String, from: Double? = nil) {
      counts[kind, default: 0] += 1
      var o: [String: JSON] = ["kind": .string(kind), "start": .number(round3(from ?? k.w.s)), "end": .number(round3(end ?? k.w.e)), "clip": .string(k.w.clip),
                               "video": .string(k.w.source == MAIN ? "main" : k.w.source), "label": .string(k.label), "text": .string(text), "fix": .string(fix)]
      if let i = k.w.index { o["word"] = .number(Double(i)) }
      out.append(.object(o))
    }
    let f2 = { (x: Double) in String(format: "%.2f", x) }
    func around(_ i: Int) -> String { kept[max(0, i - 3)...min(kept.count - 1, i + 3)].map(\.w.w).joined(separator: " ") }
    let wordFix = { (k: K) in k.w.source == MAIN ? "correct_word index \(k.w.index ?? 0)" : "the script of clip \(k.w.clip) through transcribe_source source \(k.w.source)" }

    guard !kept.isEmpty else { return ["clean": true, "count": 0, "findings": [], "note": "No kept words to check."] }
    // The reel opens about 0.2 s before its first word and ends about 0.2 s after its last.
    let lead = plays(0, kept[0].w.s), tail = plays(kept[kept.count - 1].w.e, plan.editDuration)
    if lead > 0.35 { add("gap", kept[0], kept[0].w.s, "\(f2(lead)) s before the first word", fix: "cut_range from 0 to \(f2(max(0, kept[0].w.s - 0.2)))", from: 0) }
    if tail > 0.35 { let k = kept[kept.count - 1]; add("gap", k, plan.editDuration, "\(f2(tail)) s after the last word", fix: "cut_range from \(f2(k.w.e + 0.2)) to \(f2(plan.editDuration))", from: k.w.e) }

    var sinceStop = 0, runStart = 0
    for (i, k) in kept.enumerated() {
      let b = bare(k.w.w), prev = i > 0 ? kept[i - 1] : nil
      if let p = prev {
        let g = plays(p.w.e, k.w.s)
        if g > maxGap + 0.05 {
          add("gap", p, k.w.s, "\(f2(g)) s of silence between \(p.w.w) and \(k.w.w), more than \(f2(maxGap)) s",
              fix: "cut_range from \(f2(p.w.e + 0.15)) to \(f2(k.w.s - 0.15)), leaving about 0.15 s each side", from: p.w.e)
        }
        if !b.isEmpty, b == bare(p.w.w), !punctuated(p.w.w), !fillers.contains(b) {
          add("repeat", p, k.w.e, "\(p.w.w) \(k.w.w) kept twice in a row: \(around(i))", fix: "cut the first \(p.w.w), \(f2(p.w.s)) to \(f2(k.w.s - 0.02))")
        }
      }
      if fillers.contains(b) { add("filler", k, nil, "filler \(k.w.w): \(around(i))", fix: "cut_range from \(f2(k.w.s)) to \(f2(k.w.e)) on its own sound edges, then tighten the gap") }
      if lowerI.contains(k.w.w.trimmingCharacters(in: .punctuationCharacters)), k.w.w.first == "i" { add("capital", k, nil, "\(k.w.w) is always a capital I: \(around(i))", fix: wordFix(k)) }
      if let first = k.w.w.first(where: { $0.isLetter }), first.isLowercase, prev.map({ endsSentence($0.w.w) }) ?? true {
        add("capital", k, nil, "\(k.w.w) starts a sentence: \(around(i))", fix: wordFix(k))
      }
      if numberWords.contains(b) { add("number", k, nil, "\(k.w.w) is a number, written as digits in the captions: \(around(i))", fix: wordFix(k)) }
      if b == "one", let p = prev, bare(p.w.w) == "next", i + 1 == kept.count || endsSentence(k.w.w), !k.w.w.hasSuffix("!") {
        add("punctuation", k, nil, "see you in the next one ends with an exclamation mark: \(around(i))", fix: wordFix(k))
      }
      // A long stretch with no full stop is speech the transcriber left unpunctuated.
      if endsSentence(k.w.w) { sinceStop = 0; runStart = i + 1 } else { sinceStop += 1 }
      if sinceStop == 30 { add("punctuation", kept[runStart], k.w.e, "30 words with no full stop from \(kept[runStart].w.w): \(kept[runStart...i].prefix(12).map(\.w.w).joined(separator: " ")) ...", fix: "punctuate by the meaning, a full stop and a capital at each sentence, through \(wordFix(kept[runStart]))") }
    }
    if let last = kept.last, !endsSentence(last.w.w) { add("punctuation", last, nil, "the last word, \(last.w.w), has no full stop", fix: wordFix(last)) }

    let shown = Array(out.prefix(300))
    var o: [String: JSON] = ["clean": .bool(out.isEmpty), "count": .number(Double(out.count)), "byKind": .object(counts.mapValues { .number(Double($0)) }),
                             "findings": .array(shown), "maxGap": .number(maxGap),
                             "note": .string(out.isEmpty ? "Every measurable rule holds. Run audit_audio too: a phrase said twice that the transcript writes once is only found there."
                                             : "Fix every finding, then run check_rules again until it is clean; a finding left on purpose is named in the report with why. Times are edit seconds. Run audit_audio too for repeats the transcript hides.")]
    if out.count > shown.count { o["more"] = .number(Double(out.count - shown.count)) }
    return .object(o)
  }
}

let ruleCheckTools: [ReelTool] = [
  ReelTool(name: "check_rules", description: "Checks the reel as it plays against the rules of the rule books that can be measured, and lists every place one is broken: gap (a silence over maxGap seconds between kept words, 0.3 by default, or more than about 0.2 s before the first word or after the last), filler (uh, um and the like kept), repeat (the same word kept twice in a row), capital (a sentence or I in lower case), number (a number written as a word), punctuation (30 words with no full stop, the last word with none, see you in the next one without an exclamation mark). Each finding has kind, start and end in edit seconds, clip, video, word (the project's own video's word index), text and fix, the tool call that fixes it. Only kept words count. Run it after every pass and fix all it lists before saying the pass is done; it changes nothing. A phrase said twice that the transcript writes once is found by audit_audio, not here.", inputSchema: obj([
    "project": projectArg,
    "maxGap": ["type": "number", "minimum": 0.1, "maximum": 3, "default": 0.3, "description": "The longest silence allowed between kept words, seconds."],
  ], ["project"])) { i in
    let n = try name(i)
    let l = try Store.load(n)
    Focus.set(n, "Checking the rules", 0, l.plan.editDuration)
    var r = RuleCheck.run(l, maxGap: i["maxGap"]?.double ?? 0.3)
    if case .object(var o) = r { o["project"] = .string(n); r = .object(o) }
    return r
  },
]
