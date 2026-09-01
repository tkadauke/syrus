// Tool-call rendering helpers extracted from Chat.tsx.
//
// Turn an agent tool_use/tool_result into a compact human label, a one-line
// argument detail, and a trimmed result summary/body — shortening the long
// per-workflow workspace paths that show up in tool output. Pure functions
// over the shared value utils, so they live outside the 6k-line Chat.tsx.
import { contentRecord, firstLine, stringValue } from "./utils"
import type { ChatToolResultKind, ChatToolSummaryMetadata } from "../../api/chats"

const WORKSPACE_MARKER = "/.syrus/"
const WORKSPACE_TOKEN_DELIMITERS = new Set([" ", "\n", "\r", "\t", "'", "\"", "`", ",", ":", ";", "]", ")", "}"])
const COUNTED_RESULT_TOOLS = new Set(["Read", "Glob", "Grep"])
const CHAT_MCP_SERVER_PREFIXES = ["syrus-chat-sidecar", "syrus-chat-deferred-sidecar"]
const RESULT_SUMMARY_LINE_THRESHOLD = 8
const TOOL_RESULT_PREVIEW_CHARS = 20_000
const TOOL_RESULT_PREVIEW_LINES = 400
export const TOOL_RESULT_PREVIEW_LINE_CHARS = 2_000

export type ToolPresentation = {
  raw_name: string
  name: string
  display_label: string
  argument_summary: string
  raw_payload: unknown
}

export type ToolResultPresentation = {
  kind: ChatToolResultKind
  summary: string
  metadata?: ChatToolSummaryMetadata
}

export type TypedToolResult =
  | { type: "chat_media_gallery"; snapshots: ChatMediaSnapshot[]; images: ChatMediaImage[]; whiteboard_element_count: number | null }
  | { type: "success_row"; label: string }
  | { type: "proposal_outcome"; label: string; title: string; detail: string }
  | { type: "state_summary"; label: string; rows: Array<{ label: string; value: string }> }

export type ChatMediaSnapshot = {
  id: string
  kind: "snapshot"
  name: string
  element_count: number | null
  created_at: string
}

export type ChatMediaImage = {
  id: string
  kind: "chat_image"
  filename: string
  content_type: string
  file_path: string
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function stableJsonValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stableJsonValue)
  if (!isPlainObject(value)) return value

  return Object.fromEntries(
    Object.keys(value).sort().map((key) => [key, stableJsonValue(value[key])])
  )
}

export function toolLabel(name: string) {
  return toolIdentity(name).display_label
}

export function toolPresentation(name: string, input: Record<string, unknown>): ToolPresentation {
  const identity = toolIdentity(name)

  return {
    ...identity,
    argument_summary: toolArgumentSummary(identity.name, input),
    raw_payload: input
  }
}

function toolIdentity(name: string) {
  const normalized = normalizedToolName(name)

  return {
    raw_name: name,
    name: normalized,
    display_label: displayToolName(normalized)
  }
}

function normalizedToolName(name: string) {
  if (name.startsWith("mcp__")) {
    const parts = name.split("__")
    return parts.length >= 3 ? parts.slice(2).join("__") || name : name
  }

  for (const prefix of CHAT_MCP_SERVER_PREFIXES) {
    if (name === prefix) return name
    if (name.startsWith(`${prefix}.`)) return name.slice(prefix.length + 1)
  }

  return name
}

function displayToolName(name: string) {
  if (/^[a-z0-9_]+$/.test(name) && name.includes("_")) return humanizeToolName(name)
  return name
}

function humanizeToolName(name: string) {
  const normalized = name.replace(/_/g, " ").trim().toLowerCase()
  return normalized ? normalized[0].toUpperCase() + normalized.slice(1) : name
}

export function simpleToolProgressLabel(name: string) {
  const normalized = name.replace(/[^a-z0-9]/gi, "").toLowerCase()

  if (["read", "readfile", "readfiletool", "grep", "glob", "ls"].includes(normalized)) return "Reading code..."
  if (["bash", "edit", "multiedit", "write", "create"].includes(normalized)) return "Making changes..."
  if (["websearch", "webfetch", "websearchtool", "webfetchtool"].includes(normalized)) return "Looking something up..."

  return "Thinking..."
}

export function toolDetail(name: string, input: Record<string, unknown>) {
  return toolPresentation(name, input).argument_summary
}

function toolArgumentSummary(name: string, input: Record<string, unknown>) {
  if (Object.keys(input).length === 0) return "No arguments"

  let detail = ""

  switch (name) {
    case "Bash":
      detail = firstLine(stringValue(input.command))
      break
    case "Read":
    case "Edit":
    case "Write":
      detail = stringValue(input.file_path)
      break
    case "NotebookEdit":
      detail = stringValue(input.notebook_path)
      break
    case "Glob":
      detail = stringValue(input.pattern)
      break
    case "Grep": {
      const base = stringValue(input.pattern)
      const path = stringValue(input.path)
      detail = path ? `${base} in ${path}` : base
      break
    }
    case "WebFetch":
      detail = stringValue(input.url)
      break
    case "WebSearch":
      detail = stringValue(input.query)
      break
    case "TodoWrite":
      detail = `${Array.isArray(input.todos) ? input.todos.length : 0} item(s)`
      break
    case "Task":
    case "Agent":
      detail = stringValue(input.description) || firstLine(stringValue(input.prompt))
      break
    case "ToolSearch":
      detail = stringValue(input.query)
      break
    case "resolve_skill":
      detail = stringValue(input.name)
      break
    default:
      detail = defaultToolArgumentSummary(input)
  }

  return shortenWorkspacePaths(detail)
}

function defaultToolArgumentSummary(input: Record<string, unknown>) {
  const preferred = [
    input.query,
    input.prompt,
    input.title,
    input.label,
    input.name,
    input.path,
    input.file_path,
    input.repository,
    input.slug,
    input.id
  ].find((value) => stringValue(value).trim().length > 0)

  if (preferred != null) return firstLine(stringValue(preferred))

  const candidate = Object.values(input).find((value) => typeof value === "string" && value.length > 0)
  if (candidate != null) return firstLine(stringValue(candidate))

  return firstLine(JSON.stringify(stableJsonValue(input)))
}

export function shortenWorkspacePaths(value: string) {
  if (!value.includes(WORKSPACE_MARKER)) return value

  let output = ""
  let cursor = 0
  let searchFrom = 0

  while (searchFrom < value.length) {
    const markerIndex = value.indexOf(WORKSPACE_MARKER, searchFrom)
    if (markerIndex === -1) break

    const replacement = workspacePathReplacement(value, markerIndex)
    if (!replacement) {
      searchFrom = markerIndex + WORKSPACE_MARKER.length
      continue
    }

    const [start, end, text] = replacement
    output += value.slice(cursor, start)
    output += text
    cursor = end
    searchFrom = end
  }

  return cursor === 0 ? value : output + value.slice(cursor)
}

function workspacePathReplacement(value: string, markerIndex: number): [number, number, string] | null {
  const suffixStart = markerIndex + WORKSPACE_MARKER.length
  let end: number | null = null

  if (value.startsWith("workflows/", suffixStart)) {
    end = consumePathSegments(value, suffixStart + "workflows/".length, 1)
  } else if (value.startsWith("chat-workspaces/", suffixStart)) {
    const afterWorkspaceId = consumePathSegments(value, suffixStart + "chat-workspaces/".length, 1)
    if (afterWorkspaceId == null || !value.startsWith("/repositories/", afterWorkspaceId)) return null

    end = consumePathSegments(value, afterWorkspaceId + "/repositories/".length, 2)
  }

  if (end == null) return null

  const start = findWorkspaceTokenStart(value, markerIndex)
  const includesTrailingSlash = value[end] === "/"
  if (includesTrailingSlash) end += 1

  return [start, end, includesTrailingSlash ? "" : "."]
}

function consumePathSegments(value: string, start: number, count: number) {
  let cursor = start

  for (let index = 0; index < count; index += 1) {
    const segmentStart = cursor
    while (cursor < value.length && value[cursor] !== "/" && !WORKSPACE_TOKEN_DELIMITERS.has(value[cursor])) cursor += 1
    if (cursor === segmentStart) return null
    if (index < count - 1) {
      if (value[cursor] !== "/") return null
      cursor += 1
    }
  }

  return cursor
}

function findWorkspaceTokenStart(value: string, markerIndex: number) {
  let start = markerIndex
  while (start > 0 && !WORKSPACE_TOKEN_DELIMITERS.has(value[start - 1])) start -= 1
  return start
}

export function toolResultSummary(name: string, body: string) {
  return toolResultPresentation(name, body).summary
}

export function typedToolResult(name: string, body: string, error = false): TypedToolResult | null {
  if (error) return null

  const normalizedName = normalizedToolName(name)
  const parsed = parseJsonText(body)

  switch (normalizedName) {
    case "list_chat_media":
      return chatMediaGalleryResult(parsed)
    case "set_bookmark":
      return bookmarkResult(parsed)
    case "propose_job":
    case "propose_epic":
    case "propose_epic_with_jobs":
      return proposalOutcomeResult(normalizedName, parsed)
    case "read_job":
      return jobStateSummaryResult(parsed)
    case "read_epic":
      return epicStateSummaryResult(parsed)
    case "check_job_mergeability":
      return mergeabilityStateSummaryResult(parsed)
    default:
      return null
  }
}

export function toolResultPresentation(name: string, body: string, error = false): ToolResultPresentation {
  if (error) return { kind: "error", summary: "" }

  const normalizedName = normalizedToolName(name)
  const parsed = parseJsonText(body)
  const mcpSummary = mcpResultSummary(normalizedName, parsed)
  if (mcpSummary) return mcpSummary

  if (!COUNTED_RESULT_TOOLS.has(normalizedName)) {
    return { kind: parsed == null ? "text" : Array.isArray(parsed) ? "list" : isPlainObject(parsed) ? "record" : "json", summary: "" }
  }

  const lines = body.split(/\r?\n/).filter((line) => line.trim().length > 0)
  if (lines.length <= RESULT_SUMMARY_LINE_THRESHOLD) return { kind: "text", summary: "" }

  const noun = normalizedName === "Glob" ? "path" : normalizedName === "Grep" ? "match" : "line"
  return { kind: "text", summary: countSummary(lines.length, noun), metadata: { count: lines.length, noun } }
}

function mcpResultSummary(name: string, parsed: unknown): ToolResultPresentation | null {
  const count = resultCount(parsed)
  const noun = resultNoun(name)

  if (count != null && noun) {
    return {
      kind: "list",
      summary: countSummary(count, noun),
      metadata: { count, noun }
    }
  }

  if (parsed == null || !noun || !isPlainObject(parsed)) return null

  return {
    kind: "record",
    summary: countSummary(1, noun),
    metadata: { count: 1, noun }
  }
}

function resultNoun(name: string) {
  if (name.includes("chat_media")) return "media item"
  if (name.includes("bookmark")) return "bookmark"
  if (name.includes("proposal")) return "proposal"
  if (name.includes("job")) return "Job"
  if (name.includes("epic")) return "Epic"
  if (name.startsWith("list_")) return itemNoun(name.replace(/^list_/, ""))
  if (name.startsWith("read_")) return itemNoun(name.replace(/^read_/, ""))

  return null
}

function itemNoun(value: string) {
  return value.replace(/_/g, " ").replace(/s$/, "") || "item"
}

function resultCount(value: unknown): number | null {
  if (Array.isArray(value)) return value.length
  if (!isPlainObject(value)) return null

  const chatMediaCount = chatMediaResultCount(value)
  if (chatMediaCount != null) return chatMediaCount

  for (const key of ["items", "results", "records", "proposals", "bookmarks", "media", "chat_media", "jobs", "epics", "children"]) {
    const candidate = value[key]
    if (Array.isArray(candidate)) return candidate.length
  }

  for (const key of ["count", "total", "total_count"]) {
    const candidate = value[key]
    if (typeof candidate === "number" && Number.isFinite(candidate)) return candidate
  }

  return null
}

function chatMediaResultCount(value: Record<string, unknown>) {
  const hasSnapshots = Array.isArray(value.snapshots)
  const hasChatImages = Array.isArray(value.chat_images)
  if (!hasSnapshots && !hasChatImages) return null

  return (hasSnapshots ? value.snapshots.length : 0) + (hasChatImages ? value.chat_images.length : 0)
}

function countSummary(count: number, noun: string) {
  return `${count} ${noun}${count === 1 || noun.endsWith("s") ? "" : "s"}`
}

function chatMediaGalleryResult(parsed: unknown): TypedToolResult | null {
  if (!isPlainObject(parsed)) return null

  const snapshots = typedArray(parsed.snapshots, chatMediaSnapshot)
  const images = typedArray(parsed.chat_images ?? parsed.media, chatMediaImage)
  if (snapshots.length === 0 && images.length === 0) return null

  const elementCount = typeof parsed.whiteboard_element_count === "number" && Number.isFinite(parsed.whiteboard_element_count) ? parsed.whiteboard_element_count : null
  return { type: "chat_media_gallery", snapshots, images, whiteboard_element_count: elementCount }
}

function chatMediaSnapshot(value: unknown): ChatMediaSnapshot | null {
  if (!isPlainObject(value) || stringValue(value.id) === "") return null
  return {
    id: stringValue(value.id),
    kind: "snapshot",
    name: stringValue(value.name) || stringValue(value.id),
    element_count: typeof value.element_count === "number" && Number.isFinite(value.element_count) ? value.element_count : null,
    created_at: stringValue(value.created_at)
  }
}

function chatMediaImage(value: unknown): ChatMediaImage | null {
  if (!isPlainObject(value) || stringValue(value.id) === "") return null
  return {
    id: stringValue(value.id),
    kind: "chat_image",
    filename: stringValue(value.filename) || stringValue(value.name) || stringValue(value.id),
    content_type: stringValue(value.content_type) || stringValue(value.mime_type) || "image",
    file_path: stringValue(value.file_path) || stringValue(value.image_url) || stringValue(value.url)
  }
}

function bookmarkResult(parsed: unknown): TypedToolResult | null {
  if (!isPlainObject(parsed)) return null
  const label = stringValue(parsed.label).trim()
  if (!label) return null

  return { type: "success_row", label: `Bookmark added: ${label}` }
}

function proposalOutcomeResult(name: string, parsed: unknown): TypedToolResult | null {
  if (!isPlainObject(parsed)) return null

  const title = stringValue(parsed.title).trim()
  const slug = stringValue(parsed.slug).trim()
  const kind = stringValue(parsed.kind).trim() || (name.includes("epic") ? "epic" : "job")
  if (!title && !slug) return null

  const state = stringValue(parsed.state).trim()
  const repository = stringValue(parsed.repository).trim()
  const targetEpic = isPlainObject(parsed.target_epic) ? stringValue(parsed.target_epic.label).trim() : ""
  const details = [
    slug,
    state,
    repository,
    targetEpic ? `target ${targetEpic}` : ""
  ].filter(Boolean)

  return {
    type: "proposal_outcome",
    label: `${humanizeToolName(kind)} proposal ready`,
    title: title || slug,
    detail: details.join(" · ")
  }
}

function jobStateSummaryResult(parsed: unknown): TypedToolResult | null {
  if (!isPlainObject(parsed) || !isPlainObject(parsed.job)) return null
  const job = parsed.job
  const label = stringValue(job.issue_title).trim() || stringValue(job.title).trim() || stringValue(job.slug).trim() || "Job"
  const rows = compactRows([
    ["State", job.state],
    ["Repository", job.repository],
    ["PR", job.pr_number],
    ["Branch", job.branch_name],
    ["Latest workflow", isPlainObject(parsed.latest_workflow) ? parsed.latest_workflow.state : null]
  ])
  if (rows.length === 0) return null

  return { type: "state_summary", label, rows }
}

function epicStateSummaryResult(parsed: unknown): TypedToolResult | null {
  if (!isPlainObject(parsed) || !isPlainObject(parsed.epic)) return null
  const epic = parsed.epic
  const childCount = Array.isArray(parsed.child_jobs) ? parsed.child_jobs.length : null
  const label = stringValue(epic.title).trim() || stringValue(epic.display_number).trim() || "Epic"
  const rows = compactRows([
    ["State", epic.state],
    ["Repository", epic.repository],
    ["Children", childCount],
    ["Depends on", Array.isArray(epic.depends_on_epics) ? epic.depends_on_epics.length : null]
  ])
  if (rows.length === 0) return null

  return { type: "state_summary", label, rows }
}

function mergeabilityStateSummaryResult(parsed: unknown): TypedToolResult | null {
  if (!isPlainObject(parsed)) return null

  const message = stringValue(parsed.message).trim()
  const label = message || "Mergeability check requested"
  const rows = compactRows([
    ["Pending action", parsed.pending_action_id],
    ["State", parsed.state],
    ["Job", isPlainObject(parsed.payload) ? parsed.payload.job_id : parsed.job_id]
  ])
  if (!message && rows.length === 0) return null

  return { type: "state_summary", label, rows }
}

function compactRows(rows: Array<[string, unknown]>) {
  return rows.flatMap(([label, value]) => {
    const text = value == null ? "" : String(value).trim()
    return text ? [{ label, value: text }] : []
  })
}

function typedArray<T>(value: unknown, mapper: (item: unknown) => T | null) {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const mapped = mapper(item)
    return mapped ? [mapped] : []
  })
}

function parseJsonText(value: string): unknown {
  const trimmed = value.trim()
  if (!trimmed) return null

  let current: unknown = trimmed
  for (let index = 0; index < 3; index += 1) {
    if (typeof current !== "string") return current
    const candidate = current.trim()
    if (!candidate.startsWith("{") && !candidate.startsWith("[") && !candidate.startsWith("\"")) return index === 0 ? null : current

    try {
      current = JSON.parse(candidate)
    } catch {
      return index === 0 ? null : current
    }
  }

  return current
}

export function fullResultBody(content: unknown): string {
  return toolResultPreview(fullResultBodyUnbounded(content))
}

function fullResultBodyUnbounded(content: unknown): string {
  if (typeof content === "string") return shortenWorkspacePaths(content)
  if (Array.isArray(content)) {
    return content.map((item) => {
      const record = contentRecord(item)
      if (record?.type === "text") return shortenWorkspacePaths(stringValue(record.text))
      if (record?.type === "tool_reference") return `-> ${stringValue(record.tool_name)}`
      return ""
    }).filter(Boolean).join("\n")
  }
  if (content == null) return "(empty)"
  if (isPlainObject(content)) return shortenWorkspacePaths(JSON.stringify(stableJsonValue(content), null, 2))

  return String(content)
}

export function toolResultPreview(body: string): string {
  const normalized = shortenWorkspacePaths(body)
  const lines = normalized.split(/\r?\n/)
  const lineCapped = lines.map((line) => line.length > TOOL_RESULT_PREVIEW_LINE_CHARS ? line.slice(0, TOOL_RESULT_PREVIEW_LINE_CHARS) : line)
  let preview = lineCapped.join("\n")
  let truncated = false

  if (lines.length > TOOL_RESULT_PREVIEW_LINES) {
    preview = lineCapped.slice(0, TOOL_RESULT_PREVIEW_LINES).join("\n")
    truncated = true
  }

  if (lineCapped.some((line, index) => line.length < lines[index].length)) {
    truncated = true
  }

  if (preview.length > TOOL_RESULT_PREVIEW_CHARS) {
    preview = preview.slice(0, TOOL_RESULT_PREVIEW_CHARS)
    truncated = true
  }

  if (!truncated) return preview

  const omittedLines = Math.max(0, lines.length - preview.split(/\r?\n/).length)
  const omittedBytes = Math.max(0, normalized.length - preview.length)
  const omitted = [
    omittedLines > 0 ? `${omittedLines} line${omittedLines === 1 ? "" : "s"}` : null,
    omittedBytes > 0 ? `${omittedBytes} character${omittedBytes === 1 ? "" : "s"}` : null
  ].filter(Boolean).join(", ")

  return `${preview}\n\n[Tool result preview truncated${omitted ? `; ${omitted} omitted` : ""}. Full content remains in the chat transcript.]`
}
