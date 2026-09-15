import type { ReactNode } from "react"
import { DataTable, DescriptionList, Pill, Surface, Text } from "@app/components/ui"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import {
  Badge,
  CardShell,
  Disclosure,
  displayValue,
  EmptyState,
  InternalLink,
  numberValue,
  SectionLabel,
  StatePill,
  truncateLines
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
    evidence: Array.isArray(value.evidence) ? value.evidence.flatMap((entry, index) => {
      const evidence = parseEvidence(entry, index)
      return evidence ? [evidence] : []
    }) : [],
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
  const parsed = context.parsedResult
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

  return `${rows.length} insight${rows.length === 1 ? "" : "s"}`
}

function SeverityBadge({ severity }: { severity: string | null }) {
  if (!severity) return null
  const tone = severity === "high" ? "danger" : severity === "medium" ? "warning" : "neutral"
  return <Pill className="text-2xs font-semibold uppercase" tone={tone}>{severity}</Pill>
}

function ConfidenceBadge({ confidence }: { confidence: number | null }) {
  if (confidence == null) return null
  return <Badge>{Math.round(confidence * 100)}% confidence</Badge>
}

function RefLink({ target }: { target: InsightRef | null }) {
  if (!target) return null
  const text = target.slug ?? target.title ?? `#${target.id}`
  if (!target.path) return <span className="font-mono text-gray-600 dark:text-gray-300">{text}</span>
  return <InternalLink href={target.path}>{text}</InternalLink>
}

function TextPreview({ text, maxLines = 4 }: { text: string; maxLines?: number }) {
  const { preview, truncated, totalLines } = truncateLines(text, maxLines)
  return (
    <div className="space-y-1">
      <Text as="div" className="whitespace-pre-wrap break-words">{preview}</Text>
      {truncated ? (
        <Disclosure label={`Show full text (${totalLines} lines)`}>
          <div className="whitespace-pre-wrap break-words">{text}</div>
        </Disclosure>
      ) : null}
    </div>
  )
}

function EvidenceRow({ entry }: { entry: EvidenceItem }) {
  return (
    <li className="flex flex-wrap items-center gap-2 text-gray-700 dark:text-gray-300">
      {entry.kind ? <Badge>{entry.kind.replace(/_/g, " ")}</Badge> : null}
      {entry.jobId ? entry.jobPath ? <InternalLink href={entry.jobPath}>JOB-{entry.jobId}</InternalLink> : <span className="font-mono">JOB-{entry.jobId}</span> : null}
      {entry.runId ? entry.runPath ? <InternalLink href={entry.runPath}>RUN-{entry.runId}</InternalLink> : <span className="font-mono">RUN-{entry.runId}</span> : null}
    </li>
  )
}

function EvidenceList({ evidence }: { evidence: EvidenceItem[] }) {
  if (evidence.length === 0) return <Text muted>No evidence attached.</Text>

  const visible = evidence.slice(0, 5)
  const hidden = evidence.slice(5)
  return (
    <Surface className="mt-1 space-y-1" padding="sm" variant="inset">
      <ul className="space-y-1">
        {visible.map((entry) => <EvidenceRow entry={entry} key={entry.key} />)}
      </ul>
      {hidden.length > 0 ? (
        <Disclosure label={`Show remaining evidence (${hidden.length})`}>
          <ul className="space-y-1">
            {hidden.map((entry) => <EvidenceRow entry={entry} key={entry.key} />)}
          </ul>
        </Disclosure>
      ) : null}
    </Surface>
  )
}

function ActionSections({ insight }: { insight: AgentInsight }) {
  const sections: ReactNode[] = []
  if (insight.suggestedPrompt) {
    sections.push(
      <div key="prompt">
        <SectionLabel>Recommended action</SectionLabel>
        <TextPreview text={insight.suggestedPrompt} />
      </div>
    )
  }
  if (insight.memorySuggestion) {
    sections.push(
      <div key="memory">
        <SectionLabel>Memory suggestion</SectionLabel>
        <TextPreview text={insight.memorySuggestion} />
      </div>
    )
  }
  if (insight.staleMemoryText || insight.staleMemoryEvidence) {
    sections.push(
      <div key="stale-memory">
        <SectionLabel>Memory retirement</SectionLabel>
        {insight.targetMemoryId ? <div className="font-mono text-gray-600 dark:text-gray-300">Memory #{insight.targetMemoryId}</div> : null}
        {insight.staleMemoryText ? <TextPreview text={insight.staleMemoryText} maxLines={2} /> : null}
        {insight.staleMemoryEvidence ? <TextPreview text={insight.staleMemoryEvidence} /> : null}
      </div>
    )
  }

  return sections.length ? <>{sections}</> : null
}

export function InsightDetailBody({ insight }: { insight: AgentInsight }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <Text as="span" variant="heading-sm">{insight.title}</Text>
        {insight.state ? <StatePill state={insight.state} /> : null}
        <SeverityBadge severity={insight.severity} />
        {insight.category ? <Badge>{insight.category.replace(/_/g, " ")}</Badge> : null}
        <ConfidenceBadge confidence={insight.confidence} />
      </div>
      <DescriptionList.Root className="sm:grid-cols-2" density="compact">
        <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Insight ID">{insight.id}</DescriptionList.Item>
        {insight.proposalType ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Proposal">{insight.proposalType.replace(/_/g, " ")}</DescriptionList.Item> : null}
        {insight.repository?.slug ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Repository">{insight.repository.slug}</DescriptionList.Item> : null}
        {insight.createdAt ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Created">{insight.createdAt}</DescriptionList.Item> : null}
        {insight.updatedAt ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Updated">{insight.updatedAt}</DescriptionList.Item> : null}
        {insight.retiredAt ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Retired">{insight.retiredAt}</DescriptionList.Item> : null}
      </DescriptionList.Root>
      <div className="flex flex-wrap gap-2">
        <RefLink target={insight.job} />
        <RefLink target={insight.sourceWorkflow} />
        <RefLink target={insight.sourceRun} />
      </div>
      <ActionSections insight={insight} />
      {insight.retiredReason ? (
        <div>
          <SectionLabel>Retirement outcome</SectionLabel>
          <TextPreview text={insight.retiredReason} />
          <div className="mt-1 flex flex-wrap gap-2 text-gray-500 dark:text-gray-400">
            {insight.supersededByInsightId ? <span>Superseded by insight #{insight.supersededByInsightId}</span> : null}
            {insight.supersededByJobId ? <span>Superseded by JOB-{insight.supersededByJobId}</span> : null}
          </div>
        </div>
      ) : null}
      <div>
        <SectionLabel>Evidence</SectionLabel>
        <EvidenceList evidence={insight.evidence} />
      </div>
    </CardShell>
  )
}

export function InsightListBody({ rows }: { rows: AgentInsight[] }) {
  if (rows.length === 0) return <EmptyState>No insights match this query.</EmptyState>

  return (
    <DataTable.Root className="text-xs" density="compact" wrapperClassName="mt-1">
      <DataTable.Header>
        <DataTable.Row>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Insight</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">State</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Severity</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Source</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Repository</DataTable.HeadCell>
          <DataTable.HeadCell className="px-2 py-1 text-2xs">Updated</DataTable.HeadCell>
        </DataTable.Row>
      </DataTable.Header>
      <DataTable.Body>
        {rows.map((row) => (
          <DataTable.Row key={row.id}>
            <DataTable.Cell className="max-w-[24rem] px-2 py-1">
              <Text as="div" variant="heading-sm">{row.title}</Text>
              {row.summary ? <Text as="div" className="mt-0.5 line-clamp-2" variant="caption" tone="muted">{row.summary}</Text> : null}
              <div className="flex flex-wrap gap-1 pt-1">
                {row.category ? <Badge>{row.category.replace(/_/g, " ")}</Badge> : null}
                {row.proposalType ? <Badge>{row.proposalType.replace(/_/g, " ")}</Badge> : null}
                <ConfidenceBadge confidence={row.confidence} />
              </div>
            </DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1">{row.state ? <StatePill state={row.state} /> : "-"}</DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1"><SeverityBadge severity={row.severity} /></DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1">
              <div className="flex flex-col gap-1">
                <RefLink target={row.sourceWorkflow} />
                <RefLink target={row.sourceRun} />
                {!row.sourceWorkflow && !row.sourceRun ? <RefLink target={row.job} /> : null}
              </div>
            </DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1 font-mono text-xs">{row.repository?.slug ?? "-"}</DataTable.Cell>
            <DataTable.Cell className="whitespace-nowrap px-2 py-1 font-mono text-xs text-text-muted">{row.updatedAt ?? row.createdAt ?? "-"}</DataTable.Cell>
          </DataTable.Row>
        ))}
      </DataTable.Body>
    </DataTable.Root>
  )
}

export function parseOutcome(context: ToolCardContext) {
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

export function OutcomeBody({ outcome, label }: { outcome: NonNullable<ReturnType<typeof parseOutcome>>; label: string }) {
  return (
    <CardShell>
      <SectionLabel>{label}</SectionLabel>
      <Text>{outcome.message}</Text>
      <DescriptionList.Root className="sm:grid-cols-2" density="compact">
        {outcome.targetInsightId ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Insight">#{outcome.targetInsightId}</DescriptionList.Item> : null}
        {outcome.supersededByInsightId ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Superseding insight">#{outcome.supersededByInsightId}</DescriptionList.Item> : null}
        {outcome.supersededByJobId ? <DescriptionList.Item descriptionClassName="truncate font-mono text-xs" label="Superseding job">JOB-{outcome.supersededByJobId}</DescriptionList.Item> : null}
      </DescriptionList.Root>
      {outcome.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <TextPreview text={outcome.reason} />
        </div>
      ) : null}
    </CardShell>
  )
}
