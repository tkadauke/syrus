import { useQuery } from "@tanstack/react-query"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { useMemo, useState, type FormEvent } from "react"
import { fetchChatSearch, fetchChatSearchMessages, type ChatSearchMatch, type ChatSearchPayload, type ChatSearchResult } from "../api/chats"
import { getJson } from "../api/client"
import { FilterBar, type FilterLinkBuilder, type FilterOption, type FilterSchemaField } from "../components/FilterBar"

type FilterOptionsPayload = {
  options?: FilterOption[]
}

const filterFields = ["q", "repository_id", "epic_id", "job_id"]

export function ChatSearchRoute() {
  const location = useLocation()
  const search = location.search || ""
  const searchParams = new URLSearchParams(search)
  const hasCriteria = filterFields.some((field) => Boolean(searchParams.get(field)?.trim()))
  const results = useQuery({
    queryKey: ["chat-search", search],
    queryFn: ({ signal }) => fetchChatSearch(search, { signal }),
    enabled: hasCriteria,
    placeholderData: (previousData) => previousData
  })
  const filterOptions = useQuery({
    queryKey: ["chat-search", "filter-options"],
    queryFn: ({ signal }) => loadFilterOptions(signal)
  })
  const filter = useMemo(() => filterFromSearch(search), [search])
  const filterSchema = useMemo(() => chatSearchFilterSchema(filterOptions.data), [filterOptions.data])

  return (
    <main aria-label="Chat search" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">Chat search</h1>
      </header>

      <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
        <FilterBar
          buildLink={chatSearchFilterLink}
          filter={filter}
          filterSchema={filterSchema}
          legacyFilterKeys={["repository_id", "epic_id", "job_id"]}
          pathname={location.pathname}
          search={location.search}
        />
      </section>

      {!hasCriteria ? (
        <PanelMessage>Search your chats or filter by repository, epic, or job.</PanelMessage>
      ) : results.isPending ? (
        <PanelMessage>Searching chats...</PanelMessage>
      ) : results.isError ? (
        <PanelMessage tone="error">Unable to search chats.</PanelMessage>
      ) : (
        <SearchResults payload={results.data} search={search} />
      )}
    </main>
  )
}

function SearchResults({ payload, search }: { payload: ChatSearchPayload; search: string }) {
  if (payload.results.length === 0) {
    return <PanelMessage>No chats match this search.</PanelMessage>
  }

  return (
    <>
      <section className="divide-y divide-gray-200 border-y border-gray-200 dark:divide-gray-800 dark:border-gray-800">
        {payload.results.map((result) => <SearchResultCard key={result.chat_session_id} result={result} search={search} />)}
      </section>
      <SearchPagination page={payload.page} perPage={payload.per_page} total={payload.total} />
    </>
  )
}

function SearchResultCard({ result, search }: { result: ChatSearchResult; search: string }) {
  const [expanded, setExpanded] = useState(false)
  const expandSearch = useMemo(() => {
    const params = new URLSearchParams(search)
    params.set("chat_session_id", String(result.chat_session_id))
    return `?${params.toString()}`
  }, [result.chat_session_id, search])
  const expandedMatches = useQuery({
    queryKey: ["chat-search-matches", expandSearch],
    queryFn: ({ signal }) => fetchChatSearchMessages(expandSearch, { signal }),
    enabled: expanded
  })
  const hiddenMatchCount = Math.max(result.total_match_count - result.top_matches.length, 0)

  return (
    <article className="py-4">
      <div className="flex flex-col gap-1 sm:flex-row sm:items-start sm:justify-between">
        <h2 className="text-base font-semibold text-gray-900 dark:text-gray-100">
          <Link className="hover:text-blue-700 dark:hover:text-blue-300" to={`/chats/${result.chat_session_id}`}>{result.chat_title}</Link>
        </h2>
        <span className="text-sm text-gray-500 dark:text-gray-400">{formatRelativeTime(result.top_matches[0]?.created_at)}</span>
      </div>
      <div className="mt-3 flex items-start gap-2">
        {result.has_more_matches ? (
          <button
            aria-expanded={expanded}
            aria-label={`${expanded ? "Hide" : "Show"} ${hiddenMatchCount} more ${hiddenMatchCount === 1 ? "match" : "matches"}`}
            className="mt-0.5 inline-flex h-6 w-6 shrink-0 items-center justify-center rounded text-gray-500 hover:bg-gray-100 hover:text-gray-900 dark:text-gray-400 dark:hover:bg-gray-800 dark:hover:text-gray-100"
            onClick={() => setExpanded((current) => !current)}
            title={`${hiddenMatchCount} more ${hiddenMatchCount === 1 ? "match" : "matches"}`}
            type="button"
          >
            <span aria-hidden="true" className={`text-lg leading-none transition-transform ${expanded ? "rotate-90" : ""}`}>{">"}</span>
          </button>
        ) : (
          <span className="h-6 w-6 shrink-0" aria-hidden="true" />
        )}
        <Snippet className="min-w-0 text-sm leading-6 text-gray-700 dark:text-gray-300" html={result.best_snippet || "No message snippet available."} />
      </div>
      {expanded ? (
        <div className="ml-8 mt-3 divide-y divide-gray-100 border-t border-gray-100 dark:divide-gray-800 dark:border-gray-800">
          {expandedMatches.isPending ? <div className="py-3 text-sm text-gray-500 dark:text-gray-400">Loading matches...</div> : null}
          {expandedMatches.isError ? <div className="py-3 text-sm text-red-700 dark:text-red-300">Unable to load matches.</div> : null}
          {expandedMatches.data?.matches.map((match) => (
            <MatchRow chatSessionId={result.chat_session_id} key={match.message_id} match={match} />
          ))}
        </div>
      ) : null}
    </article>
  )
}

function MatchRow({ chatSessionId, match }: { chatSessionId: number; match: ChatSearchMatch }) {
  const navigate = useNavigate()

  return (
    <button
      className="flex w-full flex-col gap-2 py-3 text-left text-sm hover:bg-gray-50 dark:hover:bg-gray-800 sm:flex-row sm:items-start"
      onClick={() => navigate(`/chats/${chatSessionId}?message_id=${match.message_id}`)}
      type="button"
    >
      <span className="inline-flex w-fit shrink-0 rounded-full bg-gray-100 px-2 py-0.5 text-xs font-medium capitalize text-gray-700 dark:bg-gray-800 dark:text-gray-200">{match.role.replace(/_/g, " ")}</span>
      <Snippet className="min-w-0 flex-1 text-gray-700 dark:text-gray-300" html={match.snippet || ""} />
      <span className="shrink-0 text-xs text-gray-500 dark:text-gray-400">{formatRelativeTime(match.created_at)}</span>
    </button>
  )
}

function Snippet({ className, html }: { className: string; html: string }) {
  return <p className={className} dangerouslySetInnerHTML={{ __html: sanitizeSnippet(html) }} />
}

function SearchPagination({ page, perPage, total }: { page: number; perPage: number; total: number }) {
  const location = useLocation()
  const totalPages = Math.ceil(total / perPage)
  if (totalPages <= 1) return null

  const firstItem = (page - 1) * perPage + 1
  const lastItem = Math.min(page * perPage, total)

  return (
    <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-300">
      <span>Showing {firstItem}-{lastItem} of {total}</span>
      <div className="flex gap-2">
        {page > 1 ? <Link className={paginationLinkClass()} to={pageLink(location.pathname, location.search, page - 1)}>Previous</Link> : <span className={disabledPaginationClass()}>Previous</span>}
        {page < totalPages ? <Link className={paginationLinkClass()} to={pageLink(location.pathname, location.search, page + 1)}>Next</Link> : <span className={disabledPaginationClass()}>Next</span>}
      </div>
    </div>
  )
}

function PanelMessage({ children, tone = "neutral" }: { children: string; tone?: "neutral" | "error" }) {
  const color = tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-500 dark:text-gray-400"
  return <div className={`rounded border border-gray-200 bg-white p-6 text-sm ${color} dark:border-gray-700 dark:bg-gray-900`}>{children}</div>
}

function chatSearchFilterSchema(options: Awaited<ReturnType<typeof loadFilterOptions>> | undefined): FilterSchemaField[] {
  return [
    { field: "q", label: "Search", bucket: "text", operators: ["contains"], values: [], expansions: { placeholder: "Keywords..." } },
    { field: "repository_id", label: "Repository", bucket: "select", operators: ["is"], values: options?.repository_id || [] },
    { field: "epic_id", label: "Epic", bucket: "select", operators: ["is"], values: options?.epic_id || [] },
    { field: "job_id", label: "Job", bucket: "select", operators: ["is"], values: options?.job_id || [] }
  ]
}

function filterFromSearch(search: string) {
  const params = new URLSearchParams(search)
  const and = filterFields.flatMap((field) => {
    const value = params.get(field)?.trim()
    return value ? [{ field, op: field === "q" ? "contains" : "is", value }] : []
  })
  return { and }
}

const chatSearchFilterLink: FilterLinkBuilder = (path, search, updates) => {
  const params = new URLSearchParams(search)
  const encodedFilter = updates.q

  for (const [key, value] of Object.entries(updates)) {
    if (key !== "q") {
      if (value == null || String(value).length === 0) params.delete(key)
      else params.set(key, String(value))
    }
  }

  if (typeof encodedFilter === "string" && encodedFilter.length > 0) {
    for (const field of filterFields) params.delete(field)
    for (const chip of decodeFilterChips(encodedFilter)) {
      if (filterFields.includes(chip.field) && chip.value) params.set(chip.field, chip.value)
    }
  } else if (encodedFilter == null) {
    for (const field of filterFields) params.delete(field)
  }

  params.delete("page")
  const query = params.toString()
  return query ? `${path}?${query}` : path
}

function decodeFilterChips(encoded: string): Array<{ field: string; value: string }> {
  try {
    const standard = encoded.replace(/-/g, "+").replace(/_/g, "/")
    const parsed = JSON.parse(atob(standard)) as { and?: unknown[] }
    return (parsed.and || []).flatMap((node) => {
      if (!node || typeof node !== "object" || !("field" in node) || !("value" in node)) return []
      const field = String((node as { field: unknown }).field)
      const value = String((node as { value: unknown }).value || "").trim()
      return value ? [{ field, value }] : []
    })
  } catch {
    return []
  }
}

function sanitizeSnippet(html: string) {
  const template = document.createElement("template")
  template.innerHTML = html
  const output = document.createElement("span")

  function appendClean(node: Node, parent: Node) {
    if (node.nodeType === Node.TEXT_NODE) {
      parent.appendChild(document.createTextNode(node.textContent || ""))
      return
    }

    if (node instanceof HTMLElement && node.tagName.toLowerCase() === "b") {
      const bold = document.createElement("b")
      node.childNodes.forEach((child) => appendClean(child, bold))
      parent.appendChild(bold)
      return
    }

    node.childNodes.forEach((child) => appendClean(child, parent))
  }

  template.content.childNodes.forEach((child) => appendClean(child, output))
  return output.innerHTML
}

async function loadFilterOptions(signal: AbortSignal) {
  const [repositoryOptions, epicOptions, jobOptions] = await Promise.all([
    loadOptions("repository_id", signal),
    loadOptions("epic_id", signal),
    loadOptions("job_id", signal)
  ])

  return {
    repository_id: repositoryOptions,
    epic_id: epicOptions,
    job_id: jobOptions
  }
}

function loadOptions(field: string, signal: AbortSignal) {
  const params = new URLSearchParams({ field })
  return getJson<FilterOptionsPayload>(`/api/v1/app/filters/fk_options?${params}`, { signal }).then((payload) => payload.options || [])
}

function pageLink(pathname: string, search: string, page: number) {
  const params = new URLSearchParams(search)
  params.set("page", String(page))
  return `${pathname}?${params.toString()}`
}

function paginationLinkClass() {
  return "rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-700 dark:hover:bg-gray-800"
}

function disabledPaginationClass() {
  return "rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-800 dark:text-gray-600"
}

function formatRelativeTime(value: string | null | undefined) {
  if (!value) return ""
  const timestamp = new Date(value).getTime()
  if (Number.isNaN(timestamp)) return ""

  const seconds = Math.round((timestamp - Date.now()) / 1000)
  const units: Array<[Intl.RelativeTimeFormatUnit, number]> = [
    ["year", 60 * 60 * 24 * 365],
    ["month", 60 * 60 * 24 * 30],
    ["week", 60 * 60 * 24 * 7],
    ["day", 60 * 60 * 24],
    ["hour", 60 * 60],
    ["minute", 60],
    ["second", 1]
  ]
  const formatter = new Intl.RelativeTimeFormat(undefined, { numeric: "always" })
  const [unit, unitSeconds] = units.find(([, unitSeconds]) => Math.abs(seconds) >= unitSeconds) || ["second", 1]
  return formatter.format(Math.round(seconds / unitSeconds), unit)
}
