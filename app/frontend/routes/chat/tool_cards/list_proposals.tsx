import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { MarkdownPreview } from "../toolCardMarkdown"
import { MaterializedOutcomeDetail, parseProposalOutcome, type ProposalOutcome } from "../proposalToolCard"
import { EmptyState, EntityReference, SectionLabel, StatePill } from "../toolCardUi"

const PROPOSAL_ROW_CLASS = [
  "min-w-0 space-y-3 px-3 py-3",
  "sm:grid sm:grid-cols-[minmax(8rem,0.8fr)_minmax(12rem,1.5fr)_minmax(10rem,1fr)]",
  "sm:gap-x-4 sm:gap-y-3 sm:space-y-0"
].join(" ")

function proposalRows(context: ToolCardContext): ProposalOutcome[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.proposals)) return null
  return parsed.proposals.flatMap((item) => {
    const proposal = parseProposalOutcome(item)
    return proposal ? [proposal] : []
  })
}

function errorMessage(context: ToolCardContext) {
  if (isPlainObject(context.parsedResult)) {
    const value = context.parsedResult.message ?? context.parsedResult.error
    if (typeof value === "string" && value.trim()) return value.trim()
  }
  return context.resultBody.trim() || i18n.t("chat:tool_card_list_proposals_error")
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultSettled === false) return i18n.t("chat:tool_card_list_proposals_pending")
  if (context.resultError) return i18n.t("chat:tool_card_list_proposals_failed")
  const rows = proposalRows(context)
  return rows ? i18n.t("chat:tool_card_list_proposals_summary", { count: rows.length }) : null
}

function LinkedValues({ proposal }: { proposal: ProposalOutcome }) {
  if (!(proposal.dependencies.length || proposal.jobDependencyIds.length || proposal.epicDependencyIds.length || proposal.dependencyRequirements.length))
    return <span className="text-text-subtle">—</span>
  return (
    <div className="min-w-0 space-y-1">
      <div className="flex min-w-0 flex-wrap gap-x-2 gap-y-1">
        {proposal.dependencies.map((slug) => (
          <EntityReference key={`proposal-${slug}`} kind="proposal" slug={slug} />
        ))}
        {proposal.jobDependencyIds.map((id) => (
          <EntityReference id={id} key={`job-${id}`} kind="job" />
        ))}
        {proposal.epicDependencyIds.map((id) => (
          <EntityReference id={id} key={`epic-${id}`} kind="epic" />
        ))}
      </div>
      {proposal.dependencyRequirements.map((requirement) => (
        <div className="min-w-0 break-words [overflow-wrap:anywhere]" key={`${requirement.target}-${requirement.mode}-${requirement.stage || "any"}`}>
          {requirement.target.startsWith("JOB-") ? (
            <EntityReference id={requirement.target.slice(4)} kind="job" />
          ) : (
            <EntityReference kind="proposal" slug={requirement.target} />
          )}{" "}
          · {requirement.mode.replace(/_/g, " ")}
          {requirement.stage ? `: ${requirement.stage}` : ""}
        </div>
      ))}
    </div>
  )
}

function ProposalRow({ context, proposal }: { context: ToolCardContext; proposal: ProposalOutcome }) {
  return (
    <li className={PROPOSAL_ROW_CLASS}>
      <div className="min-w-0 space-y-2">
        <div className="flex min-w-0 flex-wrap items-center gap-2">
          <EntityReference kind="proposal" slug={proposal.slug} />
          <StatePill state={proposal.state} />
        </div>
        <div className="break-words text-xs text-text-muted [overflow-wrap:anywhere]">{proposal.kind.replace(/_/g, " ")}</div>
      </div>
      <div className="min-w-0">
        <div className="mb-1 break-words text-sm font-medium text-text-primary [overflow-wrap:anywhere]">{proposal.title || "—"}</div>
        <MarkdownPreview
          emptyState={<span className="text-xs italic text-text-muted">{i18n.t("chat:no_description")}</span>}
          linkifySlugs
          linkifyUrls
          maxChars={360}
          maxLines={3}
          modalLabel={i18n.t("chat:tool_card_list_proposals_full_body", { title: proposal.title || proposal.slug })}
          onLinkClick={context.onLinkClick}
          text={proposal.body}
        />
      </div>
      <dl className="grid min-w-0 grid-cols-1 gap-2 text-xs">
        <div className="min-w-0">
          <SectionLabel>{i18n.t("chat:repository")}</SectionLabel>
          {proposal.repository ? <EntityReference kind="repository" repositoryId={proposal.repositoryId} repositorySlug={proposal.repository} /> : "—"}
        </div>
        <div className="min-w-0">
          <SectionLabel>{i18n.t("chat:proposal_dependencies")}</SectionLabel>
          <LinkedValues proposal={proposal} />
        </div>
        {proposal.targetEpicId || proposal.targetEpicLabel ? (
          <div className="min-w-0">
            <SectionLabel>{i18n.t("chat:target_epic")}</SectionLabel>
            {proposal.targetEpicId ? (
              <span className="flex min-w-0 flex-wrap items-baseline gap-x-1">
                <EntityReference id={proposal.targetEpicId} kind="epic" />
                {proposal.targetEpicLabel ? <span className="break-words [overflow-wrap:anywhere]">· {proposal.targetEpicLabel}</span> : null}
              </span>
            ) : (
              proposal.targetEpicLabel
            )}
          </div>
        ) : null}
        {proposal.materialized ? (
          <div className="min-w-0">
            <SectionLabel>{i18n.t("chat:tool_card_list_proposals_materialized")}</SectionLabel>
            <MaterializedOutcomeDetail materialized={proposal.materialized} />
          </div>
        ) : null}
      </dl>
    </li>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (context.resultSettled === false) return <EmptyState>{i18n.t("chat:tool_card_list_proposals_pending")}</EmptyState>
  if (context.resultError) return <EmptyState>{errorMessage(context)}</EmptyState>
  const rows = proposalRows(context)
  if (!rows) return null
  if (!rows.length) return <EmptyState>{i18n.t("chat:tool_card_list_proposals_empty")}</EmptyState>
  return (
    <ul className="mt-1 min-w-0 divide-y divide-border overflow-hidden rounded border border-border bg-surface">
      {rows.map((proposal) => (
        <ProposalRow context={context} key={proposal.slug} proposal={proposal} />
      ))}
    </ul>
  )
}

const listProposalsToolCard: ToolCardRenderer = {
  toolName: "list_proposals",
  renderWhilePending: true,
  collapsedSummary,
  renderExpanded,
  renderPending: renderExpanded
}
export default listProposalsToolCard

export const examples: ToolCardExample[] = [
  {
    id: "linked_materialized_proposals",
    label: i18n.t("chat:tool_card_list_proposals_example_mixed"),
    parsedResult: {
      proposals: [
        {
          slug: "fix-output",
          title: i18n.t("chat:tool_card_list_proposals_example_job"),
          body: "Render **all fields** and link JOB-12. See https://example.test/spec.",
          kind: "job",
          state: "confirmed",
          repository_id: 7,
          repository: "acme/widget",
          dependencies: ["card-primitives"],
          depends_on_proposal_slugs: ["card-primitives", "release-epic"],
          depends_on_job_ids: [12],
          dependency_requirements: [{ job_id: 18, satisfaction_mode: "deployed", required_deployment_stage_name: "production" }],
          target_epic: { id: 9, label: "UI polish" },
          materialized: { kind: "job", job_id: 44, job_title: "Fix output", job_state: "queued" }
        },
        {
          slug: "tier-2-cards",
          title: i18n.t("chat:tool_card_list_proposals_example_epic"),
          body: "Bundle the card work.",
          kind: "epic",
          state: "confirmed",
          repository_id: 7,
          repository: "acme/widget",
          depends_on_epic_ids: [3],
          materialized: { kind: "epic", epic_id: 10, child_jobs: [{ job_id: 45, title: "Add cards" }] }
        }
      ]
    }
  },
  {
    id: "no_proposals",
    label: i18n.t("chat:tool_card_list_proposals_example_empty"),
    description: i18n.t("chat:tool_card_list_proposals_example_empty_description"),
    parsedResult: { proposals: [] }
  },
  { id: "pending", label: i18n.t("chat:tool_card_list_proposals_pending"), resultBody: "", resultSettled: false },
  { id: "error", label: i18n.t("chat:tool_card_list_proposals_failed"), resultBody: "Unable to list proposals.", resultError: true }
]
