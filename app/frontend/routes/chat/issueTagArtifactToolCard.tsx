import type { CSSProperties, ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, InternalLink, Row, SectionLabel, StatePill, truncateLines } from "./toolCardUi"
import { ErrorCard } from "./chatHelperToolCard"
import { formatRelativeDate } from "../../lib/relativeTime"

const ARTIFACT_PREVIEW_LINES = 8
const ARTIFACT_PREVIEW_CHARS = 900

type IssueRow = {
  number: string
  title: string
  labels: string[]
  state: string | null
  createdAt: string | null
  updatedAt: string | null
  url: string | null
  repository: string | null
}

type TagRow = {
  id: string | null
  name: string
  color: string | null
  jobIds: string[]
}

type TagAction = {
  action: "create" | "add" | "remove"
  tag: TagRow | null
  inputTag: TagRow | null
  resultTag: TagRow | null
  jobId: string | null
  success: boolean
  error: string | null
  pending: boolean
}

type ArtifactResult = {
  title: string | null
  type: string | null
  id: string | null
  path: string | null
  url: string | null
  message: string | null
  preview: string | null
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function arrayStrings(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const label = displayValue(item)
    return label ? [label] : []
  })
}

function issueRows(context: ToolCardContext): IssueRow[] | null {
  const parsed = context.parsedResult
  const rows = Array.isArray(parsed) ? parsed : isPlainObject(parsed) && Array.isArray(parsed.issues) ? parsed.issues : null
  if (!rows) return null

  return rows.flatMap((item) => {
    if (!isPlainObject(item)) return []
    const number = displayValue(item.number)
    const title = displayValue(item.title)
    if (!number || !title) return []

    return [{
      number,
      title,
      labels: arrayStrings(item.labels),
      state: displayValue(item.state),
      createdAt: displayValue(item.created_at),
      updatedAt: displayValue(item.updated_at),
      url: displayValue(item.url) || displayValue(item.html_url),
      repository: displayValue(item.repository) || displayValue(item.repository_slug)
    }]
  })
}

function timestampLabel(value: string | null): string | null {
  if (!value) return null
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  return formatRelativeDate(date)
}

export function issueListSummary(context: ToolCardContext) {
  const rows = issueRows(context)
  if (!rows) return null
  return rows.length === 0 ? "No issues" : `${rows.length} issue${rows.length === 1 ? "" : "s"}`
}

export function IssueListCard({ rows }: { rows: IssueRow[] }) {
  if (rows.length === 0) return <EmptyState>No issues found.</EmptyState>

  return (
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Issue</th>
            <th className="px-2 py-1 font-semibold" scope="col">State</th>
            <th className="px-2 py-1 font-semibold" scope="col">Labels</th>
            <th className="px-2 py-1 font-semibold" scope="col">Age</th>
            <th className="px-2 py-1 font-semibold" scope="col">Updated</th>
            <th className="px-2 py-1 font-semibold" scope="col">Link</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((issue) => (
            <tr key={issue.number}>
              <td className="max-w-80 px-2 py-1">
                <div className="font-mono font-medium text-gray-800 dark:text-gray-200">#{issue.number}</div>
                <div className="truncate text-gray-700 dark:text-gray-300" title={issue.title}>{issue.title}</div>
                {issue.repository ? <div className="truncate font-mono text-2xs text-gray-500 dark:text-gray-400">{issue.repository}</div> : null}
              </td>
              <td className="whitespace-nowrap px-2 py-1">{issue.state ? <StatePill state={issue.state} /> : <span className="text-gray-400">-</span>}</td>
              <td className="min-w-36 px-2 py-1">
                {issue.labels.length > 0 ? (
                  <div className="flex flex-wrap gap-1">{issue.labels.map((label) => <Badge key={label}>{label}</Badge>)}</div>
                ) : <span className="text-gray-400">-</span>}
              </td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{timestampLabel(issue.createdAt) || "-"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{timestampLabel(issue.updatedAt) || "-"}</td>
              <td className="whitespace-nowrap px-2 py-1">{issue.url ? <InternalLink href={issue.url}>open</InternalLink> : <span className="text-gray-400">-</span>}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

export function renderIssueList(context: ToolCardContext): ReactNode | null {
  const rows = issueRows(context)
  return rows ? <IssueListCard rows={rows} /> : null
}

function parseTag(value: unknown): TagRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null
  return {
    id: displayValue(value.id) || displayValue(value.tag_id),
    name,
    color: displayValue(value.color),
    jobIds: arrayStrings(value.job_ids).map((id) => id.replace(/^JOB-/i, ""))
  }
}

function tagFromInput(context: ToolCardContext): TagRow | null {
  const name = displayValue(context.input?.name)
  const tagId = displayValue(context.input?.tag_id)
  if (!name && !tagId) return null
  return { id: tagId, name: name || `tag ${tagId}`, color: displayValue(context.input?.color), jobIds: [] }
}

function tagRows(context: ToolCardContext): TagRow[] | null {
  const parsed = context.parsedResult
  const rows = Array.isArray(parsed) ? parsed : isPlainObject(parsed) && Array.isArray(parsed.tags) ? parsed.tags : null
  if (!rows) return null
  return rows.flatMap((item) => {
    const tag = parseTag(item)
    return tag ? [tag] : []
  })
}

export function tagListSummary(context: ToolCardContext) {
  if (context.resultError) return "Could not list tags"
  const rows = tagRows(context)
  if (!rows) return context.parsedResult == null && context.resultBody === "" ? "Loading tags" : null
  return rows.length === 0 ? "No tags" : `${rows.length} tag${rows.length === 1 ? "" : "s"}`
}

const TAG_PALETTE: Record<string, { backgroundColor: string; color: string }> = {
  gray: { backgroundColor: "#f3f4f6", color: "#374151" },
  red: { backgroundColor: "#fee2e2", color: "#991b1b" },
  amber: { backgroundColor: "#fef3c7", color: "#92400e" },
  green: { backgroundColor: "#dcfce7", color: "#166534" },
  blue: { backgroundColor: "#dbeafe", color: "#1d4ed8" },
  indigo: { backgroundColor: "#e0e7ff", color: "#3730a3" },
  violet: { backgroundColor: "#ede9fe", color: "#6d28d9" },
  pink: { backgroundColor: "#fce7f3", color: "#be185d" }
}

function tagStyle(color: string | null): CSSProperties | undefined {
  if (!color) return undefined
  const paletteStyle = TAG_PALETTE[color]
  if (paletteStyle) return { ...paletteStyle, borderColor: paletteStyle.backgroundColor }
  if (!color.match(/^#[0-9a-f]{6}$/i)) return undefined

  const red = parseInt(color.slice(1, 3), 16)
  const green = parseInt(color.slice(3, 5), 16)
  const blue = parseInt(color.slice(5, 7), 16)
  const textColor = (0.299 * red + 0.587 * green + 0.114 * blue) / 255 > 0.62 ? "#111827" : "#ffffff"
  return { backgroundColor: color, borderColor: color, color: textColor }
}

function TagChip({ tag }: { tag: TagRow }) {
  return (
    <span className="inline-flex max-w-full items-center gap-1 rounded-full border border-gray-200 bg-gray-100 px-2 py-0.5 text-2xs font-medium text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200" style={tagStyle(tag.color)}>
      <span className="truncate">{tag.name}</span>
      {tag.id ? <span className="font-mono opacity-70">#{tag.id}</span> : null}
    </span>
  )
}

export function TagListCard({ rows }: { rows: TagRow[] }) {
  if (rows.length === 0) return <EmptyState>No tags found.</EmptyState>

  return (
    <CardShell>
      <div className="flex items-center justify-between gap-2">
        <SectionLabel>Tags</SectionLabel>
        <span className="text-2xs text-gray-500 dark:text-gray-400">{rows.length} total</span>
      </div>
      <div className="divide-y divide-gray-100 dark:divide-gray-800">
        {rows.map((tag, index) => {
          const jobIds = Array.from(new Set(tag.jobIds))
          return (
            <div className="flex flex-col gap-2 py-2 first:pt-0 last:pb-0 sm:flex-row sm:items-start sm:justify-between" key={tag.id || `${tag.name}-${index}`}>
              <div className="flex min-w-0 flex-wrap items-center gap-2">
                <TagChip tag={tag} />
                {tag.color ? <span className="font-mono text-2xs text-gray-500 dark:text-gray-400">{tag.color}</span> : null}
              </div>
              <div className="flex min-w-0 flex-wrap items-center gap-1 sm:max-w-3/5 sm:justify-end">
                <span className="mr-1 text-2xs text-gray-500 dark:text-gray-400">{jobIds.length} {jobIds.length === 1 ? "Job" : "Jobs"}</span>
                {jobIds.map((id) => <Badge key={id}><EntityReference id={id} kind="job" /></Badge>)}
              </div>
            </div>
          )
        })}
      </div>
    </CardShell>
  )
}

export function renderTagList(context: ToolCardContext): ReactNode | null {
  if (context.resultError) return <ErrorCard title="List tags" message={context.resultBody || "Unable to list tags."} />
  const rows = tagRows(context)
  if (rows) return <TagListCard rows={rows} />
  if (context.parsedResult == null && context.resultBody === "") {
    return <CardShell><StatePill state="pending" /></CardShell>
  }
  return null
}

export function parseTagAction(context: ToolCardContext, action: TagAction["action"]): TagAction | null {
  const parsed = context.parsedResult
  const parsedError = isPlainObject(parsed) ? displayValue(parsed.error) : null
  const resultTag = parseTag(parsed)
  const inputTag = tagFromInput(context)
  const tag = resultTag || inputTag
  const success = resultTag != null || (isPlainObject(parsed) && parsed.success === true)
  const pending = parsed == null && !context.resultError && context.resultBody === "" && inputTag != null
  if (!tag && !success && !parsedError && !context.resultError) return null

  return {
    action,
    tag,
    inputTag,
    resultTag,
    jobId: displayValue(context.input?.job_id),
    success,
    error: parsedError || (context.resultError ? context.resultBody : null),
    pending
  }
}

export function tagActionSummary(result: TagAction) {
  const verb = result.action === "create" ? "Created" : result.action === "add" ? "Added" : "Removed"
  const command = result.action === "create" ? "Create" : result.action === "add" ? "Add" : "Remove"
  const target = result.tag?.name || (result.tag?.id ? `tag ${result.tag.id}` : "tag")
  const job = result.jobId ? ` · JOB-${result.jobId}` : ""
  if (result.error) return `${verb} ${target} failed${job}`
  if (result.pending) return `${verb.replace(/ed$/, "ing")} ${target}${job}`
  if (!result.success) return `${command} ${target} returned an unexpected response${job}`
  return `${verb} ${target}${job}`
}

export function TagActionCard({ result }: { result: TagAction }) {
  const title = result.action === "create" ? "Create tag" : result.action === "add" ? "Add Job tag" : "Remove Job tag"
  if (result.error) return <ErrorCard title={title} message={result.error} />

  const state = result.pending ? "pending" : result.success ? "success" : "unknown"
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={state} tone={result.pending || !result.success ? undefined : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{title}</span>
        {result.tag ? <TagChip tag={result.tag} /> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.action === "create" && result.inputTag?.name ? <Row label="Requested name" value={result.inputTag.name} /> : null}
        {result.action === "create" && result.inputTag?.color ? <Row label="Requested color" value={result.inputTag.color} /> : null}
        {result.action === "create" && result.resultTag?.name ? <Row label="Created name" value={result.resultTag.name} /> : null}
        {result.action === "create" && result.resultTag?.color ? <Row label="Created color" value={result.resultTag.color} /> : null}
        {result.jobId ? <Row label="Job" value={`JOB-${result.jobId}`} /> : null}
        {result.tag?.id ? <Row label="Tag" value={result.tag.id} /> : null}
      </dl>
      {!result.pending && !result.success ? <EmptyState>Unexpected tool response.</EmptyState> : null}
    </CardShell>
  )
}

function previewFromPayload(payload: unknown): string | null {
  if (payload == null) return null
  const text = typeof payload === "string" ? payload : JSON.stringify(payload, null, 2)
  if (!text) return null
  const clipped = text.length > ARTIFACT_PREVIEW_CHARS ? `${text.slice(0, ARTIFACT_PREVIEW_CHARS)}...` : text
  return truncateLines(clipped, ARTIFACT_PREVIEW_LINES).preview
}

export function parseArtifactResult(context: ToolCardContext): ArtifactResult | null {
  const parsed = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const title = displayValue(parsed.title) || displayValue(context.input?.title)
  const type = displayValue(parsed.type) || displayValue(context.input?.type)
  const message = displayValue(parsed.message) || (context.resultBody === "Saved." ? "Saved." : null)
  if (!title && !type && !message && !context.resultError) return null

  return {
    title,
    type,
    id: displayValue(parsed.id) || displayValue(parsed.artifact_id),
    path: displayValue(parsed.path) || displayValue(parsed.file_path),
    url: displayValue(parsed.url) || displayValue(parsed.href),
    message: context.resultError ? context.resultBody : message,
    preview: previewFromPayload(isPlainObject(parsed) && parsed.payload !== undefined ? parsed.payload : context.input?.payload)
  }
}

export function artifactSummary(context: ToolCardContext) {
  const artifact = parseArtifactResult(context)
  if (!artifact) return null
  if (context.resultError) return artifact.title ? `Artifact ${artifact.title} failed` : "Artifact submission failed"
  return artifact.title ? `Artifact saved: ${artifact.title}` : "Artifact saved"
}

export function ArtifactCard({ artifact, error = false }: { artifact: ArtifactResult; error?: boolean }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={error ? "failed" : "saved"} tone={error ? "failure" : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{artifact.title || "Artifact"}</span>
        {artifact.type ? <Badge>{artifact.type}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {artifact.id ? <Row label="Artifact" value={artifact.id} /> : null}
        {artifact.path ? <Row label="Path" value={artifact.path} /> : null}
      </dl>
      {artifact.url || artifact.path ? (
        <div className="flex flex-wrap gap-2">
          {artifact.url ? <InternalLink href={artifact.url}>open</InternalLink> : null}
          {artifact.url ? <InternalLink href={artifact.url}>download</InternalLink> : null}
          {artifact.path ? <span className="font-mono text-gray-600 dark:text-gray-300">preview available in raw details</span> : null}
        </div>
      ) : null}
      {artifact.message ? <div className={error ? "text-danger-text" : "text-text-secondary"}>{artifact.message}</div> : null}
      {artifact.preview ? (
        <div>
          <SectionLabel>Preview</SectionLabel>
          <pre className="mt-1 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded bg-surface p-2 font-mono text-2xs text-text-secondary">{artifact.preview}</pre>
        </div>
      ) : null}
    </CardShell>
  )
}

export function renderArtifact(context: ToolCardContext): ReactNode | null {
  const artifact = parseArtifactResult(context)
  return artifact ? <ArtifactCard artifact={artifact} error={context.resultError} /> : null
}
