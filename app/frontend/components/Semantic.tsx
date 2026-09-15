import type { HTMLAttributes } from "react"

type Tone = "muted" | "info" | "success" | "warning" | "error"
type TextTone = "primary" | "secondary" | "muted" | "danger" | "success" | "warning"
type TextSize = "xs" | "sm" | "base" | "lg"

const noticeToneClasses: Record<Tone, string> = {
  muted: "border-border bg-surface text-text-secondary",
  info: "border-info/30 bg-info/10 text-info",
  success: "border-success/30 bg-success/10 text-success",
  warning: "border-warning/30 bg-warning/10 text-warning",
  error: "border-danger/30 bg-danger/10 text-danger"
}

const textToneClasses: Record<TextTone, string> = {
  primary: "text-text-primary",
  secondary: "text-text-secondary",
  muted: "text-text-muted",
  danger: "text-danger",
  success: "text-success",
  warning: "text-warning"
}

const textSizeClasses: Record<TextSize, string> = {
  xs: "text-xs",
  sm: "text-sm",
  base: "text-base",
  lg: "text-lg"
}

export function Section({ as: Component = "section", className = "", ...props }: HTMLAttributes<HTMLElement> & { as?: "article" | "form" | "section" }) {
  return <Component className={`rounded border border-border bg-surface p-4 ${className}`.trim()} {...props} />
}

export function Notice({ className = "", tone = "muted", ...props }: HTMLAttributes<HTMLDivElement> & { tone?: Tone }) {
  return <div className={`rounded border p-4 text-sm ${noticeToneClasses[tone]} ${className}`.trim()} {...props} />
}

export function Toolbar({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={`flex flex-wrap items-center gap-2 ${className}`.trim()} {...props} />
}

export function Text({ as: Component = "p", className = "", size = "sm", tone = "secondary", ...props }: HTMLAttributes<HTMLElement> & { as?: "dd" | "dt" | "p" | "span"; size?: TextSize; tone?: TextTone }) {
  return <Component className={`${textSizeClasses[size]} ${textToneClasses[tone]} ${className}`.trim()} {...props} />
}
