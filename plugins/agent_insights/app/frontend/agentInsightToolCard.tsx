import type { ReactNode } from "react"
import { isPlainObject, type ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, InternalLink, numberValue, Row, SectionLabel, StatePill, truncateLines } from "@app/routes/chat/toolCardUi"

export type InsightRef = {
  id: string
  slug: string | null
  title: string | null
  path: string | null
}

export type EvidenceItem = {
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

function parseRepository(value: unknown): InsightRef | null {
  return parseRef(value)
}

function parseEvidenceItem(value: unknown, index: number): EvidenceItem | null {
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
    category: displayValue(value.category),
    severity: displayValue(value.severity),
    confidence: numberValue(value.confidence),
    state: displayValue(value.state),
    proposalType: displayValue(value.proposal_type),
    evidence: Array.isArray(value.evidence) ? value.evidence.flatMap((entry, index) => {
      const evidence = parseEvidenceItem(entry, index)
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
    repository: parseRepository(value.repository),
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
  const classes = severity === "high"
    ? "bg-red-100 text-red-700 dark:bg-red-950/40 dark:text-red-200"
    : severity === "medium"
      ? "bg-amber-100 text-amber-800 dark:bg-amber-950/40 dark:text-amber-200"
      : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"

  return <span className={`rounded-full px-2 py-0.5 text-2xs font-semibold uppercase ${classes}`}>{severity}</span>
}

function ConfidenceBadge({ confidence }: { confidence: number | null }) {
  if (confidence == null) return null
  return <Badge>{Math.round(confidence * 100)}% confidence</Badge>
}

function RefLink({ target, label }: { target: InsightRef | null; label?: string }) {
  if (!target) return null
  const text = label ?? target.slug ?? target.title ?? `#${target.id}`
  if (!target.path) return <span className="font-mono text-gray-600 dark:text-gray-300">{text}</span>
  return <InternalLink href={target.path}>{text}</InternalLink>
}

function TextPreview({ text, maxLines = 4 }: { text: string; maxLines?: number }) {
  const { preview, truncated, totalLines } = truncateLines(text, maxLines)
  return (
    <div className="space-y-1">
      <div className="whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">{preview}</div>
      {truncated ? (
        <Disclosure label={`Show full text (${totalLines} lines)`}>
          <div className="whitespace-pre-wrap break-words">{text}</div>
        </Disclosure>
      ) : null}
    </div>
  )
}

function EvidenceList({ evidence }: { evidence: EvidenceItem[] }) {
  if (evidence.length === 0) return <div className="text-gray-500 dark:text-gray-400">No evidence attached.</div>

  return (
    <ul className="mt-1 space-y-1 rounded border border-gray-200 bg-white p-2 dark:border-gray-800 dark:bg-gray-950">
      {evidence.map((entry) => (
        <li className="flex flex-wrap items-center gap-2 text-gray-700 dark:text-gray-300" key={entry.key}>
          {entry.kind ? <Badge>{entry.kind.replace(/_/g, " ")}</Badge> : null}
          {entry.jobId ? entry.jobPath ? <InternalLink href={entry.jobPath}>JOB-{entry.jobId}</InternalLink> : <span className="font-mono">JOB-{entry.jobId}</span> : null}
          {entry.runId ? entry.runPath ? <InternalLink href={entry.runPath}>RUN-{entry.runId}</InternalLink> : <span className="font-mono">RUN-{entry.runId}</span> : null}
        </li>
      ))}
    </ul>
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
      <div className="space-y-1">
        <div className="flex flex-wrap items-center gap-2">
          <span className="font-medium text-gray-800 dark:text-gray-100">{insight.title}</span>
          {insight.state ? <StatePill state={insight.state} /> : null}
          <SeverityBadge severity={insight.severity} />
          {insight.category ? <Badge>{insight.category.replace(/_/g, " ")}</Badge> : null}
          <ConfidenceBadge confidence={insight.confidence} />
        </div>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Insight ID" value={insight.id} />
        {insight.proposalType ? <Row label="Proposal" value={insight.proposalType.replace(/_/g, " ")} /> : null}
        {insight.repository?.slug ? <Row label="Repository" value={insight.repository.slug} /> : null}
        {insight.createdAt ? <Row label="Created" value={insight.createdAt} /> : null}
        {insight.updatedAt ? <Row label="Updated" value={insight.updatedAt} /> : null}
        {insight.retiredAt ? <Row label="Retired" value={insight.retiredAt} /> : null}
      </dl>
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
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Insight</th>
            <th className="px-2 py-1 font-semibold" scope="col">State</th>
            <th className="px-2 py-1 font-semibold" scope="col">Severity</th>
            <th className="px-2 py-1 font-semibold" scope="col">Source</th>
            <th className="px-2 py-1 font-semibold" scope="col">Repository</th>
            <th className="px-2 py-1 font-semibold" scope="col">Updated</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row) => (
            <tr key={row.id}>
              <td className="max-w-[24rem] px-2 py-1">
                <div className="font-medium text-gray-800 dark:text-gray-100">{row.title}</div>
                <div className="flex flex-wrap gap-1 pt-1">
                  {row.category ? <Badge>{row.category.replace(/_/g, " ")}</Badge> : null}
                  {row.proposalType ? <Badge>{row.proposalType.replace(/_/g, " ")}</Badge> : null}
                  <ConfidenceBadge confidence={row.confidence} />
                </div>
              </td>
              <td className="whitespace-nowrap px-2 py-1">{row.state ? <StatePill state={row.state} /> : "-"}</td>
              <td className="whitespace-nowrap px-2 py-1"><SeverityBadge severity={row.severity} /></td>
              <td className="whitespace-nowrap px-2 py-1">
                <div className="flex flex-col gap-1">
                  <RefLink target={row.sourceWorkflow} />
                  <RefLink target={row.sourceRun} />
                  {!row.sourceWorkflow && !row.sourceRun ? <RefLink target={row.job} /> : null}
                </div>
              </td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{row.repository?.slug ?? "-"}</td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-500 dark:text-gray-400">{row.updatedAt ?? row.createdAt ?? "-"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export function parseOutcome(context: ToolCardContext): { id: string | null; message: string; reason: string | null; targetInsightId: string | null; supersededByInsightId: string | null; supersededByJobId: string | null } | null {
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
      <div className="text-gray-700 dark:text-gray-300">{outcome.message}</div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {outcome.targetInsightId ? <Row label="Insight" value={`#${outcome.targetInsightId}`} /> : null}
        {outcome.supersededByInsightId ? <Row label="Superseding insight" value={`#${outcome.supersededByInsightId}`} /> : null}
        {outcome.supersededByJobId ? <Row label="Superseding job" value={`JOB-${outcome.supersededByJobId}`} /> : null}
      </dl>
      {outcome.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <TextPreview text={outcome.reason} />
        </div>
      ) : null}
    </CardShell>
  )
}
