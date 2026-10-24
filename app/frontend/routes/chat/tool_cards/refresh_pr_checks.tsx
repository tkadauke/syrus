import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, Row, SectionLabel, StatePill } from "../toolCardUi"
import { MarkdownPreview } from "../toolCardMarkdown"
import { stringFromInput, ToolFailureSummaryCard, toolFailureCollapsedSummary, toolFailureDetected, type ToolFailureConfig } from "../toolFailureSummaryCard"

type CheckRow = {
  key: string
  name: string
  provider: string | null
  conclusion: string | null
  detailsUrl: string | null
  summary: string | null
}

type RefreshCard = {
  jobId: string
  slug: string | null
  prNumber: string | null
  priorState: string | null
  currentState: string
  checkedAt: string | null
  headSha: string | null
  baseSha: string | null
  providers: string[]
  refreshedChecks: CheckRow[]
  failingChecks: CheckRow[]
}

const failureConfig: ToolFailureConfig = {
  title: "PR check refresh",
  attempted: (context) => {
    const jobId = stringFromInput(context, ["job_id"])
    return jobId ? `Refresh checks for JOB-${jobId}` : "Refresh PR checks"
  },
  retrySafety: "safe",
  recovery: "Retry after GitHub or the check provider recovers; verify the Job has a tracked PR if the error says no PR was found."
}

function stringsFromArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const label = displayValue(item)
    return label ? [label] : []
  })
}

function parseCheck(value: unknown, index: number): CheckRow | null {
  if (!isPlainObject(value)) {
    const name = displayValue(value)
    return name ? { key: `check-${name}-${index}`, name, provider: null, conclusion: null, detailsUrl: null, summary: null } : null
  }

  const name = displayValue(value.name) || displayValue(value.check_name)
  if (!name) return null

  const provider = displayValue(value.provider) || displayValue(value.provider_name) || displayValue(value.app_slug) || displayValue(value.app)
  const conclusion = displayValue(value.conclusion) || displayValue(value.status)
  const detailsUrl = safeHttpUrl(displayValue(value.details_url) || displayValue(value.html_url) || displayValue(value.url))

  return {
    key: `${provider || "check"}-${name}-${index}`,
    name,
    provider,
    conclusion,
    detailsUrl,
    summary: displayValue(value.summary) || displayValue(value.message)
  }
}

function safeHttpUrl(value: string | null): string | null {
  if (!value) return null
  try {
    const url = new URL(value)
    return url.protocol === "http:" || url.protocol === "https:" ? url.toString() : null
  } catch {
    return null
  }
}

function checksFromArray(value: unknown): CheckRow[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((check, index) => {
    const row = parseCheck(check, index)
    return row ? [row] : []
  })
}

function parseRefresh(context: ToolCardContext): RefreshCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const jobId = displayValue(parsed.job_id)
  const currentState = displayValue(parsed.pr_checks_state) || displayValue(parsed.current_pr_checks_state) || displayValue(parsed.current_state)
  if (!jobId || !currentState) return null

  const failingChecks = checksFromArray(parsed.failing_checks)
  const refreshedChecks = checksFromArray(parsed.refreshed_checks ?? parsed.check_names ?? parsed.checks)

  const providerCandidates = [
    ...stringsFromArray(parsed.refreshed_providers),
    ...stringsFromArray(parsed.providers),
    ...refreshedChecks.flatMap((check) => (check.provider ? [check.provider] : [])),
    ...failingChecks.flatMap((check) => (check.provider ? [check.provider] : []))
  ]

  return {
    jobId,
    slug: displayValue(parsed.slug),
    prNumber: displayValue(parsed.pr_number),
    priorState: displayValue(parsed.previous_pr_checks_state) || displayValue(parsed.prior_pr_checks_state) || displayValue(parsed.previous_state),
    currentState,
    checkedAt: displayValue(parsed.pr_checks_checked_at) || displayValue(parsed.refreshed_at),
    headSha: displayValue(parsed.head_sha),
    baseSha: displayValue(parsed.base_sha),
    providers: Array.from(new Set(providerCandidates)),
    refreshedChecks,
    failingChecks
  }
}

function targetLabel(card: RefreshCard) {
  const target = card.slug ? `JOB-${card.jobId} (${card.slug})` : `JOB-${card.jobId}`
  return card.prNumber ? `${target} PR #${card.prNumber}` : target
}

function succeeded(card: RefreshCard) {
  return card.currentState !== "unknown"
}

function collapsedSummary(context: ToolCardContext) {
  const failureSummary = toolFailureCollapsedSummary(context, failureConfig)
  if (failureSummary) return failureSummary

  const card = parseRefresh(context)
  if (!card) return null

  return `${targetLabel(card)} checks ${succeeded(card) ? "refreshed" : "not refreshed"}: ${card.currentState}`
}

function NextActionHint({ card }: { card: RefreshCard }) {
  if (card.currentState === "failing")
    return <div className="text-text-secondary">Next: inspect the failing checks before rerunning CI repair or marking the repair no-op.</div>
  if (card.currentState === "pending")
    return <div className="text-text-secondary">Next: wait for checks to finish, then refresh again before taking repair action.</div>
  if (card.currentState === "passing") return <div className="text-text-secondary">Next: continue mergeability or landing checks.</div>
  return <div className="text-text-secondary">Next: verify the PR and provider state, then refresh again if the result still looks incomplete.</div>
}

const CHECK_NAME_WRAP_CLASS = "min-w-0 break-words [overflow-wrap:anywhere]"

function CheckList({ checks }: { checks: CheckRow[] }) {
  return (
    <ul className="space-y-1">
      {checks.map((check) => (
        <li className="rounded border border-border bg-surface px-2 py-1" key={check.key}>
          <div className="flex min-w-0 flex-wrap items-center gap-1">
            {check.detailsUrl ? (
              <a
                className={`${CHECK_NAME_WRAP_CLASS} font-mono font-medium text-brand hover:underline dark:text-brand-emphasis`}
                href={check.detailsUrl}
                rel="noreferrer"
                target="_blank"
              >
                {check.name}
              </a>
            ) : (
              <span className={`${CHECK_NAME_WRAP_CLASS} font-mono font-medium text-text-primary`}>{check.name}</span>
            )}
            {check.provider ? <Badge>{check.provider}</Badge> : null}
            {check.conclusion ? <StatePill state={check.conclusion} /> : null}
          </div>
          {check.summary ? (
            <div className="mt-1">
              <MarkdownPreview maxLines={3} modalLabel={`Full summary for ${check.name}`} text={check.summary} />
            </div>
          ) : null}
        </li>
      ))}
    </ul>
  )
}

function githubRepositoryUrl(checks: CheckRow[]) {
  for (const check of checks) {
    if (!check.detailsUrl) continue
    const url = new URL(check.detailsUrl)
    const segments = url.pathname.split("/").filter(Boolean)
    if (url.hostname.toLowerCase() === "github.com" && segments.length >= 2) return `${url.origin}/${segments[0]}/${segments[1]}`
  }
  return null
}

function ShaRow({ label, sha, repositoryUrl }: { label: string; sha: string; repositoryUrl: string | null }) {
  const shortSha = sha.slice(0, 12)
  return (
    <div className="min-w-0">
      <SectionLabel>{label}</SectionLabel>
      <EntityReference
        href={repositoryUrl ? `${repositoryUrl}/commit/${encodeURIComponent(sha)}` : null}
        id={shortSha}
        kind="commit"
        label={shortSha}
        slug={sha}
      />
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  if (toolFailureDetected(context)) return <ToolFailureSummaryCard config={failureConfig} context={context} />

  const card = parseRefresh(context)
  if (!card) return null
  const repositoryUrl = githubRepositoryUrl([...card.refreshedChecks, ...card.failingChecks])

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={card.jobId} kind="job" label={`JOB-${card.jobId}`} slug={card.slug} />
        {card.slug ? <span className="min-w-0 break-words font-mono text-text-secondary [overflow-wrap:anywhere]">({card.slug})</span> : null}
        {card.prNumber ? (
          <EntityReference id={card.prNumber} kind="pull_request" prUrl={repositoryUrl ? `${repositoryUrl}/pull/${card.prNumber}` : null} />
        ) : null}
        <StatePill state={card.currentState} tone={succeeded(card) ? undefined : "warning"} />
      </div>

      <dl className="grid gap-1 sm:grid-cols-2">
        {card.priorState ? <Row label="Prior state" value={card.priorState} /> : null}
        <Row label="Current state" value={card.currentState} />
        {card.headSha ? <ShaRow label="Head SHA" repositoryUrl={repositoryUrl} sha={card.headSha} /> : null}
        {card.baseSha ? <ShaRow label="Base SHA" repositoryUrl={repositoryUrl} sha={card.baseSha} /> : null}
        {card.checkedAt ? <Row label="Refreshed at" value={card.checkedAt} /> : null}
      </dl>

      {card.providers.length > 0 ? (
        <div className="space-y-1">
          <SectionLabel>Refreshed providers</SectionLabel>
          <div className="flex flex-wrap gap-1">
            {card.providers.map((provider) => (
              <Badge key={`provider-${provider}`}>{provider}</Badge>
            ))}
          </div>
        </div>
      ) : null}

      {card.refreshedChecks.length > 0 ? (
        <div className="space-y-1">
          <SectionLabel>Refreshed checks</SectionLabel>
          <CheckList checks={card.refreshedChecks} />
        </div>
      ) : (
        <EmptyState>No refreshed checks reported.</EmptyState>
      )}

      {card.failingChecks.length > 0 ? (
        <div className="space-y-1">
          <SectionLabel>Failing checks</SectionLabel>
          <CheckList checks={card.failingChecks} />
        </div>
      ) : (
        <EmptyState>No failing checks reported.</EmptyState>
      )}

      <div>
        <SectionLabel>Next action</SectionLabel>
        <NextActionHint card={card} />
      </div>
    </CardShell>
  )
}

const refreshPrChecksToolCard: ToolCardRenderer = {
  toolName: "refresh_pr_checks",
  collapsedSummary,
  renderExpanded
}

export default refreshPrChecksToolCard

export const examples: ToolCardExample[] = [
  {
    id: "successful_refresh",
    label: "Successful refresh with failing checks",
    input: { job_id: 42 },
    parsedResult: {
      job_id: 42,
      slug: "add-refresh-card",
      pr_number: 314,
      previous_pr_checks_state: "pending",
      pr_checks_state: "failing",
      pr_checks_checked_at: "2026-10-01T15:45:12Z",
      head_sha: "abc1234567890000000000000000000000000000",
      base_sha: "def1234567890000000000000000000000000000",
      refreshed_providers: ["GitHub Actions"],
      refreshed_checks: [
        { name: "rspec", provider: "GitHub Actions", conclusion: "failure", details_url: "https://github.com/acme/widgets/actions/runs/1" },
        { name: "frontend-lint", provider: "GitHub Actions", conclusion: "success", details_url: "https://github.com/acme/widgets/actions/runs/2" }
      ],
      failing_checks: [
        {
          name: "rspec",
          provider: "GitHub Actions",
          conclusion: "failure",
          summary: "1 example failed",
          details_url: "https://github.com/acme/widgets/actions/runs/1"
        }
      ]
    }
  },
  {
    id: "already_current",
    label: "No-op, already current",
    input: { job_id: 43 },
    parsedResult: {
      job_id: 43,
      slug: "green-pr",
      pr_number: 315,
      previous_pr_checks_state: "passing",
      pr_checks_state: "passing",
      refreshed_providers: ["GitHub Actions"],
      refreshed_checks: [
        { name: "rspec", provider: "GitHub Actions", conclusion: "success", details_url: "https://github.com/acme/widgets/actions/runs/3" },
        { name: "frontend-lint", provider: "GitHub Actions", conclusion: "success", details_url: "https://github.com/acme/widgets/actions/runs/4" }
      ],
      failing_checks: []
    }
  },
  {
    id: "missing_pr",
    label: "Missing PR",
    input: { job_id: 44 },
    resultBody: "Job has no tracked PR.",
    resultError: true
  },
  {
    id: "provider_failure",
    label: "Provider/check failure",
    input: { job_id: 45 },
    resultBody: "Error: Timed out fetching check runs.",
    resultError: true
  }
]
