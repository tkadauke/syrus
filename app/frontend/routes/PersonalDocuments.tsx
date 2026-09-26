import { PageHeading, SectionHeading } from "../components/Heading"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useMemo, useState } from "react"
import { useLocation } from "react-router-dom"
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
import type { FilterChip, FilterNode, FilterTree } from "../components/filterBar/types"
import { errorMessage } from "../lib/errorMessage"
import { formatBytes } from "../lib/format"
import { useConfirm } from "../hooks/useConfirm"
import { DocumentPreviewModal, isPreviewableContentType } from "../components/DocumentPreviewModal"

const queryKey = ["personal-documents"] as const
const DOCUMENTS_VISIBLE_COLUMNS_STORAGE_KEY = "syrus.settings.personal_documents.visible_columns"

type DocumentSortColumn = "title" | "filename" | "kind" | "content_type" | "byte_size" | "source_url" | "content_cache_state" | "content_cached_at" | "created_at" | "updated_at"
type SortDirection = "ascending" | "descending"
type DocumentSortState = { column: DocumentSortColumn; direction: SortDirection }
type SortValue = number | string | null

const DEFAULT_DOCUMENT_SORT: DocumentSortState = { column: "created_at", direction: "descending" }
const DOCUMENT_SORT_ACCESSORS: Record<DocumentSortColumn, (document: PersonalDocument) => SortValue> = {
  title: (document) => documentTitle(document),
  filename: (document) => document.filename || "",
  kind: (document) => document.kind,
  content_type: (document) => document.content_type,
  byte_size: (document) => document.byte_size,
  source_url: (document) => document.source_url || document.google_doc_url || "",
  content_cache_state: (document) => document.content_cache_state,
  content_cached_at: (document) => document.content_cached_at,
  created_at: (document) => document.created_at,
  updated_at: (document) => document.updated_at
}

export function PersonalDocumentsRoute() {
  const { t } = useT("settings")
  usePageTitle(t("personal_documents.heading"))
  const documents = useQuery({
    queryKey,
    queryFn: fetchCredentialDocuments
  })

  return (
    <main aria-label={t("aria_personal_documents")} className="mx-auto max-w-4xl space-y-6 p-6">
      <header>
        <PageHeading>
          {t('personal_documents.heading')}
        </PageHeading>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
          {t('personal_documents.description')}
        </p>
      </header>

      {documents.isPending ? <PanelMessage>
        {t('personal_documents.loading')}
      </PanelMessage> : null}
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
  const queryClient = useQueryClient()
  const [files, setFiles] = useState<File[]>([])
  const [googleDocUrl, setGoogleDocUrl] = useState("")
  const [previewDocument, setPreviewDocument] = useState<PersonalDocument | null>(null)
  const [sortState, setSortState] = useState<DocumentSortState>(DEFAULT_DOCUMENT_SORT)
  const filterSchema = buildDocumentFilterSchema(t)
  const upload = useMutation({
    mutationFn: () => addCredentialDocuments(files, googleDocUrl),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setFiles([])
      setGoogleDocUrl("")
      onNotice(updated.message || t('personal_documents.added'))
    }
  })
  const destroy = useMutation({
    mutationFn: (document: PersonalDocument) => deleteCredentialDocument(document.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || t('personal_documents.removed'))
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
      if (await confirm({ message: t('personal_documents.confirm_delete'), destructive: true })) destroy.mutate(document)
    },
    onOpen: openDocument,
    t
  })
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: DOCUMENTS_VISIBLE_COLUMNS_STORAGE_KEY })
  const filterTree = filterTreeFromSearch(location.search)
  const visibleDocuments = useMemo(
    () => sortedDocuments(filteredDocuments(payload.documents, filterTree), sortState),
    [payload.documents, filterTree, sortState]
  )

  function toggleSortColumn(column: DocumentSortColumn) {
    setSortState((current) => toggleSort(current, column))
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-5">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <SectionHeading>
            {t('personal_documents.section_heading')}
          </SectionHeading>
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {t('personal_documents.attach_description')}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <span className="text-xs text-gray-500 dark:text-gray-400">{visibleDocuments.length} / {payload.documents.length}</span>
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
        <FilterBar
          filter={filterTree}
          filterSchema={filterSchema}
          pathname={location.pathname}
          search={location.search}
        />
      </div>

      <DataTable.Root aria-label={t('personal_documents.section_heading')} className="mt-4">
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
          {visibleDocuments.length === 0 ? (
            <DataTable.Row>
              <DataTable.Empty colSpan={columns.length}>{t('personal_documents.empty')}</DataTable.Empty>
            </DataTable.Row>
          ) : visibleDocuments.map((document) => (
            <DataTable.Row key={document.id}>
              <DataTableColumnCells columns={columns} order={preferences.order} row={document} />
            </DataTable.Row>
          ))}
        </DataTable.Body>
      </DataTable.Root>

      <form className="mt-4 space-y-3" onSubmit={submit}>
        {upload.isError ? <PanelMessage tone="error">{errorMessage(upload.error, "Unable to add document.")}</PanelMessage> : null}
        {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete document.")}</PanelMessage> : null}
        <Field label={t('personal_documents.upload_files')}>
          <Form.Input
            multiple
            onChange={(event) => setFiles(Array.from(event.currentTarget.files || []))}
            type="file"
          />
        </Field>
        <Field label={t('personal_documents.google_doc_url')}>
          <Form.Input onChange={(event) => setGoogleDocUrl(event.target.value)} placeholder="https://docs.google.com/document/d/..." type="url" value={googleDocUrl} />
        </Field>
        <button className="rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-800 disabled:bg-gray-400" disabled={upload.isPending} type="submit">
          {upload.isPending ? (
            <>
              {t('personal_documents.adding')}
            </>
          ) : (
            <>
              {t('personal_documents.add')}
            </>
          )}
        </button>
      </form>
      {previewDocument && previewDocument.file_path ? (
        <DocumentPreviewModal
          file={{ title: previewDocument.filename || t('personal_documents.file'), rawUrl: previewDocument.file_path, contentType: previewDocument.content_type }}
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
    { field: "content_cached_at", label: t("personal_documents.col_content_cached_at"), bucket: "date", operators: ["before", "after", "between", "is_set", "is_unset"] },
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
      renderCell: (document) => document.kind === "google_doc" ? t("personal_documents.google_doc") : t("personal_documents.file")
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
      renderCell: (document) => document.byte_size == null ? "-" : formatBytes(document.byte_size)
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
      renderCell: (document) => document.content_cache_state === "cached" ? t("personal_documents.cache_cached") : t("personal_documents.cache_empty")
    },
    {
      key: "content_cached_at",
      label: t("personal_documents.col_content_cached_at"),
      sortKey: "content_cached_at",
      defaultVisible: false,
      renderCell: (document) => document.content_cached_at ? new Date(document.content_cached_at).toLocaleString() : "-"
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
          {t('personal_documents.delete')}
        </button>
      )
    }
  ]
}

function DocumentSummary({ document }: { document: PersonalDocument }) {
  const { t } = useT("settings")
  if (document.kind === "google_doc" && document.google_doc_url) {
    return (
      <div className="min-w-0">
        <div className="truncate text-sm font-medium text-brand dark:text-brand-emphasis">{document.google_doc_url}</div>
        <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
          {t('personal_documents.google_doc')}
        </div>
      </div>
    )
  }

  return (
    <div className="min-w-0">
      <div className="truncate text-sm font-medium text-gray-900 dark:text-gray-100">
        {document.filename || (
          <>
            {t('personal_documents.file')}
          </>
        )}
      </div>
      <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">{document.content_type || "unknown"} · {formatBytes(document.byte_size)}</div>
    </div>
  )
}

function documentTitle(document: PersonalDocument) {
  return document.kind === "google_doc" ? document.google_doc_url || "" : document.filename || ""
}

function filteredDocuments(documents: PersonalDocument[], tree: FilterTree) {
  const nodes = topLevelNodes(tree)
  if (nodes.length === 0) return documents

  return documents.filter((document) => nodes.every((node) => documentMatchesFilterNode(document, node)))
}

function documentMatchesFilterNode(document: PersonalDocument, node: FilterNode): boolean {
  if ("field" in node) return documentMatchesFilter(document, node)
  if ("and" in node && Array.isArray(node.and)) return node.and.every((child) => documentMatchesFilterNode(document, child))
  if ("or" in node && Array.isArray(node.or)) return node.or.some((child) => documentMatchesFilterNode(document, child))
  if ("not" in node && node.not) return !documentMatchesFilterNode(document, node.not)
  return true
}

function documentMatchesFilter(document: PersonalDocument, chip: FilterChip) {
  if (chip.field === "query") {
    const query = String(chip.value || "").toLowerCase()
    return documentSearchText(document).includes(query)
  }
  if (chip.field === "title") return matchesTextFilter(documentTitle(document), chip)
  if (chip.field === "filename") return matchesTextFilter(document.filename || "", chip)
  if (chip.field === "kind") return matchesTextFilter(document.kind, chip)
  if (chip.field === "content_type") return matchesTextFilter(document.content_type || "", chip)
  if (chip.field === "byte_size") return matchesNumberFilter(document.byte_size, chip)
  if (chip.field === "source_url") return matchesTextFilter(document.source_url || document.google_doc_url || "", chip)
  if (chip.field === "content_cache_state") return matchesTextFilter(document.content_cache_state, chip)
  if (chip.field === "content_cached_at") return matchesDateFilter(document.content_cached_at, chip)
  if (chip.field === "created_at") return matchesDateFilter(document.created_at, chip)
  if (chip.field === "updated_at") return matchesDateFilter(document.updated_at, chip)
  return true
}

function documentSearchText(document: PersonalDocument) {
  return [
    documentTitle(document),
    document.filename,
    document.kind,
    document.content_type,
    document.source_url,
    document.google_doc_url,
    document.content_cache_state
  ].filter(Boolean).join(" ").toLowerCase()
}

function sortedDocuments(documents: PersonalDocument[], sortState: DocumentSortState) {
  const factor = sortState.direction === "ascending" ? 1 : -1
  const valueFor = DOCUMENT_SORT_ACCESSORS[sortState.column]
  return [...documents].sort((left, right) => {
    const compared = compareSortValues(valueFor(left), valueFor(right))
    if (compared !== 0) return compared * factor
    return documentTitle(left).localeCompare(documentTitle(right))
  })
}

function toggleSort<TColumn extends string>(current: { column: TColumn; direction: SortDirection }, column: TColumn) {
  if (current.column !== column) return { column, direction: "ascending" as const }
  return { column, direction: current.direction === "ascending" ? "descending" as const : "ascending" as const }
}

function compareSortValues(left: SortValue, right: SortValue) {
  if (left == null && right == null) return 0
  if (left == null) return -1
  if (right == null) return 1
  if (typeof left === "number" && typeof right === "number") return left - right
  return String(left).localeCompare(String(right))
}

function matchesTextFilter(value: string, chip: FilterChip) {
  const target = value.toLowerCase()
  const expected = String(chip.value || "").toLowerCase()
  if (chip.op === "is") return target === expected
  if (chip.op === "is_not") return target !== expected
  if (chip.op === "is_set") return value.trim().length > 0
  if (chip.op === "is_unset") return value.trim().length === 0
  return target.includes(expected)
}

function matchesNumberFilter(value: number | null, chip: FilterChip) {
  if (chip.op === "is_set") return value != null
  if (chip.op === "is_unset") return value == null
  if (value == null) return false
  const expected = Number(chip.value)
  if (Number.isNaN(expected)) return true
  if (chip.op === "gt") return value > expected
  if (chip.op === "lt") return value < expected
  if (chip.op === "gte") return value >= expected
  if (chip.op === "lte") return value <= expected
  return value === expected
}

function matchesDateFilter(value: string | null, chip: FilterChip) {
  if (chip.op === "is_set") return Boolean(value)
  if (chip.op === "is_unset") return !value
  if (!value) return false
  const time = Date.parse(value)
  if (Number.isNaN(time)) return false
  if (chip.op === "before") return time < Date.parse(String(chip.value || ""))
  if (chip.op === "after") return time > Date.parse(String(chip.value || ""))
  if (chip.op === "between" && Array.isArray(chip.value)) {
    const [start, end] = chip.value.map((part) => Date.parse(String(part || "")))
    return (Number.isNaN(start) || time >= start) && (Number.isNaN(end) || time <= end)
  }
  return true
}

function filterTreeFromSearch(search: string): FilterTree {
  const encoded = new URLSearchParams(search).get("q")
  if (!encoded) return { and: [] }
  try {
    const padded = `${encoded.replace(/-/g, "+").replace(/_/g, "/")}${"=".repeat((4 - encoded.length % 4) % 4)}`
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
