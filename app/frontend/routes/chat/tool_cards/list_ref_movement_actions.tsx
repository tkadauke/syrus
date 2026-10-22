import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { Table, TBody, Td, THead } from "../adminToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, StatePill } from "../toolCardUi"

type ActionRow = { name: string; enabled: boolean; mode: string | null; gradePhases: string[]; available: boolean; blockedReason: string | null }
type ActionsResult = { repository: string; jobId: string | null; rows: ActionRow[] }

function parseRow(value: unknown): ActionRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null
  return {
    name,
    enabled: value.enabled === true,
    mode: displayValue(value.mode),
    gradePhases: Array.isArray(value.grade_phases) ? value.grade_phases.flatMap((phase) => displayValue(phase) ?? []) : [],
    available: value.available === true,
    blockedReason: displayValue(value.blocked_reason)
  }
}

function parseResult(context: ToolCardContext): ActionsResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.ref_movement_actions)) return null
  const repository = displayValue(parsed.repository)
  if (!repository) return null
  return {
    repository,
    jobId: displayValue(parsed.job_id),
    rows: parsed.ref_movement_actions.flatMap((item) => {
      const row = parseRow(item)
      return row ? [row] : []
    })
  }
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  const availableCount = result.rows.filter((row) => row.available).length
  return `${availableCount}/${result.rows.length} ref movement action${result.rows.length === 1 ? "" : "s"} available`
}

function Scope({ result }: { result: ActionsResult }) {
  const repositoryHref = `/repositories?search=${encodeURIComponent(result.repository)}`
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-x-4 gap-y-1 text-xs text-text-muted">
      <span className="inline-flex min-w-0 items-center gap-1">
        Repository: <EntityReference href={repositoryHref} kind="repository" repositorySlug={result.repository} />
      </span>
      <span className="inline-flex items-center gap-1">Job: {result.jobId ? <EntityReference id={result.jobId} kind="job" /> : <span>all jobs</span>}</span>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  return (
    <CardShell>
      <Scope result={result} />
      {result.rows.length === 0 ? (
        <EmptyState>No ref movement actions configured.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["Action", "Enabled", "Mode", "Grade phases", "Availability", "Blocked reason"]} />
          <TBody>
            {result.rows.map((row) => (
              <tr key={row.name}>
                <Td mono primary>
                  {row.name}
                </Td>
                <Td>
                  <StatePill state={row.enabled ? "enabled" : "disabled"} tone={row.enabled ? "success" : "neutral"} />
                </Td>
                <Td>{row.mode || "—"}</Td>
                <Td wrap>
                  {row.gradePhases.length > 0 ? (
                    <div className="flex flex-wrap gap-1">
                      {row.gradePhases.map((phase) => (
                        <Badge key={phase}>{phase}</Badge>
                      ))}
                    </div>
                  ) : (
                    "—"
                  )}
                </Td>
                <Td>
                  <StatePill state={row.available ? "available" : "blocked"} tone={row.available ? "success" : "warning"} />
                </Td>
                <Td wrap>{row.blockedReason ? <MarkdownPreview maxLines={3} text={row.blockedReason} title="Blocked reason" /> : "—"}</Td>
              </tr>
            ))}
          </TBody>
        </Table>
      )}
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "job_scoped_actions",
    label: "Job-scoped actions",
    input: { job_id: 4225 },
    parsedResult: {
      repository: "example/widgets",
      job_id: 4225,
      ref_movement_actions: [
        { name: "send_job_upstream", enabled: true, mode: "auto", grade_phases: ["test", "review"], available: true, blocked_reason: null },
        {
          name: "submit_branch_upstream",
          enabled: false,
          mode: null,
          grade_phases: [],
          available: false,
          blocked_reason: "Enable **branch submission** in `delivery.ref_movement_actions`."
        }
      ]
    }
  },
  { id: "no_actions", label: "No configured actions", parsedResult: { repository: "example/widgets", job_id: null, ref_movement_actions: [] } }
]

const listRefMovementActionsToolCard: ToolCardRenderer = { toolName: "list_ref_movement_actions", collapsedSummary, renderExpanded }
export default listRefMovementActionsToolCard
