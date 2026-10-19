import type { ReactNode } from "react"
import i18n from "i18next"
import { DataTable, DescriptionList, Pill, Surface, Text } from "@app/components/ui"
import { useT } from "@app/hooks/useT"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { MarkdownPreview, type MarkdownPreviewProps } from "@app/routes/chat/toolCardMarkdown"
import {
  Badge,
  CardShell,
  Disclosure,
  displayValue,
  EmptyState,
  EntityReference,
  InternalLink,
  numberValue,
  SectionLabel,
  StatePill
} from "@app/routes/chat/toolCardUi"

export type InsightRef = {
  id: string
  slug: string | null
  title: string | null
  path: string | null
}

type EvidenceItem = {
  key: string
  kind: string | null
  jobId: string | null
  runId: string | null
  jobPath: string | null
  runPath: string | null
}

export type AgentInsight = {
  id: string
  title: string
  summary: string | null
  category: string | null
  severity: string | null
  confidence: number | null
  state: string | null
  proposalType: string | null
  evidence: EvidenceItem[]
  suggestedPrompt: string | null
  memorySuggestion: string | null
  staleMemoryText: string | null
  staleMemoryEvidence: string | null
  retiredReason: string | null
  supersededByInsightId: string | null
  supersededByJobId: string | null
  targetMemoryId: string | null
  repository: InsightRef | null
  job: InsightRef | null
  sourceWorkflow: InsightRef | null
  sourceRun: InsightRef | null
  createdAt: string | null
  updatedAt: string | null
  retiredAt: string | null
}

function parseRef(value: unknown, fallbackPath?: (id: string) => string): InsightRef | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  if (!id) return null

  return {
    id,
    slug: displayValue(value.slug),
    title: displayValue(value.title),
    path: displayValue(value.path) ?? (fallbackPath ? fallbackPath(id) : null)
  }
}

function parseEvidence(value: unknown, index: number): EvidenceItem | null {
  if (!isPlainObject(value)) return null
  const jobId = displayValue(value.job_id)
  const runId = displayValue(value.run_id)
  const kind = displayValue(value.kind)
  if (!jobId && !runId && !kind) return null

  return {
    key: `${jobId ?? "job"}-${runId ?? "run"}-${kind ?? index}`,
    kind,
    jobId,
    runId,
    jobPath: displayValue(value.job_path) ?? (jobId ? `/jobs/${jobId}` : null),
    runPath: displayValue(value.run_transcript_path) ?? (runId ? `/admin/runs/${runId}/transcript` : null)
  }
}

export function parseInsight(value: unknown): AgentInsight | null {
  if (!isPlainObject(value)) return null
  const id = displayValue(value.id)
  const title = displayValue(value.title)
  if (!id || !title) return null

  return {
    id,
    title,
    summary: displayValue(value.summary),
    category: displayValue(value.category),
    severity: displayValue(value.severity),
    confidence: numberValue(value.confidence),
    state: displayValue(value.state),
    proposalType: displayValue(value.proposal_type),
    evidence: Array.isArray(value.evidence)
      ? value.evidence.flatMap((entry, index) => {
          const evidence = parseEvidence(entry, index)
          return evidence ? [evidence] : []
        })
      : [],
    suggestedPrompt: typeof value.suggested_prompt === "string" ? value.suggested_prompt : null,
    memorySuggestion: typeof value.memory_suggestion === "string" ? value.memory_suggestion : null,
    staleMemoryText: typeof value.stale_memory_text === "string" ? value.stale_memory_text : null,
    staleMemoryEvidence: typeof value.stale_memory_evidence === "string" ? value.stale_memory_evidence : null,
    retiredReason: typeof value.retired_reason === "string" ? value.retired_reason : null,
    supersededByInsightId: displayValue(value.superseded_by_insight_id),
    supersededByJobId: displayValue(value.superseded_by_job_id),
    targetMemoryId: displayValue(value.target_memory_id),
    repository: parseRef(value.repository),
    job: parseRef(value.job, (refId) => `/jobs/${refId}`),
    sourceWorkflow: parseRef(value.source_workflow),
    sourceRun: parseRef(value.source_run, (refId) => `/admin/runs/${refId}/transcript`),
    createdAt: displayValue(value.created_at),
    updatedAt: displayValue(value.updated_at),
    retiredAt: displayValue(value.retired_at)
  }
}

export function insightRows(context: ToolCardContext): AgentInsight[] | null {
  let root = context.parsedResult
  if (isPlainObject(root) && root.structured_content != null) root = root.structured_content
  if (isPlainObject(root) && Array.isArray(root.content) && isPlainObject(root.content[0]) && typeof root.content[0].text === "string") {
    try {
      root = JSON.parse(root.content[0].text)
    } catch {
      // Preserve the malformed envelope so the generic renderer can show it.
    }
  }
  const parsed = isPlainObject(root) && isPlainObject(root.data) ? root.data : root
  if (!isPlainObject(parsed) || !Array.isArray(parsed.insights)) return null

  return parsed.insights.flatMap((entry) => {
    const insight = parseInsight(entry)
    return insight ? [insight] : []
  })
}

export function parseInsightDetail(context: ToolCardContext): AgentInsight | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null
  return parseInsight(parsed.insight)
}

export function insightListSummary(context: ToolCardContext): string | null {
  const rows = insightRows(context)
  if (!rows) return null

  return i18n.t(`agent_insights:${rows.length === 1 ? "insight_count" : "insight_count_plural"}`, { count: rows.length })
}

function SeverityBadge({ severity }: { severity: string | null }) {
  if (!severity) return null
  const tone = severity === "high" ? "danger" : severity === "medium" ? "warning" : "neutral"
  return (
    <Pill className="text-2xs font-semibold uppercase" tone={tone}>
      {severity}
    </Pill>
  )
}

function ConfidenceBadge({ confidence }: { confidence: number | null }) {
  const { t } = useT("agent_insights")
  if (confidence == null) return null
  return <Badge>{t("confidence", { pct: Math.round(confidence * 100) })}</Badge>
}

function RefLink({ target }: { target: InsightRef | null }) {
  if (!target) return null
  const text = target.slug ?? target.title ?? `#${target.id}`
  const job = text.match(/^JOB-(\d+)$/)
  const workflow = text.match(/^WF-(\d+)$/)
  const run = text.match(/^RUN-(\d+)$/)
  if (job) return <EntityReference href={target.path} id={job[1]} kind="job" slug={text} wrap="nowrap" />
  if (workflow) return <EntityReference href={target.path} id={workflow[1]} kind="workflow" slug={text} wrap="nowrap" />
  if (run) return <EntityReference href={target.path} id={run[1]} kind="run" slug={text} wrap="nowrap" />
  if (!target.path) return <EntityReference kind="artifact" slug={text} wrap="nowrap" />
  return <InternalLink href={target.path}>{text}</InternalLink>
}

function InsightIdReference({ id }: { id: string }) {
  return <EntityReference id={id} kind="insight" slug={`INSIGHT-${id}`} wrap="nowrap" />
}

function RepositoryReference({ repository }: { repository: InsightRef }) {
  return (
    <EntityReference
      href={repository.path}
      id={repository.id}
      kind="repository"
      repositoryId={repository.id}
      repositorySlug={repository.slug ?? repository.title}
      slug={repository.slug ?? repository.title}
      wrap="nowrap"
    />
  )
}

export function TextPreview(props: MarkdownPreviewProps) {
  return <MarkdownPreview linkifySlugs linkifyUrls maxLines={4} {...props} />
}

export function InsightRefList({ insightIds = [], jobIds = [], memoryIds = [] }: { insightIds?: string[]; jobIds?: string[]; memoryIds?: string[] }) {
  const refs = [
    ...insightIds.map((id) => <EntityReference id={id} key={`insight-${id}`} kind="insight" wrap="nowrap" />),
    ...jobIds.map((id) => <EntityReference id={id} key={`job-${id}`} kind="job" wrap="nowrap" />),
    ...memoryIds.map((id) => <EntityReference id={id} key={`memory-${id}`} kind="memory" wrap="nowrap" />)
  ]
  return refs.length ? <div className="flex min-w-0 flex-wrap gap-2">{refs}</div> : null
}

function EvidenceRow({ entry }: { entry: EvidenceItem }) {
  return (
    <li className="flex flex-wrap items-center gap-2 text-gray-700 dark:text-gray-300">
      {entry.kind ? <Badge>{entry.kind.replace(/_/g, " ")}</Badge> : null}
      {entry.jobId ? <EntityReference href={entry.jobPath} id={entry.jobId} kind="job" wrap="nowrap" /> : null}
      {entry.runId ? <EntityReference href={entry.runPath} id={entry.runId} kind="run" wrap="nowrap" /> : null}
    </li>
  )
}

function EvidenceList({ evidence }: { evidence: EvidenceItem[] }) {
  const { t } = useT("agent_insights")
  if (evidence.length === 0) return <Text muted>{t("tool_no_evidence")}</Text>

  const visible = evidence.slice(0, 5)
  const hidden = evidence.slice(5)
  return (
    <Surface className="mt-1 space-y-1" padding="sm" variant="inset">
      <ul className="space-y-1">
        {visible.map((entry) => (
          <EvidenceRow entry={entry} key={entry.key} />
        ))}
      </ul>
      {hidden.length > 0 ? (
        <Disclosure label={t("tool_show_remaining_evidence", { count: hidden.length })}>
          <ul className="space-y-1">
            {hidden.map((entry) => (
              <EvidenceRow entry={entry} key={entry.key} />
            ))}
          </ul>
        </Disclosure>
      ) : null}
    </Surface>
  )
}

function ActionSections({ insight }: { insight: AgentInsight }) {
  const { t } = useT("agent_insights")
  const sections: ReactNode[] = []
  if (insight.suggestedPrompt) {
    sections.push(
      <div key="prompt">
        <SectionLabel>{t("tool_recommended_action")}</SectionLabel>
        <TextPreview text={insight.suggestedPrompt} />
      </div>
    )
  }
  if (insight.memorySuggestion) {
    sections.push(
      <div key="memory">
        <SectionLabel>{t("tool_memory_suggestion")}</SectionLabel>
        <TextPreview text={insight.memorySuggestion} />
      </div>
    )
  }
  if (insight.staleMemoryText || insight.staleMemoryEvidence) {
    sections.push(
      <div key="stale-memory">
        <SectionLabel>{t("tool_memory_retirement")}</SectionLabel>
        {insight.targetMemoryId ? (
          <div className="font-mono text-gray-600 dark:text-gray-300">{t("tool_memory_id", { id: insight.targetMemoryId })}</div>
        ) : null}
        {insight.staleMemoryText ? <TextPreview text={insight.staleMemoryText} maxLines={2} /> : null}
        {insight.staleMemoryEvidence ? <TextPreview text={insight.staleMemoryEvidence} /> : null}
      </div>
    )
  }

  return sections.length ? <>{sections}</> : null
}

export function InsightDetailBody({ insight }: { insight: AgentInsight }) {
  const { t } = useT("agent_insights")
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Text as="span" variant="heading-sm">
          {insight.title}
        </Text>
        {insight.state ? <StatePill state={insight.state} /> : null}
        <SeverityBadge severity={insight.severity} />
        {insight.category ? <Badge>{insight.category.replace(/_/g, " ")}</Badge> : null}
        <ConfidenceBadge confidence={insight.confidence} />
      </div>
      <DescriptionList.Root className="sm:grid-cols-2" density="compact">
        <DescriptionList.Item label={t("tool_insight_id")}>
          <InsightIdReference id={insight.id} />
        </DescriptionList.Item>
        {insight.proposalType ? (
          <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label={t("tool_proposal")}>
            {insight.proposalType.replace(/_/g, " ")}
          </DescriptionList.Item>
        ) : null}
        {insight.repository?.slug ? (
          <DescriptionList.Item label={t("col_repository")}>
            <RepositoryReference repository={insight.repository} />
          </DescriptionList.Item>
        ) : null}
        {insight.createdAt ? (
          <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label={t("col_created")}>
            {insight.createdAt}
          </DescriptionList.Item>
        ) : null}
        {insight.updatedAt ? (
          <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label={t("tool_updated")}>
            {insight.updatedAt}
          </DescriptionList.Item>
        ) : null}
        {insight.retiredAt ? (
          <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label={t("col_retired")}>
            {insight.retiredAt}
          </DescriptionList.Item>
        ) : null}
      </DescriptionList.Root>
      <div className="flex flex-wrap gap-2">
        <RefLink target={insight.job} />
        <RefLink target={insight.sourceWorkflow} />
        <RefLink target={insight.sourceRun} />
      </div>
      <ActionSections insight={insight} />
      {insight.retiredReason ? (
        <div>
          <SectionLabel>{t("tool_retirement_outcome")}</SectionLabel>
          <TextPreview text={insight.retiredReason} />
          <div className="mt-1 flex flex-wrap gap-2 text-gray-500 dark:text-gray-400">
            {insight.supersededByInsightId ? (
              <span className="inline-flex items-center gap-1">
                {t("tool_superseded_by")} <InsightIdReference id={insight.supersededByInsightId} />
              </span>
            ) : null}
            {insight.supersededByJobId ? (
              <span className="inline-flex items-center gap-1">
                {t("tool_superseded_by")} <EntityReference id={insight.supersededByJobId} kind="job" wrap="nowrap" />
              </span>
            ) : null}
          </div>
        </div>
      ) : null}
      <div>
        <SectionLabel>{t("tool_evidence")}</SectionLabel>
        <EvidenceList evidence={insight.evidence} />
      </div>
    </CardShell>
  )
}

export function InsightListBody({ rows }: { rows: AgentInsight[] }) {
  const { t } = useT("agent_insights")
  if (rows.length === 0) return <EmptyState>{t("tool_list_empty")}</EmptyState>

  return (
    <>
      <div className="mt-1 space-y-2 sm:hidden">
        {rows.map((row) => (
          <Surface className="min-w-0 space-y-2 overflow-hidden" key={row.id} padding="sm" variant="inset">
            <div className="flex min-w-0 flex-wrap items-center gap-1">
              <Text as="div" className="min-w-0 break-words" variant="heading-sm">
                {row.title}
              </Text>
              <InsightIdReference id={row.id} />
              {row.state ? <StatePill state={row.state} /> : null}
              <SeverityBadge severity={row.severity} />
            </div>
            {row.summary ? <TextPreview maxChars={320} maxLines={2} text={row.summary} /> : null}
            <div className="flex min-w-0 flex-wrap gap-1">
              {row.category ? <Badge>{row.category.replace(/_/g, " ")}</Badge> : null}
              {row.proposalType ? <Badge>{row.proposalType.replace(/_/g, " ")}</Badge> : null}
              <ConfidenceBadge confidence={row.confidence} />
            </div>
            <div className="flex min-w-0 flex-wrap gap-2">
              <RefLink target={row.sourceWorkflow} />
              <RefLink target={row.sourceRun} />
              {!row.sourceWorkflow && !row.sourceRun ? <RefLink target={row.job} /> : null}
              {row.repository ? <RepositoryReference repository={row.repository} /> : null}
            </div>
            <Text as="div" className="break-all font-mono" variant="caption" tone="muted">
              {row.updatedAt ?? row.createdAt ?? "-"}
            </Text>
          </Surface>
        ))}
      </div>
      <div className="hidden min-w-0 sm:block">
        <DataTable.Root className="text-xs" density="compact" wrapperClassName="mt-1 max-w-full">
          <DataTable.Header>
            <DataTable.Row>
              <DataTable.HeadCell className="px-2 py-1 text-2xs">{t("tool_col_insight")}</DataTable.HeadCell>
              <DataTable.HeadCell className="px-2 py-1 text-2xs">{t("col_state")}</DataTable.HeadCell>
              <DataTable.HeadCell className="px-2 py-1 text-2xs">{t("col_severity")}</DataTable.HeadCell>
              <DataTable.HeadCell className="px-2 py-1 text-2xs">{t("tool_col_source")}</DataTable.HeadCell>
              <DataTable.HeadCell className="px-2 py-1 text-2xs">{t("col_repository")}</DataTable.HeadCell>
              <DataTable.HeadCell className="px-2 py-1 text-2xs">{t("tool_updated")}</DataTable.HeadCell>
            </DataTable.Row>
          </DataTable.Header>
          <DataTable.Body>
            {rows.map((row) => (
              <DataTable.Row key={row.id}>
                <DataTable.Cell className="max-w-[24rem] px-2 py-1">
                  <div className="flex flex-wrap items-center gap-1">
                    <Text as="div" variant="heading-sm">
                      {row.title}
                    </Text>
                    <InsightIdReference id={row.id} />
                  </div>
                  {row.summary ? <TextPreview maxChars={320} maxLines={2} text={row.summary} /> : null}
                  <div className="flex flex-wrap gap-1 pt-1">
                    {row.category ? <Badge>{row.category.replace(/_/g, " ")}</Badge> : null}
                    {row.proposalType ? <Badge>{row.proposalType.replace(/_/g, " ")}</Badge> : null}
                    <ConfidenceBadge confidence={row.confidence} />
                  </div>
                </DataTable.Cell>
                <DataTable.Cell className="whitespace-nowrap px-2 py-1">{row.state ? <StatePill state={row.state} /> : "-"}</DataTable.Cell>
                <DataTable.Cell className="whitespace-nowrap px-2 py-1">
                  <SeverityBadge severity={row.severity} />
                </DataTable.Cell>
                <DataTable.Cell className="whitespace-nowrap px-2 py-1">
                  <div className="flex flex-col gap-1">
                    <RefLink target={row.sourceWorkflow} />
                    <RefLink target={row.sourceRun} />
                    {!row.sourceWorkflow && !row.sourceRun ? <RefLink target={row.job} /> : null}
                  </div>
                </DataTable.Cell>
                <DataTable.Cell className="whitespace-nowrap px-2 py-1 text-xs">
                  {row.repository ? <RepositoryReference repository={row.repository} /> : "-"}
                </DataTable.Cell>
                <DataTable.Cell className="whitespace-nowrap px-2 py-1 font-mono text-xs text-text-muted">
                  {row.updatedAt ?? row.createdAt ?? "-"}
                </DataTable.Cell>
              </DataTable.Row>
            ))}
          </DataTable.Body>
        </DataTable.Root>
      </div>
    </>
  )
}

export function InsightErrorCard({ message }: { message: string }) {
  const { t } = useT("agent_insights")
  return (
    <CardShell>
      <div className="flex items-center gap-2">
        <SectionLabel>{t("admin_eyebrow")}</SectionLabel>
        <Pill tone="danger">{t("tool_failed")}</Pill>
      </div>
      <Text className="break-words" tone="danger">
        {message}
      </Text>
    </CardShell>
  )
}

export function parseOutcome(context: ToolCardContext) {
  if (isPlainObject(context.parsedResult)) {
    const ids = Array.isArray(context.parsedResult.insight_ids) ? context.parsedResult.insight_ids : []
    const firstId = ids.length > 0 ? displayValue(ids[0]) : null
    const message = displayValue(context.parsedResult.message) ?? i18n.t("agent_insights:tool_outcome_fallback")
    return {
      id: firstId,
      message,
      reason: typeof context.input?.reason === "string" ? context.input.reason : null,
      targetInsightId: displayValue(context.input?.target_insight_id) ?? firstId,
      supersededByInsightId: displayValue(context.input?.superseded_by_insight_id),
      supersededByJobId: displayValue(context.input?.superseded_by_job_id)
    }
  }

  const message = context.resultBody.trim()
  if (!message || message.startsWith("{")) return null
  const id = message.match(/Suggestion #(\d+)/)?.[1] ?? null

  return {
    id,
    message,
    reason: typeof context.input?.reason === "string" ? context.input.reason : null,
    targetInsightId: displayValue(context.input?.target_insight_id) ?? id,
    supersededByInsightId: displayValue(context.input?.superseded_by_insight_id),
    supersededByJobId: displayValue(context.input?.superseded_by_job_id)
  }
}

export function OutcomeCard({ context, label }: { context: ToolCardContext; label: string }) {
  const { t } = useT("agent_insights")
  const outcome = parseOutcome(context)
  if (!outcome) return null
  const live = context.livePendingAction
  return (
    <CardShell>
      <SectionLabel>{label}</SectionLabel>
      <Text>{outcome.message}</Text>
      {live ? (
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={live.state} />
          <Text muted>{live.detail ?? live.label}</Text>
        </div>
      ) : null}
      <DescriptionList.Root className="sm:grid-cols-2" density="compact">
        {outcome.targetInsightId ? (
          <DescriptionList.Item label={t("tool_insight")}>
            <InsightIdReference id={outcome.targetInsightId} />
          </DescriptionList.Item>
        ) : null}
        {outcome.supersededByInsightId ? (
          <DescriptionList.Item label={t("tool_superseding_insight")}>
            <InsightIdReference id={outcome.supersededByInsightId} />
          </DescriptionList.Item>
        ) : null}
        {outcome.supersededByJobId ? (
          <DescriptionList.Item label={t("tool_superseding_job")}>
            <EntityReference id={outcome.supersededByJobId} kind="job" wrap="nowrap" />
          </DescriptionList.Item>
        ) : null}
      </DescriptionList.Root>
      {outcome.reason ? (
        <div>
          <SectionLabel>{t("tool_reason")}</SectionLabel>
          <TextPreview text={outcome.reason} />
        </div>
      ) : null}
    </CardShell>
  )
}
