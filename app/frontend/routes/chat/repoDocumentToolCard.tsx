import type { ReactNode } from "react"
import type { ToolCardContext } from "@app/pluginToolCards"
import { Badge, CardShell, Disclosure, displayValue, EmptyState, Row, SectionLabel, StatePill, truncateLines } from "./toolCardUi"
import { parsePendingActionResult, pendingActionCollapsedSummary, type PendingActionResult } from "./pendingActionToolCard"

const CONTENT_PREVIEW_LINES = 12
const CONTENT_PREVIEW_CHARS = 1_200

type DocumentRow = {
  id: string | null
  ref: string | null
  title: string
  kind: string | null
  status: string | null
  repository: string | null
  contentType: string | null
  sizeBytes: number | null
  url: string | null
}

type DocumentAction = {
  action: "create" | "delete"
  pending: PendingActionResult
  title: string | null
  documentId: string | null
  repositoryId: string | null
  body: string | null
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

function metadata(row: DocumentRow): string[] {
  return [
    row.contentType,
    row.sizeBytes == null ? null : formatBytes(row.sizeBytes),
    row.url ? "linked" : null
  ].filter((item): item is string => Boolean(item))
}

export function parseRepoDocumentList(context: ToolCardContext): DocumentRow[] | null {
  const parsed = context.parsedResult
  const rawRows = Array.isArray(parsed)
    ? parsed
    : isPlainObject(parsed) && Array.isArray(parsed.documents)
      ? parsed.documents
      : null
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
    <div className="mt-1 overflow-x-auto rounded border border-gray-200 dark:border-gray-700">
      <table className="w-full text-left text-xs">
        <thead className="bg-gray-50 text-2xs uppercase text-gray-500 dark:bg-gray-900 dark:text-gray-400">
          <tr>
            <th className="px-2 py-1 font-semibold" scope="col">Title</th>
            <th className="px-2 py-1 font-semibold" scope="col">Ref</th>
            <th className="px-2 py-1 font-semibold" scope="col">Type</th>
            <th className="px-2 py-1 font-semibold" scope="col">Status</th>
            <th className="px-2 py-1 font-semibold" scope="col">Repository</th>
            <th className="px-2 py-1 font-semibold" scope="col">Content</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 bg-white dark:divide-gray-800 dark:bg-gray-950">
          {rows.map((row, index) => (
            <tr key={row.id || row.ref || `${row.title}-${index}`}>
              <td className="max-w-64 truncate px-2 py-1 font-medium text-gray-800 dark:text-gray-200" title={row.title}>{row.title}</td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{row.ref || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{row.kind || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1">{row.status ? <StatePill state={row.status} /> : <span className="text-gray-400">—</span>}</td>
              <td className="whitespace-nowrap px-2 py-1 font-mono text-gray-600 dark:text-gray-300">{row.repository || "—"}</td>
              <td className="whitespace-nowrap px-2 py-1 text-gray-600 dark:text-gray-300">{metadata(row).join(" · ") || "—"}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function previewText(text: string) {
  const clipped = text.length > CONTENT_PREVIEW_CHARS ? `${text.slice(0, CONTENT_PREVIEW_CHARS)}...` : text
  return truncateLines(clipped, CONTENT_PREVIEW_LINES)
}

export function repoDocumentReadSummary(context: ToolCardContext) {
  const documentId = displayValue(context.input?.id)
  if (context.resultError) return documentId ? `Document ${documentId} read failed` : "Document read failed"
  if (context.resultBody.trim()) return documentId ? `Document ${documentId} read` : "Document read"
  return null
}

export function RepoDocumentReadCard({ context }: { context: ToolCardContext }) {
  const documentId = displayValue(context.input?.id)
  const body = context.resultBody
  if (!body.trim()) return null
  const lines = body === "" ? 0 : body.split("\n").length
  const bytes = new TextEncoder().encode(body).length
  const { preview, truncated, totalLines } = previewText(body)

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        {context.resultError ? <StatePill state="failed" /> : <StatePill state="read" tone="success" />}
        {documentId ? <Badge>document {documentId}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-3">
        {documentId ? <Row label="Ref" value={documentId} /> : null}
        <Row label="Lines" value={String(lines)} />
        <Row label="Bytes" value={formatBytes(bytes)} />
      </dl>
      <Disclosure label="Content preview">
        <pre className="max-h-72 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{preview}</pre>
        {truncated || body.length > CONTENT_PREVIEW_CHARS ? (
          <div className="mt-1 text-2xs text-gray-500 dark:text-gray-400">Showing a concise preview of {totalLines} lines.</div>
        ) : null}
      </Disclosure>
    </CardShell>
  )
}

export function renderRepoDocumentRead(context: ToolCardContext): ReactNode | null {
  return context.resultBody.trim() ? <RepoDocumentReadCard context={context} /> : null
}

export function parseRepoDocumentAction(context: ToolCardContext, action: "create" | "delete"): DocumentAction | null {
  const pending = parsePendingActionResult(context.parsedResult)
  if (!pending) return null

  return {
    action,
    pending,
    title: displayValue(context.input?.title),
    documentId: displayValue(context.input?.document_id) || displayValue(context.input?.id),
    repositoryId: displayValue(context.input?.repository_id),
    body: displayValue(context.input?.body)
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
  const bodyPreview = result.body ? previewText(result.body) : null

  return (
    <CardShell>
      <div className="flex flex-wrap items-center gap-2">
        <StatePill state={result.pending.kind === "dry_run_evidence" ? "dry_run" : result.pending.state} />
        <span className="font-semibold text-gray-900 dark:text-gray-100">{actionNoun(result.action)}</span>
        {result.pending.kind !== "dry_run_evidence" ? <Badge>pending action #{result.pending.pendingActionId}</Badge> : null}
      </div>
      <dl className="grid gap-1 sm:grid-cols-2">
        {result.title ? <Row label="Title" value={result.title} /> : null}
        {result.documentId ? <Row label="Ref" value={result.documentId} /> : null}
        {result.repositoryId ? <Row label="Repository" value={result.repositoryId} /> : null}
      </dl>
      {result.pending.kind !== "dry_run_evidence" && result.pending.message ? <div className="text-gray-700 dark:text-gray-300">{result.pending.message}</div> : null}
      {result.pending.kind !== "dry_run_evidence" && result.pending.reason ? (
        <div>
          <SectionLabel>Reason</SectionLabel>
          <div className="mt-0.5 text-gray-700 dark:text-gray-300">{result.pending.reason}</div>
        </div>
      ) : null}
      {bodyPreview ? (
        <Disclosure label="Body preview">
          <pre className="max-h-48 overflow-auto whitespace-pre-wrap break-words font-mono text-2xs">{bodyPreview.preview}</pre>
        </Disclosure>
      ) : null}
    </CardShell>
  )
}

export function renderRepoDocumentList(context: ToolCardContext): ReactNode | null {
  const rows = parseRepoDocumentList(context)
  return rows ? <RepoDocumentListCard rows={rows} /> : null
}
