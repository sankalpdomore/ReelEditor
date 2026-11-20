import Link from "next/link"
import Image from "next/image"
import { Button } from "@/components/ui/button/button"
import "./site-nav.css"

// The top bar of every page: the app's icon and name, the links, and Download at the right end. tone dark is for a dark
// page (the Screen Studio style landing).
export function SiteNav({ active, tone = "light" }: { active?: "home" | "pricing"; tone?: "light" | "dark" }) {
  return (
    <header className={`site-nav site-nav--${tone}`}>
      <div className="site-nav-inner">
        <Link href="/" className="site-nav-brand">
          <Image src="/images/app-icon.png" alt="" width={32} height={32} className="site-nav-brand-icon" priority />
          <span className="site-nav-brand-name">Reel Editor</span>
        </Link>
        <nav className="site-nav-links">
          <Link href="/#features" className={`site-nav-links-item site-nav-links-item--features`}>Features</Link>
          <Link href="/pricing" className={`site-nav-links-item site-nav-links-item--pricing${active === "pricing" ? " site-nav-links-item--active" : ""}`}>Pricing</Link>
          <Link href="/pricing#faq" className="site-nav-links-item site-nav-links-item--faq">FAQ</Link>
        </nav>
        <Button href="/pricing#beta" size="sm" variant={tone === "dark" ? "white" : "default"} className="site-nav-cta">
          <i className="ph-bold ph-apple-logo" aria-hidden />
          Get the beta
        </Button>
      </div>
    </header>
  )
}
