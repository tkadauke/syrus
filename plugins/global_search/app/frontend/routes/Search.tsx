import { withRoutePrefix } from "@app/lib/routing"
import { PageHeading, SectionHeading } from "@app/components/Heading"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { useQuery } from "@tanstack/react-query"
import { Link, useLocation } from "react-router-dom"
import { useState } from "react"
import { fallbackSearchTypeOptions, fetchSearch, type SearchResult, type SearchResultType, type SearchTypeOption, type TestCaseSearchResult } from "../api/search"
import { ChevronIcon } from "@app/components/ChevronIcon"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { FilterBar, type FilterLinkBuilder } from "@app/components/FilterBar"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { SlugHoverCard } from "@app/components/SlugHoverCard"
import { PILL_TONE_CLASSES } from "@app/components/StatusPill"

type SearchFilter = string | "all"

const fallbackFilters: SearchTypeOption[] = fallbackSearchTypeOptions

const typeStyles: Partial<Record<SearchResultType, { border: string; badge: string; label: string }>> = {
  job: {
    border: "border-l-info",
    badge: "bg-info/10 text-info ring-info/30",
    label: "Job"
  },
  epic: {
    border: "border-l-purple-500",
    badge: "bg-purple-50 text-purple-700 ring-purple-200 dark:bg-purple-950 dark:text-purple-200 dark:ring-purple-800",
    label: "Epic"
  },
  chat: {
    border: "border-l-green-500",
    badge: PILL_TONE_CLASSES.green,
    label: "Chat"
  },
  test_case: {
    border: "border-l-amber-500",
    badge: PILL_TONE_CLASSES.amber,
    label: "Test"
  },
  design_doc: {
    border: "border-l-cyan-500",
    badge: "bg-cyan-50 text-cyan-700 ring-cyan-200 dark:bg-cyan-950 dark:text-cyan-200 dark:ring-cyan-800",
    label: "Design Doc"
  }
}

const fallbackTypeStyle = {
  border: "border-l-gray-400",
  badge: "bg-gray-100 text-gray-700 ring-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:ring-gray-700",
  label: "Result"
}

export function SearchRoute() {
  const { t } = useT("common")
  usePageTitle(t("search.heading"))
  const location = useLocation()
  const params = new URLSearchParams(location.search)
  const query = searchTextFromParams(params)
  const activeFilter = activeFilterFromParams(params)
  const search = useQuery({
    queryKey: ["search", location.search],
    queryFn: ({ signal }) => fetchSearch(location.search, signal),
    enabled: query.length >= 2
  })
  const results = search.data?.results || []
  const typeFilters = search.data?.controls.types?.length ? search.data.controls.types : fallbackFilters
  const filters = [{ type: "all", label: "All" }, ...typeFilters]

  return (
    <main aria-label={t("search_aria")} className="mx-auto max-w-[72rem] space-y-6 p-6">
      <header className="space-y-4">
        <div>
          <PageHeading>{t('search.heading')}</PageHeading>
          <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">{query ? `Results for "${query}"` : "Search jobs, epics, chats, and tests."}</p>
        </div>
        <nav aria-label={t("search_type_filters_aria")} className="flex flex-wrap gap-2">
          {filters.map((filter) => (
            <Link className={filterChipClass(activeFilter === filter.type)} key={filter.type} to={filterPath(location.pathname, location.search, filter.type)}>
              {filter.label}
            </Link>
          ))}
        </nav>
        {search.data ? (
          <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-800 dark:bg-gray-950">
            <FilterBar
              buildLink={searchFilterLink}
              filter={search.data.filter}
              filterSchema={search.data.controls.filter_schema}
              pathname={location.pathname}
              search={location.search}
              suggestionSearch={activeFilter === "job" || activeFilter === "epic" ? { surface: "dashboard", subject: activeFilter } : undefined}
            />
          </section>
        ) : null}
      </header>

      {query.length === 0 ? (
        <PanelMessage>{t('search.use_sidebar')}</PanelMessage>
      ) : query.length < 2 ? (
        <PanelMessage>{t('search.min_chars')}</PanelMessage>
      ) : search.isPending ? (
        <SearchSkeleton />
      ) : search.isError ? (
        <PanelMessage tone="error">{t('search.error')}</PanelMessage>
      ) : results.length === 0 ? (
        <PanelMessage>{t('search.no_results')}</PanelMessage>
      ) : (
        <section className="divide-y divide-gray-200 overflow-hidden rounded border border-gray-200 bg-white dark:divide-gray-800 dark:border-gray-800 dark:bg-gray-950">
          {results.map((result) => <SearchResultRow key={`${result.type}-${result.id}`} result={result} />)}
        </section>
      )}
    </main>
  )
}

function SearchResultRow({ result }: { result: SearchResult }) {
  const location = useLocation()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const styles = typeStyles[result.type] || { ...fallbackTypeStyle, label: humanizeType(result.type) }
  const groupedMatches = result.type === "chat" ? result.grouped_matches || [] : []
  const hasGroupedMatches = result.type === "chat" && groupedMatches.length > 0

  return (
    <article className={`border-l-4 ${styles.border} px-4 py-4`}>
      <div className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <div className="min-w-0">
          <div className="flex flex-wrap items-center gap-2">
            <span className={`inline-flex rounded-full px-2 py-0.5 text-xs font-medium ring-1 ring-inset ${styles.badge}`}>{styles.label}</span>
            {result.slug ? (
              <SlugHoverCard id={result.id} kind={slugHoverKind(result.type)} prefix={slugPrefix(result.slug)}>
                <CopyableSlug slug={result.slug} />
              </SlugHoverCard>
            ) : null}
            {result.repository_slug ? <span className="text-xs text-gray-500 dark:text-gray-400">{result.repository_slug}</span> : null}
            {result.state ? <span className="text-xs capitalize text-gray-500 dark:text-gray-400">{result.state.replace(/_/g, " ")}</span> : null}
          </div>
          <SectionHeading className="mt-2">
            <Link className="break-words hover:text-brand hover:underline dark:hover:text-brand-emphasis" to={withRoutePrefix(result.path, prefix)}>
              {result.title || "Untitled"}
            </Link>
          </SectionHeading>
          <Snippet html={result.snippet || ""} />
          {result.type === "test_case" ? <TestCaseDetails result={result} /> : null}
          <ResultMetadata result={result} />
          {hasGroupedMatches ? <GroupedChatMatches result={result} routePrefix={prefix} /> : null}
        </div>
        {result.updated_at || result.created_at ? <RelativeTimestamp className="shrink-0 text-xs text-gray-500 dark:text-gray-400" value={result.updated_at || result.created_at} /> : null}
      </div>
    </article>
  )
}

function ResultMetadata({ result }: { result: SearchResult }) {
  const parts = [
    result.visibility ? humanizeType(result.visibility) : null,
    result.owner ? `Owner ${result.owner.name || result.owner.email_address || `#${result.owner.id}`}` : null,
    result.current_version_number ? `v${result.current_version_number}` : null,
    result.updated_at ? "Updated" : null
  ].filter(Boolean)
  if (parts.length === 0) return null

  return (
    <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
      {parts.join(" · ")}
      {result.updated_at ? <> <RelativeTimestamp value={result.updated_at} /></> : null}
    </p>
  )
}

function TestCaseDetails({ result }: { result: TestCaseSearchResult }) {
  const parts = [result.suite_name, result.file_path].filter(Boolean)
  if (parts.length === 0) return null

  return (
    <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
      {parts.join(" · ")}
    </p>
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
        className="inline-flex items-center gap-1 rounded text-sm font-medium text-brand hover:text-brand-emphasis hover:underline dark:text-brand-emphasis"
        onClick={() => setExpanded((current) => !current)}
        type="button"
      >
        <ChevronIcon className={`h-4 w-4 transition-transform ${expanded ? "rotate-90" : ""}`} />
        {expanded ? t('search.hide') : t('search.show')} {groupedMatches.length} {groupedMatches.length === 1 ? t('search.match_more') : t('search.matches_more')}
      </button>
      {!expanded ? <span className="ml-2 text-xs text-gray-500 dark:text-gray-400">{hiddenMatchCount} {t('search.more')} {matchLabel} {t('search.in_this_chat')}</span> : null}
      {expanded ? (
        <div className="mt-3 divide-y divide-gray-100 border-t border-gray-100 dark:divide-gray-800 dark:border-gray-800">
          {groupedMatches.map((match) => (
            <Link className="block py-3 hover:bg-gray-50 dark:hover:bg-gray-900" key={match.id} to={withRoutePrefix(match.path, routePrefix)}>
              <Snippet html={match.snippet || ""} />
              {match.created_at ? <RelativeTimestamp className="mt-1 block text-xs text-gray-500 dark:text-gray-400" value={match.created_at} /> : null}
            </Link>
          ))}
          {result.has_more_matches ? <div className="py-3 text-xs text-gray-500 dark:text-gray-400">{t('search.top_matches_shown', { count: groupedMatches.length })}</div> : null}
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
    <section aria-label={t("loading_search_aria")} className="space-y-3">
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
  return type || "all"
}

function searchTextFromParams(params: URLSearchParams) {
  const canonical = params.get("query")?.trim()
  if (canonical) return canonical

  const legacy = params.get("q")?.trim() || ""
  return isEncodedFilterTree(legacy) ? "" : legacy
}

function filterPath(pathname: string, search: string, filter: SearchFilter) {
  const params = new URLSearchParams(search)
  params.delete("types")
  params.delete("types[]")
  if (filter !== "all") params.append("types[]", filter)
  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

const searchFilterLink: FilterLinkBuilder = (pathname, search, updates) => {
  const params = new URLSearchParams(search)
  Object.entries(updates).forEach(([key, value]) => {
    params.delete(key)
    if (value != null && value !== "") params.set(key, String(value))
  })

  const query = params.toString()
  return query ? `${pathname}?${query}` : pathname
}

function filterChipClass(active: boolean) {
  return `rounded-full px-3 py-1 text-sm font-medium ${active ? "bg-brand text-on-brand" : "bg-gray-100 text-gray-700 hover:bg-gray-200 dark:bg-gray-800 dark:text-gray-200 dark:hover:bg-gray-700"}`
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

function slugHoverKind(type: SearchResultType): "job" | "epic" | "chat" | "plugin" {
  return type === "job" || type === "epic" || type === "chat" ? type : "plugin"
}

function slugPrefix(slug: string) {
  return slug.match(/^([A-Z]+)-\d+$/)?.[1]
}

function humanizeType(value: string) {
  return value.replace(/_/g, " ").replace(/\b\w/g, (match) => match.toUpperCase())
}

function isEncodedFilterTree(value: string) {
  if (!value) return false

  try {
    const padded = value.padEnd(value.length + ((4 - value.length % 4) % 4), "=")
    const json = window.atob(padded.replace(/-/g, "+").replace(/_/g, "/"))
    const parsed = JSON.parse(json)
    return Boolean(parsed && typeof parsed === "object" && !Array.isArray(parsed))
  } catch {
    return false
  }
}

// Default export is what the plugin component loaders require
// (app/frontend/pluginSidebarPages.tsx and siblings resolve
// `<plugin>/<Component>` to this module and read `.default`).
export default SearchRoute
