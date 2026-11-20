import Image from "next/image"
import { Button } from "@/components/ui/button/button"
import { InsetCard } from "@/components/ui/inset-card/inset-card"
import { TranscriptDemo, RepeatDemo, CaptionDemo, RulesDemo, PrivateDemo } from "./feature-demos"
import "./home-sections.css"

export function HomeHero() {
  return (
    <section className="home-hero">
      <span className="home-hero-badge"><i className="ph-bold ph-sparkle" aria-hidden />Private beta for Mac</span>
      <h1 className="home-hero-title">Talking-head reels, edited by the words you said</h1>
      <p className="home-hero-subtitle">
        Drop in your raw takes. The app transcribes them on your Mac, Claude makes the first pass, and you approve every cut by reading, not scrubbing.
      </p>
      <div className="home-hero-actions">
        <Button href="/pricing#beta" size="lg"><i className="ph-bold ph-apple-logo" aria-hidden />Get the beta</Button>
        <Button href="#how" size="lg" variant="secondary-gradient"><i className="ph-bold ph-play-circle" aria-hidden />See how it works</Button>
      </div>
      <p className="home-hero-note">For macOS 26 on Apple silicon</p>
      <div className="home-hero-shot">
        <Image src="/images/app-editor.png" alt="Reel Editor with a transcript, cuts waiting for approval, the timeline and the caption on the video" width={2880} height={1800} priority className="home-hero-shot-image" />
      </div>
    </section>
  )
}

const steps: [string, string, string][] = [
  ["upload-simple", "Drop in your takes", "One video or ten. Each is transcribed on your Mac with a time on every word."],
  ["sparkle", "Claude makes the first pass", "Fillers, restarts and repeated takes are cut by your rule books, and wait for you."],
  ["check-circle", "Approve and export", "Read the reel as text, keep or bring back any cut, then export an MP4 with captions."],
]

export function HomeHow() {
  return (
    <section className="home-how" id="how">
      <h2 className="home-section-title">From raw take to reel in three steps</h2>
      <div className="home-how-steps">
        {steps.map(([icon, title, text], i) => (
          <div key={title} className={`home-how-steps-item home-how-steps-item--${i + 1}`}>
            <span className="home-how-steps-item-number">{i + 1}</span>
            <i className={`ph-bold ph-${icon} home-how-steps-item-icon`} aria-hidden />
            <h3 className="home-how-steps-item-title">{title}</h3>
            <p className="home-how-steps-item-text">{text}</p>
          </div>
        ))}
      </div>
    </section>
  )
}

type Feature = { slug: string; eyebrow: string; title: string; text: string; points: string[]; demo: React.ReactNode; cardTitle: string; cardIcon: string }

const features: Feature[] = [
  {
    slug: "transcript", eyebrow: "Editing", title: "Cut a sentence like you delete text",
    text: "Your video reads like a document. Select words and cut them, or let Claude cut them for you. Its cuts wait in amber until you approve them.",
    points: ["Cuts play as cuts before you approve", "Undo any step, any time", "Leave a comment for Claude on any words"],
    demo: <TranscriptDemo />, cardTitle: "Transcript", cardIcon: "text-align-left",
  },
  {
    slug: "repeat", eyebrow: "Listening", title: "Catches the takes the transcript hides",
    text: "Say a line twice and most transcribers write it once. The app reads every clip letter by letter, finds the restart and offers the cut that keeps your better take.",
    points: ["Repeats, restarts and missed speech", "The earlier take is cut, the kept one stays", "Fillers and long gaps in the same pass"],
    demo: <RepeatDemo />, cardTitle: "Audio check", cardIcon: "waveform",
  },
  {
    slug: "captions", eyebrow: "Captions", title: "Captions that follow your voice",
    text: "Captions show while you speak and leave when you stop, even with music or street noise under you. Change what a caption says without touching the sound.",
    points: ["Merge, rephrase or fix any caption", "The spoken word lit up as you say it", "Your font, colours, box and place"],
    demo: <CaptionDemo />, cardTitle: "Edit caption", cardIcon: "closed-captioning",
  },
  {
    slug: "rules", eyebrow: "Rule books", title: "Your style, checked on every pass",
    text: "Write how you edit once: the longest pause, the words to drop, how numbers read. Claude follows your rule books, and the rule check lists anything still off with the fix for it.",
    points: ["Rule books in plain markdown", "A rule check before every export", "Different rules for each project"],
    demo: <RulesDemo />, cardTitle: "Rule check", cardIcon: "list-checks",
  },
  {
    slug: "private", eyebrow: "Private", title: "Everything stays on your Mac",
    text: "Your videos are read, never uploaded. Transcription, the audio check and the export all run on your Mac, so there are no credits or minutes to run out of.",
    points: ["No account needed to edit", "Projects are one file you can save anywhere", "Works offline, except the Claude chat"],
    demo: <PrivateDemo />, cardTitle: "On this Mac", cardIcon: "laptop",
  },
]

export function HomeFeatures() {
  return (
    <section className="home-features" id="features">
      {features.map((f, i) => (
        <div key={f.slug} className={`home-features-row home-features-row--${f.slug}${i % 2 ? " home-features-row--flip" : ""}`}>
          <div className="home-features-row-copy">
            <span className="home-features-row-copy-eyebrow">{f.eyebrow}</span>
            <h2 className="home-features-row-copy-title">{f.title}</h2>
            <p className="home-features-row-copy-text">{f.text}</p>
            <ul className="home-features-row-copy-points">
              {f.points.map((p) => (
                <li key={p} className="home-features-row-copy-points-item"><i className="ph-bold ph-check" aria-hidden />{p}</li>
              ))}
            </ul>
          </div>
          <InsetCard name={f.slug} title={f.cardTitle} icon={f.cardIcon} className="home-features-row-demo">{f.demo}</InsetCard>
        </div>
      ))}
    </section>
  )
}

const more: [string, string, string][] = [
  ["magnifying-glass", "Finds moved videos", "Renamed or moved a file? Claude searches your Mac and links it again."],
  ["user-focus", "Face and voice overlays", "Lay a face cam or a voice over on top, in a rounded window."],
  ["music-notes", "Music under your voice", "A music bed that sits under the voice, with the voice made louder or warmer."],
  ["palette", "Video looks", "Warmth, contrast and saved looks for the whole reel."],
  ["stack", "Reels from many videos", "Put several takes in one reel and move clips by dragging their heads."],
  ["text-t", "Text layers", "Titles and text on top of the video, coming in with their own motion."],
  ["export", "Export to MP4", "Captions and title burned in, at the speed you set."],
  ["plugs-connected", "Over 100 agent tools", "Claude Code or any agent edits the same projects, and the app follows along live."],
]

export function HomeMore() {
  return (
    <section className="home-more">
      <h2 className="home-section-title">And a lot more for every reel</h2>
      <div className="home-more-grid">
        {more.map(([icon, title, text]) => (
          <div key={title} className="home-more-grid-item">
            <span className="home-more-grid-item-icon"><i className={`ph-bold ph-${icon}`} aria-hidden /></span>
            <h3 className="home-more-grid-item-title">{title}</h3>
            <p className="home-more-grid-item-text">{text}</p>
          </div>
        ))}
      </div>
    </section>
  )
}

export function HomeNote() {
  return (
    <section className="home-note">
      <p className="home-note-quote">
        I post talking-head reels most days, and editing them took longer than recording. I built Reel Editor so the first pass is done before I sit down, and all I do is read and approve.
      </p>
      <span className="home-note-by">Sankalp, maker of Reel Editor and NextDoor.Company</span>
    </section>
  )
}

export function HomeClosing() {
  return (
    <section className="home-closing">
      <h2 className="home-closing-title">Your next reel, edited before your coffee cools</h2>
      <p className="home-closing-text">Reel Editor is free while it is in beta. I am letting creators in a few at a time.</p>
      <div className="home-closing-actions">
        <Button href="/pricing#beta" size="lg" variant="white"><i className="ph-bold ph-apple-logo" aria-hidden />Get the beta</Button>
        <Button href="/pricing" size="lg" variant="secondary-gradient">See pricing</Button>
      </div>
    </section>
  )
}
