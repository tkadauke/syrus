import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { useT } from "../hooks/useT"
import { NoticeToast } from "../components/NoticeToast"
import { OnboardingEmptyState, useSetupStatus } from "../components/OnboardingEmptyState"
import {
  archiveRepository,
  fetchRepositories,
  pollRepository,
  type RepositoriesPayload,
  type RepositoryRow,
  unarchiveRepository
} from "../api/repositories"
import { errorMessage } from "../lib/errorMessage"
import { PanelMessage } from "../components/PanelMessage"

type RepositoryAction = {
  id: number
  kind: "poll" | "archive" | "unarchive"
}

export function RepositoriesIndex() {
  const { t } = useT("settings")
  const location = useLocation()
  const repositories = useQuery({
    queryKey: ["repositories"],
    queryFn: fetchRepositories
  })
  const prefix = routePrefix(location.pathname)

  return (
    <main aria-label={t("aria_repositories")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {repositories.isPending ? (
        <PanelMessage>
          {t('repositories.loading')}
        </PanelMessage>
      ) : null}
      {repositories.isError ? <PanelMessage tone="error">{errorMessage(repositories.error, "Unable to load repositories.")}</PanelMessage> : null}
      {repositories.isSuccess ? <RepositoriesView payload={repositories.data} prefix={prefix} /> : null}
    </main>
  )
}

function RepositoriesView({ payload, prefix }: { payload: RepositoriesPayload; prefix: string }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const setupStatus = useSetupStatus()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const command = useMutation({
    mutationFn: (action: RepositoryAction) => {
      if (action.kind === "poll") return pollRepository(action.id)
      if (action.kind === "archive") return archiveRepository(action.id)
      return unarchiveRepository(action.id)
    },
    onSuccess: (updated) => {
      queryClient.setQueryData(["repositories"], updated)
      setNotice(updated.message || null)
    }
  })

  function runAction(action: RepositoryAction, repository?: RepositoryRow) {
    setNotice(null)
    if (action.kind === "archive" && repository && !window.confirm(`Archive ${repository.slug}? Polling stops; existing jobs are unaffected.`)) {
      return
    }
    command.mutate(action)
  }

  return (
    <>
      <header className="flex items-center justify-between gap-3">
        <h1 className="text-3xl font-semibold text-gray-900 dark:text-gray-100">
          {t('repositories.heading')}
        </h1>
        <Link className="rounded bg-blue-600 px-3.5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500" to={withRoutePrefix(payload.new_repository_path, prefix)}>{t('repositories.add')}</Link>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "Repository command failed.")}</PanelMessage> : null}

      {payload.active_repositories.length > 0 ? (
        <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          <RepositoryTable
            disabled={command.isPending}
            onAction={runAction}
            prefix={prefix}
            repositories={payload.active_repositories}
          />
        </section>
      ) : (
        <OnboardingEmptyState
          fallbackActionPath={payload.new_repository_path}
          fallbackActionText="Add repository"
          fallbackDescription="Add a repository to start polling for labelled GitHub issues and to unlock direct jobs."
          fallbackTitle="No active repositories"
          prefix={prefix}
          setupStatus={setupStatus}
        />
      )}

      {payload.archived_repositories.length > 0 ? (
        <section className="space-y-2">
          <h2 className="text-sm font-medium uppercase tracking-wide text-gray-500 dark:text-gray-400">
            {t('repositories.archived_count', { count: payload.archived_repositories.length })}
          </h2>
          <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 opacity-75">
            <ArchivedRepositories
              disabled={command.isPending}
              onUnarchive={(repository) => runAction({ id: repository.id, kind: "unarchive" })}
              repositories={payload.archived_repositories}
            />
          </div>
        </section>
      ) : null}
    </>
  )
}

function RepositoryTable({
  repositories,
  disabled,
  onAction,
  prefix
}: {
  repositories: RepositoryRow[]
  disabled: boolean
  onAction: (action: RepositoryAction, repository?: RepositoryRow) => void
  prefix: string
}) {
  const { t } = useT("settings")
  return (
    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
      <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs uppercase text-gray-500 dark:text-gray-400">
        <tr>
          <th className="px-4 py-2">
            {t('repositories.col_working_repo')}
          </th>
          <th className="hidden px-4 py-2 sm:table-cell">
            {t('repositories.col_polling')}
          </th>
          <th className="hidden px-4 py-2 sm:table-cell">
            {t('repositories.col_last_poll')}
          </th>
          <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
        </tr>
      </thead>
      <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
        {repositories.map((repository) => (
          <tr key={repository.id}>
            <td className="px-4 py-3">
              <div className="font-mono">
                <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(repository.repository_path, prefix)}>{repository.slug}</Link>
              </div>
              {repository.upstream_slug ? (
                <div className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                  {t('repositories.upstream')} <span className="font-mono">{repository.upstream_slug}</span>
                  {repository.upstream_default_branch ? <span className="font-mono">:{repository.upstream_default_branch}</span> : null}
                </div>
              ) : null}
              <div className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                {t('repositories.syrus_owner')} {repository.owner_user.email_address}
              </div>
              <div className="mt-0.5 text-xs text-gray-500 dark:text-gray-400">
                <span className="font-mono">{repository.default_branch}</span>
                <span className="mx-1 text-gray-300 dark:text-gray-600">·</span>
                {t('repositories.label')} <code className="rounded bg-gray-100 dark:bg-gray-800 px-1">{repository.trigger_label}</code>
                <span className="mx-1 text-gray-300 dark:text-gray-600">·</span>
                {t('repositories.agent')} {repository.agent_provider_label}
              </div>
            </td>
            <td className="hidden px-4 py-3 sm:table-cell">
              <PollingPill enabled={repository.polling_enabled} />
            </td>
            <td className="hidden px-4 py-3 text-sm sm:table-cell">
              <LastPoll repository={repository} />
            </td>
            <td className="px-4 py-3 text-right">
              <div className="flex flex-col items-end gap-1 sm:flex-row sm:justify-end sm:gap-3">
                <button
                  className="text-blue-600 dark:text-blue-400 underline hover:no-underline disabled:text-gray-300 dark:disabled:text-gray-600"
                  disabled={disabled}
                  onClick={() => onAction({ id: repository.id, kind: "poll" })}
                  type="button"
                >
                  {t('repositories.poll_now')}
                </button>
                <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(repository.edit_repository_path, prefix)}>{t('repositories.edit')}</Link>
                <button
                  className="text-amber-700 dark:text-amber-300 underline hover:no-underline disabled:text-gray-300 dark:disabled:text-gray-600"
                  disabled={disabled}
                  onClick={() => onAction({ id: repository.id, kind: "archive" }, repository)}
                  type="button"
                >
                  {t('repositories.archive')}
                </button>
              </div>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function ArchivedRepositories({
  repositories,
  disabled,
  onUnarchive
}: {
  repositories: RepositoryRow[]
  disabled: boolean
  onUnarchive: (repository: RepositoryRow) => void
}) {
  const { t } = useT("settings")
  return (
    <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
      <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
        {repositories.map((repository) => (
          <tr key={repository.id}>
            <td className="px-4 py-3 text-gray-500 dark:text-gray-400">
              <div className="font-mono">{repository.slug}</div>
              <div className="mt-0.5 text-xs text-gray-400 dark:text-gray-500">
                {t('repositories.archived')} <RelativeTimestamp value={repository.archived_at} />
              </div>
            </td>
            <td className="px-4 py-3 text-right">
              <button
                className="text-blue-600 dark:text-blue-400 underline hover:no-underline disabled:text-gray-300 dark:disabled:text-gray-600"
                disabled={disabled}
                onClick={() => onUnarchive(repository)}
                type="button"
              >
                {t('repositories.unarchive')}
              </button>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function PollingPill({ enabled }: { enabled: boolean }) {
  const { t } = useT("settings")
  if (enabled) {
    return (
      <span className="inline-block rounded bg-green-100 dark:bg-green-950/40 px-2 py-0.5 text-xs text-green-700 dark:text-green-300">
        {t('repositories.polling_enabled')}
      </span>
    )
  }
  return (
    <span className="inline-block rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs text-gray-600 dark:text-gray-400">
      {t('repositories.polling_paused')}
    </span>
  )
}

function LastPoll({ repository }: { repository: RepositoryRow }) {
  const { t } = useT("settings")
  if (repository.last_poll_status === "failed") {
    return (
      <div>
        <span className="font-medium text-red-600 dark:text-red-300">
          {t('repositories.poll_failed')}
        </span>
        <span className="ml-1 text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={repository.last_poll_started_at} /></span>
        {repository.last_poll_error ? <div className="mt-0.5 max-w-xs truncate font-mono text-xs text-red-500 dark:text-red-300" title={repository.last_poll_error}>{repository.last_poll_error}</div> : null}
      </div>
    )
  }

  if (repository.last_poll_status === "ok") {
    return (
      <div>
        <span className="text-green-700 dark:text-green-300">
          {t('repositories.poll_ok')}
        </span>
        <span className="ml-1 text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={repository.last_poll_started_at} /></span>
      </div>
    )
  }

  return <span className="text-gray-400 dark:text-gray-500">-</span>
}


