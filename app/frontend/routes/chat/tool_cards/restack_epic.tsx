import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, SectionLabel, StatePill } from "../toolCardUi"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type PlanNode = {
  jobId: string
  slug: string | null
  state: string | null
  branchName: string | null
  currentBase: string | null
  targetBase: string | null
  targetParentJobId: string | null
  currentParentJobId: string | null
  prNumber: string | null
  commitsBehind: string | null
  checksState: string | null
  mergeableState: string | null
  repairReasons: string[]
  reason: string | null
}

type RestackPlan = {
  epicId: string
  slug: string | null
  repositorySlug: string | null
  strategy: string | null
  branchOrder: PlanNode[]
  actions: PlanNode[]
  skippedNodes: PlanNode[]
  expectedLandingImpact: string | null
}

type RestackCard = {
  kind: "dry_run" | "no_op" | "pending"
  state: string
  plan: RestackPlan | null
  pendingActionId: string | null
  reason: string | null
  message: string | null
  repositorySlug: string | null
}

const failureConfig: ToolFailureConfig = {
  title: "Restack epic",
  attempted: (context) => {
    const epicId = stringFromInput(context, ["epic_id"])
    return epicId ? `Restack EPIC-${epicId}` : "Restack epic"
  },
  retrySafety: "caution",
  recovery: "Resolve the reported Epic, permission, topology, or active-workflow problem, then request the restack again."
}

function stringList(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const text = displayValue(item)
    return text ? [text] : []
  })
}

function parseNode(value: unknown): PlanNode | null {
  if (!isPlainObject(value)) return null
  const jobId = displayValue(value.job_id)
  if (!jobId) return null

  return {
    jobId,
    slug: displayValue(value.slug),
    state: displayValue(value.state),
    branchName: displayValue(value.branch_name),
    currentBase: displayValue(value.current_base),
    targetBase: displayValue(value.target_base),
    targetParentJobId: displayValue(value.target_parent_job_id),
    currentParentJobId: displayValue(value.current_parent_job_id),
    prNumber: displayValue(value.pr_number),
    commitsBehind: displayValue(value.commits_behind),
    checksState: displayValue(value.checks_state),
    mergeableState: displayValue(value.mergeable_state),
    repairReasons: stringList(value.repair_reasons),
    reason: displayValue(value.reason)
  }
}

function parseNodes(value: unknown): PlanNode[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const node = parseNode(item)
    return node ? [node] : []
  })
}

function parsePlan(value: unknown): RestackPlan | null {
  if (!isPlainObject(value)) return null
  const epicId = displayValue(value.epic_id)
  if (!epicId) return null

  return {
    epicId,
    slug: displayValue(value.slug),
    repositorySlug: displayValue(value.repository_slug),
    strategy: displayValue(value.strategy),
    branchOrder: parseNodes(value.branch_order),
    actions: parseNodes(value.actions),
    skippedNodes: parseNodes(value.skipped_nodes),
    expectedLandingImpact: displayValue(value.expected_landing_impact)
  }
}

function parseRestack(context: ToolCardContext): RestackCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const plan = parsePlan(parsed.plan)
  const pendingActionId = displayValue(parsed.pending_action_id) || displayValue(parsed.pending_confirmation_id)
  const live = pendingActionId && displayValue(context.livePendingAction?.id) === pendingActionId ? context.livePendingAction : null
  if (!plan && !pendingActionId) return null

  const noOp = parsed.no_op === true
  const inputDryRun = context.input?.dry_run === true
  return {
    kind: pendingActionId ? "pending" : noOp ? "no_op" : "dry_run",
    state: live?.state || displayValue(parsed.state) || (noOp ? "no_op" : inputDryRun || plan ? "dry_run" : "pending"),
    plan,
    pendingActionId,
    reason: live?.reason || displayValue(parsed.reason) || displayValue(context.input?.reason),
    message: displayValue(parsed.message),
    repositorySlug: plan?.repositorySlug || displayValue(parsed.repository_slug)
  }
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const card = parseRestack(context)
  if (!card) return null

  const epicId = card.plan?.epicId || stringFromInput(context, ["epic_id"])
  const label = epicId ? `EPIC-${epicId}` : "Epic"
  if (card.kind === "pending") return `Restack ${label} · ${card.state.replace(/_/g, " ")}`
  if (card.kind === "no_op") return `Restack ${label} · nothing to do`
  const count = card.plan?.actions.length ?? 0
  return `Restack ${label} · dry run · ${count} ${count === 1 ? "action" : "actions"}`
}

function Detail({ label, value, mono = false }: { label: string; value: string | null; mono?: boolean }) {
  if (!value) return null
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <div className={`${mono ? "font-mono" : ""} break-words text-xs text-text-secondary [overflow-wrap:anywhere]`}>{value}</div>
    </div>
  )
}

function NodeIdentity({ node, repositorySlug }: { node: PlanNode; repositorySlug: string | null }) {
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-2">
      <EntityReference id={node.jobId} kind="job" label={`JOB-${node.jobId}`} slug={node.slug} />
      {node.slug ? <span className="break-words text-xs text-text-secondary [overflow-wrap:anywhere]">{node.slug}</span> : null}
      {node.prNumber ? (
        <EntityReference id={node.prNumber} kind="pull_request" prUrl={repositorySlug ? `https://github.com/${repositorySlug}/pull/${node.prNumber}` : null} />
      ) : null}
      {node.state ? <StatePill state={node.state} /> : null}
    </div>
  )
}

function BranchNode({ index, node, repositorySlug }: { index: number; node: PlanNode; repositorySlug: string | null }) {
  return (
    <li className="min-w-0 rounded border border-border bg-surface p-2">
      <div className="flex min-w-0 items-start gap-2">
        <Badge>{index + 1}</Badge>
        <div className="min-w-0 flex-1 space-y-2">
          <NodeIdentity node={node} repositorySlug={repositorySlug} />
          {node.branchName ? <div className="break-all font-mono text-xs text-text-primary [overflow-wrap:anywhere]">{node.branchName}</div> : null}
          <div className="grid min-w-0 gap-2 sm:grid-cols-2">
            <Detail
              label="Base movement"
              mono
              value={node.currentBase && node.targetBase ? `${node.currentBase} → ${node.targetBase}` : node.targetBase || node.currentBase}
            />
            <Detail label="Commits behind" mono value={node.commitsBehind} />
            <Detail label="Checks" value={node.checksState} />
            <Detail label="Mergeability" value={node.mergeableState} />
            {node.targetParentJobId ? (
              <div>
                <SectionLabel>Target parent</SectionLabel>
                <EntityReference id={node.targetParentJobId} kind="job" />
              </div>
            ) : null}
            {node.currentParentJobId ? (
              <div>
                <SectionLabel>Current parent</SectionLabel>
                <EntityReference id={node.currentParentJobId} kind="job" />
              </div>
            ) : null}
          </div>
          {node.repairReasons.length > 0 ? (
            <div className="flex min-w-0 flex-wrap gap-1">
              {node.repairReasons.map((reason) => (
                <Badge key={reason}>{reason.replace(/_/g, " ")}</Badge>
              ))}
            </div>
          ) : null}
        </div>
      </div>
    </li>
  )
}

function OutcomeNode({ node, repositorySlug }: { node: PlanNode; repositorySlug: string | null }) {
  return (
    <li className="min-w-0 rounded border border-border bg-surface p-2">
      <NodeIdentity node={node} repositorySlug={repositorySlug} />
      {node.branchName ? <div className="mt-1 break-all font-mono text-xs text-text-secondary [overflow-wrap:anywhere]">{node.branchName}</div> : null}
      {node.reason ? <MarkdownPreview maxLines={3} text={node.reason} /> : null}
      {node.repairReasons.length > 0 ? (
        <MarkdownPreview maxLines={3} text={node.repairReasons.map((reason) => `- ${reason.replace(/_/g, " ")}`).join("\n")} />
      ) : null}
    </li>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const card = parseRestack(context)
  if (!card) return null
  const epicId = card.plan?.epicId || displayValue(context.input?.epic_id)

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <span className="font-semibold text-text-primary">Restack epic</span>
        {epicId ? <EntityReference id={epicId} kind="epic" label={`EPIC-${epicId}`} slug={card.plan?.slug} /> : null}
        {card.plan?.slug ? <span className="break-words text-xs text-text-secondary [overflow-wrap:anywhere]">{card.plan.slug}</span> : null}
        <StatePill state={card.state} />
        {card.kind === "pending" && card.pendingActionId ? <Badge>pending #{card.pendingActionId}</Badge> : null}
      </div>

      {card.plan?.strategy ? <Detail label="Strategy" mono value={card.plan.strategy.replace(/_/g, " ")} /> : null}
      {card.reason ? <MarkdownPreview maxLines={4} text={card.reason} title="Reason" /> : null}
      {card.message ? <MarkdownPreview maxLines={4} text={card.message} title="Message" /> : null}

      {card.kind === "pending" && !card.plan ? (
        <EmptyState>The restack is waiting for operator confirmation. Its full plan is stored with the pending action.</EmptyState>
      ) : null}
      {card.kind === "no_op" && !card.message ? <EmptyState>No open child PR branches need restacking.</EmptyState> : null}

      {card.plan?.branchOrder.length ? (
        <section className="min-w-0">
          <SectionLabel>Branch order</SectionLabel>
          <ol className="mt-1 min-w-0 space-y-2 overflow-hidden">
            {card.plan.branchOrder.map((node, index) => (
              <BranchNode index={index} key={node.jobId} node={node} repositorySlug={card.repositorySlug} />
            ))}
          </ol>
        </section>
      ) : null}

      {card.plan?.actions.length ? (
        <section className="min-w-0">
          <SectionLabel>Actions</SectionLabel>
          <ul className="mt-1 min-w-0 space-y-2 overflow-hidden">
            {card.plan.actions.map((node) => (
              <OutcomeNode key={node.jobId} node={node} repositorySlug={card.repositorySlug} />
            ))}
          </ul>
        </section>
      ) : null}

      {card.plan?.skippedNodes.length ? (
        <section className="min-w-0">
          <SectionLabel>Skipped nodes</SectionLabel>
          <ul className="mt-1 min-w-0 space-y-2 overflow-hidden">
            {card.plan.skippedNodes.map((node) => (
              <OutcomeNode key={node.jobId} node={node} repositorySlug={card.repositorySlug} />
            ))}
          </ul>
        </section>
      ) : null}

      {card.plan?.expectedLandingImpact ? <MarkdownPreview maxLines={4} text={card.plan.expectedLandingImpact} title="Expected landing impact" /> : null}
    </CardShell>
  )
}

const restackEpicToolCard: ToolCardRenderer = { toolName: "restack_epic", collapsedSummary, renderExpanded }

export default restackEpicToolCard

const examplePlan = {
  epic_id: 91,
  slug: "stacked-delivery",
  repository_slug: "tkadauke/syrus",
  strategy: "dependency_topology",
  branch_order: [
    {
      job_id: 501,
      slug: "root-change",
      state: "approved",
      branch_name: "syrus/direct-501-with-a-long-descriptive-branch-name",
      current_base: "main",
      target_base: "main",
      target_parent_job_id: null,
      pr_number: 71,
      commits_behind: 0,
      checks_state: "success",
      mergeable_state: "clean",
      current_parent_job_id: null,
      repair_reasons: []
    },
    {
      job_id: 502,
      slug: "child-change",
      state: "approved",
      branch_name: "syrus/direct-502",
      current_base: "main",
      target_base: "syrus/direct-501-with-a-long-descriptive-branch-name",
      target_parent_job_id: 501,
      pr_number: 72,
      commits_behind: 3,
      checks_state: "pending",
      mergeable_state: "clean",
      current_parent_job_id: null,
      repair_reasons: ["parent_metadata", "base_ref", "behind_base"]
    }
  ],
  actions: [
    {
      job_id: 502,
      slug: "child-change",
      state: "approved",
      branch_name: "syrus/direct-502",
      pr_number: 72,
      repair_reasons: ["parent_metadata", "base_ref", "behind_base"]
    }
  ],
  skipped_nodes: [{ job_id: 503, slug: "closed-change", state: "closed", branch_name: "syrus/direct-503", pr_number: 73, reason: "closed" }],
  expected_landing_impact: "Updates stack parents and dispatches **one rebase root**."
}

export const examples: ToolCardExample[] = [
  {
    id: "dry_run",
    label: "Dry-run restack plan",
    input: { epic_id: 91, dry_run: true },
    parsedResult: { plan: examplePlan }
  },
  {
    id: "nothing_to_do",
    label: "Nothing to restack",
    input: { epic_id: 91, reason: "Verify the stack." },
    parsedResult: {
      plan: { ...examplePlan, actions: [], expected_landing_impact: "No open child PR branches need restacking." },
      no_op: true,
      message: "No open child PR branches need restacking."
    }
  },
  {
    id: "pending",
    label: "Pending operator confirmation",
    input: { epic_id: 91, reason: "Repair **stack topology**." },
    parsedResult: { pending_action_id: 812, pending_confirmation_id: 812, state: "pending", message: "Restack stacked-delivery? Actionable repairs: 1." }
  },
  {
    id: "error",
    label: "Structured tool error",
    input: { epic_id: 999 },
    parsedResult: { error: "epic not found: 999", code: "invalid_request" },
    resultError: true
  }
]
