import "./feature-demos.css"

// Small demos of the app, drawn in HTML and CSS in the app's own look so they stay sharp and light. Each mirrors a real
// screen: the transcript with cuts waiting for approval, the repeat check, Edit caption, the rule check and what stays on
// the Mac.

const words = (s: string) => s.split(" ")

export function TranscriptDemo() {
  const kept1 = words("Here are three remote jobs hiring this week.")
  const kept2 = words("first, a product designer at a fintech in Berlin.")
  return (
    <div className="demo demo--transcript">
      <div className="demo-toolbar">
        <span className="demo-toolbar-label"><i className="ph-bold ph-text-align-left" aria-hidden />Transcript</span>
        <span className="demo-toolbar-meta"><i className="ph-bold ph-scissors" aria-hidden />2 cuts, 3 s saved</span>
        <span className="demo-toolbar-approve"><i className="ph-bold ph-check" aria-hidden />Approve 2</span>
      </div>
      <p className="demo-transcript-text">
        {kept1.map((w, i) => <span key={`a${i}`} className="demo-word">{w} </span>)}
        <span className="demo-word demo-word--cut demo-word--cut-1">Um,</span>{" "}
        <span className="demo-word demo-word--cut demo-word--cut-2">you know,</span>{" "}
        {kept2.map((w, i) => <span key={`b${i}`} className="demo-word">{w} </span>)}
      </p>
      <div className="demo-menu">
        <span className="demo-menu-item"><i className="ph-bold ph-scissors" aria-hidden />Cut</span>
        <span className="demo-menu-item"><i className="ph-bold ph-pencil-simple" aria-hidden />Edit caption</span>
        <span className="demo-menu-item"><i className="ph-bold ph-chat-text" aria-hidden />Comment for Claude</span>
      </div>
    </div>
  )
}

export function RepeatDemo() {
  return (
    <div className="demo demo--repeat">
      <div className="demo-repeat-take demo-repeat-take--first">
        <span className="demo-repeat-take-tag">Earlier take</span>
        <p className="demo-repeat-take-text">Second, a backend engineer at a climate startup, you know, open to anyone in Asia.</p>
      </div>
      <div className="demo-repeat-take demo-repeat-take--kept">
        <span className="demo-repeat-take-tag demo-repeat-take-tag--kept">Kept</span>
        <p className="demo-repeat-take-text">Second, a backend engineer at a climate startup, open to anyone in Asia.</p>
      </div>
      <div className="demo-repeat-note">
        <i className="ph-bold ph-waveform" aria-hidden />
        Heard twice, written once. The app listened letter by letter and found the restart.
      </div>
    </div>
  )
}

export function CaptionDemo() {
  return (
    <div className="demo demo--caption">
      <div className="demo-caption-phone">
        <div className="demo-caption-phone-screen">
          <span className="demo-caption-line">
            <span className="demo-caption-line-word">Lots</span> <span className="demo-caption-line-word">of</span>{" "}
            <span className="demo-caption-line-word demo-caption-line-word--active">Vegetation.</span>
          </span>
        </div>
      </div>
      <div className="demo-caption-side">
        <div className="demo-caption-field">
          <span className="demo-caption-field-label">Edit caption</span>
          <span className="demo-caption-field-heard">trees. Vegetation.</span>
          <i className="ph-bold ph-arrow-down" aria-hidden />
          <span className="demo-caption-field-new">Vegetation.</span>
        </div>
        <div className="demo-caption-timing">
          <span className="demo-caption-timing-row"><span className="demo-caption-timing-bar demo-caption-timing-bar--heard" />Voice</span>
          <span className="demo-caption-timing-row"><span className="demo-caption-timing-bar demo-caption-timing-bar--caption" />Caption</span>
        </div>
      </div>
    </div>
  )
}

const rules: [string, boolean][] = [
  ["No gap over 0.3 s", true],
  ["No fillers left", true],
  ["No word kept twice", true],
  ["Numbers written as digits", false],
  ["Every sentence ends with a full stop", true],
]

export function RulesDemo() {
  return (
    <div className="demo demo--rules">
      <div className="demo-rules-head">
        <span><i className="ph-bold ph-book-open" aria-hidden />3 rule books</span>
        <span className="demo-rules-head-status">1 to fix</span>
      </div>
      <ul className="demo-rules-list">
        {rules.map(([r, ok]) => (
          <li key={r} className={`demo-rules-list-item demo-rules-list-item--${ok ? "ok" : "fix"}`}>
            <i className={`ph-bold ${ok ? "ph-check-circle" : "ph-warning-circle"}`} aria-hidden />
            {r}
            {!ok && <span className="demo-rules-list-item-fix">&quot;three&quot; at 0:02</span>}
          </li>
        ))}
      </ul>
    </div>
  )
}

const stays: [string, string][] = [
  ["laptop", "Transcribed on your Mac"],
  ["film-strip", "Your videos never leave it"],
  ["coins", "No credits, no minutes to buy"],
  ["chat-circle-text", "Claude runs on your own Claude plan"],
]

export function PrivateDemo() {
  return (
    <div className="demo demo--private">
      {stays.map(([icon, text]) => (
        <div key={text} className="demo-private-row">
          <span className="demo-private-row-icon"><i className={`ph-bold ph-${icon}`} aria-hidden /></span>
          {text}
        </div>
      ))}
    </div>
  )
}
