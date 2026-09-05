import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, numberValue, Row, SectionLabel, StatePill } from "../toolCardUi"
import { DiffStatBadges, diffStats, RawDiffPreview } from "../toolCardDiff"

// Core-owned tool card for read_run_transcript (EPIC-291 / JOB-4221). Shows
// pagination metadata, chunk count, error/failure highlights, a transcript
// chunk preview, and the full agent diff section when present.
const CHUNK_PREVIEW_CHARS = 400

type Chunk = { key: string; sequence: number | null; kind: string | null; text: string }

type RunTranscriptCard = {
  runId: string
  runState: string
  agentOutcome: string | null
  agentSummary: string | null
  agentDiff: string | null
  totalChunks: number | null
  page: number | null
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
    text
  }
}

function parseTranscript(context: ToolCardContext): RunTranscriptCard | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const runId = displayValue(parsed.run_id)
  const runState = displayValue(parsed.run_state)
  if (!runId || !runState) return null

  const chunks = Array.isArray(parsed.chunks) ? parsed.chunks.flatMap((chunk, index) => { const parsed = parseChunk(chunk, index); return parsed ? [parsed] : [] }) : []

  return {
    runId,
    runState,
    agentOutcome: displayValue(parsed.agent_outcome),
    agentSummary: displayValue(parsed.agent_summary),
    agentDiff: typeof parsed.agent_diff === "string" && parsed.agent_diff.trim() ? parsed.agent_diff : null,
    totalChunks: numberValue(parsed.total_chunks),
    page: numberValue(parsed.page),
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
        <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">RUN-{run.runId}</span>
        <StatePill state={run.runState} />
        {run.agentOutcome ? <Badge>{run.agentOutcome}</Badge> : null}
      </div>
      {isFailureState(run.runState) ? (
        <div className="rounded border border-red-200 bg-red-50 px-2 py-1 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300">
          This Run did not finish successfully.
        </div>
      ) : null}
      {run.agentSummary ? <div className="text-gray-700 dark:text-gray-300">{run.agentSummary}</div> : null}
      {run.totalChunks != null ? (
        <dl className="grid gap-1 sm:grid-cols-2">
          <Row label="Chunks" value={String(run.totalChunks)} />
          {run.page != null && run.totalPages != null ? <Row label="Page" value={`${run.page} of ${run.totalPages}`} /> : null}
        </dl>
      ) : null}
      {run.chunks.length > 0 ? (
        <div>
          <SectionLabel>Transcript preview</SectionLabel>
          <ul className="mt-1 max-h-72 space-y-1 overflow-auto rounded border border-gray-200 bg-white p-2 font-mono text-2xs dark:border-gray-800 dark:bg-gray-950">
            {run.chunks.map((chunk) => (
              <li key={chunk.key}>
                <div className="flex items-center gap-2 text-gray-400 dark:text-gray-500">
                  {chunk.sequence != null ? <span>#{chunk.sequence}</span> : null}
                  {chunk.kind ? <Badge>{chunk.kind}</Badge> : null}
                </div>
                <div className="whitespace-pre-wrap break-words text-gray-700 dark:text-gray-300">
                  {chunk.text.length > CHUNK_PREVIEW_CHARS ? `${chunk.text.slice(0, CHUNK_PREVIEW_CHARS)}…` : chunk.text}
                </div>
              </li>
            ))}
          </ul>
        </div>
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
