import Image from "next/image"
import { Button } from "@/components/ui/button/button"
import { TranscriptDemo, RepeatDemo, CaptionDemo, RulesDemo, PrivateDemo } from "@/components/home/feature-demos"
import "./studio-sections.css"

// Version B of the landing, laid out like screen.studio: a dark page, one big centred statement per section with its
// key phrase in white, and the visual large under it on a coloured backdrop. The demos are the same ones version A uses.

export function StudioHero() {
  return (
    <section className="studio-hero">
      <div className="studio-hero-icon">
        <Image src="/images/app-icon.png" alt="" width={112} height={112} priority />
      </div>
      <span className="studio-hero-badge"><i className="ph-bold ph-sparkle" aria-hidden />Private beta for Mac</span>
      <h1 className="studio-hero-title">Reels, edited by the words you said.</h1>
      <p className="studio-hero-subtitle">
        The Mac app that handles the hard parts of a talking-head reel: <strong>fillers, restarts, captions and timing.</strong> Every take comes out tight.
      </p>
      <Button href="/pricing#beta" size="lg" variant="white" className="studio-hero-cta"><i className="ph-bold ph-apple-logo" aria-hidden />Get the beta</Button>
      <p className="studio-hero-note">macOS 26 or later</p>
      <div className="studio-hero-shot">
        <Image src="/images/app-editor.png" alt="Reel Editor with a transcript, cuts waiting for approval, the timeline and the caption on the video" width={2880} height={1800} priority className="studio-hero-shot-image" />
      </div>
    </section>
  )
}

const facts: [string, string][] = [
  ["Every word gets a time.", "Your takes are transcribed on your Mac, with the start and end of each word, so a cut lands on the word."],
  ["Light on your Mac.", "Built on Apple's own video frameworks, so the preview plays the edit as you make it, with nothing to render first."],
]

export function StudioFacts() {
  return (
    <section className="studio-facts">
      {facts.map(([lead, text]) => (
        <p key={lead} className="studio-facts-item"><strong>{lead}</strong> {text}</p>
      ))}
    </section>
  )
}

type Chapter = { slug: string; eyebrow: string; title: string; before: string; strong: string; after: string; demo: React.ReactNode; tint: string }

const chapters: Chapter[] = [
  { slug: "transcript", eyebrow: "Editing", title: "Edit with your transcript.", before: "Your video reads like a document.", strong: " Delete a sentence to cut it.", after: " Claude makes the first pass, and its cuts wait in amber until you approve them.", demo: <TranscriptDemo />, tint: "blue" },
  { slug: "repeat", eyebrow: "Listening", title: "Nothing you said twice survives.", before: "Most transcribers write a repeated line once.", strong: " The app listens letter by letter,", after: " finds the restart and cuts the earlier take.", demo: <RepeatDemo />, tint: "amber" },
  { slug: "captions", eyebrow: "Captions", title: "Captions that keep up with your voice.", before: "A caption shows while you speak and leaves when you stop.", strong: " Change what it says without touching the sound.", after: "", demo: <CaptionDemo />, tint: "green" },
  { slug: "rules", eyebrow: "Rule books", title: "Your style, on every single pass.", before: "Write how you edit once.", strong: " Claude follows your rule books,", after: " and the rule check lists anything still off, with the fix.", demo: <RulesDemo />, tint: "violet" },
]

export function StudioChapters() {
  return (
    <div className="studio-chapters" id="features">
      {chapters.map((c) => (
        <section key={c.slug} className={`studio-chapter studio-chapter--${c.slug}`}>
          <span className="studio-chapter-eyebrow">{c.eyebrow}</span>
          <h2 className="studio-chapter-title">{c.title}</h2>
          <p className="studio-chapter-text">{c.before}<strong>{c.strong}</strong>{c.after}</p>
          <div className={`studio-chapter-stage studio-chapter-stage--${c.tint}`}>
            <div className="studio-chapter-stage-window">{c.demo}</div>
          </div>
        </section>
      ))}
    </div>
  )
}

export function StudioOffline() {
  return (
    <section className="studio-offline">
      <span className="studio-chapter-eyebrow">Private</span>
      <h2 className="studio-chapter-title">Offline first.</h2>
      <p className="studio-chapter-text">Your videos are read where they are, <strong>never uploaded.</strong> No credits, no minutes to run out of.</p>
      <div className="studio-offline-columns">
        <div className="studio-offline-columns-item studio-offline-columns-item--mac">
          <h3 className="studio-offline-columns-item-title"><i className="ph-bold ph-laptop" aria-hidden />On your Mac</h3>
          <p className="studio-offline-columns-item-text">Transcription, the audio check, captions, the rule check and the export all run on your Mac.</p>
        </div>
        <div className="studio-offline-columns-item studio-offline-columns-item--choose">
          <h3 className="studio-offline-columns-item-title"><i className="ph-bold ph-chat-circle-text" aria-hidden />Only when you choose</h3>
          <p className="studio-offline-columns-item-text">The Claude chat sends your messages and the words of the reel to Claude, on your own Claude plan.</p>
        </div>
      </div>
      <div className="studio-chapter-stage studio-chapter-stage--slate">
        <div className="studio-chapter-stage-window studio-chapter-stage-window--narrow"><PrivateDemo /></div>
      </div>
    </section>
  )
}

const more: [string, string][] = [
  ["magnifying-glass", "Finds moved videos"], ["user-focus", "Face cam overlay"], ["microphone", "Voice overs"], ["music-notes", "Music bed"],
  ["sliders-horizontal", "Voice level and tone"], ["palette", "Video looks"], ["stack", "Reels from many videos"], ["text-t", "Text layers"],
  ["arrow-counter-clockwise", "Undo every step"], ["chat-text", "Comments for Claude"], ["export", "MP4 with captions"], ["plugs-connected", "Over 100 agent tools"],
]

export function StudioMore() {
  return (
    <section className="studio-more">
      <h2 className="studio-chapter-title">And a whole lot more.</h2>
      <div className="studio-more-grid">
        {more.map(([icon, label]) => (
          <div key={label} className="studio-more-grid-item">
            <i className={`ph-bold ph-${icon} studio-more-grid-item-icon`} aria-hidden />
            <span className="studio-more-grid-item-label">{label}</span>
          </div>
        ))}
      </div>
    </section>
  )
}

export function StudioClosing() {
  return (
    <section className="studio-closing">
      <h2 className="studio-closing-title">Ready when your next take is.</h2>
      <p className="studio-closing-text">Free while it is in beta. I let creators in a few at a time.</p>
      <Button href="/pricing#beta" size="lg" variant="white"><i className="ph-bold ph-apple-logo" aria-hidden />Get the beta</Button>
    </section>
  )
}
