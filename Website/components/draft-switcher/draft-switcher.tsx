import Link from "next/link"
import "./draft-switcher.css"

// A pill at the bottom of version B, /v2, to flip back to version A, the landing chosen on 19 Nov 2026. Version A does not
// show it.
export function DraftSwitcher({ current }: { current: "a" | "b" }) {
  return (
    <div className="draft-switcher">
      <span className="draft-switcher-label">Draft</span>
      <Link href="/" className={`draft-switcher-item draft-switcher-item--a${current === "a" ? " draft-switcher-item--on" : ""}`}>A · CleanShot style</Link>
      <Link href="/v2" className={`draft-switcher-item draft-switcher-item--b${current === "b" ? " draft-switcher-item--on" : ""}`}>B · Screen Studio style</Link>
    </div>
  )
}
