import * as React from "react"
import "./inset-card.css"

// The inset card of DESIGN.md: a grey shell with its header text on the grey, and a white body inset 4px, one radius step
// smaller. `name` adds a per-instance modifier class beside the shared one.
type InsetCardProps = {
  title?: React.ReactNode
  icon?: string
  aside?: React.ReactNode
  name?: string
  className?: string
  children: React.ReactNode
}

export function InsetCard({ title, icon, aside, name, className, children }: InsetCardProps) {
  return (
    <div className={["inset-card", name && `inset-card--${name}`, className].filter(Boolean).join(" ")}>
      {(title || aside) && (
        <div className="inset-card-head">
          {icon && <i className={`ph-bold ph-${icon} inset-card-head-icon`} aria-hidden />}
          {title && <span className="inset-card-head-title">{title}</span>}
          {aside && <span className="inset-card-head-aside">{aside}</span>}
        </div>
      )}
      <div className="inset-card-body">{children}</div>
    </div>
  )
}
