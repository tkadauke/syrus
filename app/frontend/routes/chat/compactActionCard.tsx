import type { ReactNode } from "react"
import { Markdown } from "../../lib/Markdown"
import { Badge, CardShell, EntityReference, StatePill, type EntityReferenceProps } from "./toolCardUi"
import { MediaPreviewShell, type MediaPreviewItem } from "./mediaPreviewShell"

export type CompactActionRow = { label: string; value: ReactNode }
export type CompactActionError = { message: string; recovery?: string | null }

export function MarkdownPreview({ children }: { children: string }) {
  return <Markdown className="line-clamp-4 break-words text-sm text-text-secondary" linkifyUrls text={children} />
}

export function CompactActionCard({
  action,
  tone = "neutral",
  entity,
  badges = [],
  rows = [],
  media,
  markdown,
  error
}: {
  action: string
  tone?: "success" | "failure" | "warning" | "info" | "neutral"
  entity?: EntityReferenceProps | ReactNode
  badges?: ReactNode[]
  rows?: CompactActionRow[]
  media?: { item: MediaPreviewItem; modalLabel?: string }
  markdown?: string
  error?: CompactActionError
}) {
  const visibleRows = rows.slice(0, 4)

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill state={action} tone={error ? "failure" : tone} />
        {entity ? "kind" in Object(entity) ? <EntityReference {...(entity as EntityReferenceProps)} /> : (entity as ReactNode) : null}
        {badges.map((badge, index) => (
          <Badge key={index}>{badge}</Badge>
        ))}
      </div>
      {error ? (
        <div className="space-y-1 rounded border border-danger/30 bg-danger/10 px-3 py-2">
          <div className="break-words text-sm text-danger-text">{error.message}</div>
          {error.recovery ? <div className="break-words text-xs text-text-secondary">{error.recovery}</div> : null}
        </div>
      ) : null}
      {visibleRows.length > 0 ? (
        <dl className="grid min-w-0 gap-2 sm:grid-cols-2">
          {visibleRows.map((row) => (
            <div className="min-w-0" key={row.label}>
              <dt className="text-2xs font-semibold uppercase text-text-subtle">{row.label}</dt>
              <dd className="flex min-w-0 flex-wrap items-center gap-x-2 gap-y-1 break-words text-xs text-text-secondary">{row.value}</dd>
            </div>
          ))}
        </dl>
      ) : null}
      {media ? <MediaPreviewShell item={media.item} modalLabel={media.modalLabel} thumbnailClassName="w-full max-w-56" /> : null}
      {markdown ? <MarkdownPreview>{markdown}</MarkdownPreview> : null}
    </CardShell>
  )
}
