import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"

export type CodeSurfaceMode = "command" | "multiline"
export type CodeSurfaceOverflow = "auto" | "wrap" | "truncate"
export type CodeTokenTone = "default" | "muted" | "keyword" | "string" | "number" | "success" | "warning" | "danger"

export interface CodeSurfaceProps extends HTMLAttributes<HTMLDivElement> {
  copySlot?: ReactNode
  language?: string
  mode?: CodeSurfaceMode
  overflow?: CodeSurfaceOverflow
}

export interface CodeTokenProps extends HTMLAttributes<HTMLSpanElement> {
  tone?: CodeTokenTone
}

const OVERFLOW_CLASSES: Record<CodeSurfaceOverflow, string> = {
  auto: "overflow-auto whitespace-pre",
  wrap: "overflow-hidden whitespace-pre-wrap break-words",
  truncate: "overflow-hidden whitespace-nowrap"
}

const TOKEN_CLASSES: Record<CodeTokenTone, string> = {
  default: "text-code-text",
  muted: "text-code-muted",
  keyword: "text-code-keyword",
  string: "text-code-string",
  number: "text-code-number",
  success: "text-success-text",
  warning: "text-warning-text",
  danger: "text-danger-text"
}

export function codeSurfaceClasses({ mode = "multiline", overflow = mode === "command" ? "truncate" : "auto", className = "" }: Pick<CodeSurfaceProps, "mode" | "overflow" | "className"> = {}) {
  return classes(
    "relative rounded-[var(--radius-control)] border border-border bg-code-surface text-code-text",
    "font-mono text-xs leading-5",
    mode === "command" ? "min-h-[var(--control-height-sm)]" : "max-h-96",
    OVERFLOW_CLASSES[overflow],
    className
  )
}

export function CodeSurface({
  children,
  className = "",
  copySlot,
  language,
  mode = "multiline",
  overflow,
  ...props
}: CodeSurfaceProps) {
  const resolvedOverflow = overflow ?? (mode === "command" ? "truncate" : "auto")
  const code = (
    <code className={classes("block", copySlot != null && "pr-12", mode === "command" ? "px-3 py-1.5" : "p-3")}>
      {children}
    </code>
  )

  return (
    <div
      className={codeSurfaceClasses({ className, mode, overflow: resolvedOverflow })}
      data-code-surface-mode={mode}
      data-code-surface-overflow={resolvedOverflow}
      data-language={language || undefined}
      {...props}
    >
      {mode === "command" ? code : <pre>{code}</pre>}
      {copySlot ? <div className="absolute right-2 top-2">{copySlot}</div> : null}
    </div>
  )
}

function Token({ className = "", tone = "default", ...props }: CodeTokenProps) {
  return <span className={classes(TOKEN_CLASSES[tone], className)} {...props} />
}

CodeSurface.Token = Token
