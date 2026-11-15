import { PageHeading, SectionHeading } from "../components/Heading"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { NoticeToast } from "../components/NoticeToast"
import {
  addCredentialDocuments,
  deleteCredentialDocument,
  fetchCredentialDocuments,
  type PersonalDocument,
  type PersonalDocumentsPayload
} from "../api/credentials"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { PanelMessage } from "../components/PanelMessage"
import { DataTable, Form } from "../components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "../components/dataTable"
import { FilterBar, type FilterSchemaField } from "../components/FilterBar"
import type { FilterNode, FilterTree } from "../components/filterBar/types"
import { errorMessage } from "../lib/errorMessage"
import { formatBytes } from "../lib/format"
import { useConfirm } from "../hooks/useConfirm"
import { DocumentPreviewModal, isPreviewableContentType } from "../components/DocumentPreviewModal"
import { routePrefix } from "../lib/routing"

const queryKey = ["personal-documents"] as const
const DOCUMENTS_VISIBLE_COLUMNS_STORAGE_KEY = "syrus.settings.personal_documents.visible_columns"

type DocumentSortColumn =
  "title" | "filename" | "kind" | "content_type" | "byte_size" | "source_url" | "content_cache_state" | "content_cached_at" | "created_at" | "updated_at"
type SortDirection = "ascending" | "descending"
type DocumentSortState = { column: DocumentSortColumn; direction: SortDirection }
const DEFAULT_DOCUMENT_SORT: DocumentSortState = { column: "created_at", direction: "descending" }

export function PersonalDocumentsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("personal_documents.heading"))
  const location = useLocation()
  const documents = useQuery({
    queryKey: [...queryKey, location.search],
    queryFn: () => fetchCredentialDocuments(location.search)
  })

  return (
    <main aria-label={t("aria_personal_documents")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <PageHeading>{t("personal_documents.heading")}</PageHeading>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{t("personal_documents.description")}</p>
      </header>

      {documents.isPending ? <PanelMessage>{t("personal_documents.loading")}</PanelMessage> : null}
      {documents.isError ? <DocumentsError error={documents.error} /> : null}
      {documents.isSuccess ? <PersonalDocumentsView payload={documents.data} /> : null}
    </main>
  )
}

function PersonalDocumentsView({ payload }: { payload: PersonalDocumentsPayload }) {
  const { t } = useT("settings")
  const [notice, setNotice] = useState<string | null>(payload.message || null)

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      <DocumentsPanel onNotice={setNotice} payload={payload} />
    </>
  )
}

function DocumentsPanel({ payload, onNotice }: { payload: PersonalDocumentsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const location = useLocation()
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const [files, setFiles] = useState<File[]>([])
  const [googleDocUrl, setGoogleDocUrl] = useState("")
  const [previewDocument, setPreviewDocument] = useState<PersonalDocument | null>(null)
  const searchParams = new URLSearchParams(location.search)
  const sortState: DocumentSortState = {
    column: isDocumentSortColumn(searchParams.get("sort")) ? (searchParams.get("sort") as DocumentSortColumn) : DEFAULT_DOCUMENT_SORT.column,
    direction: searchParams.get("direction") === "ascending" ? "ascending" : "descending"
  }
  const filterSchema = buildDocumentFilterSchema(t)
  const upload = useMutation({
    mutationFn: () => addCredentialDocuments(files, googleDocUrl),
    onSuccess: (updated) => {
      void queryClient.invalidateQueries({ queryKey })
      setFiles([])
      setGoogleDocUrl("")
      onNotice(updated.message || t("personal_documents.added"))
    }
  })
  const destroy = useMutation({
    mutationFn: (document: PersonalDocument) => deleteCredentialDocument(document.id),
    onSuccess: (updated) => {
      void queryClient.invalidateQueries({ queryKey })
      onNotice(updated.message || t("personal_documents.removed"))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    upload.mutate()
  }

  function openDocument(document: PersonalDocument) {
    if (document.kind === "google_doc") {
      if (document.google_doc_url) window.open(document.google_doc_url, "_blank", "noopener")
      return
    }
    if (!document.file_path) return
    if (isPreviewableContentType(document.content_type)) {
      setPreviewDocument(document)
    } else {
      window.open(document.file_path, "_blank", "noopener")
    }
  }

  const columns = buildDocumentColumns({
    destroyPending: destroy.isPending,
    onDelete: async (document) => {
      if (await confirm({ message: t("personal_documents.confirm_delete"), destructive: true })) destroy.mutate(document)
    },
    onOpen: openDocument,
    t
  })
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: DOCUMENTS_VISIBLE_COLUMNS_STORAGE_KEY })
  const filterTree = filterTreeFromSearch(location.search)

  useEffect(() => {
    const requestedPage = Math.max(Number(new URLSearchParams(location.search).get("page")) || 1, 1)
    if (requestedPage === payload.pagination.page) return
    const params = new URLSearchParams(location.search)
    if (payload.pagination.page === 1) params.delete("page")
    else params.set("page", String(payload.pagination.page))
    void navigate(`${location.pathname}?${params.toString()}`, { replace: true })
  }, [location.pathname, location.search, navigate, payload.pagination.page])

  function toggleSortColumn(column: DocumentSortColumn) {
    const next = toggleSort(sortState, column)
    const params = new URLSearchParams(location.search)
    params.set("sort", next.column)
    params.set("direction", next.direction)
    params.delete("page")
    void navigate(`${location.pathname}?${params.toString()}`)
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <SectionHeading>{t("personal_documents.section_heading")}</SectionHeading>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("personal_documents.attach_description")}</p>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-xs text-gray-500 dark:text-gray-400">
            {t("personal_documents.visible_range", {
              first: payload.pagination.first_item,
              last: payload.pagination.last_item,
              total: payload.pagination.total
            })}
          </span>
          <DataTableColumnMenu
            columns={columns}
            downLabel={t("personal_documents.column_down")}
            menuId="personal-documents-columns-menu"
            moveDownLabel={(title) => t("personal_documents.column_move_down", { title })}
            moveUpLabel={(title) => t("personal_documents.column_move_up", { title })}
            onChange={preferences.onChange}
            order={preferences.order}
            triggerAriaLabel={t("personal_documents.columns")}
            triggerClassName="h-[var(--control-height-md)] w-[var(--control-height-md)]"
            triggerSize="icon"
            upLabel={t("personal_documents.column_up")}
            visibleLabel={t("personal_documents.visible_columns")}
          />
        </div>
      </div>

      <div className="mt-4">
        <FilterBar filter={filterTree} filterSchema={filterSchema} pathname={location.pathname} search={location.search} />
      </div>

      <DataTable.Root aria-label={t("personal_documents.section_heading")} className="mt-4">
        <DataTable.Header>
          <DataTableColumnHeaderRow
            columns={columns}
            onReorder={preferences.onChange}
            onSort={(column) => toggleSortColumn(column as DocumentSortColumn)}
            order={preferences.order}
            sortColumn={sortState.column}
            sortDirection={sortState.direction}
          />
        </DataTable.Header>
        <DataTable.Body>
          {payload.documents.length === 0 ? (
            <DataTable.Row>
              <DataTable.Empty colSpan={columns.length}>{t("personal_documents.empty")}</DataTable.Empty>
            </DataTable.Row>
          ) : (
            payload.documents.map((document) => (
              <DataTable.Row key={document.id}>
                <DataTableColumnCells columns={columns} order={preferences.order} row={document} />
              </DataTable.Row>
            ))
          )}
        </DataTable.Body>
      </DataTable.Root>

      <DocumentsPagination pagination={payload.pagination} search={location.search} />

      <form className="mt-4 space-y-3" onSubmit={submit}>
        {upload.isError ? <PanelMessage tone="error">{errorMessage(upload.error, "Unable to add document.")}</PanelMessage> : null}
        {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete document.")}</PanelMessage> : null}
        <Field label={t("personal_documents.upload_files")}>
          <Form.Input multiple onChange={(event) => setFiles(Array.from(event.currentTarget.files || []))} type="file" />
        </Field>
        <Field label={t("personal_documents.google_doc_url")}>
          <Form.Input
            onChange={(event) => setGoogleDocUrl(event.target.value)}
            placeholder="https://docs.google.com/document/d/..."
            type="url"
            value={googleDocUrl}
          />
        </Field>
        <button
          className="rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-800 disabled:bg-gray-400"
          disabled={upload.isPending}
          type="submit"
        >
          {upload.isPending ? <>{t("personal_documents.adding")}</> : <>{t("personal_documents.add")}</>}
        </button>
      </form>
      {previewDocument && previewDocument.file_path ? (
        <DocumentPreviewModal
          file={{
            title: previewDocument.filename || t("personal_documents.file"),
            rawUrl: previewDocument.file_path,
            contentType: previewDocument.content_type
          }}
          onClose={() => setPreviewDocument(null)}
        />
      ) : null}
      {dialog}
    </section>
  )
}

function buildDocumentFilterSchema(t: (key: string, options?: Record<string, unknown>) => string): FilterSchemaField[] {
  return [
    { field: "query", label: t("personal_documents.col_document"), bucket: "text", operators: ["contains"], free_text_search: true },
    { field: "title", label: t("personal_documents.col_document"), bucket: "text", operators: ["contains", "is", "is_not"] },
    { field: "filename", label: t("personal_documents.col_filename"), bucket: "text", operators: ["contains", "is", "is_not", "is_set", "is_unset"] },
    {
      field: "kind",
      label: t("personal_documents.col_kind"),
      bucket: "text",
      operators: ["is", "is_not"],
      values: [
        { value: "file", label: t("personal_documents.file") },
        { value: "google_doc", label: t("personal_documents.google_doc") }
      ]
    },
    { field: "content_type", label: t("personal_documents.col_content_type"), bucket: "text", operators: ["contains", "is", "is_set", "is_unset"] },
    { field: "byte_size", label: t("personal_documents.col_size"), bucket: "number", operators: ["is", "gt", "lt", "gte", "lte"] },
    { field: "source_url", label: t("personal_documents.col_source_url"), bucket: "text", operators: ["contains", "is", "is_set", "is_unset"] },
    {
      field: "content_cache_state",
      label: t("personal_documents.col_content_cache_state"),
      bucket: "text",
      operators: ["is", "is_not"],
      values: [
        { value: "cached", label: t("personal_documents.cache_cached") },
        { value: "empty", label: t("personal_documents.cache_empty") }
      ]
    },
    {
      field: "content_cached_at",
      label: t("personal_documents.col_content_cached_at"),
      bucket: "date",
      operators: ["before", "after", "between", "is_set", "is_unset"]
    },
    { field: "created_at", label: t("personal_documents.col_created"), bucket: "date", operators: ["before", "after", "between"] },
    { field: "updated_at", label: t("personal_documents.col_updated"), bucket: "date", operators: ["before", "after", "between"] }
  ]
}

function buildDocumentColumns({
  destroyPending,
  onDelete,
  onOpen,
  t
}: {
  destroyPending: boolean
  onDelete: (document: PersonalDocument) => void
  onOpen: (document: PersonalDocument) => void
  t: (key: string, options?: Record<string, unknown>) => string
}): DataTableColumnDef<PersonalDocument>[] {
  return [
    {
      key: "title",
      label: t("personal_documents.col_document"),
      required: true,
      sortKey: "title",
      renderCell: (document) => (
        <button className="min-w-0 rounded text-left hover:bg-gray-50 dark:hover:bg-gray-800" onClick={() => onOpen(document)} type="button">
          <DocumentSummary document={document} />
        </button>
      )
    },
    {
      key: "filename",
      label: t("personal_documents.col_filename"),
      sortKey: "filename",
      defaultVisible: false,
      renderCell: (document) => document.filename || "-"
    },
    {
      key: "kind",
      label: t("personal_documents.col_kind"),
      sortKey: "kind",
      renderCell: (document) => (document.kind === "google_doc" ? t("personal_documents.google_doc") : t("personal_documents.file"))
    },
    {
      key: "content_type",
      label: t("personal_documents.col_content_type"),
      sortKey: "content_type",
      defaultVisible: false,
      cellClassName: "text-xs text-gray-500 dark:text-gray-400",
      renderCell: (document) => document.content_type || "-"
    },
    {
      key: "size",
      label: t("personal_documents.col_size"),
      sortKey: "byte_size",
      align: "right",
      renderCell: (document) => (document.byte_size == null ? "-" : formatBytes(document.byte_size))
    },
    {
      key: "origin",
      label: t("personal_documents.col_origin"),
      renderCell: (document) => <DocumentOrigin document={document} />
    },
    {
      key: "source_url",
      label: t("personal_documents.col_source_url"),
      sortKey: "source_url",
      defaultVisible: false,
      cellClassName: "max-w-xs truncate text-xs text-gray-500 dark:text-gray-400",
      renderCell: (document) => document.source_url || document.google_doc_url || "-"
    },
    {
      key: "content_cache_state",
      label: t("personal_documents.col_content_cache_state"),
      sortKey: "content_cache_state",
      defaultVisible: false,
      renderCell: (document) => (document.content_cache_state === "cached" ? t("personal_documents.cache_cached") : t("personal_documents.cache_empty"))
    },
    {
      key: "content_cached_at",
      label: t("personal_documents.col_content_cached_at"),
      sortKey: "content_cached_at",
      defaultVisible: false,
      renderCell: (document) => (document.content_cached_at ? new Date(document.content_cached_at).toLocaleString() : "-")
    },
    {
      key: "created",
      label: t("personal_documents.col_created"),
      sortKey: "created_at",
      renderCell: (document) => new Date(document.created_at).toLocaleString()
    },
    {
      key: "updated",
      label: t("personal_documents.col_updated"),
      sortKey: "updated_at",
      defaultVisible: false,
      renderCell: (document) => new Date(document.updated_at).toLocaleString()
    },
    {
      key: "actions",
      label: t("personal_documents.col_actions"),
      required: true,
      pin: "end",
      align: "right",
      renderHeader: () => <span className="sr-only">{t("personal_documents.col_actions")}</span>,
      renderCell: (document) => (
        <button
          className="text-xs font-medium text-red-600 dark:text-red-300 hover:text-red-700 dark:hover:text-red-300 disabled:text-red-300 dark:disabled:text-red-500"
          disabled={destroyPending}
          onClick={() => onDelete(document)}
          type="button"
        >
          {t("personal_documents.delete")}
        </button>
      )
    }
  ]
}

function DocumentOrigin({ document }: { document: PersonalDocument }) {
  const { t } = useT("settings")
  const location = useLocation()
  const label = t(`personal_documents.origin_${document.origin.kind}`)
  if (!document.origin.chat) return label

  return (
    <span className="text-xs text-gray-600 dark:text-gray-300">
      {label} ·{" "}
      <Link className="font-medium text-brand hover:underline" to={`${routePrefix(location.pathname)}${document.origin.chat.path}`}>
        {document.origin.chat.label}
      </Link>
    </span>
  )
}

function DocumentsPagination({ pagination, search }: { pagination: PersonalDocumentsPayload["pagination"]; search: string }) {
  const { t } = useT("settings")
  if (pagination.total_pages <= 1) return null

  return (
    <nav aria-label={t("personal_documents.pagination_label")} className="mt-4 flex items-center justify-end gap-3 text-sm">
      {pagination.page > 1 ? (
        <Link className="text-brand hover:underline" to={pageSearch(search, pagination.page - 1)}>
          {t("personal_documents.previous")}
        </Link>
      ) : (
        <span aria-disabled="true" className="text-gray-400">
          {t("personal_documents.previous")}
        </span>
      )}
      <span>{t("personal_documents.page_of", { page: pagination.page, total: pagination.total_pages })}</span>
      {pagination.page < pagination.total_pages ? (
        <Link className="text-brand hover:underline" to={pageSearch(search, pagination.page + 1)}>
          {t("personal_documents.next")}
        </Link>
      ) : (
        <span aria-disabled="true" className="text-gray-400">
          {t("personal_documents.next")}
        </span>
      )}
    </nav>
  )
}

function pageSearch(search: string, page: number) {
  const params = new URLSearchParams(search)
  if (page === 1) params.delete("page")
  else params.set("page", String(page))
  return `?${params.toString()}`
}

function DocumentSummary({ document }: { document: PersonalDocument }) {
  const { t } = useT("settings")
  if (document.kind === "google_doc" && document.google_doc_url) {
    return (
      <div className="min-w-0">
        <div className="truncate text-sm font-medium text-brand dark:text-brand-emphasis">{document.google_doc_url}</div>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("personal_documents.google_doc")}</div>
      </div>
    )
  }

  return (
    <div className="min-w-0">
      <div className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">{document.filename || <>{t("personal_documents.file")}</>}</div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
        {document.content_type || "unknown"} · {formatBytes(document.byte_size)}
      </div>
    </div>
  )
}

function toggleSort<TColumn extends string>(current: { column: TColumn; direction: SortDirection }, column: TColumn) {
  if (current.column !== column) return { column, direction: "ascending" as const }
  return { column, direction: current.direction === "ascending" ? ("descending" as const) : ("ascending" as const) }
}

function isDocumentSortColumn(value: string | null): value is DocumentSortColumn {
  return (
    value != null &&
    ["title", "filename", "kind", "content_type", "byte_size", "source_url", "content_cache_state", "content_cached_at", "created_at", "updated_at"].includes(
      value
    )
  )
}

function filterTreeFromSearch(search: string): FilterTree {
  const encoded = new URLSearchParams(search).get("q")
  if (!encoded) return { and: [] }
  try {
    const padded = `${encoded.replace(/-/g, "+").replace(/_/g, "/")}${"=".repeat((4 - (encoded.length % 4)) % 4)}`
    const bytes = Uint8Array.from(atob(padded), (character) => character.charCodeAt(0))
    const parsed = JSON.parse(new TextDecoder().decode(bytes)) as FilterTree
    return { and: topLevelNodes(parsed) }
  } catch {
    return { and: [] }
  }
}

function topLevelNodes(tree: FilterTree): FilterNode[] {
  return tree && Array.isArray(tree.and) ? tree.and : []
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <Form.Field>
      <Form.Label>{label}</Form.Label>
      {children}
    </Form.Field>
  )
}

function DocumentsError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load personal documents.")}</PanelMessage>
}
