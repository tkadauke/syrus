import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import { Surface, type SurfaceVariant } from "./Surface"
import { Text } from "./Text"

export interface ToolCardProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  actions?: ReactNode
  children?: ReactNode
  footer?: ReactNode
  meta?: ReactNode
  summary?: ReactNode
  title?: ReactNode
  variant?: Extract<SurfaceVariant, "panel" | "raised" | "subtle" | "inset" | "danger" | "warning" | "success">
}

export interface ToolCardSectionProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  title?: ReactNode
}

export function ToolCard({
  actions,
  children,
  className = "",
  footer,
  meta,
  summary,
  title,
  variant = "panel",
  ...props
}: ToolCardProps) {
  return (
    <Surface className={classes("min-w-0 space-y-3 text-xs", className)} data-tool-card-shell="true" padding="sm" variant={variant} {...props}>
      {title || summary || meta || actions ? (
        <div className="flex min-w-0 items-start justify-between gap-3">
          <div className="min-w-0">
            {title ? <Text as="div" className="truncate" variant="heading-sm">{title}</Text> : null}
            {summary ? <Text as="div" className="mt-0.5 min-w-0 break-words" muted variant="caption">{summary}</Text> : null}
            {meta ? <div className="mt-1 flex flex-wrap gap-1.5">{meta}</div> : null}
          </div>
          {actions ? <div className="flex shrink-0 flex-wrap justify-end gap-2">{actions}</div> : null}
        </div>
      ) : null}
      {children ? <div className="min-w-0 space-y-2">{children}</div> : null}
      {footer ? <div className="border-t border-border pt-2">{footer}</div> : null}
    </Surface>
  )
}

function ToolCardSection({ children, className = "", title, ...props }: ToolCardSectionProps) {
  return (
    <section className={classes("min-w-0 space-y-1", className)} {...props}>
      {title ? <Text as="h4" variant="label">{title}</Text> : null}
      {children}
    </section>
  )
}

ToolCard.Section = ToolCardSection
