import type { ChatToolGroupItem } from "../../api/chats"
import { Badge, CardShell, Disclosure, Row, SectionLabel, StatePill } from "./toolCardUi"
import { isPlainObject, normalizedToolName } from "./toolRendering"

type ToolCall = ChatToolGroupItem["calls"][number]

export type ToolErrorCardModel = {
  toolLabel: string
  rawName: string
  mcpServerId: string | null
  mcpToolId: string
  errorClass: string | null
  errorMessage: string
  affectedEntityIds: string[]
  retryable: boolean | null
  sideEffectRisk: "low" | "medium" | "high"
  recovery: string
  rawDetails: unknown
}

const READ_ONLY_TOOL_PATTERNS = [
  /^list_/,
  /^read_/,
  /^search_/,
  /^get_/,
  /^inspect_/,
  /^explain_/,
  /^resolve_/,
  /^check_/,
  /^git_status$/,
  /^git_diff$/
]

const HIGH_RISK_TOOL_PATTERNS = [
  /^delete_/,
  /^remove_/,
  /^kill_/,
  /^force_/,
  /^reset_/,
  /^replace_/,
  /^deploy_/,
  /^merge_/,
  /^close_/,
  /^cancel_/,
  /^admin_kill_/
]

const MEDIUM_RISK_TOOL_PATTERNS = [
  /^create_/,
  /^update_/,
  /^write_/,
  /^edit_/,
  /^propose_/,
  /^approve_/,
  /^unapprove_/,
  /^retry_/,
  /^rerun_/,
  /^reenqueue_/,
  /^wake_/,
  /^start_/,
  /^stop_/,
  /^run_/
]

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

const ENTITY_ID_KEY_PATTERN = /(^id$|_id$|_ids$|ids$|number$|slug$|ref$)/i
const ENTITY_KEY_HINTS = new Set([
  "job",
  "jobs",
  "job_id",
  "job_ids",
  "epic",
  "epics",
  "epic_id",
  "epic_ids",
  "target_epic_id",
  "workflow",
  "workflows",
  "workflow_id",
  "run",
  "runs",
  "run_id",
  "repository",
  "repositories",
  "repository_id",
  "chat",
  "chats",
  "chat_id",
  "proposal",
  "proposals",
  "proposal_id",
  "pending_action",
  "pending_actions",
  "pending_action_id",
  "pr",
  "pull_request",
  "pull_requests",
  "pr_number",
  "doc",
  "docs",
  "doc_ref"
])

export function buildToolErrorCardModel(call: ToolCall): ToolErrorCardModel {
  const identity = mcpIdentity(call.raw_name || call.tool_name)
  const parsed = call.result_json
  const errorClass = errorClassFrom(parsed)
  const errorMessage = errorMessageFrom(parsed, call.result_body)
  const retryable = retryableFrom(parsed, errorMessage)
  const sideEffectRisk = sideEffectRiskFor(call.tool_name || identity.tool)

  return {
    toolLabel: call.display_label || call.tool_name,
    rawName: call.raw_name || call.tool_name,
    mcpServerId: identity.server,
    mcpToolId: identity.tool,
    errorClass,
    errorMessage,
    affectedEntityIds: affectedEntityIds(call.raw_payload, parsed),
    retryable,
    sideEffectRisk,
    recovery: recoveryAdvice({ retryable, sideEffectRisk }),
    rawDetails: {
      name: call.raw_name || call.tool_name,
      input: call.raw_payload,
      result: parsed ?? call.result_body
    }
  }
}

export function ToolErrorCard({ call }: { call: ToolCall }) {
  const model = buildToolErrorCardModel(call)
  const retryLabel = model.retryable == null ? "Unknown retryability" : model.retryable ? "Retryable" : "Do not retry blindly"
  const retryTone = model.retryable == null ? "neutral" : model.retryable ? "warning" : "failure"
  const sideEffectLabel = `${model.sideEffectRisk} side-effect risk`
  const sideEffectTone = model.sideEffectRisk === "low" ? "success" : model.sideEffectRisk === "medium" ? "warning" : "failure"

  return (
    <CardShell>
      <div className="flex flex-wrap items-start justify-between gap-2">
        <div className="min-w-0">
          <div className="text-sm font-semibold text-red-700 dark:text-red-200">{model.toolLabel} failed</div>
          <div className="mt-1 break-words font-mono text-xs text-gray-700 dark:text-gray-300">{model.errorMessage}</div>
        </div>
        <div className="flex shrink-0 flex-wrap gap-1">
          <StatePill state={retryLabel} tone={retryTone} />
          <StatePill state={sideEffectLabel} tone={sideEffectTone} />
        </div>
      </div>

      <dl className="grid gap-2 sm:grid-cols-2">
        {model.errorClass ? <Row label="Error class" value={model.errorClass} /> : null}
        <Row label="MCP tool" value={model.mcpToolId} />
        {model.mcpServerId ? <Row label="MCP server" value={model.mcpServerId} /> : null}
        <Row label="Raw name" value={model.rawName} />
        <Row label="Recovery" value={model.recovery} />
      </dl>

      {model.affectedEntityIds.length > 0 ? (
        <div>
          <SectionLabel>Affected entities</SectionLabel>
          <div className="mt-1 flex flex-wrap gap-1">
            {model.affectedEntityIds.map((id) => <Badge key={id}>{id}</Badge>)}
          </div>
        </div>
      ) : null}

      <Disclosure label="Error details">
        <pre className="max-h-80 overflow-auto whitespace-pre-wrap break-words font-mono text-xs">{JSON.stringify(model.rawDetails, null, 2)}</pre>
      </Disclosure>
    </CardShell>
  )
}

function mcpIdentity(rawName: string) {
  if (rawName.startsWith("mcp__")) {
    const [, server, ...toolParts] = rawName.split("__")
    return { server: server || null, tool: toolParts.join("__") || normalizedToolName(rawName) }
  }

  const [server, ...toolParts] = rawName.split(".")
  if (toolParts.length > 0 && server.includes("sidecar")) return { server, tool: toolParts.join(".") }

  return { server: null, tool: normalizedToolName(rawName) }
}

function errorClassFrom(value: unknown): string | null {
  const record = firstObject(value)
  if (!record) return null

  return stringField(record, ["error_class", "class", "exception", "type", "code"])
}

function errorMessageFrom(value: unknown, fallback: string): string {
  const record = firstObject(value)
  const message = record ? stringField(record, ["error_message", "message", "error", "detail", "details", "reason"]) : null
  return message || fallback || "Tool call failed."
}

function retryableFrom(value: unknown, message: string): boolean | null {
  const explicit = booleanField(firstObject(value), ["retryable", "can_retry", "safe_to_retry"])
  if (explicit != null) return explicit
  if (RETRYABLE_ERROR_PATTERNS.some((pattern) => pattern.test(message))) return true
  if (NON_RETRYABLE_ERROR_PATTERNS.some((pattern) => pattern.test(message))) return false
  return null
}

function sideEffectRiskFor(toolName: string): ToolErrorCardModel["sideEffectRisk"] {
  const normalized = normalizedToolName(toolName)
  if (HIGH_RISK_TOOL_PATTERNS.some((pattern) => pattern.test(normalized))) return "high"
  if (MEDIUM_RISK_TOOL_PATTERNS.some((pattern) => pattern.test(normalized))) return "medium"
  if (READ_ONLY_TOOL_PATTERNS.some((pattern) => pattern.test(normalized))) return "low"
  return "medium"
}

function recoveryAdvice({ retryable, sideEffectRisk }: { retryable: boolean | null; sideEffectRisk: ToolErrorCardModel["sideEffectRisk"] }) {
  if (sideEffectRisk === "high") return "Inspect target state and raw details before retrying; this tool may have partially changed data."
  if (retryable === false) return "Correct the input, permissions, or missing resource before trying again."
  if (retryable === true && sideEffectRisk === "low") return "Safe to retry after the transient dependency recovers."
  if (retryable === true) return "Check whether the action partially completed before retrying."
  if (sideEffectRisk === "low") return "Review the error details, then retry if the dependency or access issue has cleared."
  return "Review raw details and target state before retrying."
}

function affectedEntityIds(input: unknown, result: unknown): string[] {
  const seen = new Set<string>()
  collectEntityIds(input, [], seen)
  collectEntityIds(result, [], seen)
  return Array.from(seen).slice(0, 12)
}

function collectEntityIds(value: unknown, path: string[], seen: Set<string>) {
  if (Array.isArray(value)) {
    value.slice(0, 20).forEach((item) => collectEntityIds(item, path, seen))
    return
  }
  if (!isPlainObject(value)) return

  for (const [key, child] of Object.entries(value)) {
    const childPath = [...path, key]
    const entityLabel = entityLabelFor(childPath)
    if (entityLabel && ENTITY_ID_KEY_PATTERN.test(key)) addEntityId(seen, entityLabel, child)
    collectEntityIds(child, childPath, seen)
  }
}

function addEntityId(seen: Set<string>, label: string, value: unknown) {
  if (Array.isArray(value)) {
    value.forEach((item) => addEntityId(seen, label, item))
    return
  }

  if ((typeof value === "string" || typeof value === "number") && String(value).trim()) {
    seen.add(`${label}:${String(value).trim()}`)
  }
}

function entityLabelFor(path: string[]): string | null {
  const key = path.at(-1)?.toLowerCase() || ""
  const parent = path.at(-2)?.toLowerCase() || ""
  const normalizedKey = key.replace(/^target_/, "").replace(/_ids?$/, "").replace(/_number$/, "")
  const normalizedParent = parent.replace(/s$/, "")

  if (ENTITY_KEY_HINTS.has(key)) return normalizedKey || key
  if (ENTITY_KEY_HINTS.has(parent)) return normalizedParent || parent
  if (key === "id" && normalizedParent) return normalizedParent
  if (key === "number" && normalizedParent) return normalizedParent
  if (key === "slug" && normalizedParent) return normalizedParent
  if (key === "ref" && normalizedParent) return normalizedParent
  return null
}

function firstObject(value: unknown): Record<string, unknown> | null {
  if (isPlainObject(value)) return value
  if (Array.isArray(value)) return value.find(isPlainObject) ?? null
  return null
}

function stringField(record: Record<string, unknown>, keys: string[]): string | null {
  for (const key of keys) {
    const value = record[key]
    if (typeof value === "string" && value.trim()) return value.trim()
    if (isPlainObject(value)) {
      const nested = stringField(value, keys)
      if (nested) return nested
    }
  }
  return null
}

function booleanField(record: Record<string, unknown> | null, keys: string[]): boolean | null {
  if (!record) return null
  for (const key of keys) {
    const value = record[key]
    if (typeof value === "boolean") return value
    if (isPlainObject(value)) {
      const nested = booleanField(value, keys)
      if (nested != null) return nested
    }
  }
  return null
}
