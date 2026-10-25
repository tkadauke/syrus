import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { DataTable } from "../../../components/ui"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { EmptyState, EntityReference, StatePill } from "../toolCardUi"

type EpicRow = {
  key: string
  title: string
  description: string | null
  state: string
  repositorySlug: string | null
  childJobCount: number | null
  openJobCount: number | null
  createdAt: string | null
}

const DEFAULT_LIMIT = 20
const MIN_LIMIT = 1
const MAX_LIMIT = 100

function displayValue(value: unknown): string | null {
  if (typeof value === "number" && Number.isFinite(value)) return String(value)
  if (typeof value === "string" && value.trim()) return value.trim()
  return null
}

function numberValue(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null
}

function parseEpicRow(value: unknown): EpicRow | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const state = displayValue(value.state)
  if (!id || !state) return null
  return {
    key: id,
    title: displayValue(value.title) || `EPIC-${id}`,
    description: displayValue(value.description),
    state,
    repositorySlug: displayValue(value.repository_slug),
    childJobCount: numberValue(value.child_job_count),
    openJobCount: numberValue(value.open_job_count),
    createdAt: displayValue(value.created_at)
  }
}

function epicRows(context: ToolCardContext): EpicRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.epics)) return null
  return parsed.epics.flatMap((epic) => {
    const row = parseEpicRow(epic)
    return row ? [row] : []
  })
}

function effectiveLimit(input: Record<string, unknown> | undefined) {
  const requested = input?.limit
  const numeric = typeof requested === "number" ? requested : typeof requested === "string" ? Number.parseInt(requested, 10) : DEFAULT_LIMIT
  const integer = Number.isFinite(numeric) ? Math.trunc(numeric) : 0
  return Math.min(MAX_LIMIT, Math.max(MIN_LIMIT, integer))
}

function QuerySummary({ context, count }: { context: ToolCardContext; count?: number }) {
  const limit = effectiveLimit(context.input)
  const state = displayValue(context.input?.state) || "non-archived"
  return (
    <div className="mt-1 flex flex-wrap gap-x-3 gap-y-1 text-xs text-text-muted">
      <span>
        {i18n.t("chat:tool_card_list_epics_state")}: <span className="font-medium text-text-primary">{state.replace(/_/g, " ")}</span>
      </span>
      <span>
        {i18n.t("chat:tool_card_list_epics_limit")}: <span className="font-medium text-text-primary">{limit}</span>
      </span>
      {count != null && count >= limit ? <span>{i18n.t("chat:tool_card_list_epics_limit_reached")}</span> : null}
    </div>
  )
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return i18n.t("chat:tool_card_list_epics_failed")
  const rows = epicRows(context)
  return rows ? i18n.t("chat:tool_card_list_epics_summary", { count: rows.length }) : null
}

function progressLabel(row: EpicRow) {
  if (row.childJobCount == null) return "—"
  return i18n.t("chat:tool_card_list_epics_progress", { done: row.childJobCount - (row.openJobCount ?? 0), count: row.childJobCount })
}

function createdLabel(value: string | null) {
  if (!value) return "—"
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : date.toLocaleString()
}

function errorMessage(context: ToolCardContext) {
  if (isPlainObject(context.parsedResult)) {
    return displayValue(context.parsedResult.error) || displayValue(context.parsedResult.message) || i18n.t("chat:tool_card_list_epics_error")
  }
  return context.resultBody.trim() || i18n.t("chat:tool_card_list_epics_error")
}

function EpicsTable({ rows }: { rows: EpicRow[] }) {
  return (
    <Table responsive>
      <THead columns={["epic", "details", "state", "repository", "progress", "created"].map((key) => i18n.t(`chat:tool_card_list_epics_column_${key}`))} />
      <TBody>
        {rows.map((row) => (
          <DataTable.Row key={row.key}>
            <Td>
              <EntityReference id={row.key} kind="epic" />
            </Td>
            <Td maxWidth wrap>
              <div className="break-words font-medium text-text-primary">{row.title}</div>
              {row.description ? <MarkdownPreview maxLines={3} modalLabel={i18n.t("chat:tool_card_list_epics_description", { title: row.title })} text={row.description} /> : null}
            </Td>
            <Td>
              <StatePill state={row.state} />
            </Td>
            <Td>{row.repositorySlug ? <EntityReference kind="repository" slug={row.repositorySlug} /> : "—"}</Td>
            <Td>{progressLabel(row)}</Td>
            <Td wrap>{createdLabel(row.createdAt)}</Td>
          </DataTable.Row>
        ))}
      </TBody>
    </Table>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultError)
    return (
      <>
        <QuerySummary context={context} />
        <EmptyState>{errorMessage(context)}</EmptyState>
      </>
    )
  const rows = epicRows(context)
  if (!rows) return null
  return (
    <>
      <QuerySummary context={context} count={rows.length} />
      {rows.length ? <EpicsTable rows={rows} /> : <EmptyState>{i18n.t("chat:tool_card_list_epics_empty")}</EmptyState>}
    </>
  )
}

const listEpicsToolCard: ToolCardRenderer = { toolName: "list_epics", collapsedSummary, renderExpanded }
export default listEpicsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "two_epics_in_progress",
    label: i18n.t("chat:tool_card_list_epics_example_two"),
    input: { state: "open", limit: 2 },
    parsedResult: {
      epics: [
        {
          id: 12,
          title: i18n.t("chat:tool_card_list_epics_example_first_title"),
          description: i18n.t("chat:tool_card_list_epics_example_first_description"),
          state: "open",
          repository_slug: "acme/widget-app",
          child_job_count: 5,
          open_job_count: 2,
          created_at: "2026-10-12T12:00:00Z"
        },
        {
          id: 9,
          title: i18n.t("chat:tool_card_list_epics_example_second_title"),
          description: i18n.t("chat:tool_card_list_epics_example_second_description"),
          state: "landing",
          repository_slug: "acme/widget-app",
          child_job_count: 3,
          open_job_count: 0,
          created_at: "2026-10-10T09:30:00Z"
        }
      ]
    }
  },
  { id: "no_open_epics", label: i18n.t("chat:tool_card_list_epics_example_empty"), input: { state: "open" }, parsedResult: { epics: [] } },
  { id: "error", label: i18n.t("chat:tool_card_list_epics_example_error"), input: { state: "open", limit: 10 }, parsedResult: { error: i18n.t("chat:tool_card_list_epics_example_error_message") }, resultError: true }
]
