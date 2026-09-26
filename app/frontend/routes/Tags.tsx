import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useMemo, useState } from "react"
import { useLocation } from "react-router-dom"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { useConfirm } from "../hooks/useConfirm"
import { NoticeToast } from "../components/NoticeToast"
import { Input } from "../components/Input"
import { Select } from "../components/Select"
import { PageHeading, SectionHeading } from "../components/Heading"
import {
  createTag,
  deleteTag,
  fetchTags,
  updateTag,
  type TagPaletteColor,
  type TagRow,
  type TagsPayload
} from "../api/tags"
import { errorMessage } from "../lib/errorMessage"
import { DataTable } from "../components/ui"
import {
  DataTableColumnCells,
  DataTableColumnHeaderRow,
  DataTableColumnMenu,
  useLocalStorageColumnPreferences,
  type DataTableColumnDef
} from "../components/dataTable"
import { FilterBar, type FilterSchemaField } from "../components/FilterBar"
import type { FilterChip, FilterNode, FilterTree } from "../components/filterBar/types"

const queryKey = ["tags"] as const
const TAGS_VISIBLE_COLUMNS_STORAGE_KEY = "syrus.settings.tags.visible_columns"

type TagSortColumn = "name" | "jobs_count" | "color" | "created_at" | "updated_at"
type SortDirection = "ascending" | "descending"
type TagSortState = { column: TagSortColumn; direction: SortDirection }
type SortValue = number | string | null

const DEFAULT_TAG_SORT: TagSortState = { column: "name", direction: "ascending" }
const TAG_SORT_ACCESSORS: Record<TagSortColumn, (tag: TagRow) => SortValue> = {
  name: (tag) => tag.name,
  jobs_count: (tag) => tag.jobs_count,
  color: (tag) => tag.color,
  created_at: (tag) => tag.created_at,
  updated_at: (tag) => tag.updated_at
}

export function Tags() {
  const { t } = useT("settings")
  usePageTitle(t("tags.heading"))
  const [notice, setNotice] = useState<string | null>(null)
  const tags = useQuery({
    queryKey,
    queryFn: fetchTags
  })

  return (
    <main aria-label={t("aria_tags")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header>
        <PageHeading>{t('tags.heading')}</PageHeading>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{t('tags.description')}</p>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {tags.isPending ? <PanelMessage>{t('tags.loading')}</PanelMessage> : null}
      {tags.isError ? <TagsError error={tags.error} /> : null}
      {tags.isSuccess ? <TagsView onNotice={setNotice} payload={tags.data} /> : null}
    </main>
  )
}

function TagsView({ payload, onNotice }: { payload: TagsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  return (
    <>
      <CreateTagForm onNotice={onNotice} palette={payload.palette} />
      <TagsTable onNotice={onNotice} palette={payload.palette} tags={payload.tags} />
    </>
  )
}

function CreateTagForm({ palette, onNotice }: { palette: TagPaletteColor[]; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [name, setName] = useState("")
  const [color, setColor] = useState("gray")
  const create = useMutation({
    mutationFn: () => createTag({ name, color }),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      setName("")
      setColor("gray")
      onNotice(payload.message || t('tags.created'))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <SectionHeading>{t('tags.create')}</SectionHeading>
      <form className="mt-3 flex flex-wrap items-end gap-3" onSubmit={submit}>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="new-tag-name">
          {t('tags.field_name')}
          <Input
            id="new-tag-name"
            className="mt-1 normal-case"
            fullWidth={false}
            onChange={(event) => setName(event.target.value)}
            required
            type="text"
            value={name}
          />
        </label>
        <label className="block text-xs font-medium uppercase text-gray-500 dark:text-gray-400" htmlFor="new-tag-color">
          {t('tags.field_color')}
          <Select
            id="new-tag-color"
            className="mt-1 normal-case"
            fullWidth={false}
            onChange={(event) => setColor(event.target.value)}
            value={color}
          >
            {palette.map((option) => (
              <option key={option.key} value={option.key}>{option.label}</option>
            ))}
          </Select>
        </label>
        <button
          className="rounded bg-indigo-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-indigo-500 disabled:cursor-not-allowed disabled:bg-indigo-300"
          disabled={create.isPending}
          type="submit"
        >
          {create.isPending ? t('tags.creating') : t('tags.create_btn')}
        </button>
      </form>
      {create.isError ? <p className="mt-3 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(create.error, t("tags.error_create"))}</p> : null}
    </section>
  )
}

function TagsTable({ tags, palette, onNotice }: { tags: TagRow[]; palette: TagPaletteColor[]; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const location = useLocation()
  const [sortState, setSortState] = useState<TagSortState>(DEFAULT_TAG_SORT)
  const filterSchema = buildTagFilterSchema(t)
  const filterTree = filterTreeFromSearch(location.search)
  const visibleTags = useMemo(
    () => sortedTags(filteredTags(tags, filterTree), sortState),
    [filterTree, sortState, tags]
  )
  const columns = buildTagColumns({ onNotice, palette, t })
  const preferences = useLocalStorageColumnPreferences({ columns, storageKey: TAGS_VISIBLE_COLUMNS_STORAGE_KEY })

  function toggleSortColumn(column: TagSortColumn) {
    setSortState((current) => toggleSort(current, column))
  }

  return (
    <section className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <div className="flex flex-wrap items-start justify-between gap-3">
        <FilterBar
          filter={filterTree}
          filterSchema={filterSchema}
          pathname={location.pathname}
          search={location.search}
        />
        <div className="flex items-center gap-2">
          <span className="text-xs text-gray-500 dark:text-gray-400">{visibleTags.length} / {tags.length}</span>
          <DataTableColumnMenu
            columns={columns}
            downLabel={t("tags.column_down")}
            menuId="tags-columns-menu"
            moveDownLabel={(title) => t("tags.column_move_down", { title })}
            moveUpLabel={(title) => t("tags.column_move_up", { title })}
            onChange={preferences.onChange}
            order={preferences.order}
            triggerAriaLabel={t("tags.columns")}
            triggerClassName="h-[var(--control-height-md)] w-[var(--control-height-md)]"
            triggerSize="icon"
            upLabel={t("tags.column_up")}
            visibleLabel={t("tags.visible_columns")}
          />
        </div>
      </div>

      <DataTable.Root aria-label={t('tags.heading')}>
        <DataTable.Header>
          <DataTableColumnHeaderRow
            columns={columns}
            onReorder={preferences.onChange}
            onSort={(column) => toggleSortColumn(column as TagSortColumn)}
            order={preferences.order}
            sortColumn={sortState.column}
            sortDirection={sortState.direction}
          />
        </DataTable.Header>
        <DataTable.Body>
          {visibleTags.length === 0 ? (
            <DataTable.Row>
              <DataTable.Empty colSpan={columns.length}>{t('tags.empty')}</DataTable.Empty>
            </DataTable.Row>
          ) : visibleTags.map((tag) => (
            <TagTableRow columns={columns} key={tag.id} onNotice={onNotice} order={preferences.order} palette={palette} tag={tag} />
          ))}
        </DataTable.Body>
      </DataTable.Root>
    </section>
  )
}

function buildTagFilterSchema(t: (key: string, options?: Record<string, unknown>) => string): FilterSchemaField[] {
  return [
    { field: "query", label: t("tags.col_tag"), bucket: "text", operators: ["contains"], free_text_search: true },
    { field: "name", label: t("tags.col_tag"), bucket: "text", operators: ["contains", "is", "is_not"] },
    { field: "color", label: t("tags.col_color"), bucket: "text", operators: ["is", "is_not", "contains"] },
    { field: "jobs_count", label: t("tags.col_jobs"), bucket: "number", operators: ["is", "gt", "lt", "gte", "lte"] },
    { field: "created_at", label: t("tags.col_created"), bucket: "date", operators: ["before", "after", "between"] },
    { field: "updated_at", label: t("tags.col_updated"), bucket: "date", operators: ["before", "after", "between"] }
  ]
}

function buildTagColumns({
  onNotice,
  palette,
  t
}: {
  onNotice: (message: string | null) => void
  palette: TagPaletteColor[]
  t: (key: string, options?: Record<string, unknown>) => string
}): DataTableColumnDef<TagRow>[] {
  return [
    {
      key: "tag",
      label: t("tags.col_tag"),
      required: true,
      sortKey: "name",
      renderCell: (tag) => <TagChip palette={palette} tag={tag} />
    },
    {
      key: "jobs",
      label: t("tags.col_jobs"),
      align: "right",
      sortKey: "jobs_count",
      renderCell: (tag) => tag.jobs_count
    },
    {
      key: "color",
      label: t("tags.col_color"),
      sortKey: "color",
      defaultVisible: false,
      renderCell: (tag) => palette.find((option) => option.key === tag.color)?.label || tag.color
    },
    {
      key: "created_at",
      label: t("tags.col_created"),
      sortKey: "created_at",
      defaultVisible: false,
      renderCell: (tag) => new Date(tag.created_at).toLocaleString()
    },
    {
      key: "updated_at",
      label: t("tags.col_updated"),
      sortKey: "updated_at",
      defaultVisible: false,
      renderCell: (tag) => new Date(tag.updated_at).toLocaleString()
    },
    {
      key: "rename",
      label: t("tags.col_rename"),
      required: true,
      pin: "end",
      renderCell: (tag) => <TagEditForm onNotice={onNotice} palette={palette} tag={tag} />
    },
    {
      key: "actions",
      label: t("tags.col_actions"),
      required: true,
      pin: "end",
      align: "right",
      renderHeader: () => <span className="sr-only">{t("tags.col_actions")}</span>,
      renderCell: (tag) => <TagDeleteButton onNotice={onNotice} tag={tag} />
    }
  ]
}

function TagTableRow({ tag, columns, order }: { tag: TagRow; columns: DataTableColumnDef<TagRow>[]; order: string[] | null | undefined; palette: TagPaletteColor[]; onNotice: (message: string | null) => void }) {
  return (
    <DataTable.Row>
      <DataTableColumnCells columns={columns} order={order} row={tag} />
    </DataTable.Row>
  )
}

function TagEditForm({ tag, palette, onNotice }: { tag: TagRow; palette: TagPaletteColor[]; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const [name, setName] = useState(tag.name)
  const [color, setColor] = useState(tag.color)
  const update = useMutation({
    mutationFn: () => updateTag(tag.id, { name, color }),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      onNotice(payload.message || t('tags.tag_updated'))
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    update.mutate()
  }

  return (
    <>
      <form className="flex flex-wrap items-center gap-2" onSubmit={submit}>
        <div className="w-48">
          <Input
            aria-label={t('tags.name_for', { name: tag.name })}
            onChange={(event) => setName(event.target.value)}
            required
            type="text"
            value={name}
          />
        </div>
        <Select
          aria-label={t('tags.color_for', { name: tag.name })}
          fullWidth={false}
          onChange={(event) => setColor(event.target.value)}
          value={color}
        >
          {palette.map((option) => (
            <option key={option.key} value={option.key}>{option.label}</option>
          ))}
        </Select>
        <button
          className="rounded bg-gray-900 px-3 py-1.5 text-sm font-medium text-white hover:bg-gray-800 disabled:cursor-not-allowed disabled:bg-gray-400"
          disabled={update.isPending}
          type="submit"
        >
          {update.isPending ? t('tags.saving') : t('tags.save')}
        </button>
      </form>
      {update.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(update.error, t("tags.error_update"))}</p> : null}
    </>
  )
}

function TagDeleteButton({ tag, onNotice }: { tag: TagRow; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const destroy = useMutation({
    mutationFn: () => deleteTag(tag.id),
    onSuccess: (payload) => {
      queryClient.setQueryData(queryKey, payload)
      onNotice(payload.message || t('tags.deleted'))
    }
  })

  return (
    <>
      <button
        className="text-sm text-red-600 dark:text-red-300 underline hover:no-underline disabled:cursor-not-allowed disabled:text-red-300 dark:disabled:text-red-500"
        disabled={destroy.isPending}
        onClick={async () => {
          if (await confirm({ message: t('tags.confirm_delete', { name: tag.name }), destructive: true })) {
            onNotice(null)
            destroy.mutate()
          }
        }}
        type="button"
      >
        {destroy.isPending ? t('tags.deleting') : t('tags.delete')}
      </button>
      {destroy.isError ? <p className="mt-2 text-xs text-red-700 dark:text-red-300" role="alert">{errorMessage(destroy.error, t("tags.error_delete"))}</p> : null}
      {dialog}
    </>
  )
}

function TagChip({ tag, palette }: { tag: TagRow; palette: TagPaletteColor[] }) {
  const { t } = useT("settings")
  const colors = tagColors(tag.color, palette)

  return (
    <span className="inline-flex items-center rounded px-2 py-0.5 text-xs font-medium" style={{ backgroundColor: colors.bg, color: colors.text }}>
      {tag.name}
    </span>
  )
}

function TagsError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, t("tags.error_load"))}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const { t } = useT("settings")
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-400"}`}>{children}</div>
}

function tagColors(color: string, palette: TagPaletteColor[]) {
  const match = palette.find((option) => option.key === color)
  if (match) return { bg: match.bg, text: match.text }
  if (/^#[0-9a-fA-F]{6}$/.test(color)) return { bg: color, text: readableTextColor(color) }
  const fallback = palette.find((option) => option.key === "gray")
  return fallback ? { bg: fallback.bg, text: fallback.text } : { bg: "#f3f4f6", text: "#374151" }
}

function readableTextColor(hex: string) {
  const value = hex.replace("#", "")
  const red = parseInt(value.slice(0, 2), 16)
  const green = parseInt(value.slice(2, 4), 16)
  const blue = parseInt(value.slice(4, 6), 16)
  const luminance = (0.299 * red + 0.587 * green + 0.114 * blue) / 255
  return luminance > 0.62 ? "#111827" : "#ffffff"
}

function filteredTags(tags: TagRow[], tree: FilterTree) {
  const nodes = topLevelNodes(tree)
  if (nodes.length === 0) return tags

  return tags.filter((tag) => nodes.every((node) => tagMatchesFilterNode(tag, node)))
}

function tagMatchesFilterNode(tag: TagRow, node: FilterNode): boolean {
  if ("field" in node) return tagMatchesFilter(tag, node)
  if ("and" in node && Array.isArray(node.and)) return node.and.every((child) => tagMatchesFilterNode(tag, child))
  if ("or" in node && Array.isArray(node.or)) return node.or.some((child) => tagMatchesFilterNode(tag, child))
  if ("not" in node && node.not) return !tagMatchesFilterNode(tag, node.not)
  return true
}

function tagMatchesFilter(tag: TagRow, chip: FilterChip) {
  if (chip.field === "query") return tag.name.toLowerCase().includes(String(chip.value || "").toLowerCase())
  if (chip.field === "name") return matchesTextFilter(tag.name, chip)
  if (chip.field === "color") return matchesTextFilter(tag.color, chip)
  if (chip.field === "jobs_count") return matchesNumberFilter(tag.jobs_count, chip)
  if (chip.field === "created_at") return matchesDateFilter(tag.created_at, chip)
  if (chip.field === "updated_at") return matchesDateFilter(tag.updated_at, chip)
  return true
}

function sortedTags(tags: TagRow[], sortState: TagSortState) {
  const factor = sortState.direction === "ascending" ? 1 : -1
  const valueFor = TAG_SORT_ACCESSORS[sortState.column]
  return [...tags].sort((left, right) => {
    const compared = compareSortValues(valueFor(left), valueFor(right))
    if (compared !== 0) return compared * factor
    return left.name.localeCompare(right.name)
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
  return target.includes(expected)
}

function matchesNumberFilter(value: number, chip: FilterChip) {
  const expected = Number(chip.value)
  if (Number.isNaN(expected)) return true
  if (chip.op === "gt") return value > expected
  if (chip.op === "lt") return value < expected
  if (chip.op === "gte") return value >= expected
  if (chip.op === "lte") return value <= expected
  return value === expected
}

function matchesDateFilter(value: string, chip: FilterChip) {
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
