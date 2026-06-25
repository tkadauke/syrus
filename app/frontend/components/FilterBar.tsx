import type { RefObject } from "react"
import { useEffect, useMemo, useRef, useState } from "react"
import { Link, useNavigate } from "react-router-dom"
import { CloseIcon } from "./CloseIcon"

export type FilterOption = {
  value: string | number
  label: string
}

export type FilterSchemaField = {
  field: string
  label: string
  bucket: string
  operators: string[]
  values?: Array<FilterOption | string>
  typeahead?: boolean
  expansions?: Record<string, unknown>
}

export type FilterSuggestion = {
  id: number | string
  label: string
  filter: Record<string, unknown>
  source?: string
  use_count?: number
  last_used_at?: string | null
}

export type FilterChip = {
  field: string
  op: string
  value?: unknown
}

export type FilterGroup = {
  and?: FilterNode[]
  or?: FilterNode[]
  not?: FilterNode
}

export type FilterNode = FilterChip | FilterGroup
export type FilterTree = FilterGroup

type FilterPath = number[]
type FilterLinkUpdates = Record<string, string | number | null | undefined>
type FilterSuggestionSearchConfig = {
  surface: string
  subject: string
}

export type FilterLinkBuilder = (path: string, search: string, updates: FilterLinkUpdates) => string

export function FilterBar({
  filter,
  filterSchema,
  pathname,
  search,
  legacyFilterKeys = [],
  className = "space-y-2",
  suggestions = [],
  suggestionSearch,
  onFilterApplied,
  buildLink = linkFromSearch
}: {
  filter?: Record<string, unknown> | null
  filterSchema: FilterSchemaField[]
  suggestions?: FilterSuggestion[]
  suggestionSearch?: FilterSuggestionSearchConfig
  onFilterApplied?: (tree: FilterTree) => void
  pathname: string
  search: string
  legacyFilterKeys?: string[]
  className?: string
  buildLink?: FilterLinkBuilder
}) {
  const navigate = useNavigate()
  const [draftTree, setDraftTree] = useState<FilterTree>(() => filterTreeFromPayload(filter))
  const [editingPath, setEditingPath] = useState<FilterPath | null>(null)
  const [addMenuOpen, setAddMenuOpen] = useState(false)
  const [addAlternativePath, setAddAlternativePath] = useState<FilterPath | null>(null)
  const [addQuery, setAddQuery] = useState("")
  const addMenuRef = useRef<HTMLDivElement | null>(null)
  const editorRef = useRef<HTMLDivElement>(null)
  const params = new URLSearchParams(search)
  const appliedTree = useMemo(() => filterTreeFromPayload(filter), [filter])
  const draftChildren = topFilterChildren(draftTree)
  const activeSuggestionQ = useMemo(() => topFilterChildren(appliedTree).length > 0 ? encodeFilterTree(appliedTree) : "", [appliedTree])
  const [searchedSuggestions, setSearchedSuggestions] = useState<FilterSuggestion[]>([])
  const hasFilters = draftChildren.length > 0 || params.has("q") || params.has("smart_folder_id") || legacyFilterKeys.some((key) => params.has(key))
  const suggestionQuery = addQuery.trim()
  const usesRemoteSuggestions = Boolean(suggestionSearch && addMenuOpen && !addAlternativePath && suggestionQuery.length >= 2)
  const activeSuggestions = usesRemoteSuggestions ? searchedSuggestions : suggestions
  const filteredSchema = filterSchema.filter((field) => {
    const query = addQuery.trim().toLowerCase()
    return !query || field.field.toLowerCase().includes(query) || field.label.toLowerCase().includes(query)
  })
  const filteredSuggestions = activeSuggestions.filter((suggestion) => {
    const query = addQuery.trim().toLowerCase()
    return !addAlternativePath && (!query || suggestion.label.toLowerCase().includes(query))
  })
  const editingChip = editingPath ? filterNodeAtPath(draftTree, editingPath) : null
  const editingMeta = editingChip && "field" in editingChip ? filterMetaFor(filterSchema, editingChip.field) : null

  useEffect(() => {
    setDraftTree(appliedTree)
    setEditingPath((path) => path && filterNodeAtPath(appliedTree, path) ? path : null)
    setAddMenuOpen(false)
    setAddAlternativePath(null)
    setAddQuery("")
  }, [appliedTree])

  useEffect(() => {
    if (!addMenuOpen) return

    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") {
        setAddMenuOpen(false)
        setAddAlternativePath(null)
      }
    }

    function closeOnOutsidePointer(event: PointerEvent) {
      const target = event.target
      if (target instanceof Node && addMenuRef.current?.contains(target)) return

      setAddMenuOpen(false)
      setAddAlternativePath(null)
    }

    window.addEventListener("keydown", closeOnEscape)
    window.addEventListener("pointerdown", closeOnOutsidePointer)
    return () => {
      window.removeEventListener("keydown", closeOnEscape)
      window.removeEventListener("pointerdown", closeOnOutsidePointer)
    }
  }, [addMenuOpen])

  useEffect(() => {
    if (!usesRemoteSuggestions || !suggestionSearch) {
      setSearchedSuggestions([])
      return
    }

    let cancelled = false
    const controller = new AbortController()

    void loadFilterSuggestions(suggestionSearch, suggestionQuery, activeSuggestionQ, controller.signal).then((loadedSuggestions) => {
      if (!cancelled) setSearchedSuggestions(loadedSuggestions)
    }).catch((error: unknown) => {
      if (!cancelled && !(error instanceof DOMException && error.name === "AbortError")) {
        setSearchedSuggestions([])
      }
    })

    return () => {
      cancelled = true
      controller.abort()
    }
  }, [activeSuggestionQ, suggestionQuery, suggestionSearch?.subject, suggestionSearch?.surface, usesRemoteSuggestions])

  useEffect(() => {
    if (!editingPath) return

    function closeOnEscape(event: KeyboardEvent) {
      if (event.key === "Escape") setEditingPath(null)
    }

    function closeOnOutsidePointer(event: PointerEvent) {
      const target = event.target
      if (target instanceof Node && editorRef.current?.contains(target)) return

      setEditingPath(null)
    }

    window.addEventListener("keydown", closeOnEscape)
    window.addEventListener("pointerdown", closeOnOutsidePointer)
    return () => {
      window.removeEventListener("keydown", closeOnEscape)
      window.removeEventListener("pointerdown", closeOnOutsidePointer)
    }
  }, [editingPath])

  if (filterSchema.length === 0) return null

  function updateTree(nextTree: FilterTree, nextEditingPath = editingPath) {
    setDraftTree(normalizedFilterTree(nextTree))
    setEditingPath(nextEditingPath)
  }

  function applyTree(tree = draftTree) {
    const normalized = normalizedFilterTree(tree)
    const nextQ = topFilterChildren(normalized).length > 0 ? encodeFilterTree(normalized) : null
    const updates: FilterLinkUpdates = {
      q: nextQ,
      page: null,
      smart_folder_id: null
    }
    for (const key of legacyFilterKeys) updates[key] = null

    navigate(buildLink(pathname, search, updates))
    if (nextQ) onFilterApplied?.(normalized)
  }

  function openAddMenu() {
    setEditingPath(null)
    setAddAlternativePath(null)
    setAddMenuOpen(true)
    setAddQuery("")
  }

  function openOrAlternativeMenu(path: FilterPath) {
    setEditingPath(null)
    setAddAlternativePath(path)
    setAddMenuOpen(true)
    setAddQuery("")
  }

  function addFilter(meta: FilterSchemaField) {
    if (addAlternativePath) {
      addOrAlternative(addAlternativePath, meta)
      return
    }

    const chip = defaultFilterChip(meta)
    const children = topFilterChildren(draftTree).slice()
    const nextPath: FilterPath = [children.length]

    children.push(chip)

    const nextTree = { and: children }
    updateTree(nextTree, nextPath)
    setAddMenuOpen(false)
    setAddAlternativePath(null)
    applyTree(nextTree)
  }

  function addSuggestedFilter(suggestion: FilterSuggestion) {
    const node = suggestionFilterNode(suggestion)
    if (!node) return

    const children = topFilterChildren(draftTree).slice()
    children.push(node)

    const nextTree = { and: children }
    updateTree(nextTree, null)
    setAddMenuOpen(false)
    setAddAlternativePath(null)
    applyTree(nextTree)
  }

  function addOrAlternative(path: FilterPath, meta: FilterSchemaField) {
    const children = topFilterChildren(draftTree).slice()
    const index = path[0]
    const slot = children[index]
    const negated = filterSlotIsNegated(slot)
    const inner = filterSlotInner(slot)
    const currentOr = inner && "or" in inner && Array.isArray(inner.or) ? inner.or : [inner].filter(Boolean) as FilterNode[]
    const nextOr = [...currentOr, defaultFilterChip(meta)]
    const nextPath: FilterPath = [index, nextOr.length - 1]

    children[index] = negated ? { not: { or: nextOr } } : { or: nextOr }

    const nextTree = { and: children }
    updateTree(nextTree, nextPath)
    setAddMenuOpen(false)
    setAddAlternativePath(null)
    applyTree(nextTree)
  }

  function editChip(path: FilterPath, nextChip: FilterChip) {
    const nextTree = replaceFilterNodeAtPath(draftTree, path, nextChip)
    updateTree(nextTree, path)
    applyTree(nextTree)
  }

  function removeChip(path: FilterPath) {
    const nextTree = removeFilterNodeAtPath(draftTree, path)
    updateTree(nextTree, null)
    applyTree(nextTree)
  }

  function toggleNegation(index: number) {
    const nextTree = toggleFilterNegation(draftTree, index)
    updateTree(nextTree, null)
    applyTree(nextTree)
  }

  return (
    <div className={className}>
      <div className="relative flex flex-wrap items-center gap-2">
        {draftChildren.map((node, index) => (
          <FilterNodeChip
            controls={filterSchema}
            index={index}
            key={index}
            node={node}
            onEdit={setEditingPath}
            onRemove={removeChip}
            onToggleNegation={toggleNegation}
          />
        ))}
        {draftChildren.length > 0 ? null : <span className="text-sm text-gray-400 dark:text-gray-500">No filters</span>}
        <button
          className="inline-flex items-center gap-1 rounded border border-dashed border-gray-300 px-2 py-1.5 text-sm text-gray-600 hover:border-gray-400 hover:text-gray-900 dark:border-gray-700 dark:text-gray-300 dark:hover:border-gray-500 dark:hover:text-white"
          onClick={() => openAddMenu()}
          type="button"
        >
          + Add filter
        </button>
        {hasFilters ? (
          <Link className="text-sm text-gray-500 underline hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200" to={clearFiltersLink(pathname, search, legacyFilterKeys, buildLink)}>
            Clear filters
          </Link>
        ) : null}
        {addMenuOpen ? (
          <div className="absolute left-0 top-full z-20 mt-1 w-72 rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-900" ref={addMenuRef}>
            <input
              autoFocus
              className="block w-full rounded-t border-b border-gray-200 bg-white px-3 py-2 text-sm text-gray-900 focus:outline-none dark:border-gray-700 dark:bg-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500"
              onChange={(event) => setAddQuery(event.target.value)}
              placeholder="Search filters..."
              type="search"
              value={addQuery}
            />
            <div className="max-h-72 overflow-y-auto py-1">
              {filteredSuggestions.length > 0 ? (
                <div className="border-b border-gray-100 pb-1 dark:border-gray-800">
                  <div className="px-3 py-1.5 text-xs font-semibold uppercase text-gray-400 dark:text-gray-500">Suggested</div>
                  {filteredSuggestions.map((suggestion) => (
                    <button
                      className="block w-full px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
                      key={suggestion.id}
                      onClick={() => addSuggestedFilter(suggestion)}
                      type="button"
                    >
                      {suggestion.label}
                    </button>
                  ))}
                </div>
              ) : null}
              {filteredSchema.map((field) => (
                <button
                  aria-label={`${field.label} ${field.bucket}`}
                  className="flex w-full items-center justify-between gap-2 px-3 py-2 text-left text-sm text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
                  key={field.field}
                  onClick={() => addFilter(field)}
                  type="button"
                >
                  <span>{field.label}</span>
                  <span className="text-xs text-gray-400 dark:text-gray-500">{field.bucket}</span>
                </button>
              ))}
              {filteredSchema.length === 0 && filteredSuggestions.length === 0 ? <div className="px-3 py-2 text-sm text-gray-400 dark:text-gray-500">No matching filters</div> : null}
            </div>
          </div>
        ) : null}

        {editingChip && editingMeta && "field" in editingChip ? (
          <FilterChipEditor
            chip={editingChip}
            editorRef={editorRef}
            meta={editingMeta}
            onAddAlternative={() => openOrAlternativeMenu(editingPath!)}
            onChange={(nextChip) => editChip(editingPath!, nextChip)}
          />
        ) : null}
      </div>
    </div>
  )
}

function FilterNodeChip({
  node,
  index,
  controls,
  onEdit,
  onRemove,
  onToggleNegation
}: {
  node: FilterNode
  index: number
  controls: FilterSchemaField[]
  onEdit: (path: FilterPath) => void
  onRemove: (path: FilterPath) => void
  onToggleNegation: (index: number) => void
}) {
  const negated = filterSlotIsNegated(node)
  const inner = filterSlotInner(node)
  if (isFilterChip(inner)) {
    return (
      <span className={filterChipClass(negated)}>
        <button aria-label={negated ? "Remove NOT" : "Wrap in NOT"} className={filterNotClass(negated)} onClick={() => onToggleNegation(index)} title={negated ? "Remove NOT" : "Wrap in NOT"} type="button">¬</button>
        <FilterChipButton chip={inner} controls={controls} negated={negated} onClick={() => onEdit([index])} />
        <button aria-label={`Remove ${filterChipLabel(inner, controls)} filter`} className="inline-flex h-5 w-5 items-center justify-center rounded text-gray-400 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-500 dark:hover:bg-gray-800 dark:hover:text-gray-200" onClick={() => onRemove([index])} type="button">
          <CloseIcon className="h-3.5 w-3.5" />
        </button>
      </span>
    )
  }

  if (inner && "or" in inner && Array.isArray(inner.or)) {
    return (
      <span className={negated ? "inline-flex flex-wrap items-center gap-1 rounded border border-rose-300 bg-rose-50 px-1.5 py-0.5 text-sm dark:border-rose-800 dark:bg-rose-950" : "inline-flex flex-wrap items-center gap-1 rounded border border-indigo-300 bg-indigo-50 px-1.5 py-0.5 text-sm dark:border-indigo-800 dark:bg-indigo-950"}>
        <button aria-label={negated ? "Remove NOT" : "Wrap in NOT"} className={filterNotClass(negated)} onClick={() => onToggleNegation(index)} title={negated ? "Remove NOT" : "Wrap in NOT"} type="button">¬</button>
        <span className={negated ? "text-xs font-semibold text-rose-700 dark:text-rose-200" : "text-xs font-semibold text-indigo-700 dark:text-indigo-200"}>(</span>
        {inner.or.map((child, childIndex) => (
          <span className="inline-flex items-center gap-1" key={childIndex}>
            {childIndex > 0 ? <span className="text-xs font-semibold uppercase text-indigo-500 dark:text-indigo-300">or</span> : null}
            {isFilterChip(child) ? (
              <span className="inline-flex items-center gap-1 rounded border border-gray-300 bg-gray-50 px-2 py-1 dark:border-gray-700 dark:bg-gray-800">
                <FilterChipButton chip={child} controls={controls} onClick={() => onEdit([index, childIndex])} />
                <button aria-label={`Remove ${filterChipLabel(child, controls)} filter`} className="inline-flex h-5 w-5 items-center justify-center rounded text-gray-400 hover:bg-gray-100 hover:text-gray-700 dark:text-gray-500 dark:hover:bg-gray-700 dark:hover:text-gray-200" onClick={() => onRemove([index, childIndex])} type="button">
                  <CloseIcon className="h-3.5 w-3.5" />
                </button>
              </span>
            ) : (
              <span className="rounded border border-amber-300 bg-amber-50 px-2 py-1 text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">complex filter</span>
            )}
          </span>
        ))}
        <span className={negated ? "text-xs font-semibold text-rose-700 dark:text-rose-200" : "text-xs font-semibold text-indigo-700 dark:text-indigo-200"}>)</span>
      </span>
    )
  }

  return <span className="rounded border border-amber-300 bg-amber-50 px-2 py-1 text-sm text-amber-800 dark:border-amber-800 dark:bg-amber-950 dark:text-amber-200">complex filter</span>
}

function FilterChipButton({ chip, controls, negated = false, onClick }: { chip: FilterChip; controls: FilterSchemaField[]; negated?: boolean; onClick: () => void }) {
  const meta = filterMetaFor(controls, chip.field)
  const formattedValue = useFormattedFilterValue(chip, meta)
  const label = `${negated ? "NOT " : ""}${meta?.label || chip.field} ${humanizeOp(chip.op)}${isPredicateOp(chip.op) ? "" : ` ${formattedValue}`}`
  return (
    <button aria-label={label} className="inline-flex items-baseline gap-1 text-left" onClick={onClick} type="button">
      <span className="font-medium text-gray-700 dark:text-gray-200">{meta?.label || chip.field}</span>
      <span className="text-xs text-gray-500 dark:text-gray-400">{humanizeOp(chip.op)}</span>
      {isPredicateOp(chip.op) ? null : <span className="font-mono text-gray-900 dark:text-white">{formattedValue}</span>}
    </button>
  )
}

function FilterChipEditor({ chip, editorRef, meta, onAddAlternative, onChange }: { chip: FilterChip; editorRef: RefObject<HTMLDivElement>; meta: FilterSchemaField; onAddAlternative: () => void; onChange: (chip: FilterChip) => void }) {
  function updateOp(op: string) {
    onChange({ field: chip.field, op, value: defaultFilterValue(meta, op) })
  }

  return (
    <div aria-label={`${meta.label} filter settings`} className="absolute left-0 top-full z-30 mt-2 w-[min(36rem,calc(100vw-3rem))] space-y-3 rounded border border-gray-200 bg-white p-3 shadow-lg dark:border-gray-700 dark:bg-gray-900" ref={editorRef} role="dialog">
      <div className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{meta.label}</div>
      <div className="space-y-3">
        <label className={filterLabelClass()} htmlFor={`filter-op-${meta.field}`}>
          Operator
          <select className={filterInputClass("mt-1 block rounded px-2 py-1.5")} id={`filter-op-${meta.field}`} onChange={(event) => updateOp(event.target.value)} value={chip.op}>
            {meta.operators.map((op) => <option key={op} value={op}>{humanizeOp(op)}</option>)}
          </select>
        </label>
        <FilterValueEditor chip={chip} meta={meta} onChange={onChange} />
      </div>
      <button className="rounded border border-dashed border-indigo-300 px-2 py-1 text-sm font-medium text-indigo-700 hover:bg-indigo-50 dark:border-indigo-800 dark:text-indigo-200 dark:hover:bg-indigo-950" onClick={onAddAlternative} type="button">
        + OR alternative
      </button>
    </div>
  )
}

function FilterValueEditor({ chip, meta, onChange }: { chip: FilterChip; meta: FilterSchemaField; onChange: (chip: FilterChip) => void }) {
  if (isPredicateOp(chip.op)) return null

  const options = filterOptions(meta)
  const multi = isMultiValueOp(chip.op)
  if (meta.bucket === "fk" || meta.typeahead) return <TypeaheadFilterValueEditor chip={chip} meta={meta} multi={multi} onChange={onChange} />

  if (options.length > 0 && !meta.typeahead) {
    if (multi) return <MultiFilterValueEditor chip={chip} meta={meta} onChange={onChange} options={options} />

    const selected = multi ? Array.isArray(chip.value) ? chip.value.map(String) : [] : [String(chip.value ?? "")]
    return (
      <label className={filterLabelClass()} htmlFor={`filter-value-${meta.field}`}>
        Value
        <select
          className={filterInputClass("mt-1 block min-w-44 rounded px-2 py-1.5")}
          id={`filter-value-${meta.field}`}
          onChange={(event) => {
            onChange({ ...chip, value: event.target.value })
          }}
          value={selected[0]}
        >
          {options.map((option) => <option key={String(option.value)} value={String(option.value)}>{option.label}</option>)}
        </select>
      </label>
    )
  }

  if (meta.bucket === "date") return <DateFilterValueEditor chip={chip} onChange={onChange} />
  if (meta.bucket === "number") return <NumberFilterValueEditor chip={chip} onChange={onChange} />

  return <TextFilterValueEditor chip={chip} onChange={onChange} />
}

function TextFilterValueEditor({ chip, onChange }: { chip: FilterChip; onChange: (chip: FilterChip) => void }) {
  const [localValue, setLocalValue] = useState(String(chip.value ?? ""))

  useEffect(() => {
    setLocalValue(String(chip.value ?? ""))
  }, [chip.value])

  function commit() {
    if (localValue !== String(chip.value ?? "")) onChange({ ...chip, value: localValue })
  }

  return (
    <label className={filterLabelClass()} htmlFor={`filter-value-${chip.field}`}>
      Value
      <input
        className={filterInputClass("mt-1 block w-56 rounded px-2 py-1.5")}
        id={`filter-value-${chip.field}`}
        onBlur={commit}
        onChange={(event) => setLocalValue(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Enter") commit()
        }}
        type="text"
        value={localValue}
      />
    </label>
  )
}

function TypeaheadFilterValueEditor({ chip, meta, multi, onChange }: { chip: FilterChip; meta: FilterSchemaField; multi: boolean; onChange: (chip: FilterChip) => void }) {
  const [query, setQuery] = useState("")
  const [selectedOptions, setSelectedOptions] = useState<FilterOption[]>([])
  const [options, setOptions] = useState<FilterOption[]>([])
  const inputRef = useRef<HTMLInputElement>(null)
  const selected = multi ? Array.isArray(chip.value) ? chip.value.map(String) : [] : String(chip.value ?? "") ? [String(chip.value)] : []
  const selectedSet = new Set(selected)

  useEffect(() => {
    let cancelled = false

    if (selected.length === 0) {
      setSelectedOptions([])
      return
    }

    void loadFkOptions(meta.field, { ids: selected }).then((loadedOptions) => {
      if (!cancelled) setSelectedOptions(loadedOptions)
    }).catch(() => {
      if (!cancelled) setSelectedOptions(selected.map((value) => ({ value, label: value })))
    })

    return () => {
      cancelled = true
    }
  }, [meta.field, selected.join("\0")])

  useEffect(() => {
    let cancelled = false
    const trimmedQuery = query.trim()

    if (!trimmedQuery) {
      setOptions([])
      return
    }

    void loadFkOptions(meta.field, { q: trimmedQuery }).then((loadedOptions) => {
      if (!cancelled) setOptions(loadedOptions.filter((option) => !selectedSet.has(String(option.value))))
    }).catch(() => {
      if (!cancelled) setOptions([])
    })

    return () => {
      cancelled = true
    }
  }, [meta.field, query, selected.join("\0")])

  function addValue(value: string) {
    if (multi) {
      if (selectedSet.has(value)) return
      onChange({ ...chip, value: [...selected, value] })
    } else {
      onChange({ ...chip, value })
    }
    setQuery("")
    setOptions([])
  }

  function removeValue(value: string) {
    if (multi) {
      onChange({ ...chip, value: selected.filter((selectedValue) => selectedValue !== value) })
    } else {
      onChange({ ...chip, value: "" })
    }
  }

  return (
    <div className={filterLabelClass()}>
      <label htmlFor={`filter-value-${meta.field}-search`}>Value</label>
      <div className="relative mt-1 normal-case text-gray-700 dark:text-gray-200">
        <div className="flex max-h-[10rem] min-h-11 w-full flex-wrap items-center gap-1.5 overflow-y-auto rounded border border-gray-300 bg-white px-2 py-2 text-sm dark:border-gray-700 dark:bg-gray-950" onClick={() => inputRef.current?.focus()}>
          {selected.length > 0 ? (
            selected.map((value) => {
              const option = selectedOptions.find((candidate) => String(candidate.value) === value) || { value, label: value }
              return (
                <span className="inline-flex items-center gap-1 rounded bg-indigo-100 px-2 py-0.5 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-200" key={value}>
                  {option.label}
                  <button aria-label={`Remove ${option.label}`} className="inline-flex h-4 w-4 items-center justify-center rounded text-indigo-500 hover:bg-indigo-200 hover:text-indigo-800 dark:text-indigo-300 dark:hover:bg-indigo-900 dark:hover:text-indigo-100" onClick={() => removeValue(value)} type="button">
                    <CloseIcon className="h-3 w-3" />
                  </button>
                </span>
              )
            })
          ) : null}
          <input
            className="min-w-32 flex-1 border-0 bg-transparent p-0 text-sm text-gray-900 focus:outline-none dark:text-gray-100 dark:placeholder:text-gray-500"
            id={`filter-value-${meta.field}-search`}
            onChange={(event) => setQuery(event.target.value)}
            placeholder="Search by name..."
            ref={inputRef}
            type="text"
            value={query}
          />
        </div>
        {query.trim() ? (
          <div className="absolute left-0 right-0 top-full z-10 mt-1 max-h-56 overflow-y-auto rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900">
            {options.length > 0 ? (
              options.map((option) => (
                <button
                  className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
                  key={String(option.value)}
                  onClick={() => addValue(String(option.value))}
                  type="button"
                >
                  {option.label}
                </button>
              ))
            ) : (
              <div className="px-3 py-1.5 text-sm text-gray-400 dark:text-gray-500">No matches</div>
            )}
          </div>
        ) : null}
      </div>
    </div>
  )
}

function MultiFilterValueEditor({ chip, meta, onChange, options }: { chip: FilterChip; meta: FilterSchemaField; onChange: (chip: FilterChip) => void; options: FilterOption[] }) {
  const [query, setQuery] = useState("")
  const selected = Array.isArray(chip.value) ? chip.value.map(String) : []
  const selectedSet = new Set(selected)
  const selectedOptions = selected.map((value) => options.find((option) => String(option.value) === value) || { value, label: value })
  const filteredOptions = options.filter((option) => {
    const unselected = !selectedSet.has(String(option.value))
    const matches = option.label.toLowerCase().includes(query.trim().toLowerCase())
    return unselected && matches
  })

  function addValue(value: string) {
    if (selectedSet.has(value)) return

    onChange({ ...chip, value: [...selected, value] })
    setQuery("")
  }

  function removeValue(value: string) {
    onChange({ ...chip, value: selected.filter((selectedValue) => selectedValue !== value) })
  }

  return (
    <label className={filterLabelClass()} htmlFor={`filter-value-${meta.field}-search`}>
      <span className="sr-only">Value</span>
      <div className="mt-1 w-72 overflow-hidden rounded border border-gray-300 bg-white normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-200">
        <div className="flex min-h-11 flex-wrap items-center gap-1.5 px-2 py-2 text-sm">
          {selectedOptions.length > 0 ? (
            selectedOptions.map((option) => (
              <span className="inline-flex items-center gap-1 rounded bg-indigo-100 px-2 py-0.5 text-indigo-800 dark:bg-indigo-950 dark:text-indigo-200" key={String(option.value)}>
                {option.label}
                <button aria-label={`Remove ${option.label}`} className="inline-flex h-4 w-4 items-center justify-center rounded text-indigo-500 hover:bg-indigo-200 hover:text-indigo-800 dark:text-indigo-300 dark:hover:bg-indigo-900 dark:hover:text-indigo-100" onClick={() => removeValue(String(option.value))} type="button">
                  <CloseIcon className="h-3 w-3" />
                </button>
              </span>
            ))
          ) : (
            <span className="text-gray-400 dark:text-gray-500">Nothing selected yet</span>
          )}
        </div>
        <input
          className="block w-full border-t border-gray-200 bg-white px-2 py-2 text-sm text-gray-900 focus:outline-none dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100 dark:placeholder:text-gray-500"
          id={`filter-value-${meta.field}-search`}
          onChange={(event) => setQuery(event.target.value)}
          placeholder="Search..."
          type="search"
          value={query}
        />
        <div className="max-h-56 overflow-y-auto border-t border-gray-200 py-1 dark:border-gray-700">
          {filteredOptions.map((option) => (
            <button
              className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
              key={String(option.value)}
              onClick={() => addValue(String(option.value))}
              type="button"
            >
              {option.label}
            </button>
          ))}
          {filteredOptions.length === 0 ? <div className="px-3 py-1.5 text-sm text-gray-400 dark:text-gray-500">No matches</div> : null}
        </div>
      </div>
    </label>
  )
}

function DateFilterValueEditor({ chip, onChange }: { chip: FilterChip; onChange: (chip: FilterChip) => void }) {
  if (chip.op === "within_last" || chip.op === "more_than_ago") {
    const value = isObjectValue(chip.value) ? chip.value : { n: 7, unit: "days" }
    return (
      <div className="flex items-end gap-2">
        <label className={filterLabelClass()} htmlFor="filter-date-amount">
          Amount
          <input className={filterInputClass("mt-1 block w-20 rounded px-2 py-1.5")} id="filter-date-amount" min="0" onChange={(event) => onChange({ ...chip, value: { ...value, n: Number(event.target.value || 0) } })} type="number" value={Number(value.n || 0)} />
        </label>
        <label className={filterLabelClass()} htmlFor="filter-date-unit">
          Unit
          <select className={filterInputClass("mt-1 block rounded px-2 py-1.5")} id="filter-date-unit" onChange={(event) => onChange({ ...chip, value: { ...value, unit: event.target.value } })} value={String(value.unit || "days")}>
            {["minutes", "hours", "days", "weeks", "months"].map((unit) => <option key={unit} value={unit}>{unit}</option>)}
          </select>
        </label>
      </div>
    )
  }

  if (chip.op === "between") {
    const value = Array.isArray(chip.value) ? chip.value : ["", ""]
    return (
      <div className="flex items-end gap-2">
        <label className={filterLabelClass()} htmlFor="filter-date-from">
          From
          <input className={filterInputClass("mt-1 block rounded px-2 py-1.5")} id="filter-date-from" onChange={(event) => onChange({ ...chip, value: [event.target.value, value[1] || ""] })} type="date" value={String(value[0] || "").slice(0, 10)} />
        </label>
        <label className={filterLabelClass()} htmlFor="filter-date-to">
          To
          <input className={filterInputClass("mt-1 block rounded px-2 py-1.5")} id="filter-date-to" onChange={(event) => onChange({ ...chip, value: [value[0] || "", event.target.value] })} type="date" value={String(value[1] || "").slice(0, 10)} />
        </label>
      </div>
    )
  }

  return (
    <label className={filterLabelClass()} htmlFor="filter-date-value">
      Value
      <input className={filterInputClass("mt-1 block rounded px-2 py-1.5")} id="filter-date-value" onChange={(event) => onChange({ ...chip, value: event.target.value })} type="date" value={String(chip.value || "").slice(0, 10)} />
    </label>
  )
}

function NumberFilterValueEditor({ chip, onChange }: { chip: FilterChip; onChange: (chip: FilterChip) => void }) {
  if (chip.op === "between") {
    const value = Array.isArray(chip.value) ? chip.value : [null, null]
    return (
      <div className="flex items-end gap-2">
        <label className={filterLabelClass()} htmlFor="filter-number-min">
          Min
          <input className={filterInputClass("mt-1 block w-28 rounded px-2 py-1.5")} id="filter-number-min" onChange={(event) => onChange({ ...chip, value: [event.target.value === "" ? null : Number(event.target.value), value[1] ?? null] })} type="number" value={typeof value[0] === "number" ? value[0] : ""} />
        </label>
        <label className={filterLabelClass()} htmlFor="filter-number-max">
          Max
          <input className={filterInputClass("mt-1 block w-28 rounded px-2 py-1.5")} id="filter-number-max" onChange={(event) => onChange({ ...chip, value: [value[0] ?? null, event.target.value === "" ? null : Number(event.target.value)] })} type="number" value={typeof value[1] === "number" ? value[1] : ""} />
        </label>
      </div>
    )
  }

  return (
    <label className={filterLabelClass()} htmlFor="filter-number-value">
      Value
      <input className={filterInputClass("mt-1 block w-32 rounded px-2 py-1.5")} id="filter-number-value" onChange={(event) => onChange({ ...chip, value: event.target.value === "" ? null : Number(event.target.value) })} type="number" value={typeof chip.value === "number" ? chip.value : ""} />
    </label>
  )
}

export function smartFolderFiltersFromTree(tree: FilterTree) {
  const normalized = normalizedFilterTree(tree)
  const filters: Record<string, string> = {}
  if (topFilterChildren(normalized).length > 0) filters.filter = JSON.stringify(normalized)
  return filters
}

export function filterTreeFromPayload(filter: Record<string, unknown> | null | undefined): FilterTree {
  return normalizedFilterTree(filter && typeof filter === "object" ? filter as FilterTree : null)
}

function encodeFilterTree(tree: FilterTree) {
  const json = JSON.stringify(normalizedFilterTree(tree))
  return btoa(unescape(encodeURIComponent(json))).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "")
}

function normalizedFilterTree(tree: FilterTree | null): FilterTree {
  const children = topFilterChildren(tree).filter(Boolean)
  return { and: children }
}

export function topFilterChildren(tree: FilterTree | FilterNode | null): FilterNode[] {
  if (!tree || typeof tree !== "object") return []
  if ("and" in tree && Array.isArray(tree.and)) return tree.and
  if (isFilterChip(tree) || ("or" in tree && Array.isArray(tree.or)) || ("not" in tree && tree.not)) return [tree as FilterNode]
  return []
}

function suggestionFilterNode(suggestion: FilterSuggestion): FilterNode | null {
  return topFilterChildren(suggestion.filter as FilterNode)[0] || null
}

function isFilterChip(node: unknown): node is FilterChip {
  return Boolean(node && typeof node === "object" && "field" in node && typeof (node as FilterChip).field === "string")
}

function filterSlotInner(node: FilterNode | undefined): FilterNode | undefined {
  if (node && "not" in node && node.not) return node.not
  return node
}

function filterSlotIsNegated(node: FilterNode | undefined) {
  return Boolean(node && "not" in node && node.not)
}

function filterNodeAtPath(tree: FilterTree, path: FilterPath): FilterNode | null {
  const slot = topFilterChildren(tree)[path[0]]
  const inner = filterSlotInner(slot)
  if (path.length === 1) return inner || null
  if (!inner || !("or" in inner) || !Array.isArray(inner.or)) return null
  return inner.or[path[1]] || null
}

function replaceFilterNodeAtPath(tree: FilterTree, path: FilterPath, node: FilterNode): FilterTree {
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

function removeFilterNodeAtPath(tree: FilterTree, path: FilterPath): FilterTree {
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

function toggleFilterNegation(tree: FilterTree, index: number): FilterTree {
  const children = topFilterChildren(tree).slice()
  const slot = children[index]
  if (!slot) return tree
  children[index] = filterSlotIsNegated(slot) && "not" in slot && slot.not ? slot.not : { not: slot }
  return { and: children }
}

function filterMetaFor(schema: FilterSchemaField[], field: string) {
  return schema.find((candidate) => candidate.field === field) || null
}

function defaultFilterChip(meta: FilterSchemaField): FilterChip {
  const op = meta.operators[0] || "is"
  return { field: meta.field, op, value: defaultFilterValue(meta, op) }
}

function defaultFilterValue(meta: FilterSchemaField, op: string): unknown {
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

function filterOptions(meta: FilterSchemaField): FilterOption[] {
  return normalizedOptions(meta)
}

function filterChipLabel(chip: FilterChip, controls: FilterSchemaField[]) {
  return filterMetaFor(controls, chip.field)?.label || chip.field
}

function formatFilterValue(chip: FilterChip, meta: FilterSchemaField | null) {
  if (chip.value === null || chip.value === undefined || chip.value === "") return "(unset)"
  if (Array.isArray(chip.value)) return chip.value.length > 0 ? chip.value.map((value) => labelForOption(value, meta)).join(", ") : "(unset)"
  if (isObjectValue(chip.value)) {
    if ("n" in chip.value && "unit" in chip.value) return `${chip.value.n} ${chip.value.unit}${chip.op === "more_than_ago" ? " ago" : ""}`
    return JSON.stringify(chip.value)
  }
  return labelForOption(chip.value, meta)
}

function useFormattedFilterValue(chip: FilterChip, meta: FilterSchemaField | null) {
  const fallback = formatFilterValue(chip, meta)
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
    return chip.value.length > 0 ? chip.value.map((value) => loadedByValue.get(String(value)) || labelForOption(value, meta)).join(", ") : "(unset)"
  }

  return loadedByValue.get(String(chip.value)) || fallback
}

function filterValueList(value: unknown) {
  if (Array.isArray(value)) return value.map(String).filter(Boolean)
  if (value === null || value === undefined || value === "") return []
  if (typeof value === "object") return []
  return [String(value)]
}

function isFkFilterMeta(meta: FilterSchemaField) {
  return meta.bucket === "fk" || meta.typeahead === true
}

function labelForOption(value: unknown, meta: FilterSchemaField | null) {
  if (!meta) return String(value)
  return filterOptions(meta).find((option) => String(option.value) === String(value))?.label || String(value)
}

function isPredicateOp(op: string) {
  return ["is_set", "is_unset", "is_true", "is_false"].includes(op)
}

function isMultiValueOp(op: string) {
  return ["is_one_of", "is_none_of", "contains_any", "contains_all", "contains_none"].includes(op)
}

function isObjectValue(value: unknown): value is Record<string, unknown> {
  return Boolean(value && typeof value === "object" && !Array.isArray(value))
}

function humanizeOp(op: string) {
  return op.replace(/_/g, " ")
}

function filterChipClass(negated: boolean) {
  return negated
    ? "inline-flex flex-wrap items-center gap-1 rounded border border-rose-300 bg-rose-50 px-1.5 py-1 text-sm dark:border-rose-800 dark:bg-rose-950"
    : "inline-flex flex-wrap items-center gap-1 rounded border border-gray-300 bg-gray-50 px-2 py-1 text-sm dark:border-gray-700 dark:bg-gray-800"
}

function filterNotClass(negated: boolean) {
  return negated
    ? "inline-flex h-5 w-5 items-center justify-center rounded bg-rose-200 text-sm font-bold leading-none text-rose-900 dark:bg-rose-900 dark:text-rose-100"
    : "inline-flex h-5 w-5 items-center justify-center rounded border border-gray-300 text-sm font-bold leading-none text-gray-400 hover:border-rose-300 hover:bg-rose-50 hover:text-rose-700 dark:border-gray-600 dark:text-gray-500 dark:hover:border-rose-800 dark:hover:bg-rose-950 dark:hover:text-rose-200"
}

function filterLabelClass() {
  return "block text-xs font-medium uppercase text-gray-500 dark:text-gray-400"
}

function filterInputClass(extraClasses: string) {
  return `${extraClasses} border border-gray-300 bg-white text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100`
}

function clearFiltersLink(path: string, search: string, legacyFilterKeys: string[], buildLink: FilterLinkBuilder) {
  const updates: FilterLinkUpdates = {
    q: null,
    smart_folder_id: null,
    page: null
  }
  for (const key of legacyFilterKeys) updates[key] = null

  return buildLink(path, search, updates)
}

function linkFromSearch(path: string, search: string, updates: FilterLinkUpdates) {
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

function normalizedOptions(field: FilterSchemaField): FilterOption[] {
  return (field.values || []).map((option) => {
    if (typeof option === "string") return { value: option, label: humanizeOption(option) }
    return option
  })
}

function humanizeOption(value: string) {
  return value.replace(/_/g, " ").replace(/^\w/, (match) => match.toUpperCase())
}

async function loadFkOptions(field: string, { q, ids }: { q?: string; ids?: string[] }): Promise<FilterOption[]> {
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

async function loadFilterSuggestions(config: FilterSuggestionSearchConfig, q: string, activeQ: string, signal: AbortSignal): Promise<FilterSuggestion[]> {
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
