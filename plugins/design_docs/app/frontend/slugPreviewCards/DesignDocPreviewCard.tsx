import { useQuery } from "@tanstack/react-query"
import { Link } from "react-router-dom"
import { Card, Skeleton } from "@app/components/Card"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { useT } from "@app/hooks/useT"
import { Markdown } from "@app/lib/Markdown"
import { fetchDesignDocPreview, type DesignDocUser } from "../api/designDocs"

const MAX_COLLABORATOR_NAMES = 3

function collaboratorLabel(user: DesignDocUser) {
  return user.name || user.email_address
}

function collaboratorSummary(collaborators: DesignDocUser[]) {
  const names = collaborators.map(collaboratorLabel)
  if (names.length <= MAX_COLLABORATOR_NAMES) return names.join(", ")

  const shown = names.slice(0, MAX_COLLABORATOR_NAMES)
  return `${shown.join(", ")} +${names.length - MAX_COLLABORATOR_NAMES}`
}

// Rendered by core's SlugHoverCard for `kind: "doc"` (see
// app/frontend/pluginSlugPreviewCards.tsx) whenever a DOC-<id> slug is
// linkified anywhere in the app -- chat messages, job/epic bodies, design
// doc comments, etc. Fetches the lightweight `/preview` payload rather than
// the full DesignDocDetail, since a single page can reference many docs.
export function DesignDocPreviewCard({ id, compact = false }: { id: number; compact?: boolean }) {
  const { t } = useT("design_docs")
  const { data, isPending } = useQuery({
    queryKey: ["design_docs", "preview", String(id)],
    queryFn: () => fetchDesignDocPreview(id),
    staleTime: 30_000,
  })

  if (isPending) return <DesignDocPreviewSkeleton />
  if (!data) return null

  const { design_doc: doc } = data

  if (!doc.accessible) {
    return (
      <Card compact={compact} variant="preview">
        <CopyableSlug className="text-xs" slug={doc.display_id} />
        <p className="mt-2 text-xs text-gray-500 dark:text-gray-400">{t("preview_not_accessible")}</p>
      </Card>
    )
  }

  return (
    <Card compact={compact} variant="preview">
      <div className="mb-2 flex items-center gap-2">
        <CopyableSlug className="text-xs" slug={doc.display_id} />
      </div>
      <Link
        className={`mb-2 block text-sm font-medium text-gray-900 hover:underline dark:text-gray-100 ${compact ? "line-clamp-1" : "line-clamp-2"}`}
        to={`/design_docs/${id}`}
      >
        {doc.title}
      </Link>
      {!compact && doc.preview_text ? (
        <div className="mb-3 line-clamp-6 text-xs text-gray-600 dark:text-gray-400 [&_code]:rounded [&_code]:bg-gray-100 [&_code]:px-0.5 [&_code]:font-mono dark:[&_code]:bg-gray-800 [&_h1]:text-xs [&_h1]:font-semibold [&_h2]:text-xs [&_h2]:font-semibold [&_h3]:text-xs [&_h3]:font-semibold [&_pre]:rounded [&_pre]:bg-gray-100 [&_pre]:p-1.5 [&_pre]:font-mono dark:[&_pre]:bg-gray-800 [&_pre_code]:bg-transparent [&_pre_code]:px-0">
          <Markdown text={doc.preview_text} />
        </div>
      ) : null}
      {!compact ? (
        <div className="mb-3 space-y-1 text-xs text-gray-600 dark:text-gray-400">
          <p>{t("preview_owner", { name: doc.owner ? collaboratorLabel(doc.owner) : t("preview_unknown_owner") })}</p>
          {doc.collaborators && doc.collaborators.length > 0 ? (
            <p>{t("preview_collaborators", { names: collaboratorSummary(doc.collaborators) })}</p>
          ) : null}
        </div>
      ) : null}
      <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-xs text-gray-500 dark:text-gray-400">
        <span>{t("preview_comment_count", { count: doc.comments_count ?? 0 })}</span>
        {doc.latest_version_number ? <span>{t("preview_version", { number: doc.latest_version_number })}</span> : null}
        <RelativeTimestamp value={doc.updated_at} />
      </div>
      {!compact && (
        <Link className="mt-2 inline-block text-xs text-brand hover:underline dark:text-brand-emphasis" to={`/design_docs/${id}`}>
          {t("preview_see_more")}
        </Link>
      )}
    </Card>
  )
}

function DesignDocPreviewSkeleton() {
  return (
    <Card variant="preview">
      <div className="mb-2 flex items-center gap-2">
        <Skeleton className="h-3 w-14" />
      </div>
      <div className="mb-3 space-y-1.5">
        <Skeleton className="h-4 w-full" />
        <Skeleton className="h-4 w-3/4" />
      </div>
      <div className="space-y-1">
        <Skeleton className="h-3 w-full" />
        <Skeleton className="h-3 w-full" />
        <Skeleton className="h-3 w-2/3" />
      </div>
    </Card>
  )
}

export default DesignDocPreviewCard
