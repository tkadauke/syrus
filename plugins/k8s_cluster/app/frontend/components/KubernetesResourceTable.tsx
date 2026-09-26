import { useMemo, type ReactNode } from "react"
import { useLocation } from "react-router-dom"
import { FilterBar, filterTreeFromPayload, topFilterChildren, type FilterChip, type FilterSchemaField } from "@app/components/FilterBar"
import { AdminEventLogTable, type AdminEventLogTableColumn } from "@app/components/AdminEventLogPanel"
import { buildFlatFilterLink } from "@app/lib/flatFilterLink"
import { useT } from "@app/hooks/useT"

export type KubernetesResourceTableColumn<TRow> = AdminEventLogTableColumn<TRow> & {
  filterValue?: (row: TRow) => Array<number | string | null | undefined> | number | string | null | undefined
}

type KubernetesResourceTableProps<TRow> = {
  columns: Array<KubernetesResourceTableColumn<TRow>>
  defaultSort: { column: string; direction?: "asc" | "desc" }
  empty: ReactNode
  getRowKey: (row: TRow) => string | number
  rows: TRow[]
  storageKey: string
  summary: ReactNode
}

const SEARCH_FIELD = "resource_query"

export function KubernetesResourceTable<TRow>(
  { columns, defaultSort, empty, getRowKey, rows, storageKey, summary }: KubernetesResourceTableProps<TRow>
) {
  const { t } = useT("k8s_cluster")
  const location = useLocation()
  const filterSchema = useMemo(() => resourceFilterSchema(t), [t])
  const filter = useMemo(() => filterTreeFromSearch(location.search), [location.search])
  const filteredRows = useMemo(() => filterRows(rows, columns, location.search), [columns, location.search, rows])
  const meta =
    rows.length === filteredRows.length
      ? t("resource_table_count", { count: rows.length })
      : t("resource_table_filtered_count", { shown: filteredRows.length, total: rows.length })

  if (rows.length === 0) return <>{empty}</>

  return (
    <div className="space-y-3">
      <FilterBar
        buildLink={buildFlatFilterLink([SEARCH_FIELD])}
        filter={filter}
        filterSchema={filterSchema}
        legacyFilterKeys={[SEARCH_FIELD]}
        pathname={location.pathname}
        search={location.search}
      />
      <AdminEventLogTable
        columns={columns}
        defaultSort={defaultSort}
        getRowKey={getRowKey}
        localSort
        panel={{ summary, meta }}
        rows={filteredRows}
        storageKey={storageKey}
      />
    </div>
  )
}

function resourceFilterSchema(t: ReturnType<typeof useT>["t"]): FilterSchemaField[] {
  return [
    {
      bucket: "text",
      expansions: { placeholder: t("resource_filter_placeholder") },
      field: SEARCH_FIELD,
      free_text_search: true,
      label: t("resource_filter_query"),
      operators: ["contains"]
    }
  ]
}

function filterTreeFromSearch(search: string) {
  const params = new URLSearchParams(search)
  const query = params.get(SEARCH_FIELD)?.trim()
  return filterTreeFromPayload(query ? { and: [{ field: SEARCH_FIELD, op: "contains", value: query }] } : null)
}

function filterRows<TRow>(rows: TRow[], columns: Array<KubernetesResourceTableColumn<TRow>>, search: string) {
  const query = queryFromFilter(search)
  if (!query) return rows

  return rows.filter((row) => searchableText(row, columns).includes(query))
}

function queryFromFilter(search: string) {
  const params = new URLSearchParams(search)
  const flatQuery = params.get(SEARCH_FIELD)?.trim().toLowerCase()
  if (flatQuery) return flatQuery

  const encoded = params.get("q")
  if (!encoded) return ""

  return (
    topFilterChildren(decodeFilterTree(encoded))
      .map((node) =>
        "field" in node && node.field === SEARCH_FIELD
          ? String((node as FilterChip).value ?? "")
              .trim()
              .toLowerCase()
          : ""
      )
      .find(Boolean) || ""
  )
}

function decodeFilterTree(encoded: string) {
  try {
    const normalized = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const padded = normalized.padEnd(Math.ceil(normalized.length / 4) * 4, "=")
    return filterTreeFromPayload(JSON.parse(decodeURIComponent(escape(atob(padded)))))
  } catch {
    return filterTreeFromPayload(null)
  }
}

function searchableText<TRow>(row: TRow, columns: Array<KubernetesResourceTableColumn<TRow>>) {
  return columns
    .flatMap((column) => {
      if (column.filterValue) {
        const value = column.filterValue(row)
        return Array.isArray(value) ? value : [value]
      }
      const value = (row as Record<string, unknown>)[column.key]
      return Array.isArray(value) ? value : [value]
    })
    .filter((value) => value !== null && value !== undefined)
    .map((value) => String(value).toLowerCase())
    .join(" ")
}
