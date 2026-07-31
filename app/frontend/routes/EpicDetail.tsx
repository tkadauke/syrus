import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { formatRelativeDate } from "../lib/relativeTime"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient, type UseMutationResult } from "@tanstack/react-query"
import { type FormEvent, type ReactNode } from "react"
import { useEffect, useRef, useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { buttonClass } from "../lib/buttonClasses"
import { translateBlockedReason } from "../lib/translateBlockedReason"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { NoticeToast } from "../components/NoticeToast"
import { CloseIcon } from "../components/CloseIcon"
import { ProviderAvailabilityWarning } from "../components/ProviderAvailabilityWarning"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import {
  addEpicDependency,
  archiveEpic,
  claimEpic,
  fetchEpicDetail,
  removeEpicDependency,
  searchEpicOptions,
  startEpicImplementing,
  unclaimEpic,
  updateEpicState,
  type EpicDependencyRecord,
  type EpicDetailJob,
  type EpicDetailPayload,
  type MergeTrainStatus,
  type EpicOwnerUser,
  type EpicVersionRecord,
  type EpicGraph,
  type EpicSearchOption,
  type EpicStateTransition
} from "../api/epics"
import { useConfirm } from "../hooks/useConfirm"
import { Markdown } from "../lib/Markdown"
import { CopyableSlug } from "../components/CopyableSlug"
import { SlugHoverCard } from "../components/SlugHoverCard"
import { PrHoverCard } from "../components/PrHoverCard"
import { errorMessage } from "../lib/errorMessage"
import { ChatBubbleIcon } from "./jobDetail/JobHeader"
import { TopoDepGraph } from "../components/TopoDepGraph"

type EpicCommand =
  | { kind: "state"; transition: EpicStateTransition }
  | { kind: "start" }
  | { kind: "archive" }
  | { kind: "claim" }
  | { kind: "unclaim" }

export function EpicDetailRoute() {
  const { t } = useT("epics")
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const prefix = routePrefix(location.pathname)
  const epic = useQuery({
    queryKey: ["epics", id],
    queryFn: () => fetchEpicDetail(id),
    enabled: id.length > 0
  })
  const epicData = epic.data?.epic
  const pageTitle = epicData
    ? `${epicData.display_number}: ${epicData.title}`
    : (id ? `EPIC-${id}` : undefined)
  usePageTitle(pageTitle)

  return (
    <main aria-label={t("detail_label")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {epic.isPending ? <PanelMessage>{t("loading")}</PanelMessage> : null}
      {epic.isError ? <PanelMessage tone="error">{errorMessage(epic.error, t("load_error"))}</PanelMessage> : null}
      {epic.isSuccess ? <EpicDetail payload={epic.data} prefix={prefix} /> : null}
    </main>
  )
}

export function EpicDetail({ payload, prefix }: { payload: EpicDetailPayload; prefix: string }) {
  const { t } = useT("epics")
  const queryClient = useQueryClient()
  const queryKey = ["epics", String(payload.epic.id)] as const
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const { confirm, dialog } = useConfirm()
  const command = useMutation({
    mutationFn: (action: EpicCommand) => {
      if (action.kind === "start") return startEpicImplementing(payload.paths.app_start_path)
      if (action.kind === "archive") return archiveEpic(payload.paths.app_archive_path)
      if (action.kind === "claim") return claimEpic(payload.paths.app_claim_path)
      if (action.kind === "unclaim") return unclaimEpic(payload.paths.app_unclaim_path)
      return updateEpicState(payload.paths.app_state_path, action.transition.target_state)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
    }
  })
  const dependencyCommand = useMutation({
    mutationFn: (action: { kind: "add"; dependsOnEpicId: number } | { kind: "remove"; dependsOnEpicId: number }) => {
      if (action.kind === "add") return addEpicDependency(payload.paths.app_dependencies_path, action.dependsOnEpicId)

      return removeEpicDependency(payload.paths.app_dependencies_path, action.dependsOnEpicId)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      queryClient.invalidateQueries({ queryKey })
      setNotice(updated.message || null)
    }
  })

  async function runTransition(transition: EpicStateTransition) {
    if (transition.confirm && !(await confirm({ message: transition.confirm, destructive: true }))) return
    command.mutate({ kind: "state", transition })
  }

  return (
    <>
      <header className="space-y-3">
        <div className="flex flex-wrap items-center gap-2">
          <h1 className="break-words text-3xl font-semibold text-gray-900 dark:text-gray-100">
            <CopyableSlug slug={payload.epic.display_number} />
            <span className="px-2 text-gray-400 dark:text-gray-500">·</span>
            {payload.epic.title}
          </h1>
          <StatePill state={payload.epic.state} />
          <EpicStuckBadge stuck={payload.epic.stuck} />
        </div>
        <p className="text-sm text-gray-500 dark:text-gray-400">
          <Link className="font-mono hover:underline" to={withRoutePrefix(payload.epic.repository.repository_path, prefix)}>{payload.epic.repository.slug}</Link>
          <span> · {t("jobs_count", { count: payload.epic.jobs_count })}</span>
          <span> · {epicOwnerLabel(payload.epic, t)}</span>
          <span> · {t("updated_relative", { time: formatRelativeDate(new Date(payload.epic.updated_at)) })}</span>
          {payload.origin_chat ? (
            <span> · <Link className="inline-flex items-center gap-1 font-medium text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(`/chats/${payload.origin_chat.chat_session_id}#message-${payload.origin_chat.message_id}`, prefix)}>
              <ChatBubbleIcon />
              <span>{t("view_in_chat")}</span>
            </Link></span>
          ) : null}
        </p>

        {(payload.state_transitions.length > 0 || payload.epic.claimable || !payload.epic.archived) ? (
          <div className="flex flex-wrap items-center gap-2">
            {payload.epic.startable ? (
              <button
                className={buttonClass("primary")}
                disabled={command.isPending}
                onClick={() => command.mutate({ kind: "start" })}
                type="button"
              >
                {command.isPending ? t("starting") : t("start_implementing")}
              </button>
            ) : null}
            {!payload.epic.startable && (payload.epic.start_blocked_on ?? []).length > 0 ? (
              <span className="text-sm text-gray-500 dark:text-gray-400">
                {t("waiting_on_dependencies", { names: (payload.epic.start_blocked_on ?? []).join(", ") })}
              </span>
            ) : null}
            {payload.epic.claimable && payload.epic.owner_status === "unclaimed" ? (
              <button
                className={buttonClass("secondary")}
                disabled={command.isPending}
                onClick={() => command.mutate({ kind: "claim" })}
                type="button"
              >
                {t("claim")}
              </button>
            ) : null}
            {payload.epic.claimable && payload.epic.owned_by_current_user ? (
              <button
                className={buttonClass("secondary")}
                disabled={command.isPending}
                onClick={() => command.mutate({ kind: "unclaim" })}
                type="button"
              >
                {t("unclaim")}
              </button>
            ) : null}
            {!payload.epic.archived ? (
              <Link className={buttonClass(payload.epic.startable ? "secondary" : "primary")} to={withRoutePrefix(payload.paths.edit_epic_path, prefix)}>{t("edit")}</Link>
            ) : null}
            {payload.state_transitions.length > 0 ? (
              <EpicActionsMenu disabled={command.isPending} onTransition={runTransition} transitions={payload.state_transitions} />
            ) : null}
          </div>
        ) : null}

        <div className="space-y-2">
          <ProgressBar jobs={payload.jobs} totalCount={payload.summary.total_jobs_count} />
          {payload.merge_train_status ? <MergeTrainStatusBanner status={payload.merge_train_status} /> : null}
          <div className="flex flex-wrap items-center gap-2">
            <StateChips jobs={payload.jobs} />
            {payload.summary.dependency_edge_count > 0 ? (
              <span className="rounded bg-violet-50 px-2 py-0.5 text-xs font-medium text-violet-700 dark:bg-violet-950/50 dark:text-violet-200">
                {t("dep", { count: payload.summary.dependency_edge_count })}
              </span>
            ) : null}
            {payload.summary.blocked ? <span className="rounded bg-amber-50 px-2 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-950/50 dark:text-amber-200">{payload.summary.blocked_reason ? translateBlockedReason(payload.summary.blocked_reason, t) : t("blocked")}</span> : null}
            {payload.epic.max_commits_behind_base && payload.epic.max_commits_behind_base > 0 ? (
              <FurthestBehindBadge commits={payload.epic.max_commits_behind_base} jobPath={payload.epic.furthest_behind_job_path} prefix={prefix} t={t} />
            ) : null}
          </div>
        </div>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, t("command_error"))}</PanelMessage> : null}
      {dialog}

      <div className="grid gap-6 lg:grid-cols-[minmax(0,31fr)_minmax(0,19fr)]">
        <div className="min-w-0 space-y-6">
          {payload.epic.description.trim() ? (
            <section className="rounded border border-gray-200 bg-white p-4 dark:border-gray-700 dark:bg-gray-900">
              <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("description")}</h2>
              <Markdown className="chat-prose mt-2 text-sm text-gray-700 dark:text-gray-300" text={payload.epic.description} />
            </section>
          ) : null}
          <JobsSection epicRepositorySlug={payload.epic.repository.slug} jobs={payload.jobs} newJobPath={`/jobs/new?repository_id=${payload.epic.repository.id}`} prefix={prefix} />
          <DependencyGraph graph={payload.graph} />
          <HistorySection versions={payload.versions || []} />
        </div>

        <div className="min-w-0 space-y-6">
          <DependenciesSection command={dependencyCommand} currentEpicId={payload.epic.id} dependencies={payload.dependencies} dependents={payload.dependents} prefix={prefix} />
          <DetailsPanel epic={payload.epic} jobs={payload.jobs} prefix={prefix} />
        </div>
      </div>
    </>
  )
}

function MergeTrainStatusBanner({ status }: { status: MergeTrainStatus }) {
  const { t } = useT("epics")
  const tone = status.phase === "failed"
    ? "border-red-200 bg-red-50 text-red-800 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200"
    : "border-teal-200 bg-teal-50 text-teal-900 dark:border-teal-900/70 dark:bg-teal-950/40 dark:text-teal-100"
  return (
    <div className={`rounded border px-3 py-2 text-sm ${tone}`}>
      <div className="flex flex-wrap items-center gap-x-2 gap-y-1">
        <span className="font-medium">{t(`merge_train_phase.${status.phase}`, { defaultValue: status.phase })}</span>
        <span>{t("merge_train_members", { count: status.member_count })}</span>
        {status.branch ? <code className="break-all rounded bg-white/60 px-1.5 py-0.5 font-mono text-xs dark:bg-black/20">{status.branch}</code> : null}
      </div>
      <p className="mt-1 text-xs opacity-90">{mergeTrainDetail(status, t)}</p>
    </div>
  )
}

function mergeTrainDetail(status: MergeTrainStatus, t: ReturnType<typeof useT>["t"]) {
  if (status.phase === "failed") return status.failure_reason ? t("merge_train_failed_with_reason", { reason: status.failure_reason }) : t("merge_train_failed")
  if (status.reconciliation?.result === "no_changes") return t("merge_train_reconcile_no_changes")
  if (status.reconciliation?.result === "committed") return t("merge_train_reconcile_committed")
  if (status.reconciliation?.result === "failed") return t("merge_train_reconcile_failed")
  if (status.current_step_label) return t("merge_train_current_step", { step: status.current_step_label })
  return t("merge_train_running")
}

function DependenciesSection({
  command,
  currentEpicId,
  dependencies,
  dependents,
  prefix
}: {
  command: UseMutationResult<EpicDetailPayload, Error, { kind: "add"; dependsOnEpicId: number } | { kind: "remove"; dependsOnEpicId: number }>
  currentEpicId: number
  dependencies: EpicDependencyRecord[]
  dependents: EpicDependencyRecord[]
  prefix: string
}) {
  const { t } = useT("epics")
  const [selectedDependency, setSelectedDependency] = useState<EpicSearchOption | null>(null)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    const parsedId = Number.parseInt(String(selectedDependency?.value ?? ""), 10)
    if (!Number.isFinite(parsedId)) return

    command.mutate({ kind: "add", dependsOnEpicId: parsedId }, { onSuccess: () => setSelectedDependency(null) })
  }

  return (
    <section className="space-y-4">
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("dependencies")}</h2>
        <h3 className="mt-3 text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("depends_on")}</h3>
        {dependencies.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {dependencies.map((dependency) => (
              <li className="flex min-h-10 items-center justify-between gap-3 py-2" key={dependency.epic_id}>
                <span className="flex min-w-0 flex-wrap items-center gap-2">
                  <Link className="min-w-0 break-words text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(dependency.url, prefix)}>{dependency.title}</Link>
                  <StatePill state={dependency.state} />
                </span>
                <button
                  aria-label={t("remove_dependency", { title: dependency.title })}
                  className="inline-flex h-8 w-8 shrink-0 items-center justify-center rounded border border-red-200 text-red-600 hover:bg-red-50 disabled:cursor-not-allowed disabled:opacity-50 dark:border-red-900/70 dark:text-red-300 dark:hover:bg-red-950/40"
                  disabled={command.isPending}
                  onClick={() => command.mutate({ kind: "remove", dependsOnEpicId: dependency.epic_id })}
                  title={t("remove_dependency", { title: dependency.title })}
                  type="button"
                >
                  <CloseIcon className="h-4 w-4" />
                </button>
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-gray-400 dark:text-gray-500">{t("none")}</p>
        )}
        <form className="mt-4 flex flex-wrap items-end gap-2 border-t border-gray-100 pt-3 dark:border-gray-800" onSubmit={submit}>
          <EpicDependencyTypeahead
            currentEpicId={currentEpicId}
            excludedEpicIds={dependencies.map((dependency) => dependency.epic_id)}
            onChange={setSelectedDependency}
            selected={selectedDependency}
          />
          <button className={buttonClass("secondary")} disabled={command.isPending || !selectedDependency} type="submit">{t("add_button")}</button>
        </form>
        {command.isError ? <p className="mt-2 text-sm text-red-700 dark:text-red-300" role="alert">{errorMessage(command.error, t("dependency_error"))}</p> : null}
      </div>
      <div className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("depended_on_by")}</h2>
        {dependents.length > 0 ? (
          <ul className="mt-2 divide-y divide-gray-100 dark:divide-gray-800">
            {dependents.map((dependent) => (
              <li className="flex min-h-10 flex-wrap items-center gap-2 py-2" key={dependent.epic_id}>
                <Link className="break-words text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(dependent.url, prefix)}>{dependent.title}</Link>
                <StatePill state={dependent.state} />
              </li>
            ))}
          </ul>
        ) : (
          <p className="mt-2 text-gray-400 dark:text-gray-500">{t("none")}</p>
        )}
      </div>
    </section>
  )
}

function EpicDependencyTypeahead({
  currentEpicId,
  excludedEpicIds,
  onChange,
  selected
}: {
  currentEpicId: number
  excludedEpicIds: number[]
  onChange: (option: EpicSearchOption | null) => void
  selected: EpicSearchOption | null
}) {
  const { t } = useT("epics")
  const [query, setQuery] = useState(selected?.label || "")
  const [options, setOptions] = useState<EpicSearchOption[]>([])
  const [loading, setLoading] = useState(false)
  const previousSelectedLabel = useRef<string | null>(selected?.label || null)
  const trimmedQuery = query.trim()
  const excluded = new Set([currentEpicId, ...excludedEpicIds].map(String))

  useEffect(() => {
    if (selected) {
      previousSelectedLabel.current = selected.label
      setQuery(selected.label)
      return
    }

    if (previousSelectedLabel.current && query === previousSelectedLabel.current) {
      setQuery("")
    }
    previousSelectedLabel.current = null
  }, [selected?.label])

  useEffect(() => {
    if (trimmedQuery.length < 2 || selected?.label === query) {
      setOptions([])
      setLoading(false)
      return
    }

    let cancelled = false
    const controller = new AbortController()
    setLoading(true)

    void searchEpicOptions(trimmedQuery, { signal: controller.signal }).then((loadedOptions) => {
      if (!cancelled) setOptions(loadedOptions.filter((option) => !excluded.has(String(option.value))))
    }).catch((error: unknown) => {
      if (!cancelled && !(error instanceof DOMException && error.name === "AbortError")) setOptions([])
    }).finally(() => {
      if (!cancelled) setLoading(false)
    })

    return () => {
      cancelled = true
      controller.abort()
    }
  }, [excludedEpicIds.join("\0"), currentEpicId, query, selected?.label, trimmedQuery])

  function updateQuery(value: string) {
    setQuery(value)
    if (selected) onChange(null)
  }

  function choose(option: EpicSearchOption) {
    onChange(option)
    setQuery(option.label)
    setOptions([])
  }

  return (
    <label className="relative min-w-0 flex-1 text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
      {t("add_dependency")}
      <input
        aria-autocomplete="list"
        className="mt-1 w-full min-w-64 rounded border border-gray-300 bg-white px-2 py-1.5 text-sm normal-case text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-100"
        onChange={(event) => updateQuery(event.target.value)}
        placeholder={t("search_placeholder")}
        type="search"
        value={query}
      />
      {trimmedQuery.length >= 2 && selected?.label !== query ? (
        <div className="absolute left-0 right-0 top-full z-20 mt-1 max-h-56 overflow-y-auto rounded border border-gray-200 bg-white py-1 normal-case shadow-lg dark:border-gray-700 dark:bg-gray-900">
          {options.length > 0 ? (
            options.map((option) => (
              <button
                className="block w-full px-3 py-1.5 text-left text-sm text-gray-700 hover:bg-gray-50 dark:text-gray-200 dark:hover:bg-gray-800"
                key={String(option.value)}
                onClick={() => choose(option)}
                type="button"
              >
                {option.label}
              </button>
            ))
          ) : (
            <div className="px-3 py-1.5 text-sm text-gray-400 dark:text-gray-500">{loading ? t("searching") : t("no_matches")}</div>
          )}
        </div>
      ) : null}
    </label>
  )
}

function DependencyGraph({ graph }: { graph: EpicGraph }) {
  const { t } = useT("epics")
  if (graph.empty) return <p className="text-sm text-gray-500 dark:text-gray-400">{t("no_external_dependencies")}</p>

  return (
    <details className="group rounded border border-gray-200 bg-white text-sm dark:border-gray-700 dark:bg-gray-900" open={graph.initially_open}>
      <summary className="flex cursor-pointer flex-wrap items-center justify-between gap-2 px-3 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-800">
        <span className="flex items-center gap-2">
          <span className="text-gray-400 transition-transform group-open:rotate-90 dark:text-gray-500">▶</span>
          <span className="font-medium">{t("dependency_graph")}</span>
          <span className="text-gray-500 dark:text-gray-400">({t("epic_dep", { count: graph.epic_dependency_count })}, {t("job_blocker", { count: graph.job_blocker_count })})</span>
        </span>
      </summary>
      <div aria-label={t("dependency_graph_scroll_region")} className="overflow-x-auto border-t border-gray-100 p-3 dark:border-gray-800">
        <TopoDepGraph nodes={graph.nodes} edges={graph.edges} />
      </div>
    </details>
  )
}

function HistorySection({ versions }: { versions: EpicVersionRecord[] }) {
  const { t } = useT("epics")
  return (
    <details className="group rounded border border-gray-200 bg-white text-sm dark:border-gray-700 dark:bg-gray-900">
      <summary className="flex cursor-pointer flex-wrap items-center justify-between gap-2 px-3 py-2 text-gray-700 hover:bg-gray-50 dark:text-gray-300 dark:hover:bg-gray-800">
        <span className="flex items-center gap-2">
          <span className="text-gray-400 transition-transform group-open:rotate-90 dark:text-gray-500">▶</span>
          <span className="font-medium">{t("history")}</span>
          <span className="text-gray-500 dark:text-gray-400">({versions.length})</span>
        </span>
      </summary>
      <div className="border-t border-gray-100 dark:border-gray-800">
        {versions.length > 0 ? (
          <ul className="divide-y divide-gray-100 dark:divide-gray-800">
            {versions.map((version) => (
              <li className="space-y-3 px-4 py-3" key={version.id}>
                <div className="flex flex-wrap items-center gap-2 text-xs text-gray-500 dark:text-gray-400">
                  <span className="font-medium text-gray-700 dark:text-gray-200">{version.actor.email_address}</span>
                  <span><RelativeTimestamp value={version.created_at} /></span>
                </div>
                {version.title_before !== null || version.title_after !== null ? (
                  <div className="grid gap-2 md:grid-cols-2">
                    <DiffValue label={t("title_before")} value={version.title_before} />
                    <DiffValue label={t("title_after")} value={version.title_after} />
                  </div>
                ) : null}
                {version.description_before !== null || version.description_after !== null ? (
                  <div className="grid gap-2 md:grid-cols-2">
                    <DiffValue label={t("description_before")} value={version.description_before} multiline />
                    <DiffValue label={t("description_after")} value={version.description_after} multiline />
                  </div>
                ) : null}
              </li>
            ))}
          </ul>
        ) : (
          <p className="px-4 py-6 text-sm text-gray-400 dark:text-gray-500">{t("no_history")}</p>
        )}
      </div>
    </details>
  )
}

function DiffValue({ label, multiline = false, value }: { label: string; multiline?: boolean; value: string | null }) {
  const { t } = useT("epics")
  return (
    <div>
      <div className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{label}</div>
      <pre className={`mt-1 whitespace-pre-wrap break-words rounded border border-gray-200 bg-gray-50 p-2 font-mono text-xs text-gray-700 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-200 ${multiline ? "min-h-20" : ""}`}>
        {value?.trim() ? value : t("empty_value")}
      </pre>
    </div>
  )
}

export function JobsSection({ epicRepositorySlug, jobs, newJobPath, prefix }: { epicRepositorySlug?: string; jobs: EpicDetailJob[]; newJobPath: string; prefix: string }) {
  const { t } = useT("epics")
  return (
    <section className="rounded border border-gray-200 bg-white dark:border-gray-700 dark:bg-gray-900">
      <div className="flex items-center justify-between border-b border-gray-200 px-4 py-3 dark:border-gray-700">
        <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("jobs_section")}</h2>
        <Link className="text-xs text-blue-600 hover:underline dark:text-blue-400" to={withRoutePrefix(newJobPath, prefix)}>{t("add_job")}</Link>
      </div>
      {jobs.length > 0 ? (
        <ul className="divide-y divide-gray-100 text-sm dark:divide-gray-700">
          {jobs.map((job) => (
            <li className="flex flex-wrap items-center justify-between gap-3 px-4 py-3" key={job.id}>
              <div className="min-w-0 space-y-0.5">
                <div className="flex flex-wrap items-center gap-2">
                  <SlugHoverCard kind="job" id={job.id}>
                    <CopyableSlug slug={job.slug} className="text-xs" />
                  </SlugHoverCard>
                  <ProviderAvailabilityWarning availability={job.provider_availability} />
                  {job.title ? (
                    <Link className="text-gray-700 hover:underline dark:text-gray-200" to={withRoutePrefix(job.path, prefix)}>{job.title}</Link>
                  ) : (
                    <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(job.path, prefix)}>{job.slug}</Link>
                  )}
                  {job.pr_number && job.pr_url ? (
                    <PrHoverCard jobId={job.id} prNumber={job.pr_number} prUrl={job.pr_url}>
                      <a
                        className="font-mono text-xs text-blue-600 hover:underline dark:text-blue-400"
                        href={job.pr_url}
                        rel="noreferrer"
                        target="_blank"
                      >
                        PR #{job.pr_number}
                      </a>
                    </PrHoverCard>
                  ) : null}
                </div>
                <div className="flex flex-wrap items-center gap-2 text-xs text-gray-400 dark:text-gray-500">
                  {epicRepositorySlug && job.repository_slug !== epicRepositorySlug ? (
                    <span className="font-mono">{job.repository_slug}</span>
                  ) : null}
                  {job.label !== "Direct" ? (
                    <span className="font-mono">{job.label}</span>
                  ) : null}
                </div>
              </div>
              <StatePill state={job.state} />
            </li>
          ))}
        </ul>
      ) : (
        <p className="px-4 py-6 text-sm text-gray-400 dark:text-gray-500">{t("no_jobs")}</p>
      )}
    </section>
  )
}

const PROGRESS_SEGMENTS = [
  { state: "merged", color: "bg-emerald-700" },
  { state: "approved", color: "bg-green-500" },
  { state: "implemented", color: "bg-cyan-500" },
  { state: "blocked_by_epic", color: "bg-amber-400" },
]

export function ProgressBar({ jobs, totalCount }: { jobs: EpicDetailJob[]; totalCount: number }) {
  const { t } = useT("epics")
  const segments = PROGRESS_SEGMENTS.map(({ state, color }) => ({
    state,
    color,
    percent: totalCount > 0 ? (jobs.filter((j) => j.state === state).length / totalCount) * 100 : 0,
  }))

  return (
    <div aria-label={t("job_progress_label")} className="flex h-2 w-full overflow-hidden rounded-full bg-gray-200 dark:bg-gray-700" role="progressbar">
      {segments.map(({ state, color, percent }) =>
        percent > 0 ? <div className={`h-2 transition-[width] ${color}`} key={state} style={{ width: `${percent}%` }} /> : null
      )}
    </div>
  )
}

const STATE_CHIP_ORDER = ["merged", "approved", "implemented", "blocked_by_epic", "open", "triaging", "landing", "landing_failed", "closed", "preempted", "pending"]


const STATE_CHIP_STYLES: Record<string, string> = {
  open: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-200",
  triaging: "bg-sky-100 text-sky-700 dark:bg-sky-950/50 dark:text-sky-200",
  implemented: "bg-cyan-100 text-cyan-700 dark:bg-cyan-950/50 dark:text-cyan-200",
  approved: "bg-green-100 text-green-700 dark:bg-green-950/50 dark:text-green-200",
  landing: "bg-teal-100 text-teal-700 dark:bg-teal-950/50 dark:text-teal-200",
  merged: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-200",
  blocked_by_epic: "bg-amber-100 text-amber-700 dark:bg-amber-950/50 dark:text-amber-200",
  landing_failed: "bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-200",
  closed: "bg-gray-200 text-gray-800 dark:bg-gray-700 dark:text-gray-100",
  preempted: "bg-violet-100 text-violet-700 dark:bg-violet-950/50 dark:text-violet-200",
  pending: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"
}

export function StateChips({ jobs }: { jobs: EpicDetailJob[] }) {
  const { t } = useT("epics")
  const counts = new Map<string, number>()
  for (const job of jobs) {
    counts.set(job.state, (counts.get(job.state) || 0) + 1)
  }
  if (counts.size === 0) return null

  const sortedStates = [...counts.keys()].sort((a, b) => {
    const ai = STATE_CHIP_ORDER.indexOf(a)
    const bi = STATE_CHIP_ORDER.indexOf(b)
    if (ai === -1 && bi === -1) return a.localeCompare(b)
    if (ai === -1) return 1
    if (bi === -1) return -1
    return ai - bi
  })

  return (
    <>
      {sortedStates.map((state) => (
        <span className={`rounded px-2 py-0.5 text-xs font-medium ${STATE_CHIP_STYLES[state] || "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"}`} key={state}>
          {counts.get(state)} {t(`state_chip.${state}`, { defaultValue: humanize(state) })}
        </span>
      ))}
    </>
  )
}

function DetailsPanel({ epic, jobs, prefix }: { epic: EpicDetailPayload["epic"]; jobs: EpicDetailJob[]; prefix: string }) {
  const { t } = useT("epics")
  const owner = epic.owner_user || epic.owner
  const activeMembers = uniqueActiveMembers(jobs)

  return (
    <section className="rounded border border-gray-200 bg-white p-4 text-sm dark:border-gray-700 dark:bg-gray-900">
      <h2 className="font-semibold text-gray-900 dark:text-gray-100">{t("details")}</h2>
      <dl className="mt-3 space-y-3">
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("owner")}</dt>
          <dd className="mt-0.5 text-gray-700 dark:text-gray-200">{owner ? owner.email_address : t("unclaimed")}</dd>
        </div>
        {activeMembers.length > 0 ? (
          <div>
            <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("active_members")}</dt>
            <dd className="mt-0.5 space-y-0.5">
              {activeMembers.map((member) => (
                <div key={member.id}>{member.email_address}</div>
              ))}
            </dd>
          </div>
        ) : null}
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("repository")}</dt>
          <dd className="mt-0.5">
            <Link className="font-mono text-blue-600 hover:underline dark:text-blue-300" to={withRoutePrefix(epic.repository.repository_path, prefix)}>
              {epic.repository.slug}
            </Link>
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("epic_dependency_policy_detail")}</dt>
          <dd className="mt-0.5 text-gray-700 dark:text-gray-200">
            {epic.epic_dependency_policy === "inherit"
              ? t("epic_dependency_policy_detail_inherit", { policy: epicDependencyPolicyLabel(epic.resolved_epic_dependency_policy, t), repositoryPolicy: epicDependencyPolicyLabel(epic.repository.epic_dependency_policy, t) })
              : t("epic_dependency_policy_detail_override", { policy: epicDependencyPolicyLabel(epic.resolved_epic_dependency_policy, t) })}
          </dd>
        </div>
        <div>
          <dt className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("updated_label")}</dt>
          <dd className="mt-0.5 text-gray-700 dark:text-gray-200"><RelativeTimestamp value={epic.updated_at} /></dd>
        </div>
      </dl>
    </section>
  )
}

function epicDependencyPolicyLabel(policy: "linear" | "nonlinear", t: (key: string, opts?: Record<string, unknown>) => string) {
  return policy === "nonlinear" ? t("epic_dependency_policy_nonlinear") : t("epic_dependency_policy_linear")
}

function uniqueActiveMembers(jobs: EpicDetailJob[]) {
  const seen = new Set<number>()
  const members: EpicOwnerUser[] = []
  for (const job of jobs) {
    if (job.owner_user && !seen.has(job.owner_user.id)) {
      seen.add(job.owner_user.id)
      members.push(job.owner_user)
    }
  }
  return members
}

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    backlog: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200",
    ready: "bg-sky-100 text-sky-700 dark:bg-sky-950/50 dark:text-sky-200",
    in_progress: "bg-blue-100 text-blue-700 dark:bg-blue-950/50 dark:text-blue-200",
    done: "bg-green-100 text-green-700 dark:bg-green-950/50 dark:text-green-200",
    archived: "bg-gray-200 text-gray-800 dark:bg-gray-700 dark:text-gray-100",
    queued: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200",
    running: "bg-blue-100 text-blue-700 dark:bg-blue-950/50 dark:text-blue-200",
    succeeded: "bg-green-100 text-green-700 dark:bg-green-950/50 dark:text-green-200",
    failed: "bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-200",
    cancelled: "bg-amber-100 text-amber-700 dark:bg-amber-950/50 dark:text-amber-200",
    open: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-200",
    triaging: "bg-sky-100 text-sky-700 dark:bg-sky-950/50 dark:text-sky-200",
    blocked_by_epic: "bg-amber-100 text-amber-700 dark:bg-amber-950/50 dark:text-amber-200",
    implemented: "bg-cyan-100 text-cyan-700 dark:bg-cyan-950/50 dark:text-cyan-200",
    approved: "bg-green-100 text-green-700 dark:bg-green-950/50 dark:text-green-200",
    landing: "bg-teal-100 text-teal-700 dark:bg-teal-950/50 dark:text-teal-200",
    merged: "bg-emerald-100 text-emerald-700 dark:bg-emerald-950/50 dark:text-emerald-200",
    landing_failed: "bg-red-100 text-red-700 dark:bg-red-950/50 dark:text-red-200",
    closed: "bg-gray-200 text-gray-800 dark:bg-gray-700 dark:text-gray-100",
    preempted: "bg-violet-100 text-violet-700 dark:bg-violet-950/50 dark:text-violet-200",
    pending: "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"
  }

  return <span className={`inline-flex items-center rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 text-gray-700 dark:bg-gray-800 dark:text-gray-200"}`}>{humanize(state)}</span>
}

function FurthestBehindBadge({ commits, jobPath, prefix, t }: { commits: number; jobPath: string | null; prefix: string; t: (key: string, opts?: Record<string, unknown>) => string }) {
  const isHigh = commits >= 20
  const className = `rounded px-2 py-0.5 text-xs font-medium ${isHigh ? "bg-red-50 text-red-700 dark:bg-red-950/50 dark:text-red-200" : "bg-amber-50 text-amber-800 dark:bg-amber-950/50 dark:text-amber-200"}`
  const label = t("furthest_behind", { count: commits })

  if (jobPath) {
    return (
      <span className={className}>
        <Link className="hover:underline" to={withRoutePrefix(jobPath, prefix)}>{label}</Link>
      </span>
    )
  }

  return <span className={className}>{label}</span>
}

function EpicStuckBadge({ stuck }: { stuck: boolean }) {
  const { t } = useT("epics")
  if (!stuck) return null

  return (
    <span
      aria-label={t("needs_attention")}
      className="inline-flex items-center rounded bg-amber-100 px-1.5 py-0.5 text-xs font-medium text-amber-800 ring-1 ring-amber-200 dark:bg-amber-950/60 dark:text-amber-200 dark:ring-amber-800"
      title={t("needs_attention_title")}
    >
      {t("needs_attention")}
    </span>
  )
}

function PanelMessage({ children, tone = "success" }: { children: ReactNode; tone?: "success" | "error" | "muted" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700 dark:border-red-900/70 dark:bg-red-950/40 dark:text-red-200",
    muted: "border-gray-200 bg-white text-gray-600 dark:border-gray-700 dark:bg-gray-900 dark:text-gray-300",
    success: "border-green-200 bg-green-50 text-green-700 dark:border-green-900/70 dark:bg-green-950/40 dark:text-green-200"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function EpicActionsMenu({
  disabled,
  onTransition,
  transitions
}: {
  disabled: boolean
  onTransition: (transition: EpicStateTransition) => void
  transitions: EpicStateTransition[]
}) {
  const { t } = useT("epics")
  const [open, setOpen] = useState(false)
  const menuRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))

  return (
    <div className="relative" ref={menuRef}>
      <button
        aria-expanded={open}
        aria-haspopup="menu"
        aria-label={t("more_actions")}
        className={buttonClass("secondary")}
        disabled={disabled}
        onClick={() => setOpen((prev) => !prev)}
        type="button"
      >
        ⋯
      </button>
      {open ? (
        <div className="absolute left-0 z-20 mt-2 w-48 rounded border border-gray-200 bg-white py-1 shadow-lg dark:border-gray-700 dark:bg-gray-900" role="menu">
          {transitions.map((transition) => (
            <button
              className="block w-full px-4 py-2 text-left text-sm text-gray-700 hover:bg-gray-50 disabled:cursor-not-allowed disabled:opacity-50 dark:text-gray-200 dark:hover:bg-gray-800"
              disabled={disabled}
              key={transition.target_state}
              onClick={() => {
                setOpen(false)
                onTransition(transition)
              }}
              role="menuitem"
              type="button"
            >
              {transition.label}
            </button>
          ))}
        </div>
      ) : null}
    </div>
  )
}

function humanize(value: string) {
  return value.split("_").map((part) => part.charAt(0).toUpperCase() + part.slice(1)).join(" ")
}

function epicOwnerLabel(epic: EpicDetailPayload["epic"], t: (key: string, opts?: Record<string, unknown>) => string) {
  const owner = epic.owner_user || epic.owner
  return owner ? t("owner_label", { email: owner.email_address }) : t("unclaimed")
}
