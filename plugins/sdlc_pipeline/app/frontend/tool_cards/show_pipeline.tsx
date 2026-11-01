import i18n from "i18next"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Button } from "@app/components/Button"
import { CardShell, EmptyState, Row } from "@app/routes/chat/toolCardUi"

type PipelineCard = { path: string; repository: string; at: string | null }

function parseCard(context: ToolCardContext): PipelineCard | null {
  const value = context.parsedResult
  if (!isPlainObject(value) || typeof value.path !== "string" || !isPlainObject(value.repository) || typeof value.repository.slug !== "string") return null
  return { path: value.path, repository: value.repository.slug, at: typeof value.at === "string" ? value.at : null }
}

function t(key: string, options?: Record<string, unknown>) {
  return i18n.t(`sdlc_pipeline:${key}`, options)
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (!card) return <EmptyState>{t("tool_malformed")}</EmptyState>
  const open = () =>
    window.dispatchEvent(
      new CustomEvent("syrus:tool-presentation", {
        detail: { chat_session_id: context.chatSessionId, title_i18n_key: "sdlc_pipeline:title", path: card.path }
      })
    )
  return (
    <CardShell>
      <Row label={t("tool_repository")} value={card.repository} />
      {card.at ? <Row label={t("tool_historical_cursor")} value={card.at} /> : null}
      <div className="flex flex-wrap gap-2">
        <Button onClick={open} size="sm">
          {t("tool_open")}
        </Button>
        <Button onClick={() => void navigator.clipboard.writeText(new URL(card.path, window.location.origin).toString())} size="sm" variant="secondary">
          {t("tool_copy_link")}
        </Button>
      </div>
    </CardShell>
  )
}

const renderer: ToolCardRenderer = {
  toolName: "show_pipeline",
  collapsedSummary: (context) => {
    const card = parseCard(context)
    return card ? t("tool_summary", { repository: card.repository }) : null
  },
  renderExpanded
}

export default renderer

export const examples: ToolCardExample[] = [
  {
    id: "filtered_pipeline",
    label: "Filtered pipeline",
    input: { repository_id: 7, filter: { and: [] } },
    parsedResult: { repository: { id: 7, slug: "acme/widgets" }, filter: { and: [] }, path: "/repositories/7/plugin/sdlc-pipeline?q=eyJhbmQiOltdfQ" }
  },
  { id: "malformed_pipeline", label: "Malformed result", input: {}, parsedResult: { path: 42 } }
]
