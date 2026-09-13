import { Fragment, type HTMLAttributes, type ReactNode } from "react"
import type { HighlighterLanguageId } from "@app/lib/highlighter"
import { renderCodeLine, useHighlightedLines } from "../CodeBlock"
import { classes } from "./classes"

export type CodeSurfaceMode = "command" | "multiline"
export type CodeSurfaceTone = "neutral" | "danger" | "warning" | "success"

export interface CodeSurfaceProps extends Omit<HTMLAttributes<HTMLPreElement>, "children" | "lang"> {
  children?: ReactNode
  code?: string
  copySlot?: ReactNode
  lang?: HighlighterLanguageId | null
  mode?: CodeSurfaceMode
  tone?: CodeSurfaceTone
}

const CODE_SURFACE_TONE_CLASSES: Record<CodeSurfaceTone, string> = {
  neutral: "border-border bg-surface-inset text-text-primary",
  danger: "border-danger-border bg-danger-surface text-danger-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  success: "border-success-border bg-success-surface text-success-text"
}

const CODE_SURFACE_MODE_CLASSES: Record<CodeSurfaceMode, string> = {
  command: "max-h-28 whitespace-pre overflow-x-auto overflow-y-auto",
  multiline: "max-h-96 whitespace-pre-wrap break-words overflow-auto"
}

export function CodeSurface({
  children,
  className = "",
  code,
  copySlot,
  lang = null,
  mode = "multiline",
  tone = "neutral",
  ...props
}: CodeSurfaceProps) {
  const content = code ?? (typeof children === "string" ? children : null)
  const lines = useHighlightedLines(content ?? "", lang)
  const codeLines = content?.split("\n") ?? null

  return (
    <div className="relative min-w-0" data-code-surface-wrapper="true">
      {copySlot ? <div className="absolute right-2 top-2 z-10">{copySlot}</div> : null}
      <pre
        className={classes(
          "min-w-0 rounded-[var(--radius-panel)] border border-[length:var(--border-width)] p-3 font-mono text-xs leading-5",
          "selection:bg-brand/20",
          copySlot ? "pr-12" : "",
          CODE_SURFACE_TONE_CLASSES[tone],
          CODE_SURFACE_MODE_CLASSES[mode],
          className
        )}
        data-code-surface-mode={mode}
        {...props}
      >
        <code>
          {codeLines ? (
            codeLines.map((line, index) => (
              <Fragment key={index}>
                {renderCodeLine(lines?.[index], line)}
                {index < codeLines.length - 1 ? "\n" : null}
              </Fragment>
            ))
          ) : (
            children
          )}
        </code>
      </pre>
    </div>
  )
}
