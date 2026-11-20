import Link from "next/link"
import "./site-footer.css"

export function SiteFooter({ tone = "light" }: { tone?: "light" | "dark" }) {
  return (
    <footer className={`site-footer site-footer--${tone}`}>
      <div className="site-footer-inner">
        <div className="site-footer-brand">
          <span className="site-footer-brand-name">Reel Editor</span>
          <span className="site-footer-brand-by">A NextDoor.Company product. Made on a Mac, for the Mac.</span>
        </div>
        <nav className="site-footer-links">
          <Link href="/#features" className="site-footer-links-item">Features</Link>
          <Link href="/pricing" className="site-footer-links-item">Pricing</Link>
          <Link href="/pricing#faq" className="site-footer-links-item">FAQ</Link>
          <a href="https://nextdoor.company" className="site-footer-links-item">NextDoor.Company</a>
        </nav>
      </div>
    </footer>
  )
}
