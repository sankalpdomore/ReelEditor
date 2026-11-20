"use client"

import { useState } from "react"
import { Button } from "@/components/ui/button/button"
import "./beta-form.css"

// The beta request. A draft: it is not connected to anything yet, and says so when sent. Wire it to the waitlist (the
// NextDoor.Company waitlist system or Loops) before the page goes live.
const platforms = ["Instagram", "LinkedIn", "YouTube", "TikTok", "X"]

export function BetaForm() {
  const [picked, setPicked] = useState<string[]>([])
  const [sent, setSent] = useState(false)

  const toggle = (p: string) => setPicked((now) => (now.includes(p) ? now.filter((x) => x !== p) : [...now, p]))

  if (sent) {
    return (
      <div className="beta-form beta-form--sent">
        <i className="ph-bold ph-info beta-form-sent-icon" aria-hidden />
        <p className="beta-form-sent-text">This form is a draft and is not connected yet, so nothing was sent.</p>
        <Button variant="outline" size="sm" onClick={() => setSent(false)}>Back to the form</Button>
      </div>
    )
  }

  return (
    <form className="beta-form" onSubmit={(e) => { e.preventDefault(); setSent(true) }}>
      <label className="beta-form-field">
        <span className="beta-form-field-label">Your name</span>
        <input className="beta-form-field-input" name="name" placeholder="e.g., Priya Raman" required />
      </label>
      <label className="beta-form-field">
        <span className="beta-form-field-label">Email</span>
        <input className="beta-form-field-input" name="email" type="email" placeholder="e.g., priya@example.com" required />
      </label>
      <div className="beta-form-field">
        <span className="beta-form-field-label">Where you post</span>
        <div className="beta-form-field-chips">
          {platforms.map((p) => (
            <button key={p} type="button" onClick={() => toggle(p)} className={`beta-form-field-chips-item beta-form-field-chips-item--${p.toLowerCase()}${picked.includes(p) ? " beta-form-field-chips-item--on" : ""}`}>
              {p}
            </button>
          ))}
        </div>
      </div>
      <label className="beta-form-field">
        <span className="beta-form-field-label">How often you post a talking-head reel</span>
        <select className="beta-form-field-input" name="often" defaultValue="weekly">
          <option value="daily">Most days</option>
          <option value="weekly">A few times a week</option>
          <option value="monthly">A few times a month</option>
        </select>
      </label>
      <Button type="submit" size="lg" className="beta-form-submit">Request the beta</Button>
    </form>
  )
}
