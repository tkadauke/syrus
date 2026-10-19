import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { DataTable } from "@app/components/ui"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EmptyState, EntityReference, numberValue, StatePill } from "../toolCardUi"

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
  return parsed.epics.flatMap((value) => {
    const row = parseEpicRow(value)
    return row ? [row] : []
  })
}

function collapsedSummary(context: ToolCardContext) {
  const rows = epicRows(context)
  return rows ? `${rows.length} Epic${rows.length === 1 ? "" : "s"}` : null
}

function progressLabel(row: EpicRow) {
  if (row.childJobCount == null) return "—"
  return `${row.childJobCount - (row.openJobCount ?? 0)}/${row.childJobCount} done`
}

function createdLabel(value: string | null) {
  if (!value) return "—"
  const date = new Date(value)
  return Number.isNaN(date.getTime()) ? value : new Intl.DateTimeFormat(undefined, { dateStyle: "medium" }).format(date)
}

function Repository({ slug }: { slug: string | null }) {
  return slug ? <EntityReference href={`https://github.com/${slug}`} kind="repository" repositorySlug={slug} /> : <>—</>
}

function errorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  if (isPlainObject(context.parsedResult))
    return displayValue(context.parsedResult.error) || displayValue(context.parsedResult.message) || "Unable to list Epics."
  return displayValue(context.resultBody) || "Unable to list Epics."
}

function effectiveLimit(value: unknown) {
  const requested = numberValue(value)
  if (requested == null) return 20
  return Math.min(100, Math.max(1, Math.trunc(requested)))
}

function QuerySummary({ context, rowCount }: { context: ToolCardContext; rowCount: number | null }) {
  const state = displayValue(context.input?.state)
  const limit = effectiveLimit(context.input?.limit)
  return (
    <div className="flex flex-wrap items-center gap-x-3 gap-y-1 text-2xs text-text-muted">
      <span>State: {state || "non-archived"}</span>
      <span>Limit: {limit}</span>
      {rowCount != null && rowCount >= limit ? <span className="font-medium text-warning">Result limit reached; more Epics may be available.</span> : null}
    </div>
  )
}

function DesktopTable({ rows }: { rows: EpicRow[] }) {
  return (
    <div className="hidden md:block">
      <DataTable.Root className="text-xs" density="compact">
        <DataTable.Header>
          <DataTable.Row>
            {["Epic", "Title and description", "State", "Repository", "Progress", "Created"].map((heading) => (
              <DataTable.HeadCell className="px-2 py-1 text-2xs" key={heading}>
                {heading}
              </DataTable.HeadCell>
            ))}
          </DataTable.Row>
        </DataTable.Header>
        <DataTable.Body>
          {rows.map((row) => (
            <DataTable.Row key={row.key}>
              <DataTable.Cell className="whitespace-nowrap px-2 py-2 align-top text-xs">
                <EntityReference id={row.key} kind="epic" />
              </DataTable.Cell>
              <DataTable.Cell className="min-w-52 max-w-sm px-2 py-2 align-top text-xs">
                <div className="break-words font-medium text-text-primary">{row.title}</div>
                {row.description ? (
                  <div className="mt-1">
                    <MarkdownPreview maxLines={1} modalLabel={`${row.title} description`} text={row.description} />
                  </div>
                ) : null}
              </DataTable.Cell>
              <DataTable.Cell className="whitespace-nowrap px-2 py-2 align-top text-xs">
                <StatePill state={row.state} />
              </DataTable.Cell>
              <DataTable.Cell className="px-2 py-2 align-top text-xs">
                <Repository slug={row.repositorySlug} />
              </DataTable.Cell>
              <DataTable.Cell className="whitespace-nowrap px-2 py-2 align-top text-xs">{progressLabel(row)}</DataTable.Cell>
              <DataTable.Cell className="whitespace-nowrap px-2 py-2 align-top text-xs" title={row.createdAt || undefined}>
                {createdLabel(row.createdAt)}
              </DataTable.Cell>
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>
    </div>
  )
}

function MobileList({ rows }: { rows: EpicRow[] }) {
  return (
    <div className="space-y-2 md:hidden" data-testid="epics-mobile-list">
      {rows.map((row) => (
        <div className="space-y-2 rounded-[var(--radius-panel)] border border-border bg-surface p-3" key={row.key}>
          <div className="flex flex-wrap items-center justify-between gap-2">
            <EntityReference id={row.key} kind="epic" />
            <StatePill state={row.state} />
          </div>
          <div className="break-words text-sm font-medium text-text-primary">{row.title}</div>
          {row.description ? <MarkdownPreview maxLines={2} modalLabel={`${row.title} description`} text={row.description} /> : null}
          <dl className="grid grid-cols-2 gap-x-3 gap-y-2 text-xs">
            <div>
              <dt className="text-text-muted">Repository</dt>
              <dd className="mt-0.5 break-all">
                <Repository slug={row.repositorySlug} />
              </dd>
            </div>
            <div>
              <dt className="text-text-muted">Progress</dt>
              <dd className="mt-0.5 text-text-primary">{progressLabel(row)}</dd>
            </div>
            <div className="col-span-2">
              <dt className="text-text-muted">Created</dt>
              <dd className="mt-0.5 text-text-primary">{createdLabel(row.createdAt)}</dd>
            </div>
          </dl>
        </div>
      ))}
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const error = errorMessage(context)
  if (error)
    return (
      <CardShell>
        <QuerySummary context={context} rowCount={null} />
        <EmptyState>{error}</EmptyState>
      </CardShell>
    )
  const rows = epicRows(context)
  if (!rows) return null
  return (
    <CardShell>
      <QuerySummary context={context} rowCount={rows.length} />
      {rows.length === 0 ? (
        <EmptyState>No Epics found.</EmptyState>
      ) : (
        <>
          <DesktopTable rows={rows} />
          <MobileList rows={rows} />
        </>
      )}
    </CardShell>
  )
}

const listEpicsToolCard: ToolCardRenderer = { toolName: "list_epics", collapsedSummary, renderExpanded }
export default listEpicsToolCard

export const examples = [
  {
    id: "two_epics_in_progress",
    label: "Two Epics in progress",
    input: { state: "in_progress", limit: 2 },
    parsedResult: {
      epics: [
        {
          id: 12,
          title: "Dark Mode And Theming Polish",
          description: "Polish the **operator theme** across every primary workflow.",
          state: "in_progress",
          repository_slug: "acme/widget-app",
          child_job_count: 5,
          open_job_count: 2,
          created_at: "2026-09-01T12:00:00Z"
        },
        {
          id: 9,
          title: "Checkout Flow Redesign",
          description: "Make checkout clearer on desktop and mobile.",
          state: "done",
          repository_slug: "acme/widget-app",
          child_job_count: 3,
          open_job_count: 0,
          created_at: "2026-08-20T09:30:00Z"
        }
      ]
    }
  },
  {
    id: "no_open_epics",
    label: "No open Epics",
    description: "Empty result set with the active query shown.",
    input: { state: "ready", limit: 20 },
    parsedResult: { epics: [] }
  },
  { id: "list_epics_error", label: "List Epics error", input: { state: "unknown" }, parsedResult: { error: "state is invalid" }, resultError: true }
]
