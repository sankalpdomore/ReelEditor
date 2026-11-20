import type { Metadata } from "next"
import { SiteNav } from "@/components/site-nav/site-nav"
import { SiteFooter } from "@/components/site-footer/site-footer"
import { PricingHero, PricingPlans, PricingCosts, PricingBeta, PricingFaq } from "@/components/pricing/pricing-sections"

export const metadata: Metadata = {
  title: "Pricing: Reel Editor",
  description: "Reel Editor is free while it is in beta. Transcription and export run on your Mac, and the Claude chat runs on your own Claude plan.",
}

export default function PricingPage() {
  return (
    <>
      <SiteNav active="pricing" />
      <main>
        <PricingHero />
        <PricingPlans />
        <PricingCosts />
        <PricingBeta />
        <PricingFaq />
      </main>
      <SiteFooter />
    </>
  )
}
