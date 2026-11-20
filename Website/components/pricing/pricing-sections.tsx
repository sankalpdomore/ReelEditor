import { Button } from "@/components/ui/button/button"
import { InsetCard } from "@/components/ui/inset-card/inset-card"
import { BetaForm } from "./beta-form"
import "./pricing-sections.css"

export function PricingHero() {
  return (
    <section className="pricing-hero">
      <span className="pricing-hero-eyebrow">Pricing</span>
      <h1 className="pricing-hero-title">Free while it is in beta</h1>
      <p className="pricing-hero-subtitle">Every feature is open to beta creators. The price for everyone else is set with what the beta teaches.</p>
    </section>
  )
}

type Plan = { slug: string; name: string; price: string; per?: string; badge?: string; text: string; points: string[]; cta: React.ReactNode }

const plans: Plan[] = [
  {
    slug: "beta", name: "Beta", price: "Free", badge: "Open now",
    text: "For creators who post talking-head reels every week and want to shape the app.",
    points: ["Every feature in the app", "Transcription on your Mac, no limits", "Claude makes the first pass on your own Claude plan", "New versions as they ship", "A direct line to me for feedback"],
    cta: <Button href="#beta" size="lg" className="pricing-plans-item-cta"><i className="ph-bold ph-apple-logo" aria-hidden />Request the beta</Button>,
  },
  {
    slug: "launch", name: "Reel Editor", price: "Coming soon",
    text: "The full app after the beta, for anyone with a Mac.",
    points: ["Everything in the beta", "Updates and new features", "Support by email", "Your projects stay plain files on your Mac"],
    cta: <Button size="lg" variant="secondary-gradient" className="pricing-plans-item-cta" disabled>Price after the beta</Button>,
  },
]

export function PricingPlans() {
  return (
    <section className="pricing-plans">
      {plans.map((p) => (
        <InsetCard key={p.slug} name={p.slug} title={p.name} aside={p.badge} className={`pricing-plans-item pricing-plans-item--${p.slug}`}>
          <div className="pricing-plans-item-price">{p.price}</div>
          <p className="pricing-plans-item-text">{p.text}</p>
          <ul className="pricing-plans-item-points">
            {p.points.map((x) => (
              <li key={x} className="pricing-plans-item-points-item"><i className="ph-bold ph-check" aria-hidden />{x}</li>
            ))}
          </ul>
          {p.cta}
        </InsetCard>
      ))}
    </section>
  )
}

const costs: [string, string, string][] = [
  ["laptop", "Transcription and export", "Free. Both run on your Mac, as often as you like."],
  ["chat-circle-text", "Claude", "The chat and Claude's first pass run on your own Claude plan. Editing by hand works without it."],
  ["cloud-slash", "Storage", "Nothing to pay for. Your videos and projects stay where you saved them."],
]

export function PricingCosts() {
  return (
    <section className="pricing-costs">
      <h2 className="pricing-section-title">What else you pay for</h2>
      <div className="pricing-costs-grid">
        {costs.map(([icon, title, text]) => (
          <div key={title} className="pricing-costs-grid-item">
            <i className={`ph-bold ph-${icon} pricing-costs-grid-item-icon`} aria-hidden />
            <h3 className="pricing-costs-grid-item-title">{title}</h3>
            <p className="pricing-costs-grid-item-text">{text}</p>
          </div>
        ))}
      </div>
    </section>
  )
}

export function PricingBeta() {
  return (
    <section className="pricing-beta" id="beta">
      <div className="pricing-beta-copy">
        <h2 className="pricing-beta-copy-title">Request the beta</h2>
        <p className="pricing-beta-copy-text">I let creators in a few at a time, so every one of them gets a quick reply when something is off. Tell me where you post and I will write to you.</p>
      </div>
      <BetaForm />
    </section>
  )
}

const faqs: [string, string][] = [
  ["Which Macs does it run on?", "A Mac with macOS 26 or later."],
  ["Are my videos uploaded anywhere?", "No. The app reads your videos where they are and transcribes them on your Mac. Only the Claude chat sends text to Claude: your messages and the words of the reel it works on."],
  ["Do I need Claude?", "Only for the chat and Claude's first pass. Cutting by the transcript, captions, the rule check and the export all work without it. The chat runs on the Claude account you are signed in to on your Mac."],
  ["Can Claude Code or another agent edit my reels?", "Yes. The app comes with over 100 tools any agent can call, and the window follows along live while it edits."],
  ["What happens to my projects after the beta?", "They stay yours. Each project is one file you can save anywhere, next to its videos."],
  ["What does a cut waiting for approval mean?", "When Claude cuts something it shows in amber and already plays as a cut. Approve keeps it, and you can bring back any word with one click."],
]

export function PricingFaq() {
  return (
    <section className="pricing-faq" id="faq">
      <h2 className="pricing-section-title">Questions</h2>
      <div className="pricing-faq-list">
        {faqs.map(([q, a]) => (
          <details key={q} className="pricing-faq-list-item">
            <summary className="pricing-faq-list-item-question">
              {q}
              <i className="ph-bold ph-plus pricing-faq-list-item-question-icon" aria-hidden />
            </summary>
            <p className="pricing-faq-list-item-answer">{a}</p>
          </details>
        ))}
      </div>
    </section>
  )
}
