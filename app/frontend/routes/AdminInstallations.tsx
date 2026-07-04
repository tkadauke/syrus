import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation } from "react-router-dom"
import {
  fetchAdminInstallations,
  refreshInstallations,
  type AdminInstallationsPayload,
  type InstallationRepository,
  type PatOwnerGroup
} from "../api/adminInstallations"
import { ApiError } from "../api/client"
import { useT } from "../hooks/useT"

export function AdminInstallations() {
  const { t } = useT("admin")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const installations = useQuery({
    queryKey: ["admin", "installations"],
    queryFn: fetchAdminInstallations
  })

  return (
    <main aria-label="Admin installations" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("installations.heading")}</h1>
        <p className="mt-1 text-sm text-gray-500 dark:text-gray-400">
          {t("installations.description")}
        </p>
      </header>

      {installations.isPending ? <PanelMessage>{t("installations.loading")}</PanelMessage> : null}
      {installations.isError ? <InstallationsError error={installations.error} /> : null}
      {installations.isSuccess ? <InstallationsView payload={installations.data} prefix={prefix} /> : null}
    </main>
  )
}

function InstallationsView({ payload, prefix }: { payload: AdminInstallationsPayload; prefix: string }) {
  const { t } = useT("admin")

  return (
    <>
      {!payload.github_app_registered ? (
        <section className="rounded border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/40 px-4 py-3 text-sm text-amber-900 dark:text-amber-100">
          <div className="font-semibold">{t("installations.app_not_registered_title")}</div>
          <p className="mt-1">{t("installations.app_not_registered_body")}</p>
          <Link className="mt-3 inline-block rounded bg-amber-600 dark:bg-amber-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-500 dark:hover:bg-amber-400" to={withRoutePrefix("/admin/github_app/register", prefix)}>{t("installations.run_manifest_flow")}</Link>
        </section>
      ) : null}

      <section className="space-y-3">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{t("installations.credential_modes")}</h2>
          <RefreshButton />
        </div>
        <CredentialModeComparison />
      </section>

      {payload.github_app_registered && payload.pat_owner_groups.length > 0 ? (
        <PatOwnerGroups groups={payload.pat_owner_groups} />
      ) : null}

      <RepositoriesTable repositories={payload.repositories} />
    </>
  )
}

function RefreshButton() {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const refresh = useMutation({
    mutationFn: refreshInstallations,
    onSuccess: (payload) => {
      queryClient.setQueryData(["admin", "installations"], payload)
    }
  })

  return (
    <button
      className="rounded bg-blue-600 dark:bg-blue-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-400 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
      disabled={refresh.isPending}
      onClick={() => refresh.mutate()}
      type="button"
    >
      {refresh.isPending ? t("installations.refreshing") : t("installations.refresh")}
    </button>
  )
}

function CredentialModeComparison() {
  const { t } = useT("admin")
  const rows = [
    ["Used when no active App installation exists", "Used when the App is registered and installed on the repo account"],
    ["All actions appear as you", "Actions appear as the App bot"],
    ["Can't approve your own PRs via normal flow", "Normal GitHub approve works"],
    ["Shares your personal API rate limit", "Independent App rate limit"],
    ["Required as fallback for PAT-only repos", "Does not replace PAT fallback for repos without an installation"]
  ]

  return (
    <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("installations.col_pat")}</th>
            <th className="px-4 py-2">{t("installations.col_app")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map(([pat, app]) => (
            <tr key={pat}>
              <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{pat}</td>
              <td className="px-4 py-3 text-gray-700 dark:text-gray-200">{app}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function PatOwnerGroups({ groups }: { groups: PatOwnerGroup[] }) {
  const { t } = useT("admin")

  return (
    <section className="space-y-3">
      <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100">{t("installations.install_on_pat_repos")}</h2>
      <div className="divide-y divide-gray-100 dark:divide-gray-800 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        {groups.map((group) => (
          <div className="flex flex-wrap items-center justify-between gap-3 px-4 py-3" key={group.owner}>
            <div>
              <div className="font-mono text-sm text-gray-900 dark:text-gray-100">{group.owner}</div>
              <div className="text-xs text-gray-500 dark:text-gray-400">{t("installations.pat_repos_count", { count: group.repository_count })}</div>
            </div>
            {group.install_url ? (
              <a className="rounded bg-amber-600 dark:bg-amber-500 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-500 dark:hover:bg-amber-400" href={group.install_url} rel="noopener" target="_blank">
                {t("installations.install_on_all")}
              </a>
            ) : (
              <span className="text-xs text-gray-500 dark:text-gray-400">{t("installations.github_ids_missing")}</span>
            )}
          </div>
        ))}
      </div>
    </section>
  )
}

function RepositoriesTable({ repositories }: { repositories: InstallationRepository[] }) {
  const { t } = useT("admin")

  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold text-gray-900 dark:text-gray-100">{t("installations.repositories_heading")}</h2>
      <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
          <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-4 py-2">{t("installations.col_repository")}</th>
              <th className="px-4 py-2">{t("installations.col_syrus_owner")}</th>
              <th className="px-4 py-2">{t("installations.col_app_credential")}</th>
              <th className="px-4 py-2">{t("installations.col_pat_credential")}</th>
              <th className="px-4 py-2">{t("installations.col_account")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
            {repositories.length === 0 ? (
              <tr><td className="px-4 py-6 text-center text-gray-500 dark:text-gray-400" colSpan={5}>{t("installations.no_repositories")}</td></tr>
            ) : repositories.map((repository) => (
              <tr key={repository.id}>
                <td className="px-4 py-3 font-mono">{repository.slug}</td>
                <td className="px-4 py-3 text-gray-600 dark:text-gray-300">{repository.owner_user.email_address}</td>
                <td className="px-4 py-3">{repository.app_credential_active ? <span className="font-medium text-emerald-700 dark:text-emerald-300">{t("installations.app_active")}</span> : <span className="text-gray-400">{t("installations.no_active_installation")}</span>}</td>
                <td className="px-4 py-3">{repository.app_credential_active ? <span className="text-gray-400">{t("installations.not_used")}</span> : <span className="font-medium text-amber-800 dark:text-amber-200">{t("installations.used_as_fallback")}</span>}</td>
                <td className="px-4 py-3 text-gray-600 dark:text-gray-300">
                  {repository.account_login}
                  {repository.installation_removed_at ? <span className="ml-1 text-xs text-amber-700 dark:text-amber-300">{t("installations.removed")}</span> : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </section>
  )
}

function InstallationsError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const message = error instanceof ApiError ? error.message : t("installations.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}
