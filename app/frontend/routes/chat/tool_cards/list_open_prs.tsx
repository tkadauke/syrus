import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { Badge, displayValue, EmptyState, EntityReference, InternalLink, StatePill } from "../toolCardUi"

type PrRow = {
  key: string
  number: string
  title: string
  url: string | null
  headRef: string | null
  headUrl: string | null
  baseRef: string | null
  baseUrl: string | null
  mergeable: boolean | null
  draft: boolean
  createdAt: string | null
  updatedAt: string | null
}

function parseRow(value: unknown): PrRow | null {
  if (!isPlainObject(value)) return null
  const number = displayValue(value.number)
  if (!number) return null
  return {
    key: number,
    number,
    title: displayValue(value.title) || `PR #${number}`,
    url: displayValue(value.url),
    headRef: displayValue(value.head_ref),
    headUrl: displayValue(value.head_url),
    baseRef: displayValue(value.base_ref),
    baseUrl: displayValue(value.base_url),
    mergeable: typeof value.mergeable === "boolean" ? value.mergeable : null,
    draft: value.draft === true,
    createdAt: displayValue(value.created_at),
    updatedAt: displayValue(value.updated_at)
  }
}

function prRows(context: ToolCardContext): PrRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.pull_requests)) return null
  return parsed.pull_requests.flatMap((pr) => {
    const row = parseRow(pr)
    return row ? [row] : []
  })
}

function queryLabel(context: ToolCardContext) {
  return `${displayValue(context.input?.state) || "open"} · limit ${displayValue(context.input?.limit) || "20"}`
}

function errorMessage(context: ToolCardContext) {
  if (!context.resultError) return null
  if (isPlainObject(context.parsedResult)) return displayValue(context.parsedResult.error) || displayValue(context.parsedResult.message)
  return displayValue(context.resultBody) || "Unable to list pull requests."
}

function collapsedSummary(context: ToolCardContext) {
  const error = errorMessage(context)
  if (error) return error
  const rows = prRows(context)
  return rows ? `${rows.length} pull request${rows.length === 1 ? "" : "s"} · ${queryLabel(context)}` : null
}

function MergeabilityBadge({ mergeable }: { mergeable: boolean | null }) {
  if (mergeable === null) return <StatePill state="checking" tone="neutral" />
  return mergeable ? <StatePill state="mergeable" tone="success" /> : <StatePill state="conflicts" tone="failure" />
}

function RefLink({ label, url }: { label: string | null; url: string | null }) {
  if (!label) return <>?</>
  return url ? <InternalLink href={url}>{label}</InternalLink> : <>{label}</>
}

function Timestamp({ value }: { value: string | null }) {
  if (!value) return <>—</>
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return <>{value}</>
  return (
    <time dateTime={value} title={date.toLocaleString()}>
      {date.toLocaleDateString(undefined, { dateStyle: "medium" })}
    </time>
  )
}

function renderExpanded(context: ToolCardContext) {
  const error = errorMessage(context)
  if (error) return <EmptyState>{error}</EmptyState>
  const rows = prRows(context)
  if (!rows) return null

  return (
    <div className="space-y-2">
      <div className="flex flex-wrap items-center gap-1 text-xs text-text-muted">
        <span>Filter:</span>
        <Badge>{displayValue(context.input?.state) || "open"}</Badge>
        <span>Limit:</span>
        <Badge>{displayValue(context.input?.limit) || "20"}</Badge>
      </div>
      {rows.length === 0 ? (
        <EmptyState>No pull requests found.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["PR", "Title", "Refs", "Draft", "Mergeability", "Created", "Updated"]} />
          <TBody>
            {rows.map((row) => (
              <tr key={row.key}>
                <Td mono primary>
                  <EntityReference id={row.number} kind="pull_request" prUrl={row.url} />
                </Td>
                <Td maxWidth wrap title={row.title}>
                  {row.title}
                </Td>
                <Td mono wrap>
                  <RefLink label={row.headRef} url={row.headUrl} /> → <RefLink label={row.baseRef} url={row.baseUrl} />
                </Td>
                <Td>{row.draft ? <Badge>draft</Badge> : "—"}</Td>
                <Td>
                  <MergeabilityBadge mergeable={row.mergeable} />
                </Td>
                <Td>
                  <Timestamp value={row.createdAt} />
                </Td>
                <Td>
                  <Timestamp value={row.updatedAt} />
                </Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </div>
  )
}

const listOpenPrsToolCard: ToolCardRenderer = { toolName: "list_open_prs", collapsedSummary, renderExpanded }
export default listOpenPrsToolCard

export const examples = [
  {
    id: "mixed_mergeability",
    label: "Mixed mergeability and draft state",
    input: { state: "open", limit: 20 },
    parsedResult: {
      pull_requests: [
        {
          number: 41,
          title: "Add dark mode toggle to the settings page",
          url: "https://github.com/acme/widgets/pull/41",
          head_ref: "feature/dark-mode",
          head_url: "https://github.com/acme/widgets/tree/feature/dark-mode",
          base_ref: "main",
          base_url: "https://github.com/acme/widgets/tree/main",
          mergeable: true,
          draft: false,
          created_at: "2026-09-01T09:00:00Z",
          updated_at: "2026-10-18T14:30:00Z"
        },
        {
          number: 38,
          title: "WIP: rework pagination heuristics with a title long enough to demonstrate wrapping",
          url: "https://github.com/acme/widgets/pull/38",
          head_ref: "feature/pagination",
          head_url: "https://github.com/acme/widgets/tree/feature/pagination",
          base_ref: "main",
          base_url: "https://github.com/acme/widgets/tree/main",
          mergeable: null,
          draft: true,
          created_at: "2026-08-12T09:00:00Z",
          updated_at: "2026-10-17T10:00:00Z"
        }
      ]
    }
  },
  { id: "no_merged_prs", label: "No merged pull requests", input: { state: "merged", limit: 10 }, parsedResult: { pull_requests: [] } },
  { id: "provider_error", label: "Provider error", resultError: true, parsedResult: { error: "GitHub is temporarily unavailable" } }
]
