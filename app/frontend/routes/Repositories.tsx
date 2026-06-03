import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { useState } from "react"
import { Link, useLocation } from "react-router-dom"
import { ApiError } from "../api/client"
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

type RepositoryAction = {
  id: number
  kind: "poll" | "archive" | "unarchive"
}

export function RepositoriesIndex() {
  const location = useLocation()
  const repositories = useQuery({
    queryKey: ["repositories"],
    queryFn: fetchRepositories
  })
  const prefix = routePrefix(location.pathname)

  return (
    <main aria-label="Repositories" className="mx-auto max-w-[96rem] space-y-6 p-6">
      {repositories.isPending ? <PanelMessage>Loading repositories...</PanelMessage> : null}
      {repositories.isError ? <PanelMessage tone="error">{errorMessage(repositories.error, "Unable to load repositories.")}</PanelMessage> : null}
      {repositories.isSuccess ? <RepositoriesView payload={repositories.data} prefix={prefix} /> : null}
    </main>
  )
}

function RepositoriesView({ payload, prefix }: { payload: RepositoriesPayload; prefix: string }) {
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
        <h1 className="text-3xl font-semibold text-gray-900">Repositories</h1>
        <Link className="rounded bg-blue-600 px-3.5 py-2.5 text-sm font-medium text-white hover:bg-blue-500" to={withRoutePrefix(payload.new_repository_path, prefix)}>Add</Link>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "Repository command failed.")}</PanelMessage> : null}

      {payload.active_repositories.length > 0 ? (
        <section className="overflow-hidden rounded border border-gray-200 bg-white">
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
          <h2 className="text-sm font-medium uppercase tracking-wide text-gray-500">Archived ({payload.archived_repositories.length})</h2>
          <div className="overflow-hidden rounded border border-gray-200 bg-white opacity-75">
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
  return (
    <table className="min-w-full divide-y divide-gray-200">
      <thead className="bg-gray-50 text-left text-xs uppercase text-gray-500">
        <tr>
          <th className="px-4 py-2">Repository</th>
          <th className="hidden px-4 py-2 sm:table-cell">Polling</th>
          <th className="hidden px-4 py-2 sm:table-cell">Last poll</th>
          <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
        </tr>
      </thead>
      <tbody className="divide-y divide-gray-100 text-sm">
        {repositories.map((repository) => (
          <tr key={repository.id}>
            <td className="px-4 py-3">
              <div className="font-mono">
                <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(repository.repository_path, prefix)}>{repository.slug}</Link>
              </div>
              <div className="mt-0.5 text-xs text-gray-500">
                Syrus owner {repository.owner_user.email_address}
              </div>
              <div className="mt-0.5 text-xs text-gray-500">
                <span className="font-mono">{repository.default_branch}</span>
                <span className="mx-1 text-gray-300">·</span>
                label <code className="rounded bg-gray-100 px-1">{repository.trigger_label}</code>
                <span className="mx-1 text-gray-300">·</span>
                agent {repository.agent_provider_label}
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
                  className="text-blue-600 underline hover:no-underline disabled:text-gray-300"
                  disabled={disabled}
                  onClick={() => onAction({ id: repository.id, kind: "poll" })}
                  type="button"
                >
                  Poll now
                </button>
                <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(repository.edit_repository_path, prefix)}>Edit</Link>
                <button
                  className="text-amber-700 underline hover:no-underline disabled:text-gray-300"
                  disabled={disabled}
                  onClick={() => onAction({ id: repository.id, kind: "archive" }, repository)}
                  type="button"
                >
                  Archive
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
  return (
    <table className="min-w-full divide-y divide-gray-200">
      <tbody className="divide-y divide-gray-100 text-sm">
        {repositories.map((repository) => (
          <tr key={repository.id}>
            <td className="px-4 py-3 text-gray-500">
              <div className="font-mono">{repository.slug}</div>
              <div className="mt-0.5 text-xs text-gray-400">archived {formatDate(repository.archived_at)}</div>
            </td>
            <td className="px-4 py-3 text-right">
              <button
                className="text-blue-600 underline hover:no-underline disabled:text-gray-300"
                disabled={disabled}
                onClick={() => onUnarchive(repository)}
                type="button"
              >
                Unarchive
              </button>
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  )
}

function PollingPill({ enabled }: { enabled: boolean }) {
  if (enabled) {
    return <span className="inline-block rounded bg-green-100 px-2 py-0.5 text-xs text-green-700">enabled</span>
  }
  return <span className="inline-block rounded bg-gray-100 px-2 py-0.5 text-xs text-gray-600">paused</span>
}

function LastPoll({ repository }: { repository: RepositoryRow }) {
  if (repository.last_poll_status === "failed") {
    return (
      <div>
        <span className="font-medium text-red-600">failed</span>
        <span className="ml-1 text-xs text-gray-500">{formatDate(repository.last_poll_started_at)}</span>
        {repository.last_poll_error ? <div className="mt-0.5 max-w-xs truncate font-mono text-xs text-red-500" title={repository.last_poll_error}>{repository.last_poll_error}</div> : null}
      </div>
    )
  }

  if (repository.last_poll_status === "ok") {
    return (
      <div>
        <span className="text-green-700">ok</span>
        <span className="ml-1 text-xs text-gray-500">{formatDate(repository.last_poll_started_at)}</span>
      </div>
    )
  }

  return <span className="text-gray-400">-</span>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    success: "border-green-200 bg-green-50 text-green-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function formatDate(value: string | null) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
