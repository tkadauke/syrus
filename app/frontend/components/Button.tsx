import { forwardRef } from "react"
import type { ButtonHTMLAttributes } from "react"

export type ButtonVariant = "primary" | "secondary" | "danger" | "success"
export type ButtonSize = "sm" | "md" | "icon"

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
}

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  // text-on-brand (not a hardcoded text-white): some themes' dark-mode
  // `brand` is light enough that white text fails contrast — see the
  // `on-brand` token in application.css / db/seeds/themes.rb.
  primary: "border-[length:var(--border-width)] border-transparent bg-brand text-on-brand hover:opacity-90 focus-visible:ring-brand",
  secondary: "border-[length:var(--border-width)] border-border bg-surface text-text-primary hover:bg-surface-raised focus-visible:ring-brand",
  // --color-danger flips from a dark red (light mode) to a light pink tint
  // (dark mode) — see application.css's token comment. text-white stays
  // readable in light mode; dark:text-gray-900 keeps it readable once the
  // background lightens in dark mode.
  danger: "border-[length:var(--border-width)] border-transparent bg-danger text-white hover:opacity-90 focus-visible:ring-danger dark:text-gray-900",
  // --color-success has the same light/dark flip as --color-danger (dark
  // green in light mode, a light mint tint in dark mode).
  success: "border-[length:var(--border-width)] border-transparent bg-success text-white hover:opacity-90 focus-visible:ring-success dark:text-gray-900"
}

// Control height + text size come from the density/typography token groups
// (--control-height-sm/-md, --text-caption/-body) instead of fixed
// py-*/text-xs classes, so a theme's density and typography choices apply
// without touching call sites.
const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: "h-[var(--control-height-sm)] px-2.5 text-[length:var(--text-caption)]",
  md: "h-[var(--control-height-md)] px-3 text-[length:var(--text-body)]",
  // No text-oriented horizontal/vertical padding: icon-only buttons are
  // sized by explicit h-*/w-* utilities on the caller's className, and
  // `size="sm"`'s fixed height fights those custom dimensions (both apply,
  // squeezing the icon into whatever's left).
  icon: "p-1"
}

const BASE_CLASSES = "inline-flex items-center justify-center gap-2 rounded-[var(--radius-control)] font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-60 dark:focus-visible:ring-offset-gray-950"

// Exposed so elements that can't render as an actual <button> (e.g. a
// react-router `Link`, which must stay an <a> for correct navigation/keyboard
// semantics) can still share the primitive's variant/size styling instead of
// re-hardcoding the class string.
export function buttonClasses(variant: ButtonVariant = "primary", size: ButtonSize = "md", className = "") {
  return `${BASE_CLASSES} ${VARIANT_CLASSES[variant]} ${SIZE_CLASSES[size]} ${className}`.trim()
}

// Shared button primitive: variant/size only, styled from the semantic
// color tokens (app/assets/tailwind/application.css) instead of raw
// blue-*/terracotta-* utility classes, so the epic's future re-theme work
// only has to touch the token layer.
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(function Button(
  { variant = "primary", size = "md", type = "button", className = "", disabled, ...props },
  ref
) {
  return (
    <button
      className={buttonClasses(variant, size, className)}
      disabled={disabled}
      ref={ref}
      type={type}
      {...props}
    />
  )
})
