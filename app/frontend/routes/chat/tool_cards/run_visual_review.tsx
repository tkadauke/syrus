import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { MediaPreviewShell } from "../mediaPreviewShell"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"

type ReviewMedia = { key: string; src: string; title: string; detail: string | null }

const IMAGE_KEYS = ["image_url", "thumbnail_url", "render_url", "file_url"]

function safeMediaUrl(value: unknown) {
  const url = displayValue(value)
  return url && (url.startsWith("/") || url.startsWith("data:image/") || /^https?:\/\//i.test(url)) ? url : null
}

function liveReviewMedia(context: ToolCardContext) {
  const found: ReviewMedia[] = []
  const seenObjects = new Set<object>()
  const seenUrls = new Set<string>()

  function visit(value: unknown, path: string[]) {
    if (!value || typeof value !== "object" || seenObjects.has(value)) return
    seenObjects.add(value)
    if (Array.isArray(value)) {
      value.forEach((entry, index) => visit(entry, [...path, String(index + 1)]))
      return
    }

    const record = value as Record<string, unknown>
    const src = IMAGE_KEYS.map((key) => safeMediaUrl(record[key])).find(Boolean)
    if (src && !seenUrls.has(src)) {
      seenUrls.add(src)
      const fallback = path.at(-1)?.replace(/_/g, " ") || i18n.t("chat:run_visual_review.screenshot")
      found.push({
        key: `${path.join(".")}-${src}`,
        src,
        title: displayValue(record.title) || displayValue(record.name) || fallback,
        detail: displayValue(record.description) || displayValue(record.type)
      })
    }
    Object.entries(record).forEach(([key, child]) => visit(child, [...path, key]))
  }

  visit(context.livePendingAction, [])
  return found
}

function VisualReviewDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const media = liveReviewMedia(context)
  return (
    <>
      <Row
        label={i18n.t("chat:run_visual_review.job")}
        value={jobId ? <EntityReference id={jobId} kind="job" /> : <EmptyState>{i18n.t("chat:run_visual_review.missing_target")}</EmptyState>}
      />
      {media.length ? (
        <div>
          <div className="mb-1 text-2xs font-semibold uppercase text-text-muted">{i18n.t("chat:run_visual_review.media")}</div>
          <div className="grid grid-cols-1 gap-2 min-[360px]:grid-cols-2 sm:grid-cols-3">
            {media.map((item) => (
              <MediaPreviewShell
                item={{
                  title: item.title,
                  subtitle: item.detail,
                  src: item.src,
                  alt: item.title,
                  badge: i18n.t("chat:run_visual_review.screenshot"),
                  fallbackLabel: i18n.t("chat:run_visual_review.preview_unavailable"),
                  actions: [{ label: i18n.t("chat:run_visual_review.open_image"), href: item.src }]
                }}
                key={item.key}
                modalLabel={item.title}
                thumbnailClassName="min-h-11 w-full"
              />
            ))}
          </div>
        </div>
      ) : null}
    </>
  )
}

function collapsedSummary(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? pendingActionCollapsedSummary(result) : null
}

function renderExpanded(context: ToolCardContext) {
  const result = parsePendingActionResult(context, true)
  return result ? <PendingActionResultCard details={<VisualReviewDetails context={context} />} omitJob result={result} /> : null
}

const runVisualReviewToolCard: ToolCardRenderer = {
  toolName: "run_visual_review",
  collapsedSummary,
  renderExpanded
}

export default runVisualReviewToolCard
