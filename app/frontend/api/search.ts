import { getJson } from "./client"
import type { FilterSchemaField } from "../components/FilterBar"

export type SearchResultType = "job" | "epic" | "chat" | "test_case"

export type BaseSearchResult = {
  type: SearchResultType
  id: number
  title: string
  snippet: string
  rank: number
  path: string
  state: string | null
  repository_slug: string | null
  created_at: string | null
}

export type JobSearchResult = BaseSearchResult & {
  type: "job"
  slug: string
  state: string
  repository_slug: string
}

export type EpicSearchResult = BaseSearchResult & {
  type: "epic"
  slug: string
  state: string
  repository_slug: string
}

export type ChatSearchResult = BaseSearchResult & {
  type: "chat"
  state: null
  repository_slug: null
  grouped_matches?: ChatGroupedMatch[]
  total_match_count?: number
  has_more_matches?: boolean
}

export type TestCaseSearchResult = BaseSearchResult & {
  type: "test_case"
  state: string
  repository_slug: string
  suite_name: string
  file_path: string | null
}

export type SearchResult = JobSearchResult | EpicSearchResult | ChatSearchResult | TestCaseSearchResult

export type SearchPayload = {
  results: SearchResult[]
  filter: Record<string, unknown> | null
  controls: {
    filter_schema: FilterSchemaField[]
  }
}

export type ChatGroupedMatch = {
  id: number
  snippet: string
  path: string
  created_at: string | null
}

export async function fetchSearch(search: string, signal?: AbortSignal) {
  const params = new URLSearchParams(search)

  const payload = await getJson<SearchPayload | SearchResult[] | unknown>(`/api/v1/app/search?${params.toString()}`, { signal })
  return normalizeSearchPayload(payload)
}

function normalizeSearchPayload(payload: SearchPayload | SearchResult[] | unknown): SearchPayload {
  if (Array.isArray(payload)) {
    return searchPayload(payload)
  }

  if (payload && typeof payload === "object") {
    const record = payload as Partial<SearchPayload>

    return {
      results: Array.isArray(record.results) ? record.results : [],
      filter: record.filter ?? null,
      controls: {
        filter_schema: Array.isArray(record.controls?.filter_schema) ? record.controls.filter_schema : []
      }
    }
  }

  return searchPayload([])
}

function searchPayload(results: SearchResult[]): SearchPayload {
  return {
    results,
    filter: null,
    controls: {
      filter_schema: []
    }
  }
}
