import { CopyIcon } from "@app/components/CopyableSlug"
import { useCopyToClipboard } from "@app/hooks/useCopyToClipboard"
import { detectHighlighterLanguage } from "@app/lib/highlighter"
import type { ToolCardContext, ToolCardExample, ToolCardRenderer } from "@app/pluginToolCards"
import { isPlainObject } from "@app/toolCardParsing"
import { MarkdownPreview, TextPreview } from "../toolCardMarkdown"
import { CardShell, displayValue, EmptyState, numberValue, Row, StatePill } from "../toolCardUi"

type ReadFileResult = { content: string | null; error: string | null; state: string | null; totalLines: number | null; totalBytes: number | null }

function resultRecord(value: unknown): Record<string, unknown> | null {
  if (!isPlainObject(value)) return null
  for (const key of ["result", "data", "file"]) if (isPlainObject(value[key])) return value[key]
  return value
}

function parseResult(context: ToolCardContext): ReadFileResult | null {
  const parsed = resultRecord(context.parsedResult)
  if (!parsed)
    return context.resultError && context.resultBody.trim()
      ? { content: null, error: context.resultBody.trim(), state: null, totalLines: null, totalBytes: null }
      : null
  const content = typeof parsed.content === "string" ? parsed.content : typeof parsed.text === "string" ? parsed.text : null
  const error = displayValue(parsed.error) || (context.resultError ? displayValue(parsed.message) || context.resultBody.trim() || "File read failed." : null)
  const state = displayValue(parsed.state) || displayValue(parsed.status)
  if (content == null && !error && !state) return null
  return {
    content,
    error,
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
  if (result.error) return "File read failed"
  if (result.content == null) return result.state ? `File read ${result.state.replace(/_/g, " ")}` : null
  const count = result.totalLines ?? lineCount(result.content)
  return `Read file (${count} line${count === 1 ? "" : "s"})`
}

function CopyablePath({ path, href }: { path: string; href: string | null }) {
  const { copied, copy } = useCopyToClipboard()
  const label = <span className="min-w-0 break-all font-mono text-xs font-medium text-text-primary">{path}</span>
  return (
    <div className="min-w-0">
      <div className="text-2xs font-semibold uppercase text-text-muted">Path</div>
      <div className="flex min-w-0 items-start gap-1">
        {href ? (
          <a className="min-w-0 break-all text-brand hover:underline" href={href}>
            {label}
          </a>
        ) : (
          label
        )}
        <button
          aria-label={`Copy ${path} to clipboard`}
          className="mt-0.5 shrink-0 rounded p-1 text-text-subtle hover:bg-surface-raised"
          onClick={() => copy(path)}
          title={copied ? "Copied" : "Copy path"}
          type="button"
        >
          <CopyIcon className="h-3.5 w-3.5" />
        </button>
      </div>
    </div>
  )
}

function renderExpanded(context: ToolCardContext) {
  const result = parseResult(context)
  if (!result) return null
  const path = inputPath(context)
  const pathHref = displayValue(context.input?.path_url) || displayValue(resultRecord(context.parsedResult)?.path_url)
  if (result.error)
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state="failed" tone="failure" />
          <span className="font-semibold text-text-primary">Read file</span>
        </div>
        {path ? <CopyablePath href={pathHref} path={path} /> : null}
        <div className="break-words text-xs text-danger-text [overflow-wrap:anywhere]">{result.error}</div>
      </CardShell>
    )
  if (result.content == null)
    return (
      <CardShell>
        <div className="flex flex-wrap items-center gap-2">
          <StatePill state={result.state || "pending"} />
          <span className="font-semibold text-text-primary">Read file</span>
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
        <Row label="Returned lines" value={String(returnedLines)} />
        {offset != null ? <Row label="Offset" value={String(offset)} /> : null}
        {limit != null ? <Row label="Limit" value={String(limit)} /> : null}
        {result.totalLines != null ? <Row label="Total lines" value={String(result.totalLines)} /> : null}
        {result.totalBytes != null ? <Row label="Total size" value={`${new Intl.NumberFormat().format(result.totalBytes)} bytes`} /> : null}
      </div>
      {result.content === "" ? (
        <EmptyState>Empty file.</EmptyState>
      ) : markdown ? (
        <MarkdownPreview linkifyUrls maxChars={12_000} maxLines={20} modalLabel={`Full contents of ${path}`} text={result.content} title="File content" />
      ) : (
        <TextPreview
          lang={path ? detectHighlighterLanguage(path) : null}
          maxChars={12_000}
          maxLines={200}
          modalLabel={path ? `Full contents of ${path}` : "Full file content"}
          text={result.content}
          title="File content"
        />
      )}
    </CardShell>
  )
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
