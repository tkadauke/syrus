import { isPlainObject, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import i18n from "../../../i18n"
import { Badge, EmptyState } from "../toolCardUi"

type StatusRow = {
  code: string
  path: string
  oldPath: string | null
  staged: string | null
  unstaged: string | null
  conflict: boolean
  untracked: boolean
}

const STATUS_LABEL_KEYS: Record<string, string> = { M: "modified", T: "type_changed", A: "added", D: "deleted", R: "renamed", C: "copied" }

const CONFLICT_CODES = new Set(["DD", "AU", "UD", "UA", "DU", "AA", "UU"])

function statusLabel(code: string): string | null {
  const key = STATUS_LABEL_KEYS[code]
  return key ? i18n.t(`chat:tool_card_git_status_${key}`) : code === " " ? null : i18n.t("chat:unknown")
}

function splitRenamePath(path: string): { path: string; oldPath: string | null } {
  const separator = path.lastIndexOf(" -> ")
  if (separator < 0) return { path, oldPath: null }
  return { oldPath: path.slice(0, separator), path: path.slice(separator + 4) }
}

function parseLine(line: string): StatusRow | null {
  if (line.length < 4 || line[2] !== " ") return null

  const code = line.slice(0, 2)
  const rawPath = line.slice(3).trim()
  if (!rawPath) return null

  const renamed = code.includes("R") || code.includes("C") ? splitRenamePath(rawPath) : { path: rawPath, oldPath: null }
  return {
    code,
    ...renamed,
    staged: code === "??" ? null : statusLabel(code[0]),
    unstaged: code === "??" ? null : statusLabel(code[1]),
    conflict: CONFLICT_CODES.has(code),
    untracked: code === "??"
  }
}

function parseStatus(context: ToolCardContext): string | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || typeof parsed.status !== "string") return null
  return parsed.status
}

function statusRows(status: string): StatusRow[] {
  return status.split(/\r?\n/).flatMap((line) => {
    const row = parseLine(line)
    return row ? [row] : []
  })
}

function errorText(context: ToolCardContext): string | null {
  if (!context.resultError) return null
  if (isPlainObject(context.parsedResult)) {
    for (const key of ["error", "message"]) {
      const value = context.parsedResult[key]
      if (typeof value === "string" && value.trim()) return value.trim()
    }
  }
  return context.resultBody.trim() || i18n.t("chat:tool_card_git_status_error_detail")
}

function collapsedSummary(context: ToolCardContext) {
  const error = errorText(context)
  if (error) return i18n.t("chat:tool_card_git_status_error", { error })
  const status = parseStatus(context)
  if (status == null) return context.parsedResult == null && !context.resultBody.trim() ? i18n.t("chat:tool_card_git_status_missing_summary") : null
  const rows = statusRows(status)
  return rows.length === 0 ? i18n.t("chat:tool_card_git_status_clean_summary") : i18n.t("chat:tool_card_git_status_changed_count", { count: rows.length })
}

function StatusBadges({ row }: { row: StatusRow }) {
  if (row.untracked) return <Badge>{i18n.t("chat:tool_card_git_status_untracked")}</Badge>
  if (row.conflict) return <Badge>{i18n.t("chat:tool_card_git_status_conflict", { code: row.code })}</Badge>

  return (
    <>
      {row.staged ? <Badge>{i18n.t("chat:tool_card_git_status_staged", { state: row.staged })}</Badge> : null}
      {row.unstaged ? <Badge>{i18n.t("chat:tool_card_git_status_unstaged", { state: row.unstaged })}</Badge> : null}
    </>
  )
}

function renderExpanded(context: ToolCardContext) {
  const error = errorText(context)
  if (error) return <EmptyState>{i18n.t("chat:tool_card_git_status_error", { error })}</EmptyState>

  const status = parseStatus(context)
  if (status == null) {
    return context.parsedResult == null && !context.resultBody.trim() ? <EmptyState>{i18n.t("chat:tool_card_git_status_missing")}</EmptyState> : null
  }

  const rows = statusRows(status)
  if (rows.length === 0) return <EmptyState>{i18n.t("chat:tool_card_git_status_clean")}</EmptyState>

  return (
    <div className="mt-1 max-h-72 min-w-0 space-y-1 overflow-y-auto overflow-x-hidden rounded border border-gray-200 bg-white px-2 py-1 font-mono text-xs dark:border-gray-800 dark:bg-gray-950">
      {rows.map((row, index) => (
        <div className="flex min-h-8 min-w-0 flex-wrap items-center gap-x-2 gap-y-1 py-1" key={`${row.code}-${row.oldPath ?? ""}-${row.path}-${index}`}>
          <div className="flex shrink-0 flex-wrap gap-1">
            <StatusBadges row={row} />
          </div>
          <div className="min-w-0 flex-1 break-all">
            {row.oldPath ? (
              <>
                <span>{row.oldPath}</span>
                <span aria-label={i18n.t("chat:tool_card_git_status_renamed_to")} className="px-1 text-text-subtle">
                  →
                </span>
              </>
            ) : null}
            <span>{row.path}</span>
          </div>
        </div>
      ))}
    </div>
  )
}

const gitStatusToolCard: ToolCardRenderer = {
  toolName: "git_status",
  collapsedSummary,
  renderExpanded
}

export default gitStatusToolCard

export const examples = [
  {
    id: "staged_unstaged_and_untracked",
    label: i18n.t("chat:tool_card_git_status_example_changes"),
    parsedResult: {
      status: " M app/frontend/pluginToolCards.tsx\nA  app/frontend/toolPresentationRegistry.ts\n?? app/frontend/newFile.ts\nD  app/frontend/oldFile.ts"
    }
  },
  {
    id: "rename_and_conflict",
    label: i18n.t("chat:tool_card_git_status_example_conflict"),
    parsedResult: { status: "R  app/old_name.ts -> app/new_name.ts\nUU app/frontend/conflicted.tsx" }
  },
  {
    id: "clean_tree",
    label: i18n.t("chat:tool_card_git_status_clean_summary"),
    description: i18n.t("chat:tool_card_git_status_example_clean_description"),
    parsedResult: { status: "" }
  },
  {
    id: "daemon_error",
    label: i18n.t("chat:tool_card_git_status_example_error"),
    resultBody: "Local Mode daemon is not connected",
    resultError: true
  },
  {
    id: "empty_result",
    label: i18n.t("chat:tool_card_git_status_example_empty"),
    description: i18n.t("chat:tool_card_git_status_example_empty_description"),
    resultBody: ""
  }
]
