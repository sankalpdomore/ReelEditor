import type { Metadata } from "next"
import { SiteNav } from "@/components/site-nav/site-nav"
import { SiteFooter } from "@/components/site-footer/site-footer"
import { DraftSwitcher } from "@/components/draft-switcher/draft-switcher"
import { StudioHero, StudioFacts, StudioChapters, StudioOffline, StudioMore, StudioClosing } from "@/components/home-studio/studio-sections"

export const metadata: Metadata = {
  title: "Reel Editor: reels, edited by the words you said",
  description: "The Mac app that handles the hard parts of a talking-head reel: fillers, restarts, captions and timing.",
}

// Version B of the landing, in the style of screen.studio, kept for reference. Version A, in the style of cleanshot.com,
// is the home page and the one going forward (Sankalp, 19 Nov 2026).
export default function LandingB() {
  return (
    <div className="studio-page">
      <SiteNav active="home" tone="dark" />
      <main>
        <StudioHero />
        <StudioFacts />
        <StudioChapters />
        <StudioOffline />
        <StudioMore />
        <StudioClosing />
      </main>
      <SiteFooter tone="dark" />
      <DraftSwitcher current="b" />
    </div>
  )
}
