import { forwardRef } from "react"
import type { ButtonHTMLAttributes } from "react"

export type ButtonVariant = "primary" | "secondary" | "danger" | "success"
export type ButtonSize = "sm" | "md"

export interface ButtonProps extends ButtonHTMLAttributes<HTMLButtonElement> {
  variant?: ButtonVariant
  size?: ButtonSize
}

const VARIANT_CLASSES: Record<ButtonVariant, string> = {
  primary: "border border-transparent bg-brand text-white hover:opacity-90 focus-visible:ring-brand",
  secondary: "border border-border bg-surface text-text-primary hover:bg-surface-raised focus-visible:ring-brand",
  // --color-danger flips from a dark red (light mode) to a light pink tint
  // (dark mode) — see application.css's token comment. text-white stays
  // readable in light mode; dark:text-gray-900 keeps it readable once the
  // background lightens in dark mode.
  danger: "border border-transparent bg-danger text-white hover:opacity-90 focus-visible:ring-danger dark:text-gray-900",
  // --color-success has the same light/dark flip as --color-danger (dark
  // green in light mode, a light mint tint in dark mode).
  success: "border border-transparent bg-success text-white hover:opacity-90 focus-visible:ring-success dark:text-gray-900"
}

const SIZE_CLASSES: Record<ButtonSize, string> = {
  sm: "px-2.5 py-1.5 text-xs",
  md: "px-3 py-2 text-sm"
}

const BASE_CLASSES = "inline-flex items-center justify-center gap-2 rounded-md font-medium transition-colors focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-offset-2 disabled:cursor-not-allowed disabled:opacity-60 dark:focus-visible:ring-offset-gray-950"

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
