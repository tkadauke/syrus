// Tool-call rendering helpers extracted from Chat.tsx.
//
// Turn an agent tool_use/tool_result into a compact human label, a one-line
// argument detail, and a trimmed result summary/body — shortening the long
// per-workflow workspace paths that show up in tool output. Pure functions
// over the shared value utils, so they live outside the 6k-line Chat.tsx.
import { contentRecord, firstLine, stringValue } from "./utils"

const WORKSPACE_ROOT_PATTERN = /(?:\/[^\s'"`,:;\])}]+)+\/\.syrus\/(?:chat-workspaces\/\d+\/repositories\/[^/\s'"`,:;\])}]+\/[^/\s'"`,:;\])}]+|workflows\/\d+)\/?/g
const COUNTED_RESULT_TOOLS = new Set(["Read", "Glob", "Grep"])
const RESULT_SUMMARY_LINE_THRESHOLD = 8

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
  return value.replace(WORKSPACE_ROOT_PATTERN, (match) => match.endsWith("/") ? "" : ".")
}

export function toolResultSummary(name: string, body: string) {
  if (!COUNTED_RESULT_TOOLS.has(name)) return ""

  const lines = body.split(/\r?\n/).filter((line) => line.trim().length > 0)
  if (lines.length <= RESULT_SUMMARY_LINE_THRESHOLD) return ""

  const noun = name === "Glob" ? "path" : name === "Grep" ? "match" : "line"
  return `${lines.length} ${noun}${lines.length === 1 ? "" : "s"}`
}

export function fullResultBody(content: unknown): string {
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
