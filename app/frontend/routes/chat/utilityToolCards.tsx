import type { ToolCardContext } from "@app/pluginToolCards"
import { RelativeTimestamp } from "../../components/RelativeTimestamp"
import { Badge, CardShell, displayValue, EmptyState, Row, SectionLabel, StatePill } from "./toolCardUi"

type IssueRow = {
  key: string
  number: string
  title: string
  labels: string[]
  state: string | null
  author: string | null
  createdAt: string | null
  updatedAt: string | null
  url: string | null
  bodyExcerpt: string | null
}

type TagRow = {
  key: string
  id: string | null
  name: string
  color: string | null
  jobIds: string[]
}

type TagAction = {
  kind: "created" | "added" | "removed" | "failed"
  message: string
  tag: TagRow | null
  jobIds: string[]
}

type ArtifactInfo = {
  title: string
  type: string
  id: string | null
  path: string | null
  url: string | null
  downloadUrl: string | null
  previewUrl: string | null
  rendererType: string | null
  createdAt: string | null
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function stringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return []
  return value.flatMap((item) => {
    const text = displayValue(item)
    return text ? [text] : []
  })
}

function candidateValue(source: Record<string, unknown>, keys: string[]): string | null {
  for (const key of keys) {
    const value = displayValue(source[key])
    if (value) return value
  }
  return null
}

function linkHref(value: string | null): string | null {
  if (!value) return null
  return /^(https?:|\/)/.test(value) ? value : null
}

function parseIssue(value: unknown): IssueRow | null {
  if (!isPlainObject(value)) return null
  const number = displayValue(value.number)
  if (!number) return null

  return {
    key: number,
    number,
    title: displayValue(value.title) || `Issue #${number}`,
    labels: stringArray(value.labels),
    state: displayValue(value.state),
    author: candidateValue(value, ["author", "user", "login"]),
    createdAt: displayValue(value.created_at),
    updatedAt: displayValue(value.updated_at),
    url: linkHref(candidateValue(value, ["html_url", "web_url", "url"])),
    bodyExcerpt: displayValue(value.body_excerpt)
  }
}

export function issueRows(context: ToolCardContext): IssueRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.issues)) return null
  return parsed.issues.flatMap((issue) => {
    const row = parseIssue(issue)
    return row ? [row] : []
  })
}

export function issueListSummary(context: ToolCardContext) {
  const rows = issueRows(context)
  if (!rows) return null
  return `${rows.length} issue${rows.length === 1 ? "" : "s"}`
}

export function IssueListCard({ rows }: { rows: IssueRow[] }) {
  if (rows.length === 0) return <EmptyState>No issues found.</EmptyState>

  return (
    <div className="mt-1 space-y-2">
      {rows.map((issue) => (
        <CardShell key={issue.key}>
          <div className="flex flex-wrap items-center gap-2">
            {issue.url ? (
              <a className="font-mono font-semibold text-brand hover:underline dark:text-brand-emphasis" href={issue.url} rel="noreferrer" target="_blank">#{issue.number}</a>
            ) : (
              <span className="font-mono font-semibold text-gray-900 dark:text-gray-100">#{issue.number}</span>
            )}
            {issue.state ? <StatePill state={issue.state} /> : null}
            {issue.author ? <Badge>@{issue.author}</Badge> : null}
          </div>
          <div className="text-sm font-medium text-gray-900 dark:text-gray-100">{issue.title}</div>
          {issue.labels.length > 0 ? <ChipList items={issue.labels} /> : null}
          <div className="grid gap-1 sm:grid-cols-2">
            {issue.createdAt ? <TimestampRow label="Created" value={issue.createdAt} /> : null}
            {issue.updatedAt ? <TimestampRow label="Updated" value={issue.updatedAt} /> : null}
          </div>
          {issue.bodyExcerpt ? <p className="line-clamp-3 text-xs text-gray-600 dark:text-gray-300">{issue.bodyExcerpt}</p> : null}
        </CardShell>
      ))}
    </div>
  )
}

function parseTag(value: unknown): TagRow | null {
  if (!isPlainObject(value)) return null
  const name = displayValue(value.name)
  if (!name) return null
  const id = displayValue(value.id)
  return {
    key: id || name,
    id,
    name,
    color: displayValue(value.color),
    jobIds: stringArray(value.job_ids ?? value.jobs ?? value.affected_job_ids)
  }
}

export function tagRows(context: ToolCardContext): TagRow[] | null {
  const parsed = context.parsedResult
  if (!isPlainObject(parsed) || !Array.isArray(parsed.tags)) return null
  return parsed.tags.flatMap((tag) => {
    const row = parseTag(tag)
    return row ? [row] : []
  })
}

export function tagListSummary(context: ToolCardContext) {
  const rows = tagRows(context)
  if (!rows) return null
  return `${rows.length} tag${rows.length === 1 ? "" : "s"}`
}

export function TagListCard({ rows }: { rows: TagRow[] }) {
  if (rows.length === 0) return <EmptyState>No tags found.</EmptyState>

  return (
    <CardShell>
      <div className="flex flex-wrap gap-1.5">
        {rows.map((tag) => <TagChip key={tag.key} tag={tag} />)}
      </div>
      {rows.some((tag) => tag.jobIds.length > 0) ? (
        <div className="space-y-1">
          <SectionLabel>Affected Jobs</SectionLabel>
          {rows.filter((tag) => tag.jobIds.length > 0).map((tag) => (
            <div className="flex flex-wrap items-center gap-1.5" key={`jobs-${tag.key}`}>
              <TagChip tag={tag} />
              <ChipList items={tag.jobIds.map((id) => `JOB-${id.replace(/^JOB-/i, "")}`)} />
            </div>
          ))}
        </div>
      ) : null}
    </CardShell>
  )
}

export function tagAction(context: ToolCardContext, action: "create" | "add" | "remove"): TagAction | null {
  if (context.resultError) {
    return {
      kind: "failed",
      message: context.resultBody.trim() || "Tag operation failed.",
      tag: tagFromInput(context),
      jobIds: stringArray([context.input?.job_id])
    }
  }

  const parsed = context.parsedResult
  if (!isPlainObject(parsed)) return null

  const tag = parseTag(parsed) ?? tagFromInput(context)
  const jobIds = stringArray([parsed.job_id, context.input?.job_id, ...stringArray(parsed.job_ids)])
  const kind = action === "create" ? "created" : action === "add" ? "added" : "removed"
  const message = action === "create" ? "Tag created." : action === "add" ? "Tag added to Job." : "Tag removed from Job."

  return { kind, message, tag, jobIds }
}

function tagFromInput(context: ToolCardContext): TagRow | null {
  const name = displayValue(context.input?.name)
  const id = displayValue(context.input?.tag_id)
  if (!name && !id) return null
  return { key: id || name || "tag", id, name: name || `Tag ${id}`, color: displayValue(context.input?.color), jobIds: [] }
}

export function tagActionSummary(context: ToolCardContext, action: "create" | "add" | "remove") {
  const outcome = tagAction(context, action)
  if (!outcome) return null
  if (outcome.kind === "failed") return "Tag operation failed"
  if (outcome.tag) return `${outcome.tag.name}: ${outcome.kind}`
  return outcome.message
}

export function TagActionCard({ outcome }: { outcome: TagAction }) {
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={outcome.kind} tone={outcome.kind === "failed" ? "failure" : "success"} />
        <span className="font-medium text-gray-900 dark:text-gray-100">{outcome.message}</span>
      </div>
      {outcome.tag || outcome.jobIds.length > 0 ? (
        <div className="flex flex-wrap items-center gap-1.5">
          {outcome.tag ? <TagChip tag={outcome.tag} /> : null}
          {outcome.jobIds.map((id) => <Badge key={id}>JOB-{id.replace(/^JOB-/i, "")}</Badge>)}
        </div>
      ) : null}
    </CardShell>
  )
}

function TagChip({ tag }: { tag: TagRow }) {
  const style = tag.color && /^#[0-9a-fA-F]{6}$/.test(tag.color) ? { backgroundColor: tag.color, color: readableTextColor(tag.color) } : undefined
  return (
    <span className="inline-flex max-w-full items-center gap-1 rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-200" style={style}>
      <span className="truncate">{tag.name}</span>
      {tag.id ? <span className="font-mono text-2xs opacity-70">#{tag.id}</span> : null}
    </span>
  )
}

function readableTextColor(hex: string) {
  const value = hex.replace("#", "")
  const red = parseInt(value.slice(0, 2), 16)
  const green = parseInt(value.slice(2, 4), 16)
  const blue = parseInt(value.slice(4, 6), 16)
  const luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
  return luminance > 0.62 ? "#111827" : "#ffffff"
}

export function artifactInfo(context: ToolCardContext): ArtifactInfo | null {
  if (context.resultError) return null

  const input = context.input ?? {}
  const payload = isPlainObject(input.payload) ? input.payload : {}
  const parsed = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const artifact = isPlainObject(parsed.artifact) ? parsed.artifact : parsed
  const source = { ...payload, ...artifact, ...input }

  const title = candidateValue(source, ["title", "name"])
  const type = displayValue(source.type)
  if (!title || !type) return null

  return {
    title,
    type,
    id: candidateValue(source, ["id", "artifact_id"]),
    path: candidateValue(source, ["path", "file_path", "filename"]),
    url: linkHref(candidateValue(source, ["html_url", "web_url", "url", "link"])),
    downloadUrl: linkHref(candidateValue(source, ["download_url", "download_path"])),
    previewUrl: linkHref(candidateValue(source, ["preview_url", "preview_path", "image_url"])),
    rendererType: displayValue(source.renderer_type),
    createdAt: displayValue(source.created_at)
  }
}

export function artifactSummary(context: ToolCardContext) {
  const artifact = artifactInfo(context)
  if (!artifact) return context.resultError ? "Artifact submission failed" : null
  return `${artifact.title} saved`
}

export function ArtifactSubmissionCard({ artifact }: { artifact: ArtifactInfo }) {
  const actions = [
    artifact.previewUrl ? { label: "Preview", href: artifact.previewUrl } : null,
    artifact.url ? { label: "Open", href: artifact.url } : null,
    artifact.downloadUrl ? { label: "Download", href: artifact.downloadUrl } : null
  ].filter((action): action is { label: string; href: string } => !!action)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state="saved" tone="success" />
        <span className="min-w-0 break-words text-sm font-medium text-gray-900 dark:text-gray-100">{artifact.title}</span>
        <Badge>{artifact.type}</Badge>
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {artifact.id ? <Row label="Artifact" value={artifact.id} /> : null}
        {artifact.path ? <Row label="Path" value={artifact.path} /> : null}
        {artifact.rendererType ? <Row label="Renderer" value={artifact.rendererType} /> : null}
        {artifact.createdAt ? <TimestampRow label="Created" value={artifact.createdAt} /> : null}
      </dl>
      {actions.length > 0 ? (
        <div className="flex flex-wrap gap-2">
          {actions.map((action) => (
            <a className="rounded border border-gray-200 bg-white px-2 py-1 text-xs font-medium text-brand hover:bg-gray-50 hover:underline dark:border-gray-700 dark:bg-gray-950 dark:text-brand-emphasis dark:hover:bg-gray-900" href={action.href} key={action.label} rel="noreferrer" target="_blank">
              {action.label}
            </a>
          ))}
        </div>
      ) : null}
      {artifact.previewUrl && imageLike(artifact.previewUrl) ? (
        <a href={artifact.previewUrl} rel="noreferrer" target="_blank">
          <img alt={artifact.title} className="max-h-56 max-w-full rounded border border-gray-200 object-contain dark:border-gray-700" src={artifact.previewUrl} />
        </a>
      ) : null}
    </CardShell>
  )
}

function TimestampRow({ label, value }: { label: string; value: string }) {
  return (
    <div className="min-w-0">
      <dt className="text-2xs font-semibold uppercase text-gray-500 dark:text-gray-400">{label}</dt>
      <dd className="truncate text-gray-700 dark:text-gray-300">
        <RelativeTimestamp value={value} />
      </dd>
    </div>
  )
}

function ChipList({ items }: { items: string[] }) {
  return (
    <div className="flex flex-wrap gap-1">
      {items.map((item) => <Badge key={item}>{item}</Badge>)}
    </div>
  )
}

function imageLike(url: string) {
  return /\.(png|jpe?g|gif|webp|avif|svg)(\?|#|$)/i.test(url) || url.startsWith("data:image/")
}
