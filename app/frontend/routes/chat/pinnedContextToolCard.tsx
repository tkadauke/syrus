import type { ToolCardContext } from "@app/pluginToolCards"
import { CardShell, Disclosure, Row, SectionLabel, StatePill, truncateLines } from "./toolCardUi"

const PINNED_PREVIEW_LINES = 8
const PINNED_PREVIEW_CHARS = 800

type PinnedContextResult =
  | { kind: "updated"; message: string | null; content: string }
  | { kind: "removed"; message: string | null }

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function messageValue(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null
}

export function parsePinnedContextResult(context: ToolCardContext): PinnedContextResult | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !("pinned_context" in parsed)) return null

  const message = messageValue(parsed.message)
  if (parsed.pinned_context == null) return { kind: "removed", message }
  if (typeof parsed.pinned_context !== "string") return null

  return { kind: "updated", message, content: parsed.pinned_context }
}

export function pinnedContextSummary(context: ToolCardContext) {
  const result = parsePinnedContextResult(context)
  if (!result) return null
  if (context.resultError) return result.message || "Pinned context update failed"
  return result.message || (result.kind === "updated" ? "Pinned context updated" : "Pinned context removed")
}

function concisePreview(content: string) {
  const originalLines = content === "" ? 0 : content.split("\n").length
  const clipped = content.length > PINNED_PREVIEW_CHARS ? `${content.slice(0, PINNED_PREVIEW_CHARS)}...` : content
  const preview = truncateLines(clipped, PINNED_PREVIEW_LINES)
  return { ...preview, totalLines: originalLines }
}

export function PinnedContextCard({ result, error = false }: { result: PinnedContextResult; error?: boolean }) {
  if (result.kind === "removed") {
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={error ? "failed" : "removed"} tone={error ? "failure" : "success"} />
          <span className="font-semibold text-gray-900 dark:text-gray-100">Pinned context</span>
        </div>
        {result.message ? <div className="text-gray-700 dark:text-gray-300">{result.message}</div> : null}
      </CardShell>
    )
  }

  const { preview, truncated, totalLines } = concisePreview(result.content)
  const lineCount = result.content === "" ? 0 : result.content.split("\n").length

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={error ? "failed" : "updated"} tone={error ? "failure" : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">Pinned context</span>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        <Row label="Lines" value={String(lineCount)} />
        <Row label="Characters" value={String(result.content.length)} />
      </dl>
      {result.message ? (
        <div>
          <SectionLabel>Outcome</SectionLabel>
          <div className="mt-0.5 text-gray-700 dark:text-gray-300">{result.message}</div>
        </div>
      ) : null}
      <Disclosure label="Context preview">
        <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{preview}</pre>
        {truncated || result.content.length > PINNED_PREVIEW_CHARS ? (
          <div className="mt-1 text-2xs text-gray-500 dark:text-gray-400">Showing a concise preview of {totalLines} lines.</div>
        ) : null}
      </Disclosure>
    </CardShell>
  )
}
