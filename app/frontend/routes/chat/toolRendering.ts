// Tool-call rendering helpers extracted from Chat.tsx.
//
// Turn an agent tool_use/tool_result into a compact human label, a one-line
// argument detail, and a trimmed result summary/body — shortening the long
// per-workflow workspace paths that show up in tool output. Pure functions
// over the shared value utils, so they live outside the 6k-line Chat.tsx.
import { contentRecord, firstLine, stringValue } from "./utils"
import type { ChatToolPresentation, ChatToolResultPresentation } from "../../api/chats"

const WORKSPACE_MARKER = "/.syrus/"
const WORKSPACE_TOKEN_DELIMITERS = new Set([" ", "\n", "\r", "\t", "'", "\"", "`", ",", ":", ";", "]", ")", "}"])
const COUNTED_RESULT_TOOLS = new Set(["Read", "Glob", "Grep"])
const CHAT_MCP_SERVER_PREFIXES = ["syrus-chat-sidecar", "syrus-chat-deferred-sidecar"]
const RESULT_SUMMARY_LINE_THRESHOLD = 8
const TOOL_RESULT_PREVIEW_CHARS = 20_000
const TOOL_RESULT_PREVIEW_LINES = 400
export const TOOL_RESULT_PREVIEW_LINE_CHARS = 2_000
const EMPTY_ARGUMENT_SUMMARY = "No arguments"

type ToolInputSummarizer = (input: Record<string, unknown>) => string

type ParsedToolName = {
  raw: string
  normalized: string
  displayLabel: string
}

const TOOL_INPUT_SUMMARIZERS: Record<string, ToolInputSummarizer> = {
  Bash: (input) => firstLine(stringValue(input.command)),
  Read: (input) => stringValue(input.file_path),
  Edit: (input) => stringValue(input.file_path),
  Write: (input) => stringValue(input.file_path),
  NotebookEdit: (input) => stringValue(input.notebook_path),
  Glob: (input) => stringValue(input.pattern),
  Grep: (input) => {
    const base = stringValue(input.pattern)
    const path = stringValue(input.path)
    return path ? `${base} in ${path}` : base
  },
  WebFetch: (input) => stringValue(input.url),
  WebSearch: (input) => stringValue(input.query),
  TodoWrite: (input) => `${Array.isArray(input.todos) ? input.todos.length : 0} item(s)`,
  Task: (input) => stringValue(input.description) || firstLine(stringValue(input.prompt)),
  Agent: (input) => stringValue(input.description) || firstLine(stringValue(input.prompt)),
  ToolSearch: (input) => stringValue(input.query),
  resolve_skill: (input) => stringValue(input.name),
  read_job: (input) => identifierSummary(input, ["id", "job_id", "number"]),
  read_epic: (input) => identifierSummary(input, ["id", "epic_id", "number"]),
  read_pr: (input) => identifierSummary(input, ["id", "number", "pr_number"]),
  read_workflow: (input) => identifierSummary(input, ["id", "workflow_id"]),
  read_run: (input) => identifierSummary(input, ["id", "run_id"]),
  read_design_doc: (input) => identifierSummary(input, ["id", "doc_id", "number"]),
  list_jobs: listInputSummary,
  list_proposals: listInputSummary,
  list_epics: listInputSummary,
  list_design_docs: listInputSummary,
  list_chat_media: () => "",
  list_chats: listInputSummary,
  set_bookmark: (input) => [stringValue(input.label), stringValue(input.kind)].filter(Boolean).join(" · "),
  propose_job: (input) => stringValue(input.title) || firstLine(stringValue(input.prompt)),
  propose_epic: (input) => stringValue(input.title),
  propose_epic_with_jobs: (input) => stringValue(input.title)
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
  return parseToolName(name).displayLabel
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

export function toolPresentation(name: string, input: Record<string, unknown>): ChatToolPresentation {
  const parsed = parseToolName(name)
  const summarizer = TOOL_INPUT_SUMMARIZERS[name] || TOOL_INPUT_SUMMARIZERS[parsed.normalized]
  const rawSummary = summarizer ? summarizer(input) : fallbackInputSummary(input, name)
  const summary = shortenWorkspacePaths(firstLine(rawSummary))

  return {
    display_label: parsed.displayLabel,
    argument_summary: summary || EMPTY_ARGUMENT_SUMMARY,
    raw_payload: input
  }
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

export function toolResultPresentation(name: string, body: string, rawPayload: unknown = body, error = false): ChatToolResultPresentation {
  if (error) {
    return { kind: "error", summary: firstLine(body), raw_payload: rawPayload }
  }

  const parsed = parseToolName(name)
  const parsedBody = parseJsonText(body)
  const countSummary = countedResultSummary(parsed.normalized, parsed.displayLabel, body, parsedBody)
  if (countSummary) {
    return {
      kind: "count",
      summary: countSummary.summary,
      raw_payload: rawPayload,
      metadata: countSummary.metadata
    }
  }

  if (isBlankResult(parsedBody)) return { kind: "empty", summary: "", raw_payload: rawPayload }
  if (parsedBody !== null) return { kind: "json", summary: "", raw_payload: rawPayload }

  return { kind: "text", summary: "", raw_payload: rawPayload }
}

function countedResultSummary(name: string, displayLabel: string, body: string, parsedBody: unknown): { summary: string; metadata: Record<string, unknown> } | null {
  if (COUNTED_RESULT_TOOLS.has(displayLabel)) {
    const lines = body.split(/\r?\n/).filter((line) => line.trim().length > 0)
    if (lines.length <= RESULT_SUMMARY_LINE_THRESHOLD) return null

    const noun = displayLabel === "Glob" ? "path" : displayLabel === "Grep" ? "match" : "line"
    return { summary: pluralize(lines.length, noun), metadata: { count: lines.length, noun } }
  }

  if (name === "list_chat_media" && isPlainObject(parsedBody)) {
    const snapshots = arrayCount(parsedBody.snapshots)
    const images = arrayCount(parsedBody.chat_images)
    const elements = numericCount(parsedBody.whiteboard_element_count)
    const parts = [
      snapshots > 0 ? pluralize(snapshots, "snapshot") : null,
      images > 0 ? pluralize(images, "image") : null,
      elements > 0 ? pluralize(elements, "whiteboard element") : null
    ].filter(Boolean)
    return {
      summary: parts.length > 0 ? parts.join(" · ") : "No media",
      metadata: { snapshots, images, whiteboard_element_count: elements }
    }
  }

  const primaryArray = primaryArrayValue(parsedBody)
  if (primaryArray && (name.startsWith("list_") || name.includes("proposals") || name.includes("bookmarks"))) {
    const noun = listNoun(name, primaryArray.key)
    return {
      summary: pluralize(primaryArray.count, noun),
      metadata: { count: primaryArray.count, collection: primaryArray.key }
    }
  }

  if ((name.startsWith("read_") || name === "repo_info") && isPlainObject(parsedBody)) {
    const label = stringValue(parsedBody.title) || stringValue(parsedBody.name) || stringValue(parsedBody.label)
    return {
      summary: label ? firstLine(label) : displayLabel,
      metadata: { kind: name }
    }
  }

  if ((name.includes("proposal") || name === "set_bookmark") && isPlainObject(parsedBody)) {
    const label = stringValue(parsedBody.title) || stringValue(parsedBody.label) || stringValue(parsedBody.slug)
    return {
      summary: label ? firstLine(label) : displayLabel,
      metadata: { kind: name }
    }
  }

  return null
}

function parseToolName(name: string): ParsedToolName {
  const normalized = normalizeToolName(name)

  return {
    raw: name,
    normalized,
    displayLabel: displayToolName(name, normalized)
  }
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

function normalizeToolName(name: string) {
  if (name.startsWith("mcp__")) {
    return name.split("__").at(-1) || name
  }

  for (const prefix of CHAT_MCP_SERVER_PREFIXES) {
    if (name.startsWith(`${prefix}.`)) return name.slice(prefix.length + 1)
    if (name.startsWith(`${prefix}__`)) return name.slice(prefix.length + 2)
  }

  return name
}

function displayToolName(raw: string, normalized: string) {
  if (raw !== normalized || normalized.includes("_") || /^[a-z0-9_]+$/.test(normalized)) {
    return humanizeToolName(normalized)
  }

  return normalized
}

function humanizeToolName(name: string) {
  const words = name.replace(/_id$/, "").replace(/[_-]+/g, " ").trim().toLowerCase()
  return words ? words[0].toUpperCase() + words.slice(1) : name
}

function identifierSummary(input: Record<string, unknown>, keys: string[]) {
  for (const key of keys) {
    const value = stringValue(input[key])
    if (value) return value
  }

  return ""
}

function listInputSummary(input: Record<string, unknown>) {
  return Object.entries(input)
    .filter(([, value]) => value != null && value !== "" && !(Array.isArray(value) && value.length === 0))
    .map(([key, value]) => `${humanizeToolName(key)}: ${Array.isArray(value) ? value.map(stringValue).join(", ") : stringValue(value)}`)
    .join(" · ")
}

function fallbackInputSummary(input: Record<string, unknown>, name: string) {
  if (Object.keys(input).length === 0) return ""

  if (name.startsWith("mcp__") || CHAT_MCP_SERVER_PREFIXES.some((prefix) => name.startsWith(`${prefix}.`))) {
    const candidates = Object.values(input).filter((value) => typeof value === "string" && value.length > 0)
    if (candidates.length === 1) return stringValue(candidates[0])
  }

  return JSON.stringify(stableJsonValue(input))
}

function parseJsonText(value: string): unknown {
  const trimmed = value.trim()
  if (!trimmed) return null

  const candidates = [trimmed]
  const fenced = trimmed.match(/^```(?:json)?\s*([\s\S]*?)\s*```$/i)
  if (fenced) candidates.unshift(fenced[1].trim())

  for (const candidate of candidates) {
    try {
      const parsed = JSON.parse(candidate)
      if (typeof parsed === "string" && parsed.trim() !== candidate && /^[\s\n\r]*[{[]/.test(parsed)) {
        const reparsed = parseJsonText(parsed)
        return reparsed == null ? parsed : reparsed
      }

      return parsed
    } catch {
      // Try the next representation below.
    }
  }

  const objectStart = Math.min(
    ...[trimmed.indexOf("{"), trimmed.indexOf("[")].filter((index) => index >= 0)
  )
  if (Number.isFinite(objectStart)) {
    try {
      return JSON.parse(trimmed.slice(objectStart))
    } catch {
      return null
    }
  }

  return null
}

function isBlankResult(value: unknown) {
  return value === null || value === "" || (Array.isArray(value) && value.length === 0) || (isPlainObject(value) && Object.keys(value).length === 0)
}

function primaryArrayValue(value: unknown) {
  if (Array.isArray(value)) return { key: "items", count: value.length }
  if (!isPlainObject(value)) return null

  const entry = Object.entries(value).find(([, candidate]) => Array.isArray(candidate))
  return entry && Array.isArray(entry[1]) ? { key: entry[0], count: entry[1].length } : null
}

function arrayCount(value: unknown) {
  return Array.isArray(value) ? value.length : 0
}

function numericCount(value: unknown) {
  const number = typeof value === "number" ? value : Number.parseInt(stringValue(value), 10)
  return Number.isFinite(number) ? number : 0
}

function listNoun(toolName: string, collectionKey: string) {
  if (collectionKey === "bookmarks" || toolName.includes("bookmark")) return "bookmark"
  if (collectionKey === "proposals" || toolName.includes("proposal")) return "proposal"
  if (collectionKey === "jobs" || toolName.includes("job")) return "job"
  if (collectionKey === "epics" || toolName.includes("epic")) return "epic"
  if (collectionKey === "chat_images") return "image"
  if (collectionKey === "snapshots") return "snapshot"
  return collectionKey.replace(/_id$/, "").replace(/s$/, "") || "item"
}

function pluralize(count: number, noun: string) {
  return `${count} ${noun}${count === 1 ? "" : "s"}`
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
