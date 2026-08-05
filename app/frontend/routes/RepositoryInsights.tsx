import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState, type MouseEvent } from "react"
import { Link, useParams, useLocation } from "react-router-dom"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useT } from "../hooks/useT"
import { useConfirm } from "../hooks/useConfirm"
import { RepositoryTabs } from "../components/RepositoryTabs"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import {
  acceptInsightSuggestion,
  acceptRemoveMemoryInsight,
  dismissInsightSuggestion,
  discussInsightSuggestion,
  undismissInsightSuggestion,
  fetchInsightSuggestions,
  saveInsightMemory,
  type InsightSuggestion,
  type PaginationMeta
} from "../api/insights"
import { errorMessage } from "../lib/errorMessage"

type StateFilter = "pending" | "accepted" | "dismissed" | "all"

export function RepositoryInsightsRoute() {
  const { t } = useT("insights")
  const params = useParams()
  const location = useLocation()
  const repositoryId = params.id || ""
  const prefix = routePrefix(location.pathname)
  const [page, setPage] = useState(1)
  const [stateFilter, setStateFilter] = useState<StateFilter>("pending")

  const query = useQuery({
    queryKey: ["repositories", repositoryId, "insight_suggestions", stateFilter, page],
    queryFn: () => fetchInsightSuggestions(repositoryId, page, 20, stateFilter),
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

  const { repository, tabs, suggestions, meta } = query.data

  function handleFilterChange(filter: StateFilter) {
    setStateFilter(filter)
    setPage(1)
  }

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
        meta={meta}
        page={page}
        stateFilter={stateFilter}
        onFilterChange={handleFilterChange}
        onPageChange={setPage}
      />
    </main>
  )
}

function InsightSuggestionsList({
  repositoryId,
  suggestions,
  meta,
  page,
  onPageChange,
  stateFilter,
  onFilterChange
}: {
  repositoryId: string
  suggestions: InsightSuggestion[]
  meta: PaginationMeta
  page: number
  onPageChange: (page: number) => void
  stateFilter: StateFilter
  onFilterChange: (filter: StateFilter) => void
}) {
  const { t } = useT("insights")

  const filterTabs: Array<{ key: StateFilter; label: string; count: number }> = [
    { key: "pending", label: t("filter_pending"), count: meta.counts.pending },
    { key: "accepted", label: t("filter_accepted"), count: meta.counts.accepted },
    { key: "dismissed", label: t("filter_dismissed"), count: meta.counts.dismissed },
    { key: "all", label: t("filter_all"), count: meta.counts.all }
  ]

  const firstItem = meta.total === 0 ? 0 : (page - 1) * meta.per_page + 1
  const lastItem = Math.min(page * meta.per_page, meta.total)

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between gap-4">
        <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{t("suggestions_heading")}</h2>
        <nav aria-label={t("filter_aria")} className="flex gap-1">
          {filterTabs.map((tab) => (
            <button
              className={`rounded px-3 py-1 text-sm font-medium transition-colors ${stateFilter === tab.key ? "bg-terracotta-600 text-white" : "text-gray-600 hover:bg-gray-100 dark:text-gray-400 dark:hover:bg-gray-800"}`}
              key={tab.key}
              onClick={() => onFilterChange(tab.key)}
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

      {suggestions.length === 0 ? (
        <div className="rounded border border-gray-200 bg-white p-8 text-center text-sm text-gray-500 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-400">
          {t("empty")}
        </div>
      ) : (
        <div className="space-y-3">
          {suggestions.map((suggestion) => (
            <SuggestionCard
              key={suggestion.id}
              repositoryId={repositoryId}
              suggestion={suggestion}
            />
          ))}
        </div>
      )}

      {meta.total_pages > 1 && (
        <div className="flex items-center justify-between text-sm text-gray-600 dark:text-gray-400">
          <span>{t("pagination_showing", { first: firstItem, last: lastItem, total: meta.total })}</span>
          <div className="flex gap-2">
            {page > 1 ? (
              <button
                className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"
                onClick={() => onPageChange(page - 1)}
                type="button"
              >
                {t("pagination_previous")}
              </button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">
                {t("pagination_previous")}
              </span>
            )}
            {page < meta.total_pages ? (
              <button
                className="rounded border border-gray-300 px-3 py-1 hover:bg-gray-50 dark:border-gray-600 dark:hover:bg-gray-800"
                onClick={() => onPageChange(page + 1)}
                type="button"
              >
                {t("pagination_next")}
              </button>
            ) : (
              <span className="rounded border border-gray-200 px-3 py-1 text-gray-300 dark:border-gray-700 dark:text-gray-600">
                {t("pagination_next")}
              </span>
            )}
          </div>
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
  const { confirm, dialog: confirmDialog } = useConfirm()
  const [expanded, setExpanded] = useState(false)
  const [showAcceptForm, setShowAcceptForm] = useState(false)
  const [notice, setNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const legacyRevision = suggestion.proposal_type === "revise_existing_insight"

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

  const undismissMutation = useMutation({
    mutationFn: () => undismissInsightSuggestion(suggestion.id),
    onSuccess: (data) => {
      setNotice(data.message)
      setError(null)
      queryClient.invalidateQueries({ queryKey })
    },
    onError: (err) => setError(errorMessage(err, t("undismiss_error")))
  })

  const saveMemoryMutation = useMutation({
    mutationFn: () => saveInsightMemory(suggestion.id),
    onSuccess: (data) => {
      setNotice(data.message)
      setError(null)
    },
    onError: (err) => setError(errorMessage(err, t("save_memory_error")))
  })

  const acceptRemoveMemoryMutation = useMutation({
    mutationFn: () => acceptRemoveMemoryInsight(suggestion.id),
    onSuccess: (data) => {
      setNotice(data.message)
      setError(null)
      queryClient.invalidateQueries({ queryKey })
    },
    onError: (err) => setError(errorMessage(err, t("remove_memory_error")))
  })

  const discussMutation = useMutation({
    mutationFn: () => discussInsightSuggestion(suggestion.id),
    onSuccess: (data) => {
      setError(null)
      window.open(data.redirect_to, "_blank")
    },
    onError: (err) => setError(errorMessage(err, t("discuss_error")))
  })

  async function handleDismiss() {
    const confirmed = await confirm({
      message: t("dismiss_confirm_message"),
      confirmLabel: t("dismiss"),
      destructive: true
    })
    if (confirmed) dismissMutation.mutate()
  }

  function handleCardClick(event: MouseEvent<HTMLElement>) {
    if (isInteractiveClickTarget(event.target)) return

    setExpanded((v) => !v)
  }

  return (
    <article className="cursor-pointer rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900" onClick={handleCardClick}>
      {confirmDialog}
      <div className="p-4">
        <div className="flex items-start justify-between gap-3">
          <div className="min-w-0 flex-1">
            <div className="flex flex-wrap items-center gap-2">
              <SeverityPill severity={suggestion.severity} />
              <ProposalPill proposalType={suggestion.proposal_type} />
              <span className="rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                {suggestion.category}
              </span>
              <span className="text-xs text-gray-500 dark:text-gray-400">
                {t("confidence", { pct: Math.round(suggestion.confidence * 100) })}
                <span aria-hidden="true"> · </span>
                <span className="sr-only">{t("age_label")} </span>
                <RelativeTimestamp value={suggestion.created_at} />
              </span>
              {suggestion.state !== "pending" && (
                <StatePill state={suggestion.state} />
              )}
              {suggestion.state === "accepted" && suggestion.created_job && (
                <Link
                  className="text-xs text-terracotta-700 underline hover:no-underline dark:text-terracotta-400"
                  to={suggestion.created_job.job_path}
                >
                  {suggestion.created_job.slug}
                </Link>
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
            {suggestion.proposal_type === "remove_memory" && (
              <div className="rounded border border-red-200 bg-red-50 p-3 dark:border-red-900/50 dark:bg-red-950/20">
                <p className="text-xs font-medium uppercase text-red-700 dark:text-red-300">
                  {t("remove_memory_label", { id: suggestion.target_memory_id })}
                </p>
                {suggestion.stale_memory_text && (
                  <pre className="mt-1 whitespace-pre-wrap rounded bg-white p-3 text-xs text-red-900 ring-1 ring-red-100 dark:bg-gray-950 dark:text-red-200 dark:ring-red-900/60">
                    {suggestion.stale_memory_text}
                  </pre>
                )}
                {suggestion.stale_memory_evidence && (
                  <p className="mt-2 whitespace-pre-wrap text-xs text-red-800 dark:text-red-200">
                    {suggestion.stale_memory_evidence}
                  </p>
                )}
              </div>
            )}
            {suggestion.proposal_type === "revise_existing_insight" && suggestion.target_insight_id && (
              <div className="rounded border border-gray-200 bg-gray-50 p-3 text-xs text-gray-600 dark:border-gray-700 dark:bg-gray-800 dark:text-gray-300">
                <p className="font-medium text-gray-700 dark:text-gray-200">
                  {t("legacy_revision_heading")}
                </p>
                <p className="mt-1">
                  {t("legacy_revision_body", { id: suggestion.target_insight_id })}
                </p>
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
            {suggestion.proposal_type === "remove_memory" ? (
              <button
                className="rounded bg-red-600 px-3 py-1 text-xs font-medium text-white hover:bg-red-700 disabled:opacity-50"
                disabled={acceptRemoveMemoryMutation.isPending}
                onClick={() => acceptRemoveMemoryMutation.mutate()}
                type="button"
              >
                {acceptRemoveMemoryMutation.isPending ? t("removing_memory") : t("accept_remove_memory")}
              </button>
            ) : legacyRevision ? null : (
              <button
                className="rounded bg-terracotta-600 px-3 py-1 text-xs font-medium text-white hover:bg-terracotta-700 disabled:opacity-50"
                disabled={showAcceptForm}
                onClick={() => { setShowAcceptForm(true); setExpanded(true) }}
                type="button"
              >
                {t("accept")}
              </button>
            )}
            <button
              className="rounded border border-gray-300 px-3 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              disabled={discussMutation.isPending}
              onClick={() => discussMutation.mutate()}
              type="button"
            >
              {discussMutation.isPending ? t("discussing") : t("discuss_in_new_chat")}
            </button>
            <button
              className="rounded border border-gray-300 px-3 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              disabled={dismissMutation.isPending}
              onClick={handleDismiss}
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

        {suggestion.state === "accepted" && (
          <div className="mt-3 flex flex-wrap gap-2 border-t border-gray-100 pt-3 dark:border-gray-800">
            <button
              className="rounded border border-gray-300 px-3 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              disabled={discussMutation.isPending}
              onClick={() => discussMutation.mutate()}
              type="button"
            >
              {discussMutation.isPending ? t("discussing") : t("discuss_in_new_chat")}
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

        {suggestion.state === "dismissed" && (
          <div className="mt-3 flex flex-wrap gap-2 border-t border-gray-100 pt-3 dark:border-gray-800">
            <button
              className="rounded border border-gray-300 px-3 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              disabled={discussMutation.isPending}
              onClick={() => discussMutation.mutate()}
              type="button"
            >
              {discussMutation.isPending ? t("discussing") : t("discuss_in_new_chat")}
            </button>
            <button
              className="rounded border border-gray-300 px-3 py-1 text-xs font-medium text-gray-700 hover:bg-gray-50 disabled:opacity-50 dark:border-gray-600 dark:text-gray-300 dark:hover:bg-gray-800"
              disabled={undismissMutation.isPending}
              onClick={() => undismissMutation.mutate()}
              type="button"
            >
              {undismissMutation.isPending ? t("undismissing") : t("undismiss")}
            </button>
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
  const [promptExpanded, setPromptExpanded] = useState(!suggestion.suggested_prompt)
  const [prompt, setPrompt] = useState(suggestion.suggested_prompt || "")

  const mutation = useMutation({
    mutationFn: () =>
      acceptInsightSuggestion(suggestion.id, {
        createJob: true,
        prompt
      }),
    onSuccess: (data) => {
      onSuccess(data.job ? t("accepted_with_job", { slug: data.job.slug }) : t("accepted"))
    },
    onError: (err) => onError(errorMessage(err, t("accept_error")))
  })

  return (
    <div className="cursor-default border-t border-gray-200 bg-gray-50 p-4 dark:border-gray-700 dark:bg-gray-800" data-insight-card-interactive>
      <h4 className="text-sm font-medium text-gray-900 dark:text-gray-100">{t("accept_heading")}</h4>

      <div className="mt-3">
        <button
          className="flex items-center gap-1 text-xs text-gray-500 hover:text-gray-700 dark:text-gray-400 dark:hover:text-gray-200"
          onClick={() => setPromptExpanded((v) => !v)}
          type="button"
        >
          <svg
            className={`h-3 w-3 transition-transform ${promptExpanded ? "rotate-90" : ""}`}
            fill="none"
            stroke="currentColor"
            viewBox="0 0 24 24"
          >
            <path d="M9 5l7 7-7 7" strokeLinecap="round" strokeLinejoin="round" strokeWidth={2} />
          </svg>
          {t("edit_prompt")}
        </button>
      </div>

      {promptExpanded && (
        <div className="mt-2">
          <textarea
            aria-label={t("prompt_label")}
            className="mt-1 w-full rounded border border-gray-300 p-2 text-sm text-gray-900 dark:border-gray-600 dark:bg-gray-900 dark:text-gray-100"
            onChange={(e) => setPrompt(e.target.value)}
            rows={6}
            value={prompt}
          />
        </div>
      )}

      <div className="mt-3 flex gap-2">
        <button
          className="rounded bg-terracotta-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-terracotta-700 disabled:opacity-50"
          disabled={mutation.isPending || !prompt.trim()}
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

function ProposalPill({ proposalType }: { proposalType: InsightSuggestion["proposal_type"] }) {
  const { t } = useT("insights")
  const classes =
    proposalType === "remove_memory"
      ? "bg-red-100 text-red-800 dark:bg-red-900/30 dark:text-red-300"
      : proposalType === "save_memory"
        ? "bg-emerald-100 text-emerald-800 dark:bg-emerald-900/30 dark:text-emerald-300"
        : "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-400"
  return (
    <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${classes}`}>
      {t(`proposal_${proposalType}`)}
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

function isInteractiveClickTarget(target: EventTarget | null) {
  return target instanceof Element && Boolean(target.closest("a, button, input, label, select, textarea, [role='button'], [role='link'], [data-insight-card-interactive]"))
}
