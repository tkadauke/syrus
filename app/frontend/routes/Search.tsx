import { useQuery } from "@tanstack/react-query"
import { Link, useLocation } from "react-router-dom"
import { useState } from "react"
import { fetchSearch, type SearchResult, type SearchResultType } from "../api/search"
import { ChevronIcon } from "../components/ChevronIcon"
import { useT } from "../hooks/useT"

type SearchFilter = SearchResultType | "all"

const filters: Array<{ key: SearchFilter; label: string }> = [
  { key: "all", label: "All" },
  { key: "job", label: "Jobs" },
  { key: "epic", label: "Epics" },
  { key: "chat", label: "Chats" }
]

const typeStyles: Record<SearchResultType, { border: string; badge: string; label: string }> = {
  job: {
    border: "border-l-blue-500",
    badge: "bg-blue-50 text-blue-700 ring-blue-200 dark:bg-blue-950 dark:text-blue-200 dark:ring-blue-800",
    label: "Job"
  },
  epic: {
    border: "border-l-purple-500",
    badge: "bg-purple-50 text-purple-700 ring-purple-200 dark:bg-purple-950 dark:text-purple-200 dark:ring-purple-800",
    label: "Epic"
  },
  chat: {
    border: "border-l-green-500",
    badge: "bg-green-50 text-green-700 ring-green-200 dark:bg-green-950 dark:text-green-200 dark:ring-green-800",
    label: "Chat"
  }
}

export function SearchRoute() {
  const { t } = useT("common")
  const location = useLocation()
  const params = new URLSearchParams(location.search)
  const query = params.get("q")?.trim() || ""
  const activeFilter = activeFilterFromParams(params)
  const selectedTypes = activeFilter === "all" ? [] : [activeFilter]
  const search = useQuery({
    queryKey: ["search", query, activeFilter],
    queryFn: ({ signal }) => fetchSearch(query, selectedTypes, signal),
    enabled: query.length >= 2
  })

  return (
    <main aria-label="Search" className="mx-auto max-w-[72rem] space-y-6 p-6">
      <header className="space-y-4">
        <div>
          {/* TODO: missing i18n key */}
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">Search</h1>
          <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{query ? `Results for "${query}"` : "Search jobs, epics, and chats."}</p>
        </div>
        <nav aria-label="Search type filters" className="flex flex-wrap gap-2">
          {filters.map((filter) => (
            <Link className={filterChipClass(activeFilter === filter.key)} key={filter.key} to={filterPath(location.pathname, location.search, filter.key)}>
              {filter.label}
            </Link>
          ))}
        </nav>
      </header>

      {query.length === 0 ? (
        <PanelMessage>{/* TODO: missing i18n key */}Use the sidebar search field to search across Syrus.</PanelMessage>
      ) : query.length < 2 ? (
        <PanelMessage>{/* TODO: missing i18n key */}Enter at least 2 characters to search.</PanelMessage>
      ) : search.isPending ? (
        <SearchSkeleton />
      ) : search.isError ? (
        <PanelMessage tone="error">{/* TODO: missing i18n key */}Unable to load search results.</PanelMessage>
      ) : search.data.length === 0 ? (
        <PanelMessage>{/* TODO: missing i18n key */}No results match this search.</PanelMessage>
      ) : (
        <section className="divide-y divide-gray-200 overflow-hidden rounded border border-gray-200 bg-white dark:divide-gray-800 dark:border-gray-800 dark:bg-gray-950">
          {search.data.map((result) => <SearchResultRow key={`${result.type}-${result.id}`} result={result} />)}
        </section>
      )}
    </main>
  )
}

function SearchResultRow({ result }: { result: SearchResult }) {
  const { t } = useT("common")
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const styles = typeStyles[result.type]
  const groupedMatches = result.type === "chat" ? result.grouped_matches || [] : []
  const hasGroupedMatches = result.type === "chat" && groupedMatches.length > 0

  return (
    <article className={`border-l-4 ${styles.border} px-4 py-4`}>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset ${styles.badge}`}>{styles.label}</span>
            {result.repository_slug ? <span className="text-xs text-gray-500 dark:text-gray-400">{result.repository_slug}</span> : null}
            {result.state ? <span className="text-xs capitalize text-gray-500 dark:text-gray-400">{result.state.replace(/_/g, " ")}</span> : null}
          </div>
          <h2 className="mt-2 text-base font-semibold text-gray-900 dark:text-gray-100">
            <Link className="break-words hover:text-blue-700 hover:underline dark:hover:text-blue-300" to={withRoutePrefix(result.path, prefix)}>
              {result.title || "Untitled"}
            </Link>
          </h2>
          <Snippet html={result.snippet || ""} />
          {hasGroupedMatches ? <GroupedChatMatches result={result} routePrefix={prefix} /> : null}
        </div>
        {result.created_at ? <time className="shrink-0 text-xs text-gray-500 dark:text-gray-400" dateTime={result.created_at}>{formatDate(result.created_at)}</time> : null}
      </div>
    </article>
  )
}

function GroupedChatMatches({ result, routePrefix }: { result: Extract<SearchResult, { type: "chat" }>; routePrefix: string }) {
  const { t } = useT("common")
  const [expanded, setExpanded] = useState(false)
  const groupedMatches = result.grouped_matches || []
  const hiddenMatchCount = Math.max((result.total_match_count || groupedMatches.length + 1) - 1, groupedMatches.length)
  const matchLabel = hiddenMatchCount === 1 ? "match" : "matches"

  return (
    <div className="mt-3">
      <button
        aria-expanded={expanded}
        className="inline-flex items-center gap-1 rounded text-sm font-medium text-blue-700 hover:text-blue-900 hover:underline dark:text-blue-300 dark:hover:text-blue-200"
        onClick={() => setExpanded((current) => !current)}
        type="button"
      >
        <ChevronIcon className={`h-4 w-4 transition-transform ${expanded ? "rotate-90" : ""}`} />
        {expanded ? "Hide" : "Show"} {groupedMatches.length} {/* TODO: missing i18n key */}more {groupedMatches.length === 1 ? "match" : "matches"}
      </button>
      {!expanded ? <span className="ml-2 text-xs text-gray-500 dark:text-gray-400">{hiddenMatchCount} {/* TODO: missing i18n key */}more {matchLabel} {/* TODO: missing i18n key */}in this chat</span> : null}
      {expanded ? (
        <div className="mt-3 divide-y divide-gray-100 border-t border-gray-100 dark:divide-gray-800 dark:border-gray-800">
          {groupedMatches.map((match) => (
            <Link className="block py-3 hover:bg-gray-50 dark:hover:bg-gray-900" key={match.id} to={withRoutePrefix(match.path, routePrefix)}>
              <Snippet html={match.snippet || ""} />
              {match.created_at ? <time className="mt-1 block text-xs text-gray-500 dark:text-gray-400" dateTime={match.created_at}>{formatDate(match.created_at)}</time> : null}
            </Link>
          ))}
          {result.has_more_matches ? <div className="py-3 text-xs text-gray-500 dark:text-gray-400">{/* TODO: missing i18n key */}Only the top {groupedMatches.length} additional matches are shown.</div> : null}
        </div>
      ) : null}
    </div>
  )
}

function Snippet({ html }: { html: string }) {
  const { t } = useT("common")
  return (
    <p
      className="mt-2 text-sm leading-6 text-gray-700 dark:text-gray-300 [&_mark]:rounded [&_mark]:bg-yellow-200 [&_mark]:px-0.5 [&_mark]:text-gray-950 dark:[&_mark]:bg-yellow-500/40 dark:[&_mark]:text-yellow-50"
      dangerouslySetInnerHTML={{ __html: sanitizeSnippet(html) }}
    />
  )
}

function SearchSkeleton() {
  const { t } = useT("common")
  return (
    <section aria-label="Loading search results" className="space-y-3">
      {[0, 1, 2, 3].map((index) => (
        <div className="animate-pulse rounded border border-gray-200 bg-white p-4 dark:border-gray-800 dark:bg-gray-950" key={index}>
          <div className="h-4 w-20 rounded bg-gray-200 dark:bg-gray-800" />
          <div className="mt-3 h-5 w-2/3 rounded bg-gray-200 dark:bg-gray-800" />
          <div className="mt-3 h-4 w-full rounded bg-gray-100 dark:bg-gray-900" />
          <div className="mt-2 h-4 w-5/6 rounded bg-gray-100 dark:bg-gray-900" />
        </div>
      ))}
    </section>
  )
}

function PanelMessage({ children, tone = "neutral" }: { children: string; tone?: "neutral" | "error" }) {
  const { t } = useT("common")
  const color = tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-500 dark:text-gray-400"
  return <div className={`rounded border border-gray-200 bg-white p-6 text-sm ${color} dark:border-gray-800 dark:bg-gray-950`}>{children}</div>
}

function activeFilterFromParams(params: URLSearchParams): SearchFilter {
  const type = params.getAll("types[]")[0] || params.getAll("types")[0]
  return type === "job" || type === "epic" || type === "chat" ? type : "all"
}

function filterPath(pathname: string, search: string, filter: SearchFilter) {
  const params = new URLSearchParams(search)
  params.delete("types")
  params.delete("types[]")
  if (filter !== "all") params.append("types[]", filter)
  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

function filterChipClass(active: boolean) {
  return `rounded-full px-3 py-1 text-sm font-medium ${active ? "bg-blue-600 text-white" : "bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:hover:bg-gray-700"}`
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

    if (node instanceof HTMLElement && node.tagName.toLowerCase() === "mark") {
      const mark = document.createElement("mark")
      node.childNodes.forEach((child) => appendClean(child, mark))
      parent.appendChild(mark)
      return
    }

    node.childNodes.forEach((child) => appendClean(child, parent))
  }

  template.content.childNodes.forEach((child) => appendClean(child, output))
  return output.innerHTML
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function formatDate(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return ""

  return new Intl.DateTimeFormat(undefined, { month: "short", day: "numeric" }).format(date)
}
