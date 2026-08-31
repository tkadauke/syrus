// Filter model types extracted from FilterBar.tsx. Shared by the FilterBar
// component, its value editors, the tree helpers, and external consumers
// (Dashboard, admin views, smart-folder APIs) which import them via FilterBar.

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
  full_text_suggestions?: boolean
  date_precision?: "date" | "datetime"
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

export type FilterPath = number[]
export type FilterLinkUpdates = Record<string, string | number | null | undefined>
export type FilterSuggestionSearchConfig = {
  surface: string
  subject: string
}

export type FilterLinkBuilder = (path: string, search: string, updates: FilterLinkUpdates) => string
