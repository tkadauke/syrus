import { keepPreviousData, useQuery, useQueryClient } from "@tanstack/react-query"
import { type ReactNode, useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { AdminFiltersLayout } from "@app/components/AdminFiltersLayout"
import { AdminSmartFolderNav } from "@app/components/AdminSmartFolderNav"
import { FilterBar } from "@app/components/FilterBar"
import { adminSmartFolderFilterLinkBuilder } from "@app/lib/adminSmartFolderLinks"
import { useMediaQuery } from "@app/routes/dashboard/components"
import { CopyableSlug } from "@app/components/CopyableSlug"
import { SlugHoverCard } from "@app/components/SlugHoverCard"
import { TonePill } from "@app/components/StatusPill"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { RunTranscriptLogs } from "@app/routes/jobDetail/components"
import {
  fetchAgentActivitySessions,
  fetchAgentActivityTranscript,
  recordAgentActivityFilterUsage,
  type AgentActivitySession
} from "../api/agentActivity"

function stateTone(state: string): "blue" | "green" | "red" | "gray" {
  if (state === "running" || state === "queued") return "blue"
  if (state === "succeeded") return "green"
  if (state === "failed") return "red"
  return "gray"
}

function formatDuration(seconds: number | null) {
  if (seconds == null) return null
  if (seconds < 60) return `${seconds}s`
  const minutes = Math.floor(seconds / 60)
  if (minutes < 60) return `${minutes}m`
  const hours = Math.floor(minutes / 60)
  return `${hours}h ${minutes % 60}m`
}

function pageLink(pathname: string, search: string, page: number, prefix: string) {
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search)
  params.set("page", String(page))
  params.set("per", "20")
  return withRoutePrefix(`${pathname}?${params.toString()}`, prefix)
}

function withoutPagination(search: string) {
  const params = new URLSearchParams(search.startsWith("?") ? search.slice(1) : search)
  params.delete("page")
  params.delete("per")
  const query = params.toString()
  return query ? `?${query}` : ""
}

export function AgentActivityFeed({ scope }: { scope: "mine" | "admin" }) {
  const { t } = useT("agent_activity")
  usePageTitle(t(scope === "admin" ? "admin_heading" : "heading"))
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const queryClient = useQueryClient()
  const isDesktop = useMediaQuery("(min-width: 1024px)", true)

  const sessions = useQuery({
    queryKey: [ "agent_activity", scope, location.search ],
    queryFn: () => fetchAgentActivitySessions(scope, location.search),
    placeholderData: keepPreviousData,
    refetchInterval: 15_000
  })

  const runningCount = sessions.data?.running_count ?? 0
  const activeUserFolderId = sessions.data?.smart_folders.find((folder) => folder.id === sessions.data?.active_smart_folder_id && folder.kind === "user_defined")?.id
  const smartFolders = (sessions.data?.smart_folders ?? []).map((folder) => (
    folder.i18n_key
      ? { ...folder, i18n_key: null, name: t(`smart_folder_${folder.i18n_key}`, { defaultValue: folder.name }) }
      : folder
  ))
  const inlineFolders = (
    <AdminSmartFolderNav
      activeFolderId={sessions.data?.active_smart_folder_id ?? null}
      allLabel={t("smart_folder_all")}
      allPath={scope === "admin" ? "/admin/agent_activity?smart_folder_id=" : "/agent_activity?smart_folder_id="}
      allowSaveWithoutActiveFolder={scope === "mine"}
      ariaLabel={t("smart_folders_aria")}
      currentFilter={sessions.data?.filter ?? undefined}
      folders={smartFolders}
      heading={t("smart_folders_heading")}
      onMutationSuccess={() => {
        void queryClient.invalidateQueries({ queryKey: [ "agent_activity", scope ] })
      }}
      prefix={prefix}
      queryKey={[ "agent_activity", scope ]}
      rewriteRedirectTo={scope === "admin" ? (path) => path.replace(/^\/agent_activity/, "/admin/agent_activity") : undefined}
      subjectType="agent_session"
    />
  )
  const filterBar = (
    <FilterBar
      filter={sessions.data?.filter ?? null}
      filterSchema={sessions.data?.filter_schema ?? []}
      buildLink={scope === "admin" ? adminSmartFolderFilterLinkBuilder(activeUserFolderId) : undefined}
      onFilterApplied={(tree) => {
        void recordAgentActivityFilterUsage(scope, tree as Record<string, unknown>).catch(() => {})
      }}
      pathname={location.pathname}
      search={location.search}
      suggestionSearch={{ surface: scope === "admin" ? "agent_activity_admin" : "agent_activity", subject: "agent_activity" }}
    />
  )
  const sessionList = (
    <>
      {sessions.isPending ? <p className="p-6 text-sm text-gray-600 dark:text-gray-400">{t("loading")}</p> : null}
      {sessions.isError ? <p className="p-6 text-sm text-red-700 dark:text-red-300">{errorMessage(sessions.error, t("error_loading"))}</p> : null}
      {sessions.data && sessions.data.sessions.length === 0 ? <p className="p-6 text-sm text-gray-500 dark:text-gray-400">{t("empty")}</p> : null}

      {sessions.data ? (
        <ol className="space-y-2">
          {sessions.data.sessions.map((session) => (
            <SessionCard key={session.id} session={session} />
          ))}
        </ol>
      ) : null}

      {sessions.data ? <SessionsPagination payload={sessions.data} pathname={location.pathname} prefix={prefix} search={location.search} /> : null}
    </>
  )

  return (
    <main aria-label={t("aria_page")} className="mx-auto max-w-6xl space-y-4 p-6">
      <header className="border-b border-gray-200 pb-4 dark:border-gray-700">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("eyebrow")}</p>
        <div className="mt-1 flex flex-wrap items-center gap-3">
          <h1 className="text-3xl font-semibold text-gray-900 dark:text-gray-100">{t(scope === "admin" ? "admin_heading" : "heading")}</h1>
          {runningCount > 0 ? (
            <span className="inline-flex items-center gap-2 rounded-full bg-info/10 px-3 py-1 text-sm font-medium text-info" data-testid="running-now-indicator">
              <span aria-hidden="true" className="h-2 w-2 animate-pulse rounded-full bg-info" />
              {t("running_now_count", { count: runningCount })}
            </span>
          ) : null}
        </div>
        <p className="mt-2 text-sm text-gray-600 dark:text-gray-400">{t(scope === "admin" ? "admin_description" : "description")}</p>
      </header>

      {scope === "admin" || !isDesktop ? (
        <AdminFiltersLayout
          filterBar={filterBar}
          smartFolders={inlineFolders}
        >
          {sessionList}
        </AdminFiltersLayout>
      ) : (
        <AgentActivityListLayout filterBar={filterBar}>{sessionList}</AgentActivityListLayout>
      )}
    </main>
  )
}

function AgentActivityListLayout({ children, filterBar }: { children: ReactNode; filterBar: ReactNode }) {
  return (
    <div className="space-y-3">
      {filterBar}
      {children}
    </div>
  )
}

function SessionsPagination({ payload, pathname, prefix, search }: { payload: { page: number; per: number; total: number; sessions: AgentActivitySession[] }; pathname: string; prefix: string; search: string }) {
  const { t } = useT("agent_activity")
  const totalPages = Math.max(1, Math.ceil(payload.total / payload.per))
  const first = payload.total === 0 ? 0 : (payload.page - 1) * payload.per + 1
  const last = Math.min(payload.total, first + payload.sessions.length - 1)
  const currentSearch = withoutPagination(search)

  if (payload.total <= payload.per && payload.page <= 1) return null

  return (
    <nav aria-label={t("pagination_label")} className="flex flex-wrap items-center justify-between gap-3 border-t border-gray-200 pt-4 text-sm dark:border-gray-700">
      <p className="text-gray-600 dark:text-gray-400">{t("pagination_showing", { first, last, total: payload.total })}</p>
      <div className="flex items-center gap-2">
        {payload.page > 1 ? (
          <Link className="rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800" to={pageLink(pathname, currentSearch, payload.page - 1, prefix)}>{t("pagination_previous")}</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-400 dark:border-gray-700 dark:text-gray-500">{t("pagination_previous")}</span>
        )}
        <span className="text-gray-500 dark:text-gray-400">{t("pagination_page_of", { page: payload.page, total: totalPages })}</span>
        {payload.page < totalPages ? (
          <Link className="rounded border border-gray-300 px-3 py-1 text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-200 dark:hover:bg-gray-800" to={pageLink(pathname, currentSearch, payload.page + 1, prefix)}>{t("pagination_next")}</Link>
        ) : (
          <span className="rounded border border-gray-200 px-3 py-1 text-gray-400 dark:border-gray-700 dark:text-gray-500">{t("pagination_next")}</span>
        )}
      </div>
    </nav>
  )
}

function SessionCard({ session }: { session: AgentActivitySession }) {
  const { t } = useT("agent_activity")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const duration = formatDuration(session.duration_seconds)
  const [expanded, setExpanded] = useState(false)

  return (
    <li className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex flex-col gap-1 p-4">
        <div className="flex flex-wrap items-center gap-2">
          <TonePill active={session.state === "running"} tone={stateTone(session.state)}>{session.state}</TonePill>
          <span className="rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-700 dark:bg-gray-800 dark:text-gray-200">{session.role_label}</span>
          {session.outcome_verdict ? (
            <TonePill tone={session.outcome_verdict === "needs_work" ? "red" : "green"}>{session.outcome_verdict}</TonePill>
          ) : null}
          <span className="text-xs text-gray-400 dark:text-gray-500">{session.agent_provider}</span>
          <span className="ml-auto flex items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
            {session.job ? (
              <SlugHoverCard id={session.job.id} kind="job">
                <CopyableSlug className="text-xs text-brand dark:text-brand-emphasis" slug={session.job.slug} />
              </SlugHoverCard>
            ) : null}
            {session.repository ? <span>{session.repository.slug}</span> : null}
            {duration ? <span>{duration}</span> : null}
            {session.started_at ? <RelativeTimestamp value={session.started_at} /> : null}
          </span>
        </div>
        {session.job?.title ? <p className="truncate text-xs text-gray-500 dark:text-gray-400">{session.job.title}</p> : null}
        {session.transcript_path ? (
          <button className="truncate text-left text-sm text-gray-800 hover:underline dark:text-gray-200" onClick={() => setExpanded((current) => !current)} type="button">
            {session.outcome_summary || t("no_summary_submitted")}
          </button>
        ) : session.chat_path ? (
          <Link className="truncate text-sm text-gray-800 hover:underline dark:text-gray-200" to={withRoutePrefix(session.chat_path, prefix)}>
            {session.outcome_summary || t("no_summary_submitted")}
          </Link>
        ) : (
          <p className="truncate text-sm text-gray-800 dark:text-gray-200">{session.outcome_summary || t("no_summary_submitted")}</p>
        )}
        {session.transcript_path ? (
          <button className="self-start text-xs font-medium text-brand hover:underline" onClick={() => setExpanded((current) => !current)} type="button">
            {expanded ? t("transcript_hide") : t("transcript_heading")}
          </button>
        ) : session.chat_path ? (
          <Link className="self-start text-xs font-medium text-brand hover:underline" to={withRoutePrefix(session.chat_path, prefix)}>
            {t("open_chat")}
          </Link>
        ) : null}
      </div>
      {expanded && session.transcript_path ? <TranscriptDrawer session={session} /> : null}
    </li>
  )
}

function TranscriptDrawer({ session }: { session: AgentActivitySession }) {
  if (!session.transcript_path) return null

  const { t } = useT("agent_activity")
  const transcriptPath = session.transcript_path
  const transcript = useQuery({
    queryKey: [ "agent_activity", "transcript", transcriptPath ],
    queryFn: () => fetchAgentActivityTranscript(transcriptPath)
  })

  return (
    <div className="border-t border-gray-200 dark:border-gray-700">
      <div className="flex items-center justify-between px-4 py-2">
        <h2 className="text-xs font-semibold uppercase text-gray-500 dark:text-gray-400">{t("transcript_heading")}</h2>
      </div>
      {transcript.isPending ? <p className="px-4 pb-3 text-sm text-gray-500 dark:text-gray-400">{t("loading_transcript")}</p> : null}
      {transcript.isError ? <p className="px-4 pb-3 text-sm text-red-700 dark:text-red-300">{errorMessage(transcript.error, t("error_loading"))}</p> : null}
      {transcript.data ? (
        transcript.data.logs.length > 0 ? (
          <RunTranscriptLogs logs={transcript.data.logs} />
        ) : (
          <p className="px-4 pb-3 text-sm text-gray-400 dark:text-gray-500">{t("no_transcript")}</p>
        )
      ) : null}
    </div>
  )
}
