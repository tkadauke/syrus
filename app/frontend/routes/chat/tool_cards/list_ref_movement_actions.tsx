import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { DataTable } from "../../../components/ui"
import { TBody, Table, Td, THead } from "../adminToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, numberValue, SectionLabel, StatePill } from "../toolCardUi"

// Core-owned tool card for list_ref_movement_actions (the tool-card work).
type ActionRow = { name: string; enabled: boolean; mode: string | null; gradePhases: string[]; available: boolean; blockedReason: string | null }
type Card =
  | { kind: "actions"; repository: string | null; repositoryId: number | null; jobId: number | null; rows: ActionRow[] }
  | { kind: "error"; message: string }
  | { kind: "malformed" }

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

function parseCard(context: ToolCardContext): Card {
  if (context.resultError) return { kind: "error", message: displayValue(context.resultBody) ?? "Could not list ref movement actions." }
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.ref_movement_actions)) return { kind: "malformed" }

  return {
    kind: "actions",
    repository: displayValue(parsed.repository),
    repositoryId: numberValue(parsed.repository_id),
    jobId: numberValue(parsed.job_id) ?? numberValue(context.input?.job_id),
    rows: parsed.ref_movement_actions.flatMap((item) => {
      const row = parseRow(item)
      return row ? [row] : []
    })
  }
}

function collapsedSummary(context: ToolCardContext) {
  const card = parseCard(context)
  if (card.kind === "error") return "Ref movement actions failed"
  if (card.kind === "malformed") return null
  const availableCount = card.rows.filter((row) => row.available).length
  return `${availableCount}/${card.rows.length} ref movement action${card.rows.length === 1 ? "" : "s"} available`
}

function renderExpanded(context: ToolCardContext) {
  const card = parseCard(context)
  if (card.kind === "malformed") return null
  if (card.kind === "error") return <EmptyState>{card.message}</EmptyState>

  return (
    <CardShell>
      {card.repository ? (
        <div className="min-w-0">
          <SectionLabel>Repository</SectionLabel>
          <EntityReference kind="repository" repositoryId={card.repositoryId} repositorySlug={card.repository} />
        </div>
      ) : null}
      {card.jobId != null ? (
        <div className="min-w-0">
          <SectionLabel>Job</SectionLabel>
          <EntityReference id={card.jobId} kind="job" />
        </div>
      ) : null}
      {card.rows.length === 0 ? (
        <EmptyState>No ref movement actions configured.</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["Action", "Enabled", "Mode", "Grade phases", "Availability"]} />
          <TBody>
            {card.rows.map((row) => (
              <DataTable.Row key={row.name}>
                <Td mono primary>
                  {row.name}
                </Td>
                <Td>
                  <StatePill state={row.enabled ? "enabled" : "disabled"} tone={row.enabled ? "success" : "neutral"} />
                </Td>
                <Td>{row.mode || "—"}</Td>
                <Td wrap>
                  {row.gradePhases.length > 0 ? (
                    <span className="flex flex-wrap gap-1">
                      {row.gradePhases.map((phase) => (
                        <Badge key={phase}>{phase}</Badge>
                      ))}
                    </span>
                  ) : (
                    "—"
                  )}
                </Td>
                <Td wrap>
                  <div className="space-y-1">
                    <StatePill state={row.available ? "available" : "blocked"} tone={row.available ? "success" : "warning"} />
                    {!row.available && row.blockedReason ? (
                      <MarkdownPreview maxLines={3} modalLabel={`Blocked reason for ${row.name}`} text={row.blockedReason} />
                    ) : null}
                  </div>
                </Td>
              </DataTable.Row>
            ))}
          </TBody>
        </Table>
      )}
    </CardShell>
  )
}

const listRefMovementActionsToolCard: ToolCardRenderer = {
  toolName: "list_ref_movement_actions",
  collapsedSummary,
  renderExpanded
}

export default listRefMovementActionsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "mixed_availability",
    label: "Enabled and disabled actions",
    input: { job_id: 42 },
    parsedResult: {
      repository: "tkadauke/syrus",
      repository_id: 1,
      job_id: 42,
      ref_movement_actions: [
        { name: "send_job_upstream", enabled: true, mode: "manual_pr", grade_phases: ["review", "landing"], available: true, blocked_reason: null },
        {
          name: "submit_branch_upstream",
          enabled: false,
          mode: null,
          grade_phases: [],
          available: false,
          blocked_reason: "Disabled in **delivery.ref_movement_actions**."
        }
      ]
    }
  },
  {
    id: "no_actions",
    label: "No configured actions",
    parsedResult: { repository: "tkadauke/syrus", repository_id: 1, job_id: null, ref_movement_actions: [] }
  },
  { id: "tool_error", label: "Tool error", resultBody: "Error: no repository attached", resultError: true }
]
