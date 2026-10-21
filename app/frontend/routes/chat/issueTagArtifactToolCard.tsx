import type { CSSProperties, ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, InternalLink, Row, SectionLabel, StatePill } from "./toolCardUi"
import { ErrorCard } from "./chatHelperToolCard"
import { MarkdownPreview } from "./toolCardMarkdown"
import { MediaPreviewShell } from "./mediaPreviewShell"
import { formatRelativeDate } from "../../lib/relativeTime"
import { useT } from "../../hooks/useT"
import i18n from "../../i18n"

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
  name: string | null
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
  payload: unknown
  workflowId: string | null
  runId: string | null
  jobId: string | null
  chatSessionId: string | null
  pending: boolean
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

    return [
      {
        number,
        title,
        labels: arrayStrings(item.labels),
        state: displayValue(item.state),
        createdAt: displayValue(item.created_at),
        updatedAt: displayValue(item.updated_at),
        url: displayValue(item.url) || displayValue(item.html_url),
        repository: displayValue(item.repository) || displayValue(item.repository_slug)
      }
    ]
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
            <th className="px-2 py-1 font-semibold" scope="col">
              Issue
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              State
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Labels
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Age
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Updated
            </th>
            <th className="px-2 py-1 font-semibold" scope="col">
              Link
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((issue) => (
            <tr key={issue.number}>
              <td className="max-w-80 px-2 py-1">
                <div className="font-mono font-medium text-gray-800 dark:text-gray-200">#{issue.number}</div>
                <div className="truncate text-gray-700 dark:text-gray-300" title={issue.title}>
                  {issue.title}
                </div>
                {issue.repository ? <div className="truncate font-mono text-2xs text-gray-500 dark:text-gray-400">{issue.repository}</div> : null}
              </td>
              <td className="whitespace-nowrap px-2 py-1">{issue.state ? <StatePill state={issue.state} /> : <span className="text-gray-400">-</span>}</td>
              <td className="min-w-36 px-2 py-1">
                {issue.labels.length > 0 ? (
                  <div className="flex flex-wrap gap-1">
                    {issue.labels.map((label) => (
                      <Badge key={label}>{label}</Badge>
                    ))}
                  </div>
                ) : (
                  <span className="text-gray-400">-</span>
                )}
              </td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{timestampLabel(issue.createdAt) || "-"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{timestampLabel(issue.updatedAt) || "-"}</td>
              <td className="whitespace-nowrap px-2 py-1">
                {issue.url ? <InternalLink href={issue.url}>open</InternalLink> : <span className="text-gray-400">-</span>}
              </td>
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
  return { id: tagId, name, color: displayValue(context.input?.color), jobIds: [] }
}

function tagFromPriorResults(context: ToolCardContext, tagId: string | null): TagRow | null {
  if (!tagId) return null
  const prior = context.priorResults?.list_tags
  const rows = Array.isArray(prior) ? prior : isPlainObject(prior) && Array.isArray(prior.tags) ? prior.tags : []
  return (
    rows.flatMap((item) => {
      const tag = parseTag(item)
      return tag?.id === tagId ? [tag] : []
    })[0] ?? null
  )
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
  if (context.resultError) return i18n.t("chat:tool_card_tags_error_summary")
  if (context.parsedResult == null && context.resultBody === "") return i18n.t("chat:tool_card_tags_loading_summary")
  const rows = tagRows(context)
  if (!rows) return null
  return i18n.t("chat:tool_card_tags_count", { count: rows.length })
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
    <span
      className="inline-flex max-w-full items-center gap-1 rounded-full border border-gray-200 bg-gray-100 px-2 py-0.5 text-2xs font-medium text-gray-700 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-200"
      style={tagStyle(tag.color)}
    >
      <span className="truncate">{tag.name || `Tag #${tag.id}`}</span>
      {tag.name && tag.id ? <span className="font-mono opacity-70">#{tag.id}</span> : null}
    </span>
  )
}

export function TagListCard({ rows }: { rows: TagRow[] }) {
  const { t } = useT("chat")
  if (rows.length === 0) return <EmptyState>{t("tool_card_tags_empty")}</EmptyState>

  return (
    <CardShell>
      <SectionLabel>{t("tool_card_tags_section", { count: rows.length })}</SectionLabel>
      <div className="grid gap-2">
        {rows.map((tag, index) => (
          <div
            className="flex min-w-0 flex-col gap-1 rounded border border-gray-200 p-2 sm:flex-row sm:items-center sm:justify-between dark:border-gray-700"
            key={tag.id || `${tag.name || "tag"}-${index}`}
          >
            <TagChip tag={tag} />
            <div className="flex flex-wrap items-center gap-1 sm:justify-end">
              <span className="text-2xs text-gray-500 dark:text-gray-400">{t("tool_card_tags_jobs_count", { count: tag.jobIds.length })}</span>
              {tag.jobIds.map((id) => (
                <Badge key={id}>
                  <EntityReference id={id} kind="job" />
                </Badge>
              ))}
            </div>
          </div>
        ))}
      </div>
    </CardShell>
  )
}

function TagListResult({ context }: { context: ToolCardContext }) {
  const { t } = useT("chat")
  if (context.resultError) {
    return <ErrorCard title={t("tool_card_tags_error_title")} message={context.resultBody || t("tool_card_tags_error_fallback")} />
  }
  if (context.parsedResult == null && context.resultBody === "") {
    return (
      <CardShell>
        <div className="flex items-center gap-2">
          <StatePill state="pending" />
          <span>{t("tool_card_tags_loading")}</span>
        </div>
      </CardShell>
    )
  }

  const rows = tagRows(context)
  return rows ? <TagListCard rows={rows} /> : null
}

export function renderTagList(context: ToolCardContext): ReactNode | null {
  if (!context.resultError && !(context.parsedResult == null && context.resultBody === "") && !tagRows(context)) return null
  return <TagListResult context={context} />
}

export function parseTagAction(context: ToolCardContext, action: TagAction["action"]): TagAction | null {
  const parsed = context.parsedResult
  const parsedError = isPlainObject(parsed) ? displayValue(parsed.error) : null
  const resultTag = parseTag(parsed)
  const inputTag = tagFromInput(context)
  const priorTag = action === "create" ? null : tagFromPriorResults(context, inputTag?.id ?? null)
  const tag = resultTag || priorTag || inputTag
  const success = resultTag != null || (isPlainObject(parsed) && parsed.success === true)
  const pending = context.resultSettled !== true && parsed == null && !context.resultError && context.resultBody === "" && inputTag != null
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
  const target = result.tag?.name || (result.tag?.id ? `tag #${result.tag.id}` : "tag")
  const job = result.jobId ? ` · JOB-${result.jobId}` : ""
  if (result.error) return `${verb} ${target} failed${job}`
  if (result.pending) return `${verb.replace(/ed$/, "ing")} ${target}${job}`
  if (!result.success) return `${command} ${target} returned an unexpected response${job}`
  return `${verb} ${target}${job}`
}

export function TagActionCard({ result }: { result: TagAction }) {
  const title = result.action === "create" ? "Create tag" : result.action === "add" ? "Add Job tag" : "Remove Job tag"
  if (result.error) {
    return (
      <ErrorCard title={title} message={result.error}>
        {result.tag ? <TagChip tag={result.tag} /> : null}
        <TagActionMetadata result={result} />
      </ErrorCard>
    )
  }

  const state = result.pending ? "pending" : result.success ? "success" : "unknown"
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={state} tone={result.pending || !result.success ? undefined : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{title}</span>
        {result.tag ? <TagChip tag={result.tag} /> : null}
      </div>
      <TagActionMetadata result={result} />
      {!result.pending && !result.success ? <EmptyState>Unexpected tool response.</EmptyState> : null}
    </CardShell>
  )
}

function TagActionMetadata({ result }: { result: TagAction }) {
  return (
    <dl className="grid min-w-0 gap-1 sm:grid-cols-2">
      {result.action === "create" && result.inputTag?.name ? <Row label="Requested name" value={result.inputTag.name} /> : null}
      {result.action === "create" && result.inputTag?.color ? <Row label="Requested color" value={result.inputTag.color} /> : null}
      {result.action === "create" && result.resultTag?.name ? <Row label="Created name" value={result.resultTag.name} /> : null}
      {result.action === "create" && result.resultTag?.color ? <Row label="Created color" value={result.resultTag.color} /> : null}
      {result.jobId ? (
        <div className="min-w-0">
          <SectionLabel>Job</SectionLabel>
          <EntityReference id={result.jobId} kind="job" wrap="break" />
        </div>
      ) : null}
      {result.tag?.id ? <Row label="Tag ID" value={result.tag.id} /> : null}
    </dl>
  )
}

function artifactEnvelope(value: unknown): Record<string, unknown> {
  if (!isPlainObject(value)) return {}
  for (const key of ["structured_content", "structuredContent", "result", "output"]) {
    if (isPlainObject(value[key])) return { ...value, ...artifactEnvelope(value[key]) }
  }
  return value
}

function artifactPayloadText(payload: unknown): string {
  if (payload == null) return ""
  if (typeof payload === "string") return payload
  if (isPlainObject(payload)) {
    const prose = Object.entries(payload).flatMap(([key, value]) =>
      typeof value === "string" && value.trim() && !/(url|path|image|screenshot|data)/i.test(key) ? [`**${key.replace(/_/g, " ")}**\n\n${value}`] : []
    )
    if (prose.length > 0) return prose.join("\n\n")
    if (Object.values(payload).every((value) => typeof value === "string" && !value.trim())) return ""
  }
  return `\`\`\`json\n${JSON.stringify(payload, null, 2)}\n\`\`\``
}

function artifactImage(payload: unknown): string | null {
  if (!isPlainObject(payload)) return null
  for (const key of ["image_url", "screenshot_url", "preview_url", "data_url", "file_path", "path", "image", "screenshot"]) {
    const candidate = displayValue(payload[key])
    if (candidate && (candidate.startsWith("/") || candidate.startsWith("data:image/") || /^https?:\/\//i.test(candidate))) return candidate
  }
  return null
}

export function parseArtifactResult(context: ToolCardContext): ArtifactResult | null {
  const parsed = artifactEnvelope(context.parsedResult)
  const title = displayValue(parsed.title) || displayValue(context.input?.title)
  const type = displayValue(parsed.type) || displayValue(context.input?.type)
  const message = displayValue(parsed.message) || (context.resultBody === "Saved." ? "Saved." : null)
  const pending = context.resultSettled !== true && context.parsedResult == null && context.resultBody === "" && !!(title || type)
  if (!title && !type && !message && !context.resultError && !pending) return null

  return {
    title,
    type,
    id: displayValue(parsed.id) || displayValue(parsed.artifact_id),
    path: displayValue(parsed.path) || displayValue(parsed.file_path),
    url: displayValue(parsed.url) || displayValue(parsed.href),
    message: context.resultError ? context.resultBody : message,
    payload: parsed.payload !== undefined ? parsed.payload : context.input?.payload,
    workflowId: displayValue(parsed.workflow_id) || displayValue(context.input?.workflow_id),
    runId: displayValue(parsed.run_id) || displayValue(context.input?.run_id),
    jobId: displayValue(parsed.job_id) || displayValue(context.input?.job_id),
    chatSessionId: displayValue(parsed.chat_session_id) || displayValue(context.chatSessionId),
    pending
  }
}

export function artifactSummary(context: ToolCardContext) {
  const artifact = parseArtifactResult(context)
  if (!artifact) return null
  if (context.resultError) return artifact.title ? `Artifact ${artifact.title} failed` : "Artifact submission failed"
  if (artifact.pending) return artifact.title ? `Saving artifact: ${artifact.title}` : "Saving artifact"
  return artifact.title ? `Artifact saved: ${artifact.title}` : "Artifact saved"
}

export function ArtifactCard({ artifact, error = false }: { artifact: ArtifactResult; error?: boolean }) {
  if (error) return <ErrorCard title="Artifact submission failed" message={artifact.message || "The artifact could not be saved."} />
  const image = artifactImage(artifact.payload)
  const preview = artifactPayloadText(artifact.payload)
  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={artifact.pending ? "pending" : "saved"} tone={artifact.pending ? "info" : "success"} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{artifact.title || "Artifact"}</span>
        {artifact.type ? <Badge>{artifact.type}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {artifact.id ? <Row label="Artifact" value={artifact.id} /> : null}
        {artifact.path ? <Row label="Path" value={artifact.path} /> : null}
        {artifact.workflowId ? (
          <div className="min-w-0">
            <SectionLabel>Workflow</SectionLabel>
            <EntityReference id={artifact.workflowId} jobId={artifact.jobId} kind="workflow" />
          </div>
        ) : null}
        {artifact.runId ? (
          <div className="min-w-0">
            <SectionLabel>Run</SectionLabel>
            <EntityReference id={artifact.runId} jobId={artifact.jobId} workflowId={artifact.workflowId} kind="run" />
          </div>
        ) : null}
      </dl>
      {artifact.url || artifact.chatSessionId ? (
        <div className="flex flex-wrap gap-2">
          {artifact.url ? <InternalLink href={artifact.url}>open</InternalLink> : null}
          {artifact.url ? <InternalLink href={artifact.url}>download</InternalLink> : null}
          {artifact.chatSessionId ? <InternalLink href={`/chats/${artifact.chatSessionId}#media`}>Chat Media library</InternalLink> : null}
        </div>
      ) : null}
      {artifact.message ? <div className="break-words text-gray-700 dark:text-gray-300">{artifact.message}</div> : null}
      {artifact.pending ? (
        <EmptyState>Waiting for the artifact result.</EmptyState>
      ) : image ? (
        <MediaPreviewShell
          item={{
            title: artifact.title || artifact.type || "Artifact",
            src: image,
            alt: artifact.title || "Submitted artifact",
            badge: artifact.type || "image",
            actions: [
              { label: "Open", href: image },
              { label: "Download", href: image, download: true }
            ]
          }}
          thumbnailClassName="w-full max-w-72"
        />
      ) : (
        <MarkdownPreview
          emptyLabel="No artifact payload was submitted."
          linkifySlugs
          linkifyUrls
          maxChars={ARTIFACT_PREVIEW_CHARS}
          modalLabel={`${artifact.title || "Artifact"} payload`}
          text={preview}
          title="Payload"
        />
      )}
    </CardShell>
  )
}

export function renderArtifact(context: ToolCardContext): ReactNode | null {
  const artifact = parseArtifactResult(context)
  return artifact ? <ArtifactCard artifact={artifact} error={context.resultError} /> : null
}
