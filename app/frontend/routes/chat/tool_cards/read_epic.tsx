import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { StatusCard } from "../chatHelperToolCard"
import { MarkdownPreview } from "../toolCardMarkdown"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, InternalLink, Row, SectionLabel, StatePill } from "../toolCardUi"

type TruncatedText = { text: string; truncated: boolean; bytes: number | null; omittedBytes: number | null }
type DependencyBadge = { key: string; id: string; label: string; state: string | null; title: string | null }
type JobDependency = { key: string; id: string | null; label: string; detail: string | null }
type ChildJobRow = {
  key: string
  id: string
  jobId: string
  title: string
  state: string
  repository: string | null
  prNumber: string | null
  branch: string | null
  priority: string | null
  provider: string | null
  providerSetting: string | null
  closureReason: string | null
  landedSha: string | null
  issueBody: TruncatedText | null
  dependencies: JobDependency[]
}
type EpicCard = {
  id: string
  displayNumber: string
  title: string
  state: string
  repository: string | null
  githubIssueUrl: string | null
  description: TruncatedText | null
  autoApproveMode: string | null
  goalChatId: string | null
  goalPrompt: string | null
  maxCommitsBehind: string | null
  furthestBehindJob: { id: string; slug: string | null } | null
  dependsOnEpics: DependencyBadge[]
  dependentEpics: DependencyBadge[]
  childJobs: ChildJobRow[]
}

const WAIT_PILL_CLASS = [
  "inline-flex max-w-full flex-wrap items-center gap-1 rounded-full px-2 py-0.5 text-2xs",
  "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
].join(" ")

function safeHttpUrl(value: unknown) {
  const url = displayValue(value)
  if (!url) return null
  try {
    const parsed = new URL(url)
    return ["http:", "https:"].includes(parsed.protocol) ? parsed.toString() : null
  } catch {
    return null
  }
}

function githubRepositoryUrl(repository: string) {
  return `https://github.com/${repository.split("/").map(encodeURIComponent).join("/")}`
}

function truncatedText(value: unknown): TruncatedText | null {
  if (!isPlainObject(value) || typeof value.text !== "string") return null
  return {
    text: value.text,
    truncated: value.truncated === true,
    bytes: typeof value.bytes === "number" ? value.bytes : null,
    omittedBytes: typeof value.omitted_bytes === "number" ? value.omitted_bytes : null
  }
}

function epicDependencyBadges(value: unknown): DependencyBadge[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    if (!id) return []
    return [{ key: id, id, label: displayValue(item.display_number) || `EPIC-${id}`, state: displayValue(item.state), title: displayValue(item.title) }]
  })
}

function jobDependencies(value: unknown): JobDependency[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item, index) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    const unresolved = displayValue(item.unresolved_ref)
    const label = id ? `JOB-${id}` : unresolved
    if (!label) return []
    const mode = displayValue(item.satisfaction_mode)
    const stage = displayValue(item.required_deployment_stage_name)
    const latest = isPlainObject(item.latest_deployment_stage)
      ? displayValue(item.latest_deployment_stage.label) || displayValue(item.latest_deployment_stage.name)
      : null
    const detail = mode === "deployment_stage" ? `stage ${stage || "unspecified"}${latest ? ` · latest ${latest}` : ""}` : mode
    return [{ key: `${id || unresolved}-${index}`, id, label, detail }]
  })
}

function childJobRows(value: unknown): ChildJobRow[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const id = displayValue(item.id)
    const state = displayValue(item.state)
    if (!id || !state) return []
    return [
      {
        key: id,
        id,
        jobId: `JOB-${id}`,
        title: displayValue(item.issue_title) || `JOB-${id}`,
        state,
        repository: displayValue(item.repository),
        prNumber: displayValue(item.pr_number),
        branch: displayValue(item.branch_name),
        priority: displayValue(item.priority),
        provider: displayValue(item.agent_provider),
        providerSetting: displayValue(item.job_provider_setting),
        closureReason: displayValue(item.closure_reason),
        landedSha: displayValue(item.landed_sha),
        issueBody: truncatedText(item.issue_body),
        dependencies: jobDependencies(item.depends_on_jobs)
      }
    ]
  })
}

function parseEpic(context: ToolCardContext): EpicCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !isPlainObject(parsed.epic)) return null
  const epic = parsed.epic
  const id = displayValue(epic.id)
  const state = displayValue(epic.state)
  if (!id || !state) return null
  const provenance = isPlainObject(epic.goal_provenance) ? epic.goal_provenance : null
  const promptSnapshot = provenance && isPlainObject(provenance.prompt_snapshot) ? provenance.prompt_snapshot : null
  const furthest = isPlainObject(epic.furthest_behind_job) ? epic.furthest_behind_job : null
  const furthestId = furthest ? displayValue(furthest.id) : null
  return {
    id,
    displayNumber: displayValue(epic.display_number) || `EPIC-${id}`,
    title: displayValue(epic.title) || `EPIC-${id}`,
    state,
    repository: displayValue(epic.repository),
    githubIssueUrl: safeHttpUrl(epic.github_issue_url),
    description: truncatedText(epic.description),
    autoApproveMode: displayValue(epic.auto_approve_mode),
    goalChatId: provenance ? displayValue(provenance.chat_goal_id) : null,
    goalPrompt: promptSnapshot ? displayValue(promptSnapshot.prompt) : null,
    maxCommitsBehind: displayValue(epic.max_commits_behind_base),
    furthestBehindJob: furthestId ? { id: furthestId, slug: displayValue(furthest?.slug) } : null,
    dependsOnEpics: epicDependencyBadges(epic.depends_on_epics),
    dependentEpics: epicDependencyBadges(epic.dependent_epics),
    childJobs: childJobRows(parsed.child_jobs)
  }
}

function requestedEpicId(context: ToolCardContext) {
  return displayValue(context.input?.id) || displayValue(context.input?.epic_id)
}

function collapsedSummary(context: ToolCardContext) {
  const requestedId = requestedEpicId(context)
  if (context.resultError) return requestedId ? i18n.t("chat:tool_card_epic_failed_id", { id: requestedId }) : i18n.t("chat:tool_card_epic_failed")
  const epic = parseEpic(context)
  if (!epic)
    return context.parsedResult == null && !context.resultBody
      ? i18n.t("chat:tool_card_epic_reading", { epic: requestedId ? `EPIC-${requestedId}` : i18n.t("chat:tool_card_epic") })
      : null
  return `${epic.displayNumber}: ${epic.title}`
}

function isDoneState(state: string) {
  return ["merged", "closed", "approved", "landing"].includes(state)
}

function TextTruncationNote({ value }: { value: TruncatedText }) {
  if (!value.truncated) return null
  const detail =
    value.bytes == null
      ? ""
      : ` (${value.bytes.toLocaleString()} bytes total${value.omittedBytes == null ? "" : `, ${value.omittedBytes.toLocaleString()} omitted`})`
  return <div className="mt-1 text-2xs text-warning-text">{i18n.t("chat:tool_card_source_truncated", { detail })}</div>
}

function renderExpanded(context: ToolCardContext) {
  const requestedId = requestedEpicId(context)
  if (context.resultError)
    return (
      <StatusCard title={i18n.t("chat:tool_card_epic_attempt")} status="failed">
        {requestedId ? <EntityReference id={requestedId} kind="epic" /> : null}
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-200">
          {displayValue(context.resultBody) || i18n.t("chat:tool_card_epic_error")}
        </div>
      </StatusCard>
    )
  const epic = parseEpic(context)
  if (!epic)
    return context.parsedResult != null || context.resultBody ? null : (
      <StatusCard title={i18n.t("chat:tool_card_epic_attempt")} status="pending">
        {requestedId ? <EntityReference id={requestedId} kind="epic" /> : null}
        <EmptyState>{i18n.t("chat:tool_card_epic_waiting")}</EmptyState>
      </StatusCard>
    )
  const doneCount = epic.childJobs.filter((job) => isDoneState(job.state)).length
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={epic.id} kind="epic" label={epic.displayNumber} slug={epic.displayNumber} />
        <StatePill state={epic.state} />
        {epic.repository ? (
          <EntityReference href={githubRepositoryUrl(epic.repository)} kind="repository" label={epic.repository} repositorySlug={epic.repository} />
        ) : null}
        {epic.githubIssueUrl ? <InternalLink href={epic.githubIssueUrl}>{i18n.t("chat:tool_card_github_issue")}</InternalLink> : null}
      </div>
      <div className="break-words text-sm font-medium text-gray-900 dark:text-gray-100">{epic.title}</div>
      {epic.description?.text.trim() ? (
        <div>
          <MarkdownPreview text={epic.description.text} title={i18n.t("chat:tool_card_description")} />
          <TextTruncationNote value={epic.description} />
        </div>
      ) : (
        <EmptyState>{i18n.t("chat:tool_card_no_epic_description")}</EmptyState>
      )}
      <div className="grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {epic.autoApproveMode ? <Row label={i18n.t("chat:tool_card_auto_approve")} value={epic.autoApproveMode} /> : null}
        {epic.goalChatId ? (
          <div>
            <SectionLabel>{i18n.t("chat:tool_card_goal_provenance")}</SectionLabel>
            <EntityReference id={epic.goalChatId} kind="chat" />
          </div>
        ) : null}
        {epic.maxCommitsBehind ? (
          <div>
            <SectionLabel>{i18n.t("chat:tool_card_furthest_behind")}</SectionLabel>
            <div className="flex flex-wrap items-center gap-1">
              {epic.furthestBehindJob ? <EntityReference id={epic.furthestBehindJob.id} kind="job" slug={epic.furthestBehindJob.slug} /> : null}
              <span>{i18n.t("chat:tool_card_commit_count", { count: Number(epic.maxCommitsBehind) })}</span>
            </div>
          </div>
        ) : null}
      </div>
      {epic.goalPrompt ? <MarkdownPreview maxLines={3} text={epic.goalPrompt} title={i18n.t("chat:tool_card_goal_prompt")} /> : null}
      {epic.dependsOnEpics.length || epic.dependentEpics.length ? (
        <div className="flex flex-wrap gap-3">
          {epic.dependsOnEpics.length ? <DependencyGroup badges={epic.dependsOnEpics} label={i18n.t("chat:tool_card_depends_on")} /> : null}
          {epic.dependentEpics.length ? <DependencyGroup badges={epic.dependentEpics} label={i18n.t("chat:tool_card_dependents")} /> : null}
        </div>
      ) : null}
      <div>
        <SectionLabel>{i18n.t("chat:tool_card_child_jobs_progress", { done: doneCount, count: epic.childJobs.length })}</SectionLabel>
        {epic.childJobs.length ? (
          <ol className="mt-1 space-y-2">
            {epic.childJobs.map((job) => (
              <ChildJob key={job.key} job={job} />
            ))}
          </ol>
        ) : (
          <EmptyState>{i18n.t("chat:tool_card_no_child_jobs")}</EmptyState>
        )}
      </div>
    </CardShell>
  )
}

function ChildJob({ job }: { job: ChildJobRow }) {
  const prUrl = job.prNumber && job.repository ? `${githubRepositoryUrl(job.repository)}/pull/${encodeURIComponent(job.prNumber)}` : null
  return (
    <li className="min-w-0 rounded border border-border bg-surface-raised p-2">
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <EntityReference id={job.id} kind="job" label={job.jobId} />
        <span className="min-w-0 break-words font-medium text-text-primary">{job.title}</span>
        <StatePill state={job.state} />
        {job.priority ? <Badge>{job.priority}</Badge> : null}
      </div>
      <div className="mt-2 grid gap-2 sm:grid-cols-2 lg:grid-cols-3">
        {prUrl ? (
          <div>
            <SectionLabel>{i18n.t("chat:tool_card_pull_request")}</SectionLabel>
            <EntityReference id={job.prNumber} kind="pull_request" prUrl={prUrl} />
          </div>
        ) : null}
        {job.branch ? <Row label={i18n.t("chat:tool_card_branch")} value={job.branch} /> : null}
        {job.provider ? (
          <Row label={i18n.t("chat:tool_card_provider")} value={`${job.provider}${job.providerSetting ? ` (${job.providerSetting})` : ""}`} />
        ) : job.providerSetting ? (
          <Row label={i18n.t("chat:tool_card_provider_setting")} value={job.providerSetting} />
        ) : null}
        {job.closureReason ? <Row label={i18n.t("chat:tool_card_closure_reason")} value={job.closureReason} /> : null}
        {job.landedSha ? <Row label={i18n.t("chat:tool_card_landed_sha")} value={job.landedSha} /> : null}
      </div>
      {job.issueBody?.text.trim() ? (
        <div className="mt-2">
          <MarkdownPreview maxLines={4} text={job.issueBody.text} title={i18n.t("chat:tool_card_issue_body")} />
          <TextTruncationNote value={job.issueBody} />
        </div>
      ) : null}
      {job.dependencies.length ? (
        <div className="mt-2">
          <SectionLabel>{i18n.t("chat:tool_card_waits_for")}</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {job.dependencies.map((dependency) => (
              <span className={WAIT_PILL_CLASS} key={dependency.key}>
                {dependency.id ? (
                  <EntityReference id={dependency.id} kind="job" label={dependency.label} />
                ) : (
                  <span className="break-all font-mono font-medium">{dependency.label}</span>
                )}
                {dependency.detail ? <span className="break-words">· {dependency.detail}</span> : null}
              </span>
            ))}
          </div>
        </div>
      ) : null}
    </li>
  )
}

function DependencyGroup({ label, badges }: { label: string; badges: DependencyBadge[] }) {
  return (
    <div>
      <SectionLabel>{label}</SectionLabel>
      <div className="mt-1 flex flex-wrap gap-1">
        {badges.map((badge) => (
          <span
            className="inline-flex max-w-full flex-wrap items-center gap-1 rounded-full bg-surface px-2 py-0.5 text-2xs text-text-secondary"
            key={badge.key}
          >
            <EntityReference id={badge.id} kind="epic" label={badge.label} slug={badge.label} />
            {badge.title ? <span className="break-words">{badge.title}</span> : null}
            {badge.state ? <span>· {badge.state}</span> : null}
          </span>
        ))}
      </div>
    </div>
  )
}

const readEpicToolCard: ToolCardRenderer = { toolName: "read_epic", collapsedSummary, renderExpanded }

export const examples: ToolCardExample[] = [
  {
    id: "epic_with_child_details",
    label: i18n.t("chat:tool_card_epic_example_details"),
    sourceType: "generic",
    parsedResult: {
      epic: {
        id: 42,
        display_number: "EPIC-42",
        title: i18n.t("chat:tool_card_epic_example_title"),
        state: "running",
        repository: "acme/widgets",
        description: { text: "Ship **clear** Epic cards.", truncated: false, bytes: 27 },
        auto_approve_mode: "after_review"
      },
      child_jobs: [
        {
          id: 101,
          issue_title: "Render details",
          state: "running",
          repository: "acme/widgets",
          pr_number: 15,
          branch_name: "feature/cards",
          priority: "high",
          agent_provider: "codex",
          issue_body: { text: "Add the card.", truncated: false, bytes: 13 },
          depends_on_jobs: []
        }
      ]
    }
  },
  {
    id: "empty_epic",
    label: i18n.t("chat:tool_card_epic_example_empty"),
    sourceType: "generic",
    parsedResult: { epic: { id: 43, state: "queued", description: { text: "", truncated: false, bytes: 0 } }, child_jobs: [] }
  },
  { id: "read_error", label: i18n.t("chat:tool_card_epic_example_error"), sourceType: "generic", resultBody: "Epic was not found.", resultError: true }
]

export default readEpicToolCard
