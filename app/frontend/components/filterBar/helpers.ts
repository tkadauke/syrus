import { useEffect, useMemo, useState } from "react"

import { useT } from "../../hooks/useT"
import type { FilterChip, FilterLinkBuilder, FilterLinkUpdates, FilterNode, FilterOption, FilterPath, FilterSchemaField, FilterSuggestion, FilterSuggestionSearchConfig, FilterTree } from "./types"

// Pure filter-tree helpers extracted from FilterBar.tsx: encode/normalize/diff
// a filter tree, path traversal/mutation, chip/label/option derivation, and
// the class/link helpers. FilterBar re-exports the externally-consumed ones
// (smartFolderFiltersFromTree, filterTreeFromPayload, filterTreesEqual,
// topFilterChildren). Depends only on the filter types + lib helpers.

export function smartFolderFiltersFromTree(tree: FilterTree) {
  const normalized = normalizedFilterTree(tree)
  const filters: Record<string, string> = {}
  if (topFilterChildren(normalized).length > 0) filters.filter = JSON.stringify(normalized)
  return filters
}

export function filterTreeFromPayload(filter: Record<string, unknown> | null | undefined): FilterTree {
  return normalizedFilterTree(filter && typeof filter === "object" ? filter as FilterTree : null)
}

export function filterTreesEqual(left: FilterTree, right: FilterTree) {
  return stableFilterJson(normalizedFilterTree(left)) === stableFilterJson(normalizedFilterTree(right))
}

export function encodeFilterTree(tree: FilterTree) {
  const json = JSON.stringify(normalizedFilterTree(tree))
  return btoa(unescape(encodeURIComponent(json))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

export function normalizedFilterTree(tree: FilterTree | null): FilterTree {
  const children = topFilterChildren(tree).filter(Boolean)
  return { and: children }
}

export function stableFilterJson(value: unknown): string {
  return JSON.stringify(stableFilterValue(value))
}

export function stableFilterValue(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(stableFilterValue)
  if (!value || typeof value !== "object") return value

  return Object.fromEntries(
    Object.entries(value as Record<string, unknown>)
      .sort(([left], [right]) => left.localeCompare(right))
      .map(([key, nested]) => [key, stableFilterValue(nested)])
  )
}

export function topFilterChildren(tree: FilterTree | FilterNode | null): FilterNode[] {
  if (!tree || typeof tree !== "object") return []
  if ("and" in tree && Array.isArray(tree.and)) return tree.and
  if (isFilterChip(tree) || ("or" in tree && Array.isArray(tree.or)) || ("not" in tree && tree.not)) return [tree as FilterNode]
  return []
}

export function suggestionFilterNode(suggestion: FilterSuggestion): FilterNode | null {
  return topFilterChildren(suggestion.filter as FilterNode)[0] || null
}

export function isFilterChip(node: unknown): node is FilterChip {
  return Boolean(node && typeof node === "object" && "field" in node && typeof (node as FilterChip).field === "string")
}

export function filterSlotInner(node: FilterNode | undefined): FilterNode | undefined {
  if (node && "not" in node && node.not) return node.not
  return node
}

export function filterSlotIsNegated(node: FilterNode | undefined) {
  return Boolean(node && "not" in node && node.not)
}

export function filterNodeAtPath(tree: FilterTree, path: FilterPath): FilterNode | null {
  const slot = topFilterChildren(tree)[path[0]]
  const inner = filterSlotInner(slot)
  if (path.length === 1) return inner || null
  if (!inner || !("or" in inner) || !Array.isArray(inner.or)) return null
  return inner.or[path[1]] || null
}

export function replaceFilterNodeAtPath(tree: FilterTree, path: FilterPath, node: FilterNode): FilterTree {
  const children = topFilterChildren(tree).slice()
  const slot = children[path[0]]
  const negated = filterSlotIsNegated(slot)
  if (path.length === 1) {
    children[path[0]] = negated ? { not: node } : node
    return { and: children }
  }

  const inner = filterSlotInner(slot)
  if (!inner || !("or" in inner) || !Array.isArray(inner.or)) return tree
  const nextOr = inner.or.slice()
  nextOr[path[1]] = node
  children[path[0]] = negated ? { not: { or: nextOr } } : { or: nextOr }
  return { and: children }
}

export function removeFilterNodeAtPath(tree: FilterTree, path: FilterPath): FilterTree {
  const children = topFilterChildren(tree).slice()
  if (path.length === 1) {
    children.splice(path[0], 1)
    return { and: children }
  }

  const slot = children[path[0]]
  const negated = filterSlotIsNegated(slot)
  const inner = filterSlotInner(slot)
  if (!inner || !("or" in inner) || !Array.isArray(inner.or)) return tree
  const nextOr = inner.or.slice()
  nextOr.splice(path[1], 1)
  if (nextOr.length === 0) children.splice(path[0], 1)
  else if (nextOr.length === 1) children[path[0]] = negated ? { not: nextOr[0] } : nextOr[0]
  else children[path[0]] = negated ? { not: { or: nextOr } } : { or: nextOr }
  return { and: children }
}

export function toggleFilterNegation(tree: FilterTree, index: number): FilterTree {
  const children = topFilterChildren(tree).slice()
  const slot = children[index]
  if (!slot) return tree
  children[index] = filterSlotIsNegated(slot) && "not" in slot && slot.not ? slot.not : { not: slot }
  return { and: children }
}

export function filterMetaFor(schema: FilterSchemaField[], field: string) {
  return schema.find((candidate) => candidate.field === field) || null
}

export function defaultFilterChip(meta: FilterSchemaField): FilterChip {
  const op = meta.operators[0] || "is"
  return { field: meta.field, op, value: defaultFilterValue(meta, op) }
}

export function defaultFilterValue(meta: FilterSchemaField, op: string): unknown {
  if (isPredicateOp(op)) return null
  if (isMultiValueOp(op)) return []
  if (meta.bucket === "date") {
    if (op === "within_last" || op === "more_than_ago") return { n: 7, unit: "days" }
    if (op === "between") return ["", ""]
    return ""
  }
  if (meta.bucket === "number") return op === "between" ? [null, null] : null
  return filterOptions(meta)[0]?.value ?? ""
}

export function filterOptions(meta: FilterSchemaField): FilterOption[] {
  return normalizedOptions(meta)
}

export function filterChipLabel(chip: FilterChip, controls: FilterSchemaField[]) {
  return filterMetaFor(controls, chip.field)?.label || chip.field
}

export function formatFilterValue(
  chip: FilterChip,
  meta: FilterSchemaField | null,
  {
    unsetLabel = "(unset)",
    agoLabel = "ago",
    translateUnit = (u: string) => u
  }: { unsetLabel?: string; agoLabel?: string; translateUnit?: (unit: string) => string } = {}
) {
  if (chip.value === null || chip.value === undefined || chip.value === "") return unsetLabel
  if (Array.isArray(chip.value)) return chip.value.length > 0 ? chip.value.map((value) => labelForOption(value, meta)).join(", ") : unsetLabel
  if (isObjectValue(chip.value)) {
    if ("n" in chip.value && "unit" in chip.value) return `${chip.value.n} ${translateUnit(String(chip.value.unit || ""))}${chip.op === "more_than_ago" ? ` ${agoLabel}` : ""}`
    return JSON.stringify(chip.value)
  }
  return labelForOption(chip.value, meta)
}

export function useFormattedFilterValue(chip: FilterChip, meta: FilterSchemaField | null) {
  const { t } = useT("nav")
  const unsetLabel = t("filter_bar.unset")
  const agoLabel = t("filter_bar.ago")
  const translateUnit = (unit: string) => t(`filter_bar.time_unit.${unit}`, { defaultValue: unit })
  const fallback = formatFilterValue(chip, meta, { unsetLabel, agoLabel, translateUnit })
  const values = useMemo(() => filterValueList(chip.value), [chip.value])
  const [loadedOptions, setLoadedOptions] = useState<FilterOption[]>([])

  useEffect(() => {
    let cancelled = false

    setLoadedOptions([])
    if (!meta || !isFkFilterMeta(meta) || values.length === 0) return

    void loadFkOptions(meta.field, { ids: values }).then((options) => {
      if (!cancelled) setLoadedOptions(options)
    }).catch(() => {
      if (!cancelled) setLoadedOptions([])
    })

    return () => {
      cancelled = true
    }
  }, [meta?.field, values.join("\0")])

  if (!meta || !isFkFilterMeta(meta) || values.length === 0 || loadedOptions.length === 0) return fallback

  const loadedByValue = new Map(loadedOptions.map((option) => [String(option.value), option.label]))
  if (Array.isArray(chip.value)) {
    return chip.value.length > 0 ? chip.value.map((value) => loadedByValue.get(String(value)) || labelForOption(value, meta)).join(", ") : unsetLabel
  }

  return loadedByValue.get(String(chip.value)) || fallback
}

export function filterValueList(value: unknown) {
  if (Array.isArray(value)) return value.map(String).filter(Boolean)
  if (value === null || value === undefined || value === "") return []
  if (typeof value === "object") return []
  return [String(value)]
}

export function isFkFilterMeta(meta: FilterSchemaField) {
  return meta.bucket === "fk" || meta.typeahead === true
}

export function labelForOption(value: unknown, meta: FilterSchemaField | null) {
  if (!meta) return String(value)
  return filterOptions(meta).find((option) => String(option.value) === String(value))?.label || String(value)
}

export function isPredicateOp(op: string) {
  return ["is_set", "is_unset", "is_true", "is_false"].includes(op)
}

export function isMultiValueOp(op: string) {
  return ["is_one_of", "is_none_of", "contains_any", "contains_all", "contains_none"].includes(op)
}

export function isObjectValue(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value))
}

export function humanizeOp(op: string) {
  return op.replace(/_/g, " ")
}

export function translateOp(op: string, t: (key: string, opts?: Record<string, unknown>) => string): string {
  return t(`filter_bar.op.${op}`, { defaultValue: humanizeOp(op) })
}

export function translateBucket(bucket: string, t: (key: string, opts?: Record<string, unknown>) => string): string {
  return t(`filter_bar.bucket.${bucket}`, { defaultValue: bucket })
}

export function filterChipClass(negated: boolean) {
  return negated
    ? "inline-flex flex-wrap items-center gap-1 rounded border border-rose-300 bg-rose-50 px-1.5 py-1 text-sm dark:border-rose-800 dark:bg-rose-950"
    : "inline-flex flex-wrap items-center gap-1 rounded border border-gray-300 bg-gray-50 px-2 py-1 text-sm dark:border-gray-700 dark:bg-gray-800"
}

export function filterNotClass(negated: boolean) {
  return negated
    ? "inline-flex h-5 w-5 items-center justify-center rounded bg-rose-200 text-sm font-bold leading-none text-rose-900 dark:bg-rose-900 dark:text-rose-100"
    : "inline-flex h-5 w-5 items-center justify-center rounded border border-gray-300 text-sm font-bold leading-none text-gray-400 hover:border-rose-300 hover:bg-rose-50 hover:text-rose-700 dark:border-gray-600 dark:text-gray-500 dark:hover:border-rose-800 dark:hover:bg-rose-950 dark:hover:text-rose-200"
}

export function filterLabelClass() {
  return "block text-xs font-medium uppercase text-gray-500 dark:text-gray-400"
}

export function filterInputClass(extraClasses: string) {
  return `${extraClasses} border border-gray-300 bg-white text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100`
}

export function filterPlaceholder(meta: FilterSchemaField) {
  return typeof meta.expansions?.placeholder === "string" ? meta.expansions.placeholder : undefined
}

export function clearFiltersLink(path: string, search: string, legacyFilterKeys: string[], buildLink: FilterLinkBuilder) {
  const updates: FilterLinkUpdates = {
    q: null,
    smart_folder_id: null,
    page: null
  }
  for (const key of legacyFilterKeys) updates[key] = null

  return buildLink(path, search, updates)
}

export function linkFromSearch(path: string, search: string, updates: FilterLinkUpdates) {
  const params = new URLSearchParams(search)
  for (const [key, value] of Object.entries(updates)) {
    if (value == null || String(value).length === 0) {
      params.delete(key)
    } else {
      params.set(key, String(value))
    }
  }

  const query = params.toString()
  return query ? `${path}?${query}` : path
}

export function normalizedOptions(field: FilterSchemaField): FilterOption[] {
  return (field.values || []).map((option) => {
    if (typeof option === "string") return { value: option, label: humanizeOption(option) }
    return option
  })
}

export function humanizeOption(value: string) {
  return value.replace(/_/g, " ").replace(/^\w/, (match) => match.toUpperCase())
}

export async function loadFkOptions(field: string, { q, ids }: { q?: string; ids?: string[] }): Promise<FilterOption[]> {
  const params = new URLSearchParams({ field })
  if (q) params.set("q", q)
  for (const id of ids || []) params.append("ids[]", id)

  const response = await fetch(`/api/v1/app/filters/fk_options?${params}`, {
    credentials: "same-origin",
    headers: { Accept: "application/json" }
  })

  if (!response.ok) throw new Error(`Failed to load filter options: ${response.status}`)

  const payload = await response.json() as { options?: FilterOption[] }
  return payload.options || []
}

export async function loadFilterSuggestions(config: FilterSuggestionSearchConfig, q: string, activeQ: string, signal: AbortSignal): Promise<FilterSuggestion[]> {
  const params = new URLSearchParams({
    surface: config.surface,
    subject: config.subject,
    q
  })
  if (activeQ) params.set("active_q", activeQ)

  const response = await fetch(`/api/v1/app/filters/suggestions?${params}`, {
    credentials: "same-origin",
    headers: { Accept: "application/json" },
    signal
  })

  if (!response.ok) throw new Error(`Failed to load filter suggestions: ${response.status}`)

  const payload = await response.json() as { suggestions?: FilterSuggestion[] }
  return payload.suggestions || []
}
