import { SiteNav } from "@/components/site-nav/site-nav"
import { SiteFooter } from "@/components/site-footer/site-footer"
import { HomeHero, HomeHow, HomeFeatures, HomeMore, HomeNote, HomeClosing } from "@/components/home/home-sections"

// The landing, version A in the style of cleanshot.com, chosen by Sankalp on 19 Nov 2026. Version B, in the style of
// screen.studio, stays at /v2 for reference and is not linked from the site.
export default function HomePage() {
  return (
    <>
      <SiteNav active="home" />
      <main>
        <HomeHero />
        <HomeHow />
        <HomeFeatures />
        <HomeMore />
        <HomeNote />
        <HomeClosing />
      </main>
      <SiteFooter />
    </>
  )
}
