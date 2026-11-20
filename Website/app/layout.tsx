import type { Metadata } from "next"
import localFont from "next/font/local"
import "@phosphor-icons/web/bold"
import "@phosphor-icons/web/fill"
import "./globals.css"

const inter = localFont({
  src: [
    { path: "./fonts/Inter-Regular.ttf", weight: "400" },
    { path: "./fonts/Inter-Medium.ttf", weight: "500" },
    { path: "./fonts/Inter-SemiBold.ttf", weight: "600" },
    { path: "./fonts/Inter-Bold.ttf", weight: "700" },
  ],
  variable: "--font-inter",
  display: "swap",
})

// The reels' caption font, for the caption samples drawn on the page.
const advercase = localFont({ src: "./fonts/Advercase-Bold.otf", weight: "700", variable: "--font-advercase", display: "swap" })

export const metadata: Metadata = {
  title: "Reel Editor: talking-head reels, edited by the words you said",
  description: "A Mac app that turns a raw talking-head take into a tight reel. Cut by the transcript, let Claude make the first pass, and keep every file on your Mac.",
}

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en" className={`${inter.variable} ${advercase.variable}`}>
      <body>{children}</body>
    </html>
  )
}
