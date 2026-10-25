import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, Row, SectionLabel, StatePill } from "../toolCardUi"
import { MarkdownPreview } from "../toolCardMarkdown"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type PlanNode = {
  jobId: string
  slug: string | null
  state: string | null
  branchName: string | null
  currentBase: string | null
  targetBase: string | null
  targetParentJobId: string | null
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
  strategy: string | null
  repositorySlug: string | null
  branchOrder: PlanNode[]
  actions: PlanNode[]
  skippedNodes: PlanNode[]
  expectedLandingImpact: string | null
}

type RestackCard = {
  plan: RestackPlan
  state: string
  pendingActionId: string | null
  reason: string | null
  message: string | null
  noOp: boolean
  dryRun: boolean
  executionError: string | null
}

const failureConfig: ToolFailureConfig = {
  title: "Restack Epic",
  attempted: (context) => {
    const epicId = stringFromInput(context, ["epic_id"])
    return epicId ? `Restack EPIC-${epicId}` : "Restack Epic"
  },
  retrySafety: "caution",
  recovery: "Resolve the reported Epic, dependency, branch, or permission error, then preview the restack again before requesting it."
}

function stringList(value: unknown) {
  return Array.isArray(value) ? value.map(displayValue).filter((item): item is string => Boolean(item)) : []
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
    prNumber: displayValue(value.pr_number),
    commitsBehind: displayValue(value.commits_behind),
    checksState: displayValue(value.checks_state),
    mergeableState: displayValue(value.mergeable_state),
    repairReasons: stringList(value.repair_reasons),
    reason: displayValue(value.reason)
  }
}

function parseNodes(value: unknown) {
  return Array.isArray(value) ? value.flatMap((item) => parseNode(item) ?? []) : []
}

function parseCard(context: ToolCardContext): RestackCard | null {
  const result = context.parsedResult
  if (!isPlainObject(result) || !isPlainObject(result.plan)) return null
  const plan = result.plan
  const epicId = displayValue(plan.epic_id)
  if (!epicId) return null
  const pendingActionId = displayValue(result.pending_action_id) || displayValue(result.pending_confirmation_id)
  const live = pendingActionId && displayValue(context.livePendingAction?.id) === pendingActionId ? context.livePendingAction : null
  const dryRun = context.input?.dry_run === true
  return {
    plan: {
      epicId,
      slug: displayValue(plan.slug),
      strategy: displayValue(plan.strategy),
      repositorySlug: displayValue(plan.repository_slug),
      branchOrder: parseNodes(plan.branch_order),
      actions: parseNodes(plan.actions),
      skippedNodes: parseNodes(plan.skipped_nodes),
      expectedLandingImpact: displayValue(plan.expected_landing_impact)
    },
    state: live?.state || displayValue(result.state) || (dryRun ? "planned" : "pending"),
    pendingActionId,
    reason: live?.reason || displayValue(result.reason) || displayValue(context.input?.reason),
    message: displayValue(result.message),
    noOp: result.no_op === true,
    dryRun,
    executionError: displayValue(live?.execution_error) || displayValue(result.execution_error)
  }
}

function epicLabel(plan: RestackPlan) {
  return plan.slug ? `EPIC-${plan.epicId} (${plan.slug})` : `EPIC-${plan.epicId}`
}

function collapsedSummary(context: ToolCardContext) {
  const failure = toolFailureCollapsedSummary(context, failureConfig)
  if (failure) return failure
  const card = parseCard(context)
  if (!card) return null
  const mode = card.noOp ? "nothing to do" : card.dryRun ? "dry-run plan" : card.state === "pending" ? "pending confirmation" : card.state.replace(/_/g, " ")
  return `Restack ${epicLabel(card.plan)} · ${mode} · ${card.plan.branchOrder.length} branches · ${card.plan.skippedNodes.length} skipped`
}

function BranchValue({ repositorySlug, value }: { repositorySlug: string | null; value: string }) {
  const encoded = value.split("/").map(encodeURIComponent).join("/")
  const href = repositorySlug ? `https://github.com/${repositorySlug}/tree/${encoded}` : null
  const className = "inline-flex min-h-11 max-w-full min-w-0 items-center break-all font-mono text-xs sm:min-h-7 [overflow-wrap:anywhere]"
  if (!href) return <span className={className}>{value}</span>
  return (
    <a className={`${className} text-brand hover:underline`} href={href} rel="noreferrer" target="_blank">
      {value}
    </a>
  )
}

function NodeHeader({ node, repositorySlug }: { node: PlanNode; repositorySlug: string | null }) {
  const prUrl = repositorySlug && node.prNumber ? `https://github.com/${repositorySlug}/pull/${node.prNumber}` : null
  return (
    <div className="flex min-w-0 flex-wrap items-center gap-2">
      <EntityReference id={node.jobId} kind="job" label={node.slug ? `JOB-${node.jobId} (${node.slug})` : null} slug={node.slug} touchTarget />
      {node.prNumber ? <EntityReference id={node.prNumber} kind="pull_request" prUrl={prUrl} touchTarget /> : null}
      {node.state ? <StatePill state={node.state} /> : null}
    </div>
  )
}

function BranchNode({ index, node, repositorySlug }: { index: number; node: PlanNode; repositorySlug: string | null }) {
  return (
    <li className="min-w-0 rounded border border-border bg-surface p-2">
      <div className="flex min-w-0 items-start gap-2">
        <Badge>{index + 1}</Badge>
        <div className="min-w-0 flex-1">
          <NodeHeader node={node} repositorySlug={repositorySlug} />
          {node.branchName ? <BranchValue repositorySlug={repositorySlug} value={node.branchName} /> : null}
          <dl className="mt-1 grid min-w-0 gap-1 sm:grid-cols-2">
            {node.currentBase || node.targetBase ? <Row label="Base change" value={`${node.currentBase || "—"} → ${node.targetBase || "—"}`} /> : null}
            {node.targetParentJobId ? <Row label="Target parent" value={`JOB-${node.targetParentJobId}`} /> : null}
            {node.commitsBehind ? <Row label="Commits behind" value={node.commitsBehind} /> : null}
            {node.checksState ? <Row label="Checks" value={node.checksState} /> : null}
            {node.mergeableState ? <Row label="Mergeability" value={node.mergeableState} /> : null}
          </dl>
          {node.repairReasons.length ? (
            <div className="mt-2 flex flex-wrap gap-1">
              {node.repairReasons.map((reason) => (
                <Badge key={reason} wrap>
                  {reason}
                </Badge>
              ))}
            </div>
          ) : null}
        </div>
      </div>
    </li>
  )
}

function CompactNodes({ label, nodes, repositorySlug }: { label: string; nodes: PlanNode[]; repositorySlug: string | null }) {
  if (!nodes.length) return null
  return (
    <section>
      <SectionLabel>{label}</SectionLabel>
      <ul className="mt-1 space-y-1">
        {nodes.map((node) => (
          <li className="min-w-0 rounded border border-border bg-surface p-2" key={`${label}-${node.jobId}`}>
            <NodeHeader node={node} repositorySlug={repositorySlug} />
            {node.branchName ? <BranchValue repositorySlug={repositorySlug} value={node.branchName} /> : null}
            {node.reason ? <div className="mt-1 break-words text-text-secondary [overflow-wrap:anywhere]">{node.reason}</div> : null}
            {node.repairReasons.length ? (
              <div className="mt-1 flex flex-wrap gap-1">
                {node.repairReasons.map((reason) => (
                  <Badge key={reason} wrap>
                    {reason}
                  </Badge>
                ))}
              </div>
            ) : null}
          </li>
        ))}
      </ul>
    </section>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />
  const card = parseCard(context)
  if (!card) return null
  const { plan } = card
  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <EntityReference id={plan.epicId} kind="epic" label={epicLabel(plan)} slug={plan.slug} touchTarget />
        <StatePill state={card.noOp ? "no_op" : card.state} />
        <Badge>{card.dryRun ? "dry run" : "pending action"}</Badge>
        {plan.strategy ? <Badge wrap>{plan.strategy}</Badge> : null}
        {card.pendingActionId ? <Badge>pending #{card.pendingActionId}</Badge> : null}
      </div>
      {card.message ? <MarkdownPreview maxLines={3} modalLabel="Restack message" text={card.message} /> : null}
      {card.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <MarkdownPreview maxLines={3} modalLabel="Restack reason" text={card.reason} />
        </div>
      ) : null}
      {card.executionError ? <div className="break-words text-danger-text [overflow-wrap:anywhere]">{card.executionError}</div> : null}
      {plan.expectedLandingImpact ? (
        <div>
          <SectionLabel>Expected landing impact</SectionLabel>
          <MarkdownPreview maxLines={3} modalLabel="Expected landing impact" text={plan.expectedLandingImpact} />
        </div>
      ) : null}
      {card.noOp ? <EmptyState>{card.message || "No child branches need restacking."}</EmptyState> : null}
      {plan.branchOrder.length ? (
        <section>
          <SectionLabel>Branch order</SectionLabel>
          <ol className="mt-1 space-y-2">
            {plan.branchOrder.map((node, index) => (
              <BranchNode index={index} key={node.jobId} node={node} repositorySlug={plan.repositorySlug} />
            ))}
          </ol>
        </section>
      ) : (
        <EmptyState>No branches are in the restack plan.</EmptyState>
      )}
      <CompactNodes label="Actions" nodes={plan.actions} repositorySlug={plan.repositorySlug} />
      <CompactNodes label="Skipped nodes" nodes={plan.skippedNodes} repositorySlug={plan.repositorySlug} />
    </CardShell>
  )
}

const restackEpicToolCard: ToolCardRenderer = { toolName: "restack_epic", collapsedSummary, renderExpanded }
export default restackEpicToolCard

const plan = {
  epic_id: 91,
  slug: "stack-repair",
  strategy: "dependency_topology",
  repository_slug: "tkadauke/syrus",
  branch_order: [
    {
      job_id: 101,
      slug: "stack-root",
      branch_name: "syrus/stack-root-with-a-very-long-branch-name",
      current_base: "main",
      target_base: "main",
      pr_number: 501,
      commits_behind: 2,
      state: "approved",
      checks_state: "success",
      mergeable_state: "clean",
      repair_reasons: ["behind_base"]
    }
  ],
  actions: [
    {
      job_id: 101,
      slug: "stack-root",
      branch_name: "syrus/stack-root-with-a-very-long-branch-name",
      pr_number: 501,
      state: "approved",
      repair_reasons: ["behind_base"]
    }
  ],
  skipped_nodes: [{ job_id: 102, slug: "busy-child", branch_name: "syrus/busy-child", pr_number: 502, state: "running", reason: "active_rebase_workflow" }],
  expected_landing_impact: "Updates stack parents and dispatches **one rebase root**."
}

export const examples: ToolCardExample[] = [
  {
    id: "dry_run",
    label: "Dry-run plan",
    input: { epic_id: 91, reason: "Repair the stack.", strategy: "dependency_topology", dry_run: true },
    parsedResult: { plan }
  },
  {
    id: "no_op",
    label: "Nothing to restack",
    input: { epic_id: 91, dry_run: true },
    parsedResult: {
      plan: { ...plan, branch_order: [], actions: [], skipped_nodes: [], expected_landing_impact: "No open child PR branches need restacking." },
      no_op: true,
      message: "No open child PR branches need restacking."
    }
  },
  {
    id: "pending",
    label: "Pending confirmation",
    input: { epic_id: 91, reason: "Repair the stack." },
    parsedResult: { pending_action_id: 77, state: "pending", reason: "Repair the stack.", message: "Restack stack-repair?", plan }
  },
  {
    id: "live_confirmed",
    label: "Confirmed live action",
    input: { epic_id: 91 },
    parsedResult: { pending_action_id: 77, state: "pending", plan },
    livePendingAction: {
      id: 77,
      action: "restack_epic",
      state: "confirmed",
      label: "Restack Epic",
      detail: null,
      app_confirm_path: "/chats/1/pending_actions/77/confirm",
      app_reject_path: "/chats/1/pending_actions/77/reject"
    }
  },
  {
    id: "error",
    label: "Structured error",
    input: { epic_id: 404 },
    resultBody: JSON.stringify({ code: "invalid_params", message: "epic not found: 404" }),
    resultError: true
  }
]
