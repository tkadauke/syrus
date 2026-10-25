import i18n from "@app/i18n"
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
  return i18n.t("chat:tool_card_list_ref_actions_summary", { available: availableCount, count: result.rows.length })
}

function Scope({ result }: { result: ActionsResult }) {
  const repositoryHref = `/repositories?search=${encodeURIComponent(result.repository)}`
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-x-4 gap-y-1 text-xs text-text-muted">
      <span className="inline-flex min-w-0 items-center gap-1">
        {i18n.t("chat:tool_card_list_ref_actions_repository")}: <EntityReference href={repositoryHref} kind="repository" repositorySlug={result.repository} />
      </span>
      <span className="inline-flex items-center gap-1">{i18n.t("chat:tool_card_list_ref_actions_job")}: {result.jobId ? <EntityReference id={result.jobId} kind="job" /> : <span>{i18n.t("chat:tool_card_list_ref_actions_all_jobs")}</span>}</span>
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
        <EmptyState>{i18n.t("chat:tool_card_list_ref_actions_empty")}</EmptyState>
      ) : (
        <Table responsive>
          <THead columns={["action", "enabled", "mode", "grade_phases", "availability", "blocked_reason"].map((key) => i18n.t(`chat:tool_card_list_ref_actions_${key}`))} />
          <TBody>
            {result.rows.map((row) => (
              <tr key={row.name}>
                <Td mono primary>
                  {row.name}
                </Td>
                <Td>
                  <StatePill state={row.enabled ? i18n.t("chat:tool_card_enabled") : i18n.t("chat:tool_card_disabled")} tone={row.enabled ? "success" : "neutral"} />
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
                  <StatePill state={row.available ? i18n.t("chat:tool_card_available") : i18n.t("chat:tool_card_blocked")} tone={row.available ? "success" : "warning"} />
                </Td>
                <Td wrap>{row.blockedReason ? <MarkdownPreview maxLines={3} text={row.blockedReason} title={i18n.t("chat:tool_card_list_ref_actions_blocked_reason")} /> : "—"}</Td>
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
    label: i18n.t("chat:tool_card_list_ref_actions_example_job"),
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
  { id: "no_actions", label: i18n.t("chat:tool_card_list_ref_actions_example_empty"), parsedResult: { repository: "example/widgets", job_id: null, ref_movement_actions: [] } }
]

const listRefMovementActionsToolCard: ToolCardRenderer = { toolName: "list_ref_movement_actions", collapsedSummary, renderExpanded }
export default listRefMovementActionsToolCard
