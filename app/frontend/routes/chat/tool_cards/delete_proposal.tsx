import i18n from "@app/i18n"
import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { CardShell, displayValue, EntityReference, SectionLabel, StatePill } from "../toolCardUi"
import { parseProposalOutcome, type ProposalOutcome } from "../proposalToolCard"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

// Core-owned tool card for delete_proposal (the pending-action tool-card work). Shows the
// withdrawn slug plus any cascade of downstream proposals withdrawn with it
// (delete_proposal_tool.rb's `cascade`).
type DeleteProposalResult = { slug: string; state: string; cascade: ProposalOutcome[] }

const failureConfig: ToolFailureConfig = {
  title: i18n.t("chat:tool_card_proposal_withdrawal"),
  attempted: (context) => {
    const slug = stringFromInput(context, ["slug"])
    return slug ? i18n.t("chat:tool_card_withdraw_proposal_named", { slug }) : i18n.t("chat:tool_card_withdraw_proposal")
  },
  retrySafety: "caution",
  recovery: i18n.t("chat:tool_card_withdraw_proposal_recovery")
}

function parseDeleteProposal(context: ToolCardContext): DeleteProposalResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  const slug = displayValue(parsed.slug)
  const state = displayValue(parsed.state)
  if (!slug || !state) return null

  const cascade = Array.isArray(parsed.cascade)
    ? parsed.cascade.flatMap((item) => {
        const proposal = parseProposalOutcome(item)
        return proposal ? [proposal] : []
      })
    : []

  return { slug, state, cascade }
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const result = parseDeleteProposal(context)
  if (!result) return null
  return result.cascade.length > 0
    ? i18n.t("chat:tool_card_withdrew_proposal_with_cascade", { slug: result.slug, count: result.cascade.length })
    : i18n.t("chat:tool_card_withdrew_proposal", { slug: result.slug })
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const result = parseDeleteProposal(context)
  if (!result) return null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.state} />
        <EntityReference kind="proposal" slug={result.slug} />
      </div>
      {result.cascade.length > 0 ? (
        <div>
          <SectionLabel>{i18n.t("chat:tool_card_also_withdrawn", { count: result.cascade.length })}</SectionLabel>
          <ul className="mt-1 min-w-0 divide-y divide-border overflow-hidden rounded border border-border bg-surface">
            {result.cascade.map((proposal) => (
              <li className="grid min-w-0 gap-2 px-3 py-2 sm:grid-cols-[minmax(9rem,0.8fr)_minmax(12rem,1.4fr)_auto] sm:items-center" key={proposal.slug}>
                <div className="flex min-w-0 flex-wrap items-center gap-2">
                  <EntityReference kind="proposal" slug={proposal.slug} />
                  <StatePill state={proposal.state} />
                </div>
                <div className="min-w-0 break-words text-sm font-medium text-text-primary [overflow-wrap:anywhere]">{proposal.title || "—"}</div>
                <div className="min-w-0 break-words text-xs text-text-muted [overflow-wrap:anywhere]">{proposal.kind.replace(/_/g, " ")}</div>
              </li>
            ))}
          </ul>
        </div>
      ) : null}
    </CardShell>
  )
}

export const examples: ToolCardExample[] = [
  {
    id: "cascade",
    label: i18n.t("chat:tool_card_withdraw_proposal_example_cascade"),
    input: { slug: "shared-card-primitives" },
    parsedResult: {
      slug: "shared-card-primitives",
      state: "withdrawn",
      cascade: [
        { slug: "proposal-list-card", title: "Render proposal lists", kind: "job", state: "withdrawn" },
        { slug: "proposal-card-suite", title: "Complete the proposal card suite", kind: "epic", state: "withdrawn" }
      ]
    }
  },
  {
    id: "no_cascade",
    label: i18n.t("chat:tool_card_withdraw_proposal_example_empty"),
    input: { slug: "standalone-proposal" },
    parsedResult: { slug: "standalone-proposal", state: "withdrawn", cascade: [] }
  },
  {
    id: "unknown_slug",
    label: i18n.t("chat:tool_card_withdraw_proposal_example_error"),
    input: { slug: "missing-proposal" },
    resultBody: "Error: unknown proposal slug: missing-proposal",
    resultError: true
  }
]

const deleteProposalToolCard: ToolCardRenderer = {
  toolName: "delete_proposal",
  collapsedSummary,
  renderExpanded
}

export default deleteProposalToolCard
