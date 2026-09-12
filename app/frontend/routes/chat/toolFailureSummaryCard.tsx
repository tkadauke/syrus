import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, Row, SectionLabel, StatePill } from "./toolCardUi"

type RetrySafety = "safe" | "caution" | "unknown"

export type ToolFailureConfig = {
  title: string
  attempted: (context: ToolCardContext) => string
  retrySafety: RetrySafety
  recovery: string
}

const RETRYABLE_ERROR_PATTERNS = [
  /timeout/i,
  /timed out/i,
  /temporar/i,
  /rate.?limit/i,
  /busy/i,
  /unavailable/i,
  /connection/i,
  /network/i,
  /deadlock/i,
  /lock wait/i,
  /try again/i
]

const NON_RETRYABLE_ERROR_PATTERNS = [
  /unauthori[sz]ed/i,
  /forbidden/i,
  /permission/i,
  /not found/i,
  /invalid/i,
  /validation/i,
  /already exists/i,
  /missing required/i
]

export function toolFailureCollapsedSummary(context: ToolCardContext, config: ToolFailureConfig) {
  if (!context.resultError) return null
  return `${config.title} failed: ${failureMessage(context)}`
}

export function ToolFailureSummaryCard({ context, config }: { context: ToolCardContext; config: ToolFailureConfig }) {
  if (!context.resultError) return null

  const message = failureMessage(context)
  const errorClass = failureClass(context)
  const safety = retrySafety(context, config)
  const ids = affectedIds(context)

  return (
    <CardShell>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="text-sm font-semibold text-red-700 dark:text-red-200">{config.title} failed</div>
          <div className="mt-1 break-words text-gray-700 dark:text-gray-300">{message}</div>
        </div>
        <StatePill state={safety.label} tone={safety.tone} />
      </div>

      <dl className="grid gap-2 sm:grid-cols-2">
        <Row label="Attempted" value={config.attempted(context)} />
        <Row label="Recovery" value={config.recovery} />
        {errorClass ? <Row label="Error class" value={errorClass} /> : null}
      </dl>

      {ids.length > 0 ? (
        <div>
          <SectionLabel>Relevant IDs</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {ids.map((id) => <Badge key={id}>{id}</Badge>)}
          </div>
        </div>
      ) : null}

      <Disclosure label="Failure details">
        <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-words font-mono text-xs">{JSON.stringify({
          tool: context.toolName,
          input: context.input ?? null,
          result: context.parsedResult ?? context.resultBody
        }, null, 2)}</pre>
      </Disclosure>
    </CardShell>
  )
}

export function stringFromInput(context: ToolCardContext, keys: string[]) {
  return stringFromRecord(context.input, keys)
}

export function countFromInputArray(context: ToolCardContext, key: string) {
  const value = context.input?.[key]
  return Array.isArray(value) ? value.length : null
}

export function humanizeToolName(name: string) {
  const spaced = name.replace(/_/g, " ").trim()
  return spaced ? spaced.charAt(0).toUpperCase() + spaced.slice(1) : name
}

function retrySafety(context: ToolCardContext, config: ToolFailureConfig) {
  const explicit = explicitRetryable(context.parsedResult)
  const inferred = explicit ?? inferredRetryable(failureMessage(context))
  const safety = explicit === false
    ? "caution"
    : inferred === true
      ? "safe"
      : inferred === false && config.retrySafety !== "safe"
        ? "caution"
        : config.retrySafety

  if (safety === "safe") return { label: "Safe to retry", tone: "success" as const }
  if (safety === "caution") return { label: "Check before retrying", tone: "warning" as const }
  return { label: "Retryability unknown", tone: "neutral" as const }
}

function failureMessage(context: ToolCardContext) {
  const record = firstObject(context.parsedResult)
  const message = record ? stringFromRecord(record, ["error_message", "message", "error", "detail", "details", "reason"]) : null
  return message || displayValue(context.resultBody) || "Tool call failed."
}

function failureClass(context: ToolCardContext) {
  const record = firstObject(context.parsedResult)
  return record ? stringFromRecord(record, ["error_class", "class", "exception", "type", "code"]) : null
}

function explicitRetryable(value: unknown): boolean | null {
  const record = firstObject(value)
  if (!record) return null

  for (const key of ["retryable", "can_retry", "safe_to_retry"]) {
    const candidate = record[key]
    if (typeof candidate === "boolean") return candidate
    if (isPlainObject(candidate)) {
      const nested = explicitRetryable(candidate)
      if (nested != null) return nested
    }
  }

  return null
}

function inferredRetryable(message: string): boolean | null {
  if (RETRYABLE_ERROR_PATTERNS.some((pattern) => pattern.test(message))) return true
  if (NON_RETRYABLE_ERROR_PATTERNS.some((pattern) => pattern.test(message))) return false
  return null
}

function affectedIds(context: ToolCardContext) {
  const ids = new Set<string>()
  collectIds(context.input, ids)
  collectIds(context.parsedResult, ids)
  return Array.from(ids).slice(0, 12)
}

function collectIds(value: unknown, ids: Set<string>) {
  if (Array.isArray(value)) {
    value.slice(0, 20).forEach((item) => collectIds(item, ids))
    return
  }
  if (!isPlainObject(value)) return

  addPrefixed(ids, "JOB", value.job_id)
  addManyPrefixed(ids, "JOB", value.job_ids)
  addPrefixed(ids, "EPIC", value.epic_id)
  addPrefixed(ids, "EPIC", value.target_epic_id)
  addManyPrefixed(ids, "EPIC", value.epic_ids)
  addPrefixed(ids, "PR", value.pr_number, "#")
  addPrefixed(ids, "PR", value.pull_request_number, "#")
  addPrefixed(ids, "chat", value.chat_id, "#")
  addPrefixed(ids, "chat", value.chat_session_id, "#")
  addPrefixed(ids, "repository", value.repository_id, "#")

  for (const [key, child] of Object.entries(value)) {
    if (key === "slug" || key === "repository" || key === "repository_slug") addRaw(ids, child)
    collectIds(child, ids)
  }
}

function addPrefixed(ids: Set<string>, label: string, value: unknown, separator = "-") {
  const text = displayValue(value)
  if (text) ids.add(`${label}${separator}${text}`)
}

function addManyPrefixed(ids: Set<string>, label: string, value: unknown) {
  if (!Array.isArray(value)) return
  value.forEach((item) => addPrefixed(ids, label, item))
}

function addRaw(ids: Set<string>, value: unknown) {
  const text = displayValue(value)
  if (text) ids.add(text)
}

function firstObject(value: unknown): Record<string, unknown> | null {
  if (isPlainObject(value)) return value
  if (Array.isArray(value)) return value.find(isPlainObject) ?? null
  return null
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function stringFromRecord(record: Record<string, unknown> | undefined, keys: string[]): string | null {
  if (!record) return null

  for (const key of keys) {
    const value = record[key]
    if (typeof value === "string" && value.trim()) return value.trim()
    if (typeof value === "number" && Number.isFinite(value)) return String(value)
    if (isPlainObject(value)) {
      const nested: string | null = stringFromRecord(value, keys)
      if (nested) return nested
    }
  }

  return null
}
