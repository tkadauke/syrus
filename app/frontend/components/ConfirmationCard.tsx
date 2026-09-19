import type { ReactNode } from "react"

type ConfirmationCardTone = "default" | "warning"

const toneClasses: Record<ConfirmationCardTone, string> = {
  default: "border-brand/30 bg-white dark:border-brand/40 dark:bg-gray-900",
  warning: "border-warning-border bg-warning-surface dark:border-warning-border dark:bg-warning-surface"
}

export function ConfirmationCard({
  body,
  footer,
  header,
  muted = false,
  proposalCard = false,
  tone = "default"
}: {
  header: ReactNode
  body?: ReactNode
  footer?: ReactNode
  muted?: boolean
  proposalCard?: boolean
  tone?: ConfirmationCardTone
}) {
  return (
    <article className={`max-w-4xl rounded border px-4 py-3 ${muted ? "border-gray-200 bg-white opacity-70 grayscale dark:border-gray-700 dark:bg-gray-900" : toneClasses[tone]}`} data-proposal-card={proposalCard ? "true" : undefined}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0 w-full">{header}</div>
      </div>
      {body ? <div className="mt-3">{body}</div> : null}
      {footer ? <div className="mt-4">{footer}</div> : null}
    </article>
  )
}
