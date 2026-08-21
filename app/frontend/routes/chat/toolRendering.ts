// Tool-call rendering helpers extracted from Chat.tsx.
//
// Turn an agent tool_use/tool_result into a compact human label, a one-line
// argument detail, and a trimmed result summary/body — shortening the long
// per-workflow workspace paths that show up in tool output. Pure functions
// over the shared value utils, so they live outside the 6k-line Chat.tsx.
import { contentRecord, firstLine, stringValue } from "./utils"

const WORKSPACE_MARKER = "/.syrus/"
const WORKSPACE_TOKEN_DELIMITERS = new Set([" ", "\n", "\r", "\t", "'", "\"", "`", ",", ":", ";", "]", ")", "}"])
const COUNTED_RESULT_TOOLS = new Set(["Read", "Glob", "Grep"])
const RESULT_SUMMARY_LINE_THRESHOLD = 8
const TOOL_RESULT_PREVIEW_CHARS = 20_000
const TOOL_RESULT_PREVIEW_LINES = 400
export const TOOL_RESULT_PREVIEW_LINE_CHARS = 2_000

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
  return name.startsWith("mcp__") ? name.split("__", 3).at(-1) || name : name
}

export function simpleToolProgressLabel(name: string) {
  const normalized = name.replace(/[^a-z0-9]/gi, "").toLowerCase()

  if (["read", "readfile", "readfiletool", "grep", "glob", "ls"].includes(normalized)) return "Reading code..."
  if (["bash", "edit", "multiedit", "write", "create"].includes(normalized)) return "Making changes..."
  if (["websearch", "webfetch", "websearchtool", "webfetchtool"].includes(normalized)) return "Looking something up..."

  return "Thinking..."
}

export function toolDetail(name: string, input: Record<string, unknown>) {
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
      if (name.startsWith("mcp__")) {
        const candidate = Object.values(input).find((value) => typeof value === "string" && value.length > 0)
        detail = firstLine(stringValue(candidate))
        break
      }

      detail = firstLine(JSON.stringify(input))
  }

  return shortenWorkspacePaths(detail)
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
  if (!COUNTED_RESULT_TOOLS.has(name)) return ""

  const lines = body.split(/\r?\n/).filter((line) => line.trim().length > 0)
  if (lines.length <= RESULT_SUMMARY_LINE_THRESHOLD) return ""

  const noun = name === "Glob" ? "path" : name === "Grep" ? "match" : "line"
  return `${lines.length} ${noun}${lines.length === 1 ? "" : "s"}`
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
