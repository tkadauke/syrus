import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import { Surface } from "./Surface"
import type { SemanticTone } from "./Pill"

export interface ToolCardRootProps extends HTMLAttributes<HTMLDivElement> {
  tone?: SemanticTone
}

export interface ToolCardHeaderProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  actions?: ReactNode
  eyebrow?: ReactNode
  meta?: ReactNode
  title: ReactNode
}

export interface ToolCardBodyProps extends HTMLAttributes<HTMLDivElement> {}
export interface ToolCardFooterProps extends HTMLAttributes<HTMLDivElement> {}

const TONE_ACCENT_CLASSES: Record<SemanticTone, string> = {
  neutral: "before:bg-neutral-border",
  info: "before:bg-info-border",
  warning: "before:bg-warning-border",
  danger: "before:bg-danger-border",
  success: "before:bg-success-border"
}

function Root({ children, className = "", tone = "neutral", ...props }: ToolCardRootProps) {
  return (
    <Surface
      className={classes(
        "relative overflow-hidden text-[length:var(--text-caption)] before:absolute before:inset-y-0 before:left-0 before:w-1",
        TONE_ACCENT_CLASSES[tone],
        className
      )}
      padding="sm"
      variant="panel"
      {...props}
    >
      {children}
    </Surface>
  )
}

function Header({ actions, className = "", eyebrow, meta, title, ...props }: ToolCardHeaderProps) {
  return (
    <div className={classes("flex min-w-0 items-start justify-between gap-3 pl-1", className)} {...props}>
      <div className="min-w-0">
        {eyebrow ? <div className="truncate text-2xs font-semibold uppercase leading-4 tracking-wide text-text-subtle">{eyebrow}</div> : null}
        <div className="truncate text-[length:var(--text-body)] font-semibold leading-5 text-text-primary">{title}</div>
        {meta ? <div className="mt-0.5 truncate text-[length:var(--text-caption)] leading-4 text-text-muted">{meta}</div> : null}
      </div>
      {actions ? <div className="flex shrink-0 items-center gap-1">{actions}</div> : null}
    </div>
  )
}

function Body({ className = "", ...props }: ToolCardBodyProps) {
  return <div className={classes("mt-2 min-w-0 space-y-2 pl-1 text-text-primary", className)} {...props} />
}

function Footer({ className = "", ...props }: ToolCardFooterProps) {
  return (
    <div
      className={classes("mt-2 flex flex-wrap items-center gap-2 border-t border-[length:var(--border-width)] border-border pt-2 pl-1", className)}
      {...props}
    />
  )
}

export const ToolCard = { Root, Header, Body, Footer }
