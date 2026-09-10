import type { CSSProperties, ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, InternalLink, Row, SectionLabel, StatePill, truncateLines } from "./toolCardUi"
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
  jobId: string | null
  success: boolean
  error: string | null
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
  const rows = tagRows(context)
  if (!rows) return null
  return rows.length === 0 ? "No tags" : `${rows.length} tag${rows.length === 1 ? "" : "s"}`
}

function tagStyle(color: string | null): CSSProperties | undefined {
  if (!color?.match(/^#[0-9a-f]{6}$/i)) return undefined
  return { backgroundColor: color, borderColor: color, color: "#111827" }
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
      <div className="flex flex-wrap gap-1">
        {rows.map((tag, index) => <TagChip key={tag.id || `${tag.name}-${index}`} tag={tag} />)}
      </div>
      <div>
        <SectionLabel>Affected Jobs</SectionLabel>
        <div className="mt-1 flex flex-wrap gap-1">
          {Array.from(new Set(rows.flatMap((tag) => tag.jobIds))).length > 0
            ? Array.from(new Set(rows.flatMap((tag) => tag.jobIds))).map((id) => <Badge key={id}>JOB-{id}</Badge>)
            : <span className="text-gray-500 dark:text-gray-400">No tagged Jobs.</span>}
        </div>
      </div>
    </CardShell>
  )
}

export function renderTagList(context: ToolCardContext): ReactNode | null {
  const rows = tagRows(context)
  return rows ? <TagListCard rows={rows} /> : null
}

export function parseTagAction(context: ToolCardContext, action: TagAction["action"]): TagAction | null {
  const parsed = context.parsedResult
  const parsedError = isPlainObject(parsed) ? displayValue(parsed.error) : null
  const tag = parseTag(parsed) || tagFromInput(context)
  const success = isPlainObject(parsed) && parsed.success === true
  if (!tag && !success && !parsedError && !context.resultError) return null

  return {
    action,
    tag,
    jobId: displayValue(context.input?.job_id),
    success,
    error: parsedError || (context.resultError ? context.resultBody : null)
  }
}

export function tagActionSummary(result: TagAction) {
  const verb = result.action === "create" ? "Created" : result.action === "add" ? "Added" : "Removed"
  const target = result.tag?.name || (result.tag?.id ? `tag ${result.tag.id}` : "tag")
  const job = result.jobId ? ` · JOB-${result.jobId}` : ""
  if (result.error) return `${verb} ${target} failed${job}`
  return `${verb} ${target}${job}`
}

export function TagActionCard({ result }: { result: TagAction }) {
  const state = result.error ? "failed" : result.success || result.tag ? "success" : "unknown"
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={state} tone={result.error ? "failure" : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{result.action === "create" ? "Create tag" : result.action === "add" ? "Add Job tag" : "Remove Job tag"}</span>
        {result.tag ? <TagChip tag={result.tag} /> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.jobId ? <Row label="Job" value={`JOB-${result.jobId}`} /> : null}
        {result.tag?.id ? <Row label="Tag" value={result.tag.id} /> : null}
      </dl>
      {result.error ? (
        <div>
          <SectionLabel>Outcome</SectionLabel>
          <div className="mt-0.5 text-red-700 dark:text-red-300">{result.error}</div>
        </div>
      ) : null}
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
      {artifact.message ? <div className={error ? "text-red-700 dark:text-red-300" : "text-gray-700 dark:text-gray-300"}>{artifact.message}</div> : null}
      {artifact.preview ? (
        <div>
          <SectionLabel>Preview</SectionLabel>
          <pre className="mt-1 max-h-48 overflow-auto whitespace-pre-wrap break-words rounded bg-white p-2 font-mono text-2xs text-gray-700 dark:bg-gray-950 dark:text-gray-300">{artifact.preview}</pre>
        </div>
      ) : null}
    </CardShell>
  )
}

export function renderArtifact(context: ToolCardContext): ReactNode | null {
  const artifact = parseArtifactResult(context)
  return artifact ? <ArtifactCard artifact={artifact} error={context.resultError} /> : null
}
