import * as React from "react"
import Link from "next/link"
import "./button.css"

// The shared button, the same classes, variants and sizes as NextDoor.Company's components/ui/button, so the site and the
// main product look like one family. With href it renders a link that looks the same.
type ButtonVariant = "default" | "outline" | "secondary" | "ghost" | "link" | "white" | "secondary-gradient"
// Heights: sm 32, md 40 (default is the same size), lg 48, xl 60, icon 36 square
type ButtonSize = "default" | "sm" | "md" | "lg" | "xl" | "icon"

type Common = { variant?: ButtonVariant; size?: ButtonSize; className?: string; children?: React.ReactNode }
type AsButton = Common & Omit<React.ComponentProps<"button">, keyof Common> & { href?: undefined }
type AsLink = Common & Omit<React.ComponentProps<typeof Link>, keyof Common> & { href: string }

function classes(variant: ButtonVariant, size: ButtonSize, className?: string) {
  return ["btn", `btn-variant-${variant}`, `btn-size-${size}`, className].filter(Boolean).join(" ")
}

function Button(props: AsButton | AsLink) {
  const { variant = "default", size = "default", className, ...rest } = props
  if (typeof rest.href === "string") {
    return <Link data-slot="button" className={classes(variant, size, className)} {...(rest as Omit<AsLink, keyof Common>)} />
  }
  return <button type="button" data-slot="button" className={classes(variant, size, className)} {...(rest as Omit<AsButton, keyof Common>)} />
}

export { Button }
export type { ButtonVariant, ButtonSize }
