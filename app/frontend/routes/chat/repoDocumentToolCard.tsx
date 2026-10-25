import type { ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import i18n from "../../i18n"
import { Badge, CardShell, displayValue, EmptyState, EntityReference, Row, SectionLabel, StatePill } from "./toolCardUi"
import { parsePendingActionResult, pendingActionCollapsedSummary, type PendingActionResult } from "./pendingActionToolCard"
import { MarkdownPreview } from "./toolCardMarkdown"
import { MediaPreviewShell } from "./mediaPreviewShell"
import { normalizedToolCardContentBlocks } from "./toolRendering"

const CONTENT_PREVIEW_LINES = 12
const CONTENT_PREVIEW_CHARS = 1_200

type DocumentRow = {
  id: string | null
  ref: string | null
  title: string
  kind: string | null
  status: string | null
  repositoryId: string | null
  repository: string | null
  contentType: string | null
  sizeBytes: number | null
  url: string | null
}

type DocumentAction = {
  action: "create" | "delete"
  pending: Exclude<PendingActionResult, { kind: "error" }>
  title: string | null
  documentId: string | null
  repositoryId: string | null
  repositorySlug: string | null
  body: string | null
  contentType: string | null
  sizeBytes: number | null
  documentUrl: string | null
}

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return Object.prototype.toString.call(value) === "[object Object]"
}

function numberValue(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) return Number(value)
  return null
}

function documentRef(value: Record<string, unknown>): string | null {
  return displayValue(value.ref) || displayValue(value.doc_ref) || displayValue(value.document_ref) || displayValue(value.id)
}

function parseDocument(value: unknown): DocumentRow | null {
  if (!isPlainObject(value)) return null
  const title = displayValue(value.title) || displayValue(value.name)
  if (!title) return null

  const id = displayValue(value.id) || displayValue(value.document_id)
  const repository = displayValue(value.repository) || displayValue(value.repository_slug) || displayValue(value.repo)

  return {
    id,
    ref: documentRef(value),
    title,
    kind: displayValue(value.kind) || displayValue(value.type),
    status: displayValue(value.status) || displayValue(value.state),
    repositoryId: displayValue(value.repository_id),
    repository,
    contentType: displayValue(value.content_type) || displayValue(value.mime_type),
    sizeBytes: numberValue(value.size_bytes) ?? numberValue(value.byte_size),
    url: displayValue(value.url) || displayValue(value.google_docs_url)
  }
}

function formatBytes(bytes: number): string {
  if (bytes < 1024) return `${bytes} B`
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(bytes < 10 * 1024 ? 1 : 0)} KB`
  return `${(bytes / 1024 / 1024).toFixed(1)} MB`
}

function documentHref(row: DocumentRow): string | null {
  if (row.url) return row.url
  return row.id && row.kind === "file" && row.status === "attached" ? `/api/v1/app/repository_documents/${encodeURIComponent(row.id)}/file` : null
}

export function parseRepoDocumentList(context: ToolCardContext): DocumentRow[] | null {
  const parsed = context.parsedResult
  const rawRows = Array.isArray(parsed) ? parsed : isPlainObject(parsed) && Array.isArray(parsed.documents) ? parsed.documents : null
  if (!rawRows) return null

  return rawRows.flatMap((item) => {
    const row = parseDocument(item)
    return row ? [row] : []
  })
}

export function repoDocumentListSummary(context: ToolCardContext) {
  const rows = parseRepoDocumentList(context)
  if (!rows) return null
  return rows.length === 0 ? "No repository documents" : `${rows.length} repository document${rows.length === 1 ? "" : "s"}`
}

export function RepoDocumentListCard({ rows }: { rows: DocumentRow[] }) {
  if (rows.length === 0) return <EmptyState>No repository documents found.</EmptyState>

  return (
    <div className="mt-1 divide-y divide-border overflow-hidden rounded border border-border bg-surface">
      {rows.map((row, index) => (
        <article className="min-w-0 space-y-2 p-2" key={row.id || row.ref || `${row.title}-${index}`}>
          <div className="flex min-w-0 flex-wrap items-start justify-between gap-2">
            <EntityReference className="min-w-0 text-sm" href={documentHref(row) || undefined} id={row.id} kind="artifact" label={row.title} slug={row.title} />
            {row.status ? <StatePill state={row.status} /> : null}
          </div>
          <dl className="grid min-w-0 gap-2 sm:grid-cols-2 lg:grid-cols-4">
            {row.ref ? <Row label="Ref" value={row.ref} /> : null}
            {row.kind ? <Row label="Type" value={row.kind} /> : null}
            {row.repositoryId || row.repository ? (
              <div className="min-w-0">
                <SectionLabel>Repository</SectionLabel>
                <EntityReference
                  kind="repository"
                  label={row.repository || `Repository #${row.repositoryId}`}
                  repositoryId={row.repositoryId}
                  repositorySlug={row.repository}
                  slug={row.repository}
                />
              </div>
            ) : null}
            {row.contentType ? <Row label="Content type" value={row.contentType} /> : null}
            {row.sizeBytes != null ? <Row label="Size" value={formatBytes(row.sizeBytes)} /> : null}
            {row.url ? (
              <div className="min-w-0 sm:col-span-2 lg:col-span-4">
                <SectionLabel>URL</SectionLabel>
                <EntityReference href={row.url} kind="artifact" label={row.url} slug={row.url} />
              </div>
            ) : null}
          </dl>
        </article>
      ))}
    </div>
  )
}

type DocumentRead = {
  row: DocumentRow
  text: string | null
  image: { src: string; mimeType: string } | null
  truncated: boolean
}

export function repoDocumentReadSummary(context: ToolCardContext) {
  const documentId = readDocumentRow(context).id
  if (context.resultError) return documentId ? `Document ${documentId} read failed` : "Document read failed"
  if (context.resultSettled === false) return documentId ? `Reading document ${documentId}` : "Reading document"
  const result = parseRepoDocumentRead(context)
  if (result?.image) return documentId ? `Document ${documentId} image` : "Document image"
  return documentId ? `Document ${documentId} read` : "Document read"
}

export function RepoDocumentReadCard({ context }: { context: ToolCardContext }) {
  const result = parseRepoDocumentRead(context)
  if (!result) return null
  const { row, text, image, truncated } = result
  const lines = text == null || text === "" ? 0 : text.split(/\r?\n/).length
  const measuredBytes = text == null ? null : new TextEncoder().encode(text).length
  const href = documentHref(row)
  const label = row.title || (row.id ? `Document ${row.id}` : "Repository document")

  return (
    <CardShell>
      <div className="flex min-w-0 flex-wrap items-center gap-2">
        <StatePill
          state={context.resultSettled === false ? "pending" : image ? "image" : text?.trim() ? "read" : "empty"}
          tone={context.resultSettled === false ? "info" : text?.trim() || image ? "success" : "neutral"}
        />
        {href ? (
          <EntityReference className="min-w-0" href={href} id={row.id} kind="artifact" label={label} slug={label} />
        ) : (
          <span className="min-w-0 break-words font-semibold">{label}</span>
        )}
        {truncated ? <Badge>server truncated</Badge> : null}
      </div>
      <dl className="grid min-w-0 gap-2 sm:grid-cols-2 lg:grid-cols-4">
        {row.ref ? <Row label="Ref" value={row.ref} /> : null}
        {row.contentType ? <Row label="Content type" value={row.contentType} /> : null}
        {row.sizeBytes != null || measuredBytes != null ? <Row label="Size" value={formatBytes(row.sizeBytes ?? measuredBytes!)} /> : null}
        {text != null ? <Row label="Lines" value={String(lines)} /> : null}
      </dl>
      {image ? (
        <MediaPreviewShell
          item={{
            title: label,
            src: image.src,
            alt: label,
            badge: image.mimeType.split("/").pop()?.toUpperCase(),
            actions: [
              { label: "Open", href: image.src },
              { label: "Download", href: image.src, download: true }
            ],
            meta: [
              { label: "Content type", value: row.contentType || image.mimeType },
              { label: "Size", value: row.sizeBytes == null ? null : formatBytes(row.sizeBytes) }
            ]
          }}
          modalLabel={`${label} preview`}
          thumbnailClassName="w-full max-w-72"
        />
      ) : context.resultSettled === false ? (
        <EmptyState>Waiting for the document result.</EmptyState>
      ) : (
        <MarkdownPreview
          className={plainTextDocument(row.contentType) ? "font-mono" : undefined}
          emptyState={<EmptyState>This document is blank.</EmptyState>}
          linkifySlugs
          linkifyUrls
          maxChars={CONTENT_PREVIEW_CHARS}
          maxLines={CONTENT_PREVIEW_LINES}
          modalContentClassName={plainTextDocument(row.contentType) ? "font-mono whitespace-pre-wrap" : undefined}
          modalLabel={`${label} content`}
          text={text || ""}
          title="Content preview"
        />
      )}
    </CardShell>
  )
}

export function renderRepoDocumentRead(context: ToolCardContext): ReactNode | null {
  return parseRepoDocumentRead(context) ? <RepoDocumentReadCard context={context} /> : null
}

function readDocumentRow(context: ToolCardContext): DocumentRow {
  const id = displayValue(context.input?.id) || displayValue(context.input?.document_id)
  const inputRow = parseDocument({ ...context.input, id, title: displayValue(context.input?.title) || (id ? `Document ${id}` : "Repository document") })
  const priorRows = parseRepoDocumentList({ ...context, parsedResult: context.priorResults?.list_repo_documents }) || []
  const prior = priorRows.find((row) => row.id === id || row.ref === id)
  return (
    prior ||
    inputRow || {
      id,
      ref: id,
      title: id ? `Document ${id}` : "Repository document",
      kind: null,
      status: null,
      repositoryId: null,
      repository: null,
      contentType: null,
      sizeBytes: null,
      url: null
    }
  )
}

function parseRepoDocumentRead(context: ToolCardContext): DocumentRead | null {
  const row = readDocumentRow(context)
  const blocks = normalizedToolCardContentBlocks(context.parsedResult)
  const imageBlock = blocks.find((block) => ["image", "input_image", "output_image"].includes(displayValue(block.type) || ""))
  const source = imageBlock && isPlainObject(imageBlock.source) ? imageBlock.source : null
  const imageData = imageBlock
    ? displayValue(imageBlock.data) || displayValue(imageBlock.dataUrl) || displayValue(imageBlock.image_url) || displayValue(source?.data)
    : null
  const mimeType = imageBlock
    ? displayValue(imageBlock.mimeType) ||
      displayValue(imageBlock.mime_type) ||
      displayValue(imageBlock.media_type) ||
      displayValue(source?.media_type) ||
      row.contentType ||
      "image/png"
    : null
  const image = imageData && mimeType ? { src: imageData.startsWith("data:") ? imageData : `data:${mimeType};base64,${imageData}`, mimeType } : null
  const blockText = blocks
    .filter((block) => ["text", "output_text"].includes(displayValue(block.type) || ""))
    .map((block) => displayValue(block.text) || displayValue(block.output))
    .filter((value): value is string => value != null)
    .join("\n")
  const text = blockText || context.resultBody
  const truncated = /\[Document truncated after \d+ bytes; omitted \d+ bytes\.\]/.test(text)

  if (!image && !text && context.resultSettled == null && context.parsedResult != null) return null
  return { row, text: image ? null : text, image, truncated }
}

function plainTextDocument(contentType: string | null) {
  return contentType === "text/plain"
}

export function parseRepoDocumentAction(context: ToolCardContext, action: "create" | "delete"): DocumentAction | null {
  const pending = parsePendingActionResult(context)
  if (!pending || pending.kind === "error") return null

  const parsed = isPlainObject(context.parsedResult) ? context.parsedResult : {}
  const live = context.livePendingAction
  const document: Record<string, unknown> = live?.document ? { ...live.document } : isPlainObject(parsed.document) ? parsed.document : parsed
  const body = displayValue(context.input?.body)
  const documentId =
    displayValue(context.input?.document_id) || displayValue(context.input?.id) || displayValue(document.document_id) || displayValue(document.id)
  const messageTitle =
    action === "delete" && pending.kind !== "dry_run_evidence" ? pending.message?.match(/delete\s+document\s+["“]([^"”]+)["”]/i)?.[1]?.trim() || null : null

  return {
    action,
    pending,
    title: displayValue(context.input?.title) || displayValue(document.title) || displayValue(live?.resource_title) || messageTitle,
    documentId,
    repositoryId: displayValue(context.input?.repository_id) || displayValue(document.repository_id),
    repositorySlug:
      displayValue(context.input?.repository_slug) ||
      displayValue(context.input?.repository) ||
      displayValue(document.repository_slug) ||
      displayValue(document.repository),
    body,
    contentType: displayValue(context.input?.content_type) || displayValue(document.content_type) || (body != null ? "text/markdown" : null),
    sizeBytes: numberValue(document.size_bytes) ?? numberValue(document.byte_size) ?? (body == null ? null : new TextEncoder().encode(body).length),
    documentUrl:
      displayValue(document.url) ||
      displayValue(document.file_path) ||
      displayValue(live?.resource_url) ||
      (documentId ? `/api/v1/app/repository_documents/${encodeURIComponent(documentId)}/file` : null)
  }
}

export function repoDocumentActionSummary(result: DocumentAction) {
  const target = result.title || (result.documentId ? `document ${result.documentId}` : null)
  const prefix = result.action === "create" ? "Create" : "Delete"
  const pending = pendingActionCollapsedSummary(result.pending)
  return target ? `${prefix} ${target} · ${pending}` : pending
}

function actionNoun(action: "create" | "delete") {
  return action === "create" ? "Create document" : "Delete document"
}

export function RepoDocumentActionCard({ result }: { result: DocumentAction }) {
  const documentLabel = result.title || (result.documentId ? i18n.t("chat:document_number", { id: result.documentId }) : null)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.pending.kind === "dry_run_evidence" ? "dry_run" : result.pending.state} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{actionNoun(result.action)}</span>
        {result.pending.kind === "standard" || result.pending.kind === "bulk" ? (
          <Badge>{i18n.t("chat:pending_action_number", { id: result.pending.pendingActionId })}</Badge>
        ) : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.title ? <Row label="Title" value={result.title} /> : null}
        {documentLabel && result.documentUrl ? (
          <div className="min-w-0">
            <SectionLabel>Document</SectionLabel>
            <EntityReference href={result.documentUrl} id={result.documentId} kind="artifact" label={documentLabel} slug={documentLabel} />
          </div>
        ) : result.documentId ? (
          <Row label="Ref" value={result.documentId} />
        ) : null}
        {result.repositoryId || result.repositorySlug ? (
          <div className="min-w-0">
            <SectionLabel>Repository</SectionLabel>
            <EntityReference
              kind="repository"
              label={result.repositorySlug || i18n.t("chat:repository_number", { id: result.repositoryId })}
              repositoryId={result.repositoryId}
              repositorySlug={result.repositorySlug}
              slug={result.repositorySlug}
            />
          </div>
        ) : null}
        {result.contentType ? <Row label="Content type" value={result.contentType} /> : null}
        {result.sizeBytes != null ? <Row label="Size" value={formatBytes(result.sizeBytes)} /> : null}
      </dl>
      {(result.pending.kind === "standard" || result.pending.kind === "bulk") && result.pending.message ? (
        <MarkdownPreview linkifyUrls maxChars={600} maxLines={3} text={result.pending.message} />
      ) : null}
      {(result.pending.kind === "standard" || result.pending.kind === "bulk") && result.pending.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <div className="mt-0.5">
            <MarkdownPreview linkifyUrls maxChars={600} maxLines={3} text={result.pending.reason} />
          </div>
        </div>
      ) : null}
      {result.action === "create" ? (
        <div>
          <SectionLabel>Body preview</SectionLabel>
          <div className="mt-1">
            <MarkdownPreview
              emptyState={<EmptyState>No document body provided.</EmptyState>}
              linkifyUrls
              maxChars={CONTENT_PREVIEW_CHARS}
              maxLines={CONTENT_PREVIEW_LINES}
              modalLabel={result.title ? `${result.title} body` : "Document body"}
              text={result.body || ""}
            />
          </div>
        </div>
      ) : null}
    </CardShell>
  )
}

export function renderRepoDocumentList(context: ToolCardContext): ReactNode | null {
  const rows = parseRepoDocumentList(context)
  return rows ? <RepoDocumentListCard rows={rows} /> : null
}
