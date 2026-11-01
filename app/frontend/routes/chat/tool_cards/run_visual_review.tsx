import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { MediaPreviewShell } from "../mediaPreviewShell"
import { MarkdownPreview } from "../toolCardMarkdown"
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
  const instructions = displayValue(context.input?.prompt)
  const media = liveReviewMedia(context)
  return (
    <>
      <Row
        label={i18n.t("chat:run_visual_review.job")}
        value={jobId ? <EntityReference id={jobId} kind="job" /> : <EmptyState>{i18n.t("chat:run_visual_review.missing_target")}</EmptyState>}
      />
      {instructions ? (
        <MarkdownPreview
          maxLines={4}
          modalLabel={i18n.t("chat:run_visual_review.full_instructions")}
          text={instructions}
          title={i18n.t("chat:run_visual_review.instructions")}
        />
      ) : null}
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

const desktopPreview =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='960' height='540' viewBox='0 0 960 540'%3E%3Crect width='960' height='540' fill='%23f8fafc'/%3E%3Crect x='55' y='45' width='850' height='450' rx='18' fill='%23ffffff' stroke='%23cbd5e1' stroke-width='4'/%3E%3Crect x='90' y='85' width='210' height='28' rx='8' fill='%23b6492e'/%3E%3Crect x='90' y='150' width='500' height='22' rx='6' fill='%2394a3b8'/%3E%3Crect x='90' y='195' width='760' height='220' rx='12' fill='%23e2e8f0'/%3E%3Ctext x='480' y='320' text-anchor='middle' font-family='sans-serif' font-size='32' fill='%23475569'%3EDesktop review%3C/text%3E%3C/svg%3E"
const mobilePreview =
  "data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' width='360' height='640' viewBox='0 0 360 640'%3E%3Crect width='360' height='640' fill='%23f8fafc'/%3E%3Crect x='42' y='25' width='276' height='590' rx='32' fill='%23ffffff' stroke='%23cbd5e1' stroke-width='4'/%3E%3Crect x='75' y='82' width='145' height='24' rx='7' fill='%23b6492e'/%3E%3Crect x='75' y='145' width='210' height='250' rx='12' fill='%23e2e8f0'/%3E%3Ctext x='180' y='280' text-anchor='middle' font-family='sans-serif' font-size='24' fill='%23475569'%3EMobile review%3C/text%3E%3C/svg%3E"

const pendingResult = {
  pending_confirmation_id: 501,
  pending_action_id: 501,
  state: "pending",
  message: "Run a visual review pass for JOB-4222?"
}

export const examples: ToolCardExample[] = [
  {
    id: "pending",
    label: "Pending confirmation",
    description: "Shows the linked Job while the visual review request waits for confirmation.",
    input: { job_id: 4222, prompt: "Capture the sticky file title directly below the app header." },
    parsedResult: pendingResult,
    sourceType: "generic"
  },
  {
    id: "missing_input",
    label: "Missing Job input",
    description: "Shows the retained pending action when its original tool input is unavailable.",
    parsedResult: pendingResult,
    sourceType: "generic"
  },
  {
    id: "validation_error",
    label: "Visual review unavailable",
    description: "Keeps the attempted Job visible alongside the tool error.",
    input: { job_id: 4222 },
    parsedResult: { error: "not_eligible", message: "Visual review is unavailable while the Job has an active run." },
    resultError: true,
    sourceType: "generic"
  },
  {
    id: "completed_with_media",
    label: "Completed with desktop and mobile screenshots",
    description: "Shows the production live outcome after the resulting Workflow has submitted visual artifacts.",
    input: { job_id: 4222 },
    parsedResult: pendingResult,
    sourceType: "generic",
    livePendingAction: {
      id: 501,
      action: "run_visual_review",
      state: "confirmed",
      label: "Run visual review for JOB-4222",
      detail: "Visual review workflow completed.",
      execution_status: "applied",
      execution_step: "Applied.",
      outcome: {
        workflow_id: 61270,
        job_id: 4222,
        media: [
          { type: "visual_review_screenshot_run_1_1", title: "Desktop result", image_url: desktopPreview, content_type: "image/svg+xml" },
          { type: "visual_review_screenshot_run_1_2", title: "Mobile result", image_url: mobilePreview, content_type: "image/svg+xml" }
        ]
      },
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/501/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/501/reject"
    }
  }
]
