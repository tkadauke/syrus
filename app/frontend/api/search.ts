import { getJson } from "./client"

export type SearchResultType = "job" | "epic" | "chat"

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
  state: string
  repository_slug: string
}

export type EpicSearchResult = BaseSearchResult & {
  type: "epic"
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

export type SearchResult = JobSearchResult | EpicSearchResult | ChatSearchResult

export type ChatGroupedMatch = {
  id: number
  snippet: string
  path: string
  created_at: string | null
}

export function fetchSearch(q: string, types: SearchResultType[] = [], signal?: AbortSignal) {
  const params = new URLSearchParams()
  params.set("q", q)
  types.forEach((type) => params.append("types[]", type))

  return getJson<SearchResult[]>(`/api/v1/app/search?${params.toString()}`, { signal })
}
