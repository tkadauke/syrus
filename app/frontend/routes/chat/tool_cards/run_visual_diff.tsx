import type { TypedArtifact } from "../../../api/artifacts"
import { ArtifactBody } from "../../../components/artifacts/TypedArtifactPanel"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { parsePendingActionResult, pendingActionCollapsedSummary, PendingActionResultCard } from "../pendingActionToolCard"
import { displayValue, EmptyState, EntityReference, Row } from "../toolCardUi"

function comparisonArtifact(context: ToolCardContext): TypedArtifact | null {
  const live = context.livePendingAction as unknown as { outcome?: { comparison?: unknown } } | undefined
  const value = live?.outcome?.comparison
  if (!value || typeof value !== "object" || Array.isArray(value)) return null

  const artifact = value as Record<string, unknown>
  if (artifact.type !== "visual_diff_comparison" || artifact.renderer_type !== "before_after_visual_diff") return null
  if (!artifact.payload || typeof artifact.payload !== "object") return null

  return {
    type: artifact.type,
    title: displayValue(artifact.title) || i18n.t("chat:run_visual_diff.comparison"),
    renderer_type: artifact.renderer_type,
    payload: artifact.payload as TypedArtifact["payload"],
    created_at: displayValue(artifact.created_at) || ""
  }
}

function VisualDiffDetails({ context }: { context: ToolCardContext }) {
  const jobId = displayValue(context.input?.job_id)
  const artifact = comparisonArtifact(context)
  return (
    <>
      <Row
        label={i18n.t("chat:run_visual_diff.job")}
        value={jobId ? <EntityReference id={jobId} kind="job" /> : <EmptyState>{i18n.t("chat:run_visual_diff.missing_target")}</EmptyState>}
      />
      {artifact ? (
        <div className="space-y-1">
          <div className="text-2xs font-semibold uppercase text-text-muted">{i18n.t("chat:run_visual_diff.comparison")}</div>
          <ArtifactBody artifact={artifact} />
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
  return result ? <PendingActionResultCard details={<VisualDiffDetails context={context} />} omitJob result={result} /> : null
}

const runVisualDiffToolCard: ToolCardRenderer = { toolName: "run_visual_diff", collapsedSummary, renderExpanded }
export default runVisualDiffToolCard

const pendingResult = { pending_confirmation_id: 502, pending_action_id: 502, state: "pending", message: "Run a before/after visual comparison for JOB-4222?" }

export const examples: ToolCardExample[] = [
  { id: "pending", label: "Pending visual diff confirmation", input: { job_id: 4222 }, parsedResult: pendingResult, sourceType: "generic" },
  {
    id: "completed",
    label: "Completed before/after comparison",
    input: { job_id: 4222 },
    parsedResult: pendingResult,
    sourceType: "generic",
    livePendingAction: {
      id: 502,
      action: "run_visual_diff",
      state: "confirmed",
      label: "Run visual diff for JOB-4222",
      detail: "Before/after visual comparison completed.",
      execution_status: "applied",
      execution_step: "Applied.",
      outcome: {
        workflow_id: 61271,
        job_id: 4222,
        comparison: {
          type: "visual_diff_comparison",
          title: "Before/after visual comparison",
          renderer_type: "before_after_visual_diff",
          payload: { base_branch: "main", head_revision: "syrus/direct-4222", pairs: [] }
        }
      },
      app_confirm_path: "/api/v1/app/chats/7/pending_actions/502/confirm",
      app_reject_path: "/api/v1/app/chats/7/pending_actions/502/reject"
    }
  }
]
