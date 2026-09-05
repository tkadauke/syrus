import { keepPreviousData, useQuery } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "@app/lib/routing"
import { useT } from "@app/hooks/useT"
import { usePageTitle } from "@app/hooks/usePageTitle"
import { errorMessage } from "@app/lib/errorMessage"
import { FilterBar } from "@app/components/FilterBar"
import { encodeFilterTree } from "@app/components/filterBar/helpers"
import { Button } from "@app/components/Button"
import { TonePill } from "@app/components/StatusPill"
import { RelativeTimestamp } from "@app/components/RelativeTimestamp"
import { RunTranscriptLogs } from "@app/routes/jobDetail/components"
import {
  fetchAgentActivitySessions,
  fetchAgentActivityTranscript,
  recordAgentActivityFilterUsage,
  type AgentActivitySession
} from "../api/agentActivity"

const QUICK_FILTERS: Record<string, Record<string, unknown>> = {
  running_now: { and: [ { field: "status", op: "is_one_of", value: [ "running" ] } ] },
  needs_work: { and: [ { field: "status", op: "is_one_of", value: [ "failed" ] } ] }
}

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

export function AgentActivityFeed({ scope }: { scope: "mine" | "admin" }) {
  const { t } = useT("agent_activity")
  usePageTitle(t(scope === "admin" ? "admin_heading" : "heading"))
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = routePrefix(location.pathname)

  const sessions = useQuery({
    queryKey: [ "agent_activity", scope, location.search ],
    queryFn: () => fetchAgentActivitySessions(scope, location.search),
    placeholderData: keepPreviousData,
    refetchInterval: 15_000
  })

  function applyQuickFilter(key: keyof typeof QUICK_FILTERS | "all") {
    if (key === "all") {
      navigate(withRoutePrefix(location.pathname, prefix))
      return
    }
    const q = encodeFilterTree(QUICK_FILTERS[key] as never)
    navigate(withRoutePrefix(`${location.pathname}?q=${q}`, prefix))
  }

  const runningCount = sessions.data?.running_count ?? 0

  return (
    <main aria-label={t("aria_page")} className="mx-auto max-w-5xl space-y-4 p-6">
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

      <div className="flex flex-wrap gap-2">
        <Button onClick={() => applyQuickFilter("running_now")} size="sm" variant="secondary">
          {t("quick_filter_running_now")}
        </Button>
        <Button onClick={() => applyQuickFilter("needs_work")} size="sm" variant="secondary">
          {t("quick_filter_needs_work")}
        </Button>
        <Button onClick={() => applyQuickFilter("all")} size="sm" variant="secondary">
          {t("quick_filter_all")}
        </Button>
      </div>

      <FilterBar
        filter={sessions.data?.filter ?? null}
        filterSchema={sessions.data?.filter_schema ?? []}
        onFilterApplied={(tree) => {
          void recordAgentActivityFilterUsage(scope, tree as Record<string, unknown>).catch(() => {})
        }}
        pathname={location.pathname}
        search={location.search}
        suggestionSearch={{ surface: scope === "admin" ? "agent_activity_admin" : "agent_activity", subject: "agent_activity" }}
      />

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
    </main>
  )
}

function SessionCard({ session }: { session: AgentActivitySession }) {
  const { t } = useT("agent_activity")
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
            {session.job ? <Link className="text-brand hover:underline" to={`/jobs/${session.job.slug}`}>{session.job.slug}</Link> : null}
            {session.repository ? <span>{session.repository.slug}</span> : null}
            {duration ? <span>{duration}</span> : null}
            {session.started_at ? <RelativeTimestamp value={session.started_at} /> : null}
          </span>
        </div>
        {session.job?.title ? <p className="truncate text-xs text-gray-500 dark:text-gray-400">{session.job.title}</p> : null}
        <button className="truncate text-left text-sm text-gray-800 hover:underline dark:text-gray-200" onClick={() => setExpanded((current) => !current)} type="button">
          {session.outcome_summary || t("no_summary_submitted")}
        </button>
        <button className="self-start text-xs font-medium text-brand hover:underline" onClick={() => setExpanded((current) => !current)} type="button">
          {expanded ? t("transcript_hide") : t("transcript_heading")}
        </button>
      </div>
      {expanded ? <TranscriptDrawer session={session} /> : null}
    </li>
  )
}

function TranscriptDrawer({ session }: { session: AgentActivitySession }) {
  const { t } = useT("agent_activity")
  const transcript = useQuery({
    queryKey: [ "agent_activity", "transcript", session.transcript_path ],
    queryFn: () => fetchAgentActivityTranscript(session.transcript_path)
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
