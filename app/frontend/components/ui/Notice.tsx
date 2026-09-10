import type { HTMLAttributes, ReactNode } from "react"
import { classes } from "./classes"
import { Text } from "./Text"

export type NoticeTone = "info" | "warning" | "danger" | "success" | "neutral"

export interface NoticeProps extends Omit<HTMLAttributes<HTMLDivElement>, "title"> {
  title?: ReactNode
  tone?: NoticeTone
}

const NOTICE_TONE_CLASSES: Record<NoticeTone, string> = {
  info: "border-info-border bg-info-surface text-info-text",
  warning: "border-warning-border bg-warning-surface text-warning-text",
  danger: "border-danger-border bg-danger-surface text-danger-text",
  success: "border-success-border bg-success-surface text-success-text",
  neutral: "border-neutral-border bg-neutral-surface text-neutral-text"
}

function Root({ children, className = "", title, tone = "neutral", ...props }: NoticeProps) {
  return (
    <div className={classes("rounded-[var(--radius-panel)] border border-[length:var(--border-width)] p-[var(--space-section)] text-sm", NOTICE_TONE_CLASSES[tone], className)} {...props}>
      {title ? <Text as="p" className="font-semibold" tone={tone === "neutral" ? "neutral" : tone} variant="heading-sm">{title}</Text> : null}
      {children ? <div className={classes(title ? "mt-1" : "", "leading-5")}>{children}</div> : null}
    </div>
  )
}

function Actions({ className = "", ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={classes("mt-3 flex flex-wrap items-center gap-2", className)} {...props} />
}

export const Notice = Object.assign(Root, { Actions })
