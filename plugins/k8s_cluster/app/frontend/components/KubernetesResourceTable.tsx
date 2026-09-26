import { useMemo, type ReactNode } from "react"
import { useLocation } from "react-router-dom"
import { FilterBar, filterTreeFromPayload, topFilterChildren, type FilterChip, type FilterNode, type FilterSchemaField, type FilterTree } from "@app/components/FilterBar"
import { AdminEventLogTable, type AdminEventLogTableColumn } from "@app/components/AdminEventLogPanel"
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
  const filterSchema = useMemo(() => resourceFilterSchema(t, columns, rows), [columns, rows, t])
  const filter = useMemo(() => filterTreeFromSearch(location.search), [location.search])
  const filteredRows = useMemo(() => filterRows(rows, columns, filter), [columns, filter, rows])
  const meta =
    rows.length === filteredRows.length
      ? t("resource_table_count", { count: rows.length })
      : t("resource_table_filtered_count", { shown: filteredRows.length, total: rows.length })

  if (rows.length === 0) return <>{empty}</>

  return (
    <div className="space-y-3">
      <FilterBar
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

function resourceFilterSchema<TRow>(t: ReturnType<typeof useT>["t"], columns: Array<KubernetesResourceTableColumn<TRow>>, rows: TRow[]): FilterSchemaField[] {
  return [
    {
      bucket: "text",
      expansions: { placeholder: t("resource_filter_placeholder") },
      field: SEARCH_FIELD,
      free_text_search: true,
      label: t("resource_filter_query"),
      operators: ["contains"]
    },
    ...columns.map((column) => {
      const bucket = resourceColumnBucket(column, rows)
      return {
        bucket,
        field: column.key,
        label: columnLabel(column),
        operators: resourceFilterOperators(bucket)
      }
    })
  ]
}

function filterTreeFromSearch(search: string) {
  const params = new URLSearchParams(search)
  const encoded = params.get("q")
  if (encoded) return decodeFilterTree(encoded)

  const query = params.get(SEARCH_FIELD)?.trim()
  return filterTreeFromPayload(query ? { and: [{ field: SEARCH_FIELD, op: "contains", value: query }] } : null)
}

function filterRows<TRow>(rows: TRow[], columns: Array<KubernetesResourceTableColumn<TRow>>, filter: FilterTree) {
  const nodes = topFilterChildren(filter)
  if (nodes.length === 0) return rows

  return rows.filter((row) => nodes.every((node) => rowMatchesFilterNode(row, columns, node)))
}

function rowMatchesFilterNode<TRow>(row: TRow, columns: Array<KubernetesResourceTableColumn<TRow>>, node: FilterNode): boolean {
  if ("field" in node) return rowMatchesFilter(row, columns, node)
  if ("and" in node && Array.isArray(node.and)) return node.and.every((child) => rowMatchesFilterNode(row, columns, child))
  if ("or" in node && Array.isArray(node.or)) return node.or.some((child) => rowMatchesFilterNode(row, columns, child))
  if ("not" in node && node.not) return !rowMatchesFilterNode(row, columns, node.not)
  return true
}

function rowMatchesFilter<TRow>(row: TRow, columns: Array<KubernetesResourceTableColumn<TRow>>, chip: FilterChip): boolean {
  if (chip.field === SEARCH_FIELD) return searchableText(row, columns).includes(String(chip.value || "").trim().toLowerCase())

  const column = columns.find((candidate) => candidate.key === chip.field)
  if (!column) return true
  const bucket = resourceValueBucket(valuesForColumn(row, column))
  if (bucket === "number") return matchesNumberFilter(valuesForColumn(row, column), chip)
  if (bucket === "date") return matchesDateFilter(valuesForColumn(row, column), chip)
  return matchesTextFilter(valuesForColumn(row, column), chip)
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

function resourceColumnBucket<TRow>(column: KubernetesResourceTableColumn<TRow>, rows: TRow[]) {
  const firstValues = rows.flatMap((row) => valuesForColumn(row, column)).filter((value) => value !== null && value !== undefined)
  if (column.key.endsWith("_at") || firstValues.some((value) => typeof value === "string" && !Number.isNaN(Date.parse(value)) && /\d{4}-\d{2}-\d{2}/.test(value))) return "date"
  if (firstValues.some((value) => typeof value === "number")) return "number"
  return "text"
}

function resourceValueBucket(values: Array<number | string | null | undefined>) {
  const present = values.filter((value) => value !== null && value !== undefined)
  if (present.some((value) => typeof value === "number")) return "number"
  if (present.some((value) => typeof value === "string" && !Number.isNaN(Date.parse(value)) && /\d{4}-\d{2}-\d{2}/.test(value))) return "date"
  return "text"
}

function resourceFilterOperators(bucket: string) {
  if (bucket === "number") return ["is", "gt", "lt", "gte", "lte", "is_set", "is_unset"]
  if (bucket === "date") return ["before", "after", "between", "is_set", "is_unset"]
  return ["contains", "is", "is_not", "is_set", "is_unset"]
}

function columnLabel<TRow>(column: KubernetesResourceTableColumn<TRow>) {
  if (typeof column.label === "string") return column.label
  if (typeof column.header === "string") return column.header
  return humanizeField(column.key)
}

function valuesForColumn<TRow>(row: TRow, column: KubernetesResourceTableColumn<TRow>) {
  const value = column.filterValue ? column.filterValue(row) : (row as Record<string, unknown>)[column.key]
  return (Array.isArray(value) ? value : [value]) as Array<number | string | null | undefined>
}

function searchableText<TRow>(row: TRow, columns: Array<KubernetesResourceTableColumn<TRow>>) {
  return columns
    .flatMap((column) => valuesForColumn(row, column))
    .filter((value) => value !== null && value !== undefined)
    .map((value) => String(value).toLowerCase())
    .join(" ")
}

function matchesTextFilter(values: Array<number | string | null | undefined>, chip: FilterChip) {
  const present = values.filter((value) => value !== null && value !== undefined).map((value) => String(value))
  if (chip.op === "is_set") return present.some((value) => value.trim().length > 0)
  if (chip.op === "is_unset") return present.every((value) => value.trim().length === 0)
  const expected = String(chip.value || "").toLowerCase()
  if (chip.op === "is") return present.some((value) => value.toLowerCase() === expected)
  if (chip.op === "is_not") return present.every((value) => value.toLowerCase() !== expected)
  return present.some((value) => value.toLowerCase().includes(expected))
}

function matchesNumberFilter(values: Array<number | string | null | undefined>, chip: FilterChip) {
  const numbers = values.map((value) => Number(value)).filter((value) => !Number.isNaN(value))
  if (chip.op === "is_set") return numbers.length > 0
  if (chip.op === "is_unset") return numbers.length === 0
  const expected = Number(chip.value)
  if (Number.isNaN(expected)) return true
  if (chip.op === "gt") return numbers.some((value) => value > expected)
  if (chip.op === "lt") return numbers.some((value) => value < expected)
  if (chip.op === "gte") return numbers.some((value) => value >= expected)
  if (chip.op === "lte") return numbers.some((value) => value <= expected)
  return numbers.some((value) => value === expected)
}

function matchesDateFilter(values: Array<number | string | null | undefined>, chip: FilterChip) {
  const times = values.map((value) => Date.parse(String(value || ""))).filter((value) => !Number.isNaN(value))
  if (chip.op === "is_set") return times.length > 0
  if (chip.op === "is_unset") return times.length === 0
  if (chip.op === "before") return times.some((value) => value < Date.parse(String(chip.value || "")))
  if (chip.op === "after") return times.some((value) => value > Date.parse(String(chip.value || "")))
  if (chip.op === "between" && Array.isArray(chip.value)) {
    const [start, end] = chip.value.map((part) => Date.parse(String(part || "")))
    return times.some((value) => (Number.isNaN(start) || value >= start) && (Number.isNaN(end) || value <= end))
  }
  return true
}

function humanizeField(field: string) {
  return field.replace(/_/g, " ").replace(/\b\w/g, (letter) => letter.toUpperCase())
}
