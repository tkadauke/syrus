import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { parseCancelCodingCheckoutOutcome, type CodingCheckoutSnapshot } from "../localModeJobOutcomeCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { CardShell, Disclosure, displayValue, EmptyState, EntityReference, Row, StatePill } from "../toolCardUi"
import i18n from "@app/i18n"

const DESTRUCTIVE_WARNING_CLASS =
  "rounded-[var(--radius-panel)] border border-warning-border bg-warning-surface px-3 py-2 text-sm font-semibold text-warning-text"

function snapshotValue(value: unknown): string {
  if (typeof value === "boolean") return value ? "true" : "false"
  if (Array.isArray(value))
    return value
      .map((item) => snapshotValue(item))
      .filter(Boolean)
      .join(", ")
  if (value && typeof value === "object") return JSON.stringify(value)
  return displayValue(value) || "—"
}

function Snapshot({ snapshot }: { snapshot: CodingCheckoutSnapshot | null }) {
  if (!snapshot) return <EmptyState>{i18n.t("chat:mutation_snapshot_unavailable")}</EmptyState>
  return (
    <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
      {Object.entries(snapshot).map(([key, value]) => (
        <Row key={key} label={key.replaceAll("_", " ")} value={snapshotValue(value)} wrap />
      ))}
    </dl>
  )
}

function collapsedSummary(context: ToolCardContext) {
  if (context.resultError) return i18n.t("chat:mutation_coding_mode_cancellation_failed")
  const result = parseCancelCodingCheckoutOutcome(context.parsedResult)
  return result?.message || (result ? i18n.t("chat:mutation_checkout_canceled_for", { repository: result.repositorySlug }) : null)
}

export const examples: ToolCardExample[] = [
  {
    id: "released_job",
    get label() {
      return i18n.t("chat:mutation_example_checkout_job_released")
    },
    input: { repository_id: 7 },
    parsedResult: {
      canceled: true,
      repository_id: 7,
      repository_slug: "tkadauke/syrus",
      released_job: { id: 4225, slug: "JOB-4225", state: "implemented", branch_name: "syrus/direct-4225-long-coding-branch" },
      before: {
        path: "/workspace/tkadauke/syrus",
        exists: true,
        current_branch: "syrus/direct-4225-long-coding-branch",
        dirty: true,
        committed_ahead_count: 2
      },
      after: { path: "/workspace/tkadauke/syrus", exists: true, current_branch: "main", dirty: false, committed_ahead_count: 0 },
      message: "JOB-4225 was detached from this Coding Mode chat. No code changes were preserved or applied by this operation."
    }
  },
  {
    id: "checkout_only",
    get label() {
      return i18n.t("chat:mutation_example_checkout_released")
    },
    parsedResult: {
      canceled: true,
      repository_id: 7,
      repository_slug: "tkadauke/syrus",
      released_job: null,
      before: { exists: true, current_branch: "local-experiment", dirty: false },
      after: { exists: true, current_branch: "main", dirty: false },
      message: "Coding Mode checkout canceled for this chat. No code changes were preserved or applied by this operation."
    }
  },
  {
    id: "error",
    get label() {
      return i18n.t("chat:mutation_example_cancellation_failed")
    },
    input: { repository_id: 7 },
    resultBody: "No active Coding Mode checkout.",
    resultError: true
  }
]

const cancelCodingCheckoutToolCard: ToolCardRenderer = {
  toolName: "cancel_coding_checkout",
  collapsedSummary,
  renderExpanded: (context) => {
    if (context.resultError) return <EmptyState>{displayValue(context.resultBody) || i18n.t("chat:mutation_checkout_could_not_cancel")}</EmptyState>
    const result = parseCancelCodingCheckoutOutcome(context.parsedResult)
    if (!result) return null
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="canceled" />
          <EntityReference kind="repository" repositoryId={result.repositoryId} repositorySlug={result.repositorySlug} slug={result.repositorySlug} />
        </div>
        {result.releasedJob ? (
          <div className="grid min-w-0 gap-1 sm:grid-cols-2">
            <div className="min-w-0">
              <div className="text-xs font-medium text-text-muted">{i18n.t("chat:mutation_released_job")}</div>
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <EntityReference id={result.releasedJob.id} kind="job" label={result.releasedJob.slug} />
                <StatePill state={result.releasedJob.state} />
              </div>
            </div>
            {result.releasedJob.branchName ? <Row copyable label={i18n.t("chat:shared.branch")} value={result.releasedJob.branchName} wrap /> : null}
          </div>
        ) : (
          <EmptyState>{i18n.t("chat:mutation_no_coding_job_attached")}</EmptyState>
        )}
        <div className={DESTRUCTIVE_WARNING_CLASS}>{i18n.t("chat:mutation_no_changes_preserved")}</div>
        {result.message ? <MarkdownPreview text={result.message} title={i18n.t("chat:shared.outcome")} /> : null}
        <Disclosure label={i18n.t("chat:mutation_before_after_checkout")}>
          <div className="grid min-w-0 gap-3 lg:grid-cols-2">
            <section className="min-w-0">
              <h4 className="mb-1 text-xs font-semibold text-text-muted">{i18n.t("chat:mutation_before")}</h4>
              <Snapshot snapshot={result.before} />
            </section>
            <section className="min-w-0">
              <h4 className="mb-1 text-xs font-semibold text-text-muted">{i18n.t("chat:mutation_after")}</h4>
              <Snapshot snapshot={result.after} />
            </section>
          </div>
        </Disclosure>
      </CardShell>
    )
  }
}

export default cancelCodingCheckoutToolCard
