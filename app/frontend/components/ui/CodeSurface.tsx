import type { HTMLAttributes, ReactNode } from "react"
import { CodeBlock } from "../CodeBlock"
import { CopyIcon } from "../CopyableSlug"
import { useCopyToClipboard } from "../../hooks/useCopyToClipboard"
import type { HighlighterLanguageId } from "../../lib/highlighter"
import { classes } from "./classes"

export type CodeSurfaceMode = "command" | "multiline"

export interface CodeSurfaceProps extends Omit<HTMLAttributes<HTMLDivElement>, "lang"> {
  code: string
  copyLabel?: string
  copySlot?: ReactNode
  lang?: HighlighterLanguageId | null
  maxHeightClassName?: string
  mode?: CodeSurfaceMode
}

const MODE_CLASSES: Record<CodeSurfaceMode, string> = {
  command: "whitespace-pre overflow-x-auto",
  multiline: "whitespace-pre-wrap break-words overflow-auto"
}

export function CodeSurface({
  children,
  code,
  className = "",
  copyLabel = "Copy code",
  copySlot,
  lang = null,
  maxHeightClassName = "max-h-80",
  mode = "multiline",
  ...props
}: CodeSurfaceProps) {
  const { copied, copy } = useCopyToClipboard()
  const copyControl = copySlot ?? (
    <button
      aria-label={copyLabel}
      className="inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-[var(--radius-control)] text-text-muted hover:bg-surface-subtle hover:text-text-primary focus:outline-none focus:ring-2 focus:ring-brand"
      onClick={() => copy(code)}
      title={copied ? "Copied" : copyLabel}
      type="button"
    >
      <CopyIcon className={classes("h-3.5 w-3.5", copied && "text-success-text")} />
    </button>
  )

  return (
    <div
      className={classes(
        "group/code-surface overflow-hidden rounded-[var(--radius-panel)] border border-border bg-surface-inset text-text-primary",
        className
      )}
      data-code-surface-mode={mode}
      {...props}
    >
      <div className="flex items-start gap-2">
        {children ? (
          <pre
            className={classes(
              "min-w-0 flex-1 p-3 font-mono text-xs leading-5 [color-scheme:dark] [&_span]:contrast-more:!text-text-primary",
              MODE_CLASSES[mode],
              maxHeightClassName
            )}
          >
            {children}
          </pre>
        ) : (
          <CodeBlock
            code={code}
            lang={lang}
            className={classes(
              "min-w-0 flex-1 p-3 font-mono text-xs leading-5 [color-scheme:dark] [&_span]:contrast-more:!text-text-primary",
              MODE_CLASSES[mode],
              maxHeightClassName
            )}
          />
        )}
        <div className="sticky right-0 top-0 p-1.5">{copyControl}</div>
      </div>
    </div>
  )
}
