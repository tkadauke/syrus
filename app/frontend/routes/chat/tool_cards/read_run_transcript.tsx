import { isPlainObject, type ToolCardContext, type ToolCardExample, type ToolCardRenderer } from "@app/pluginToolCards"
import { redactToolCardText } from "@app/toolCardSecurity"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import {
  Badge,
  CardShell,
  Disclosure,
  EmptyState,
  EntityReference,
  FilterableList,
  displayValue,
  numberValue,
  Row,
  SectionLabel,
  StatePill
} from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"

// Core-owned tool card for read_run_transcript (the Tier 1 tool-card work). Shows
// pagination metadata, chunk count, error/failure highlights, a transcript
// chunk preview, and the full agent diff section when present.
const CHUNK_PREVIEW_CHARS = 400
const PAGE_LINK_CLASS = "inline-flex min-h-11 items-center rounded border border-border px-3 text-xs font-medium text-brand hover:bg-surface-raised sm:min-h-9"

type Chunk = { key: string; sequence: number | null; kind: string | null; text: string }

type RunTranscriptCard = {
  error: string | null
  runId: string
  runState: string
  agentOutcome: string | null
  agentSummary: string | null
  agentDiff: string | null
  totalChunks: number | null
  page: number | null
  per: number | null
  totalPages: number | null
  chunks: Chunk[]
}

function parseChunk(value: unknown, index: number): Chunk | null {
  if (!isPlainObject(value)) return null
  const text = typeof value.chunk === "string" ? value.chunk : ""
  return {
    key: `${displayValue(value.sequence) ?? index}`,
    sequence: numberValue(value.sequence),
    kind: displayValue(value.kind),
    text: redactToolCardText(text)
  }
}

function parseTranscript(context: ToolCardContext): RunTranscriptCard | null {
  let parsed: unknown = context.parsedResult
  if (typeof parsed === "string") {
    try {
      parsed = JSON.parse(parsed)
    } catch {
      return null
    }
  }
  if (!isPlainObject(parsed)) return null

  const runId = displayValue(parsed.run_id) || displayValue(context.input?.run_id)
  const runState = displayValue(parsed.run_state) || (context.resultError ? "error" : null)
  const error = displayValue(parsed.error) || (context.resultError ? displayValue(parsed.message) || context.resultBody.trim() : null)
  if (!runId || !runState) return null

  const chunks = Array.isArray(parsed.chunks)
    ? parsed.chunks.flatMap((chunk, index) => {
        const parsed = parseChunk(chunk, index)
        return parsed ? [parsed] : []
      })
    : []

  return {
    error: error ? redactToolCardText(error) : null,
    runId,
    runState,
    agentOutcome: displayValue(parsed.agent_outcome) ? redactToolCardText(displayValue(parsed.agent_outcome)!) : null,
    agentSummary: displayValue(parsed.agent_summary) ? redactToolCardText(displayValue(parsed.agent_summary)!) : null,
    agentDiff: typeof parsed.agent_diff === "string" && parsed.agent_diff.trim() ? redactToolCardText(parsed.agent_diff) : null,
    totalChunks: numberValue(parsed.total_chunks),
    page: numberValue(parsed.page) ?? numberValue(context.input?.page),
    per: numberValue(parsed.per) ?? numberValue(context.input?.per),
    totalPages: numberValue(parsed.total_pages),
    chunks
  }
}

function collapsedSummary(context: ToolCardContext) {
  const run = parseTranscript(context)
  if (!run) return null
  return `RUN-${run.runId} (${run.runState})`
}

function isFailureState(state: string) {
  return ["failed", "error", "cancelled", "canceled"].includes(state.toLowerCase())
}

function renderExpanded(context: ToolCardContext) {
  const run = parseTranscript(context)
  if (!run) return null

  const stats = run.agentDiff ? diffStats(run.agentDiff) : null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <EntityReference id={run.runId} kind="run" />
        <StatePill state={run.runState} />
        {run.agentOutcome ? <Badge>{run.agentOutcome}</Badge> : null}
      </div>
      {isFailureState(run.runState) ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          This Run did not finish successfully.
        </div>
      ) : null}
      {run.error ? (
        <div className="break-words rounded border border-danger-border bg-danger-surface px-2 py-1 text-danger-text [overflow-wrap:anywhere]">{run.error}</div>
      ) : null}
      {run.agentSummary ? <MarkdownPreview maxChars={2_000} text={run.agentSummary} title="Agent summary" /> : null}
      {run.totalChunks != null || run.page != null || run.per != null ? (
        <dl className="grid gap-1 sm:grid-cols-3">
          {run.totalChunks != null ? <Row label="Chunks" value={String(run.totalChunks)} /> : null}
          {run.page != null ? <Row label="Page" value={run.totalPages != null ? `${run.page} of ${run.totalPages}` : String(run.page)} /> : null}
          {run.per != null ? <Row label="Per page" value={String(run.per)} /> : null}
        </dl>
      ) : null}
      {run.chunks.length > 0 ? (
        <Disclosure label={`Transcript preview (${run.chunks.length})`}>
          <SectionLabel>Transcript preview</SectionLabel>
          <div className="mt-1">
            <FilterableList
              itemText={(chunk) => [chunk.sequence, chunk.kind, chunk.text].filter(Boolean).join(" ")}
              items={run.chunks}
              placeholder="Filter transcript chunks"
            >
              {(chunks) => (
                <ul className="max-h-72 space-y-1 overflow-auto rounded border border-gray-200 bg-white p-2 font-mono text-2xs dark:border-gray-800 dark:bg-gray-950">
                  {chunks.map((chunk) => (
                    <li key={chunk.key}>
                      <div className="flex items-center gap-2 text-gray-400 dark:text-gray-500">
                        {chunk.sequence != null ? <span>#{chunk.sequence}</span> : null}
                        {chunk.kind ? <Badge>{chunk.kind}</Badge> : null}
                      </div>
                      <TextPreview maxChars={CHUNK_PREVIEW_CHARS} modalLabel={`Transcript chunk ${chunk.sequence ?? chunk.key}`} text={chunk.text} />
                    </li>
                  ))}
                </ul>
              )}
            </FilterableList>
          </div>
        </Disclosure>
      ) : (
        <EmptyState>{run.totalChunks === 0 ? "This Run has no transcript chunks." : "No transcript chunks were returned for this page."}</EmptyState>
      )}
      {run.page != null && run.totalPages != null && run.totalPages > 1 ? (
        <nav aria-label="Transcript pages" className="flex flex-wrap gap-2">
          {run.page > 1 ? (
            <a className={PAGE_LINK_CLASS} href={`/admin/runs/${run.runId}/transcript?page=${run.page - 1}${run.per != null ? `&per=${run.per}` : ""}`}>
              Previous page
            </a>
          ) : null}
          {run.page < run.totalPages ? (
            <a className={PAGE_LINK_CLASS} href={`/admin/runs/${run.runId}/transcript?page=${run.page + 1}${run.per != null ? `&per=${run.per}` : ""}`}>
              Next page
            </a>
          ) : null}
        </nav>
      ) : null}
      {run.agentDiff ? (
        <div>
          <SectionLabel>Diff</SectionLabel>
          <div className="mt-1 space-y-1">
            {stats ? <DiffStatBadges stats={stats} /> : null}
            <RawDiffPreview diff={run.agentDiff} />
          </div>
        </div>
      ) : null}
    </CardShell>
  )
}

const readRunTranscriptToolCard: ToolCardRenderer = {
  toolName: "read_run_transcript",
  collapsedSummary,
  renderExpanded
}

export default readRunTranscriptToolCard

export const examples: ToolCardExample[] = [
  {
    id: "completed_with_markdown_and_diff",
    label: "Completed Run with transcript",
    input: { run_id: 42, page: 1, per: 2 },
    parsedResult: {
      run_id: 42,
      run_state: "succeeded",
      agent_outcome: "success",
      agent_summary: "## Result\n\nUpdated **two** files.",
      agent_diff: "diff --git a/app.rb b/app.rb\n@@ -1 +1 @@\n-old\n+new",
      total_chunks: 3,
      page: 1,
      per: 2,
      total_pages: 2,
      chunks: [{ sequence: 1, kind: "assistant", chunk: "Implemented the requested behavior." }]
    }
  },
  {
    id: "empty_page",
    label: "Empty transcript page",
    input: { run_id: 43, page: 2, per: 50 },
    parsedResult: { run_id: 43, run_state: "running", total_chunks: 1, page: 2, per: 50, total_pages: 1, chunks: [] }
  },
  {
    id: "failed_run",
    label: "Failed Run",
    parsedResult: {
      run_id: 44,
      run_state: "failed",
      error: "Agent process exited unexpectedly.",
      total_chunks: 0,
      page: 1,
      per: 50,
      total_pages: 0,
      chunks: []
    }
  }
]
