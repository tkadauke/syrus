import type { ReactNode } from "react"

export function ConfirmationCard({ body, footer, header, muted = false, proposalCard = false }: { header: ReactNode; body?: ReactNode; footer?: ReactNode; muted?: boolean; proposalCard?: boolean }) {
  return (
    <article className={`max-w-4xl rounded border bg-white px-4 py-3 dark:bg-gray-900 ${muted ? "border-gray-200 opacity-70 grayscale dark:border-gray-700" : "border-blue-200 dark:border-blue-800"}`} data-proposal-card={proposalCard ? "true" : undefined}>
      <div className="flex flex-wrap items-start justify-between gap-3">
        <div className="min-w-0">{header}</div>
      </div>
      {body ? <div className="mt-3">{body}</div> : null}
      {footer ? <div className="mt-4">{footer}</div> : null}
    </article>
  )
}
