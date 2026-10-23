import { CopyIcon } from "@app/components/CopyableSlug"
import { useCopyToClipboard } from "@app/hooks/useCopyToClipboard"
import { useT } from "@app/hooks/useT"
import i18n from "@app/i18n"
import { detectHighlighterLanguage } from "@app/lib/highlighter"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "../toolCardUi"

type ReadFileResult = {
  content: string | null
  error: string | null
  failed: boolean
  state: string | null
  totalLines: number | null
  totalBytes: number | null
}

function resultRecord(value: unknown): Record<string, unknown> | null {
  if (!isPlainObject(value)) return null
  for (const key of ["result", "data", "file"]) if (isPlainObject(value[key])) return value[key]
  return value
}

function parseResult(context: ToolCardContext): ReadFileResult | null {
  const parsed = resultRecord(context.parsedResult)
  if (!parsed)
    return context.resultError && context.resultBody.trim()
      ? { content: null, error: context.resultBody.trim(), failed: true, state: null, totalLines: null, totalBytes: null }
      : null
  const content = typeof parsed.content === "string" ? parsed.content : typeof parsed.text === "string" ? parsed.text : null
  const error = displayValue(parsed.error) || (context.resultError ? displayValue(parsed.message) || context.resultBody.trim() || null : null)
  const state = displayValue(parsed.state) || displayValue(parsed.status)
  if (content == null && !error && !state && !context.resultError) return null
  return {
    content,
    error,
    failed: context.resultError || error != null,
    state,
    totalLines: numberValue(parsed.total_lines) ?? numberValue(parsed.totalLines),
    totalBytes: numberValue(parsed.total_bytes) ?? numberValue(parsed.totalBytes) ?? numberValue(parsed.bytes)
  }
}

function inputPath(context: ToolCardContext) {
  return displayValue(context.input?.path) || displayValue(resultRecord(context.parsedResult)?.path)
}

function lineCount(content: string) {
  return content === "" ? 0 : content.split(/\r?\n/).length
}

function collapsedSummary(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  if (result.failed) return i18n.t("chat:tool_card_read_file_failed")
  if (result.content == null)
    return result.state
      ? i18n.t("chat:tool_card_read_file_state", {
          state: result.state === "pending" ? i18n.t("chat:tool_card_read_file_pending_state") : result.state.replace(/_/g, " ")
        })
      : null
  const count = result.totalLines ?? lineCount(result.content)
  return i18n.t("chat:tool_card_read_file_summary", { count })
}

function CopyablePath({ path, href }: { path: string; href: string | null }) {
  const { t } = useT("chat")
  const { copied, copy } = useCopyToClipboard()
  const label = <span className="min-w-0 break-all font-mono text-xs font-medium text-text-primary">{path}</span>
  return (
    <div className="min-w-0">
      <div className="text-2xs font-semibold uppercase text-text-muted">{t("tool_card_read_file_path")}</div>
      <div className="flex min-w-0 items-start gap-1">
        {href ? (
          <a className="min-w-0 break-all text-brand hover:underline" href={href}>
            {label}
          </a>
        ) : (
          label
        )}
        <button
          aria-label={t("tool_card_read_file_copy_path_label", { path })}
          className="mt-0.5 shrink-0 rounded p-1 text-text-subtle hover:bg-surface-raised"
          onClick={() => copy(path)}
          title={copied ? t("tool_card_read_file_copied") : t("tool_card_read_file_copy_path")}
          type="button"
        >
          <CopyIcon className="h-3.5 w-3.5" />
        </button>
      </div>
    </div>
  )
}

function safePathHref(value: string | null) {
  if (!value) return null
  if (value.startsWith("/") && !value.startsWith("//")) return value
  try {
    const url = new URL(value)
    return ["http:", "https:"].includes(url.protocol) ? value : null
  } catch {
    return null
  }
}

function ReadFileCard({ context, result }: { context: ToolCardContext; result: ReadFileResult }) {
  const { t } = useT("chat")
  const path = inputPath(context)
  const pathHref = safePathHref(displayValue(context.input?.path_url) || displayValue(resultRecord(context.parsedResult)?.path_url))
  if (result.failed)
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={t("tool_card_read_file_failed_state")} tone="failure" />
          <span className="font-semibold text-text-primary">{t("tool_card_read_file_title")}</span>
        </div>
        {path ? <CopyablePath href={pathHref} path={path} /> : null}
        <div className="break-words text-xs text-danger-text [overflow-wrap:anywhere]">{result.error || t("tool_card_read_file_failed")}</div>
      </CardShell>
    )
  if (result.content == null)
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={result.state === "pending" || !result.state ? t("tool_card_read_file_pending_state") : result.state} tone="info" />
          <span className="font-semibold text-text-primary">{t("tool_card_read_file_title")}</span>
        </div>
        {path ? <CopyablePath href={pathHref} path={path} /> : null}
      </CardShell>
    )

  const returnedLines = lineCount(result.content)
  const offset = numberValue(context.input?.offset)
  const limit = numberValue(context.input?.limit)
  const markdown = Boolean(path?.match(/\.(?:md|markdown)$/i))
  return (
    <CardShell>
      <div className="grid min-w-0 gap-2 sm:grid-cols-2">
        {path ? <CopyablePath href={pathHref} path={path} /> : null}
        <Row label={t("tool_card_read_file_returned_lines")} value={String(returnedLines)} />
        {offset != null ? <Row label={t("tool_card_read_file_offset")} value={String(offset)} /> : null}
        {limit != null ? <Row label={t("tool_card_read_file_limit")} value={String(limit)} /> : null}
        {result.totalLines != null ? <Row label={t("tool_card_read_file_total_lines")} value={String(result.totalLines)} /> : null}
        {result.totalBytes != null ? (
          <Row
            label={t("tool_card_read_file_total_size")}
            value={t("tool_card_read_file_bytes", { value: new Intl.NumberFormat(i18n.language).format(result.totalBytes) })}
          />
        ) : null}
      </div>
      {result.content === "" ? (
        <EmptyState>{t("tool_card_read_file_empty")}</EmptyState>
      ) : markdown ? (
        <MarkdownPreview
          copyLabel={i18n.t("common:copy_markdown")}
          linkifyUrls
          maxChars={12_000}
          maxLines={20}
          modalLabel={t("tool_card_read_file_full_contents", { path })}
          text={result.content}
          title={t("tool_card_read_file_content")}
        />
      ) : (
        <TextPreview
          lang={path ? detectHighlighterLanguage(path) : null}
          maxChars={12_000}
          maxLines={200}
          modalLabel={path ? t("tool_card_read_file_full_contents", { path }) : t("tool_card_read_file_full_content")}
          text={result.content}
          title={t("tool_card_read_file_content")}
        />
      )}
    </CardShell>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  return result ? <ReadFileCard context={context} result={result} /> : null
}

const readFileToolCard: ToolCardRenderer = { toolName: "read_file", collapsedSummary, renderExpanded }
export default readFileToolCard

export const examples: ToolCardExample[] = [
  { id: "markdown", label: "Markdown file", input: { path: "README.md" }, parsedResult: { content: "# Syrus\n\nSee JOB-42 and https://example.test/docs." } },
  {
    id: "paged_text",
    label: "Paged source file",
    input: { path: "app/models/job.rb", offset: 20, limit: 100 },
    parsedResult: { result: { content: "class Job\nend", total_lines: 642, total_bytes: 18_920 } }
  },
  { id: "read_error", label: "Sandbox error", input: { path: "../secret" }, parsedResult: { error: "path escapes repository root" }, resultError: true }
]
