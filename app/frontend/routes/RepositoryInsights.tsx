import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useParams, useLocation } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useT } from "../hooks/useT"
import { RepositoryTabs } from "../components/RepositoryTabs"
import {
  acceptInsightSuggestion,
  dismissInsightSuggestion,
  fetchInsightSuggestions,
  saveInsightMemory,
  type InsightSuggestion
} from "../api/insights"
import { errorMessage } from "../lib/errorMessage"

type StateFilter = "pending" | "accepted" | "dismissed" | "all"

export function RepositoryInsightsRoute() {
  const { t } = useT("insights")
  const params = useParams()
  const location = useLocation()
  const repositoryId = params.id || ""
  const prefix = routePrefix(location.pathname)

  const query = useQuery({
    queryKey: ["repositories", repositoryId, "insight_suggestions"],
    queryFn: () => fetchInsightSuggestions(repositoryId),
    enabled: repositoryId.length > 0
  })

  if (query.isPending) {
    return (
      <main aria-label={t("aria_insights")} className="p-6 text-sm text-gray-600 dark:text-gray-400">
        {t("loading")}
      </main>
    )
  }

  if (query.isError) {
    return (
      <main aria-label={t("aria_insights")} className="p-6">
        <p className="text-sm text-red-700 dark:text-red-300">{errorMessage(query.error, t("load_error"))}</p>
      </main>
    )
  }

  const { repository, tabs, suggestions } = query.data

  return (
    <main aria-label={t("aria_insights")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <Link className="hover:underline" to={withRoutePrefix(repository.repository_path, prefix)}>
            {repository.slug}
          </Link>
        </h1>
      </header>

      <RepositoryTabs active="insights" prefix={prefix} tabs={tabs} />

      <InsightSuggestionsList
        repositoryId={repositoryId}
        suggestions={suggestions}
        prefix={prefix}
      />
    </main>
  )
}

function InsightSuggestionsList({
  repositoryId,
  suggestions,
  prefix
}: {
  repositoryId: string
  suggestions: InsightSuggestion[]
  prefix: string
}) {
  const { t } = useT("insights")
  const [stateFilter, setStateFilter] = useState<StateFilter>("pending")

  const filtered = suggestions.filter((s) => stateFilter === "all" || s.state === stateFilter)
  const counts = {
    pending: suggestions.filter((s) => s.state === "pending").length,
    accepted: suggestions.filter((s) => s.state === "accepted").length,
    dismissed: suggestions.filter((s) => s.state === "dismissed").length
  }

  const filterTabs: Array<{ key: StateFilter; label: string; count: number }> = [
    { key: "pending", label: t("filter_pending"), count: counts.pending },
    { key: "accepted", label: t("filter_accepted"), count: counts.accepted },
    { key: "dismissed", label: t("filter_dismissed"), count: counts.dismissed },
    { key: "all", label: t("filter_all"), count: suggestions.length }
  ]

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-4">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{t("suggestions_heading")}</h2>
        <nav aria-label={t("filter_aria")} className="flex gap-1">
          {filterTabs.map((tab) => (
            <button
              className={`rounded px-3 py-1 text-sm font-medium transition-colors ${stateFilter === tab.key ? "bg-terracotta-600 text-white" : "text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"}`}
              key={tab.key}
              onClick={() => setStateFilter(tab.key)}
              type="button"
            >
              {tab.label}
              <span className="ml-1.5 rounded-full bg-gray-100 px-1.5 py-0.5 text-xs text-gray-700 dark:bg-gray-700 dark:text-gray-300">
                {tab.count}
              </span>
            </button>
          ))}
        </nav>
      </div>

      {filtered.length === 0 ? (
        <div className="rounded border border-gray-200 bg-white p-8 text-center text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
          {t("empty")}
        </div>
      ) : (
        <div className="space-y-3">
          {filtered.map((suggestion) => (
            <SuggestionCard
              key={suggestion.id}
              repositoryId={repositoryId}
              suggestion={suggestion}
            />
          ))}
        </div>
      )}
    </div>
  )
}

function SuggestionCard({
  repositoryId,
  suggestion
}: {
  repositoryId: string
  suggestion: InsightSuggestion
}) {
  const { t } = useT("insights")
  const queryClient = useQueryClient()
  const [expanded, setExpanded] = useState(false)
  const [showAcceptForm, setShowAcceptForm] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  const queryKey = ["repositories", repositoryId, "insight_suggestions"]

  const dismissMutation = useMutation({
    mutationFn: () => dismissInsightSuggestion(suggestion.id),
    onSuccess: (data) => {
      setNotice(data.message)
      setError(null)
      queryClient.invalidateQueries({ queryKey })
    },
    onError: (err) => setError(errorMessage(err, t("dismiss_error")))
  })

  const saveMemoryMutation = useMutation({
    mutationFn: () => saveInsightMemory(suggestion.id),
    onSuccess: (data) => {
      setNotice(data.message)
      setError(null)
    },
    onError: (err) => setError(errorMessage(err, t("save_memory_error")))
  })

  return (
    <article className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="p-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <SeverityPill severity={suggestion.severity} />
              <span className="rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                {suggestion.category}
              </span>
              <span className="text-xs text-gray-500 dark:text-gray-400">
                {t("confidence", { pct: Math.round(suggestion.confidence * 100) })}
              </span>
              {suggestion.state !== "pending" && (
                <StatePill state={suggestion.state} />
              )}
            </div>
            <h3 className="mt-1.5 text-sm font-semibold text-gray-900 dark:text-gray-100">
              {suggestion.title}
            </h3>
          </div>
          <button
            className="shrink-0 rounded px-2 py-1 text-xs text-gray-500 hover:bg-gray-100 dark:hover:bg-gray-800"
            onClick={() => setExpanded((v) => !v)}
            type="button"
          >
            {expanded ? t("collapse") : t("expand")}
          </button>
        </div>

        {suggestion.evidence.length > 0 && (
          <div className="mt-2 flex flex-wrap gap-2">
            {suggestion.evidence.map((ev, idx) => (
              <span key={idx}>
                {ev.job_path ? (
                  <Link
                    className="text-xs text-terracotta-700 underline hover:no-underline dark:text-terracotta-400"
                    to={ev.job_path}
                  >
                    {ev.kind || t("evidence_job")} #{ev.job_id}
                  </Link>
                ) : null}
                {ev.run_transcript_path ? (
                  <Link
                    className="ml-1 text-xs text-gray-500 underline hover:no-underline dark:text-gray-400"
                    to={ev.run_transcript_path}
                  >
                    {t("evidence_transcript")}
                  </Link>
                ) : null}
              </span>
            ))}
          </div>
        )}

        {expanded && (
          <div className="mt-3 space-y-3 border-t border-gray-100 pt-3 dark:border-gray-800">
            {suggestion.suggested_prompt && (
              <div>
                <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("suggested_prompt_label")}</p>
                <pre className="mt-1 whitespace-pre-wrap rounded bg-gray-50 p-3 text-xs text-gray-700 dark:bg-gray-800 dark:text-gray-300">
                  {suggestion.suggested_prompt}
                </pre>
              </div>
            )}
            {suggestion.memory_suggestion && (
              <div>
                <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("memory_suggestion_label")}</p>
                <pre className="mt-1 whitespace-pre-wrap rounded bg-gray-50 p-3 text-xs text-gray-700 dark:bg-gray-800 dark:text-gray-300">
                  {suggestion.memory_suggestion}
                </pre>
              </div>
            )}
            {suggestion.created_job && (
              <div className="text-xs text-gray-600 dark:text-gray-400">
                {t("created_job_label")}:{" "}
                <Link className="underline hover:no-underline" to={suggestion.created_job.job_path}>
                  {suggestion.created_job.slug}
                </Link>
              </div>
            )}
          </div>
        )}

        {notice && (
          <p className="mt-2 text-xs text-green-700 dark:text-green-400">{notice}</p>
        )}
        {error && (
          <p className="mt-2 text-xs text-red-700 dark:text-red-400">{error}</p>
        )}

        {suggestion.state === "pending" && (
          <div className="mt-3 flex flex-wrap gap-2 border-t border-gray-100 pt-3 dark:border-gray-800">
            <button
              className="rounded bg-terracotta-600 px-3 py-1 text-xs font-medium text-white hover:bg-terracotta-700 disabled:opacity-50"
              disabled={showAcceptForm}
              onClick={() => { setShowAcceptForm(true); setExpanded(true) }}
              type="button"
            >
              {t("accept")}
            </button>
            <button
              className="rounded border border-gray-300 px-3 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              disabled={dismissMutation.isPending}
              onClick={() => dismissMutation.mutate()}
              type="button"
            >
              {dismissMutation.isPending ? t("dismissing") : t("dismiss")}
            </button>
            {suggestion.has_memory_suggestion && (
              <button
                className="rounded border border-gray-300 px-3 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
                disabled={saveMemoryMutation.isPending}
                onClick={() => saveMemoryMutation.mutate()}
                type="button"
              >
                {saveMemoryMutation.isPending ? t("saving_memory") : t("save_as_memory")}
              </button>
            )}
          </div>
        )}
      </div>

      {showAcceptForm && suggestion.state === "pending" && (
        <AcceptForm
          repositoryId={repositoryId}
          suggestion={suggestion}
          onClose={() => setShowAcceptForm(false)}
          onSuccess={(msg) => {
            setShowAcceptForm(false)
            setNotice(msg)
            queryClient.invalidateQueries({ queryKey })
          }}
          onError={(msg) => setError(msg)}
        />
      )}
    </article>
  )
}

function AcceptForm({
  repositoryId,
  suggestion,
  onClose,
  onSuccess,
  onError
}: {
  repositoryId: string
  suggestion: InsightSuggestion
  onClose: () => void
  onSuccess: (message: string) => void
  onError: (message: string) => void
}) {
  const { t } = useT("insights")
  const [createJob, setCreateJob] = useState(suggestion.suggested_prompt != null)
  const [prompt, setPrompt] = useState(suggestion.suggested_prompt || "")

  const mutation = useMutation({
    mutationFn: () =>
      acceptInsightSuggestion(suggestion.id, {
        createJob,
        prompt: createJob ? prompt : undefined
      }),
    onSuccess: (data) => {
      onSuccess(data.job ? t("accepted_with_job", { slug: data.job.slug }) : t("accepted"))
    },
    onError: (err) => onError(errorMessage(err, t("accept_error")))
  })

  return (
    <div className="border-t border-gray-200 bg-gray-50 p-4 dark:border-gray-700 dark:bg-gray-800">
      <h4 className="text-sm font-medium text-gray-900 dark:text-gray-100">{t("accept_heading")}</h4>

      <div className="mt-3">
        <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
          <input
            checked={createJob}
            className="rounded border-gray-300"
            onChange={(e) => setCreateJob(e.target.checked)}
            type="checkbox"
          />
          {t("create_job_label")}
        </label>
      </div>

      {createJob && (
        <div className="mt-3">
          <label className="block text-xs font-medium text-gray-700 dark:text-gray-300">
            {t("prompt_label")}
          </label>
          <textarea
            className="mt-1 w-full rounded border border-gray-300 p-2 text-sm text-gray-900 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-100"
            onChange={(e) => setPrompt(e.target.value)}
            required={createJob}
            rows={6}
            value={prompt}
          />
        </div>
      )}

      <div className="mt-3 flex gap-2">
        <button
          className="rounded bg-terracotta-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-terracotta-700 disabled:opacity-50"
          disabled={mutation.isPending || (createJob && !prompt.trim())}
          onClick={() => mutation.mutate()}
          type="button"
        >
          {mutation.isPending ? t("confirming") : t("confirm_accept")}
        </button>
        <button
          className="rounded border border-gray-300 px-3 py-1.5 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-700"
          onClick={onClose}
          type="button"
        >
          {t("cancel")}
        </button>
      </div>
    </div>
  )
}

function SeverityPill({ severity }: { severity: string }) {
  const { t } = useT("insights")
  const classes =
    severity === "high"
      ? "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300"
      : severity === "medium"
        ? "bg-amber-100 text-amber-800 dark:bg-amber-900/30 dark:text-amber-300"
        : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-400"
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${classes}`}>
      {t(`severity_${severity}`)}
    </span>
  )
}

function StatePill({ state }: { state: string }) {
  const { t } = useT("insights")
  const classes =
    state === "accepted"
      ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-300"
      : "bg-gray-100 text-gray-600 dark:bg-gray-800 dark:text-gray-400"
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${classes}`}>
      {t(`state_${state}`)}
    </span>
  )
}
