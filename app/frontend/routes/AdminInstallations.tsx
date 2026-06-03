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

export function AdminInstallations() {
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const installations = useQuery({
    queryKey: ["admin", "installations"],
    queryFn: fetchAdminInstallations
  })

  return (
    <main aria-label="Admin installations" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 pb-4">
        <p className="text-xs font-medium uppercase text-gray-500">Admin</p>
        <h1 className="mt-1 text-2xl font-semibold text-gray-900">GitHub App Installations</h1>
        <p className="mt-1 text-sm text-gray-500">
          Syrus uses the GitHub App for repositories with an active installation. Repositories without one use the owner's personal access token fallback.
        </p>
      </header>

      {installations.isPending ? <PanelMessage>Loading installations...</PanelMessage> : null}
      {installations.isError ? <InstallationsError error={installations.error} /> : null}
      {installations.isSuccess ? <InstallationsView payload={installations.data} prefix={prefix} /> : null}
    </main>
  )
}

function InstallationsView({ payload, prefix }: { payload: AdminInstallationsPayload; prefix: string }) {
  return (
    <>
      {!payload.github_app_registered ? (
        <section className="rounded border border-amber-200 bg-amber-50 px-4 py-3 text-sm text-amber-900">
          <div className="font-semibold">Syrus App is not registered yet.</div>
          <p className="mt-1">Register the GitHub App before installing it on repositories. Until then, configured repositories run through PAT fallback.</p>
          <Link className="mt-3 inline-block rounded bg-amber-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-500" to={withRoutePrefix("/admin/github_app/register", prefix)}>Run manifest flow</Link>
        </section>
      ) : null}

      <section className="space-y-3">
        <div className="flex flex-col gap-3 sm:flex-row sm:items-center sm:justify-between">
          <h2 className="text-lg font-semibold text-gray-900">Credential modes</h2>
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
  const queryClient = useQueryClient()
  const refresh = useMutation({
    mutationFn: refreshInstallations,
    onSuccess: (payload) => {
      queryClient.setQueryData(["admin", "installations"], payload)
    }
  })

  return (
    <button
      className="rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300"
      disabled={refresh.isPending}
      onClick={() => refresh.mutate()}
      type="button"
    >
      {refresh.isPending ? "Refreshing..." : "Refresh installation list"}
    </button>
  )
}

function CredentialModeComparison() {
  const rows = [
    ["Used when no active App installation exists", "Used when the App is registered and installed on the repo account"],
    ["All actions appear as you", "Actions appear as the App bot"],
    ["Can't approve your own PRs via normal flow", "Normal GitHub approve works"],
    ["Shares your personal API rate limit", "Independent App rate limit"],
    ["Required as fallback for PAT-only repos", "Does not replace PAT fallback for repos without an installation"]
  ]

  return (
    <div className="overflow-hidden rounded border border-gray-200 bg-white">
      <table className="min-w-full divide-y divide-gray-200 text-sm">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500">
          <tr>
            <th className="px-4 py-2">PAT-only</th>
            <th className="px-4 py-2">App-installed</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100">
          {rows.map(([pat, app]) => (
            <tr key={pat}>
              <td className="px-4 py-3 text-gray-700">{pat}</td>
              <td className="px-4 py-3 text-gray-700">{app}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function PatOwnerGroups({ groups }: { groups: PatOwnerGroup[] }) {
  return (
    <section className="space-y-3">
      <h2 className="text-lg font-semibold text-gray-900">Install App on PAT-only repositories</h2>
      <div className="divide-y divide-gray-100 rounded border border-gray-200 bg-white">
        {groups.map((group) => (
          <div className="flex flex-wrap items-center justify-between gap-3 px-4 py-3" key={group.owner}>
            <div>
              <div className="font-mono text-sm text-gray-900">{group.owner}</div>
              <div className="text-xs text-gray-500">{group.repository_count} PAT-only repositories</div>
            </div>
            {group.install_url ? (
              <a className="rounded bg-amber-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-amber-500" href={group.install_url} rel="noopener" target="_blank">
                Install on all PAT-only repos in this account
              </a>
            ) : (
              <span className="text-xs text-gray-500">GitHub IDs missing; re-select these repos from the registration form.</span>
            )}
          </div>
        ))}
      </div>
    </section>
  )
}

function RepositoriesTable({ repositories }: { repositories: InstallationRepository[] }) {
  return (
    <section>
      <h2 className="mb-3 text-lg font-semibold text-gray-900">Repositories</h2>
      <div className="overflow-hidden rounded border border-gray-200 bg-white">
        <table className="min-w-full divide-y divide-gray-200 text-sm">
          <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500">
            <tr>
              <th className="px-4 py-2">Repository</th>
              <th className="px-4 py-2">Syrus owner</th>
              <th className="px-4 py-2">App</th>
              <th className="px-4 py-2">PAT</th>
              <th className="px-4 py-2">Account</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100">
            {repositories.length === 0 ? (
              <tr><td className="px-4 py-6 text-center text-gray-500" colSpan={5}>No repositories configured.</td></tr>
            ) : repositories.map((repository) => (
              <tr key={repository.id}>
                <td className="px-4 py-3 font-mono">{repository.slug}</td>
                <td className="px-4 py-3 text-gray-600">{repository.owner_user.email_address}</td>
                <td className="px-4 py-3">{repository.app_credential_active ? <span className="font-medium text-emerald-700">Active</span> : <span className="text-gray-400">No active installation</span>}</td>
                <td className="px-4 py-3">{repository.app_credential_active ? <span className="text-gray-400">Not used for this repo</span> : <span className="font-medium text-amber-800">Used as fallback</span>}</td>
                <td className="px-4 py-3 text-gray-600">
                  {repository.account_login}
                  {repository.installation_removed_at ? <span className="ml-1 text-xs text-amber-700">(removed)</span> : null}
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
  const message = error instanceof ApiError ? error.message : "Unable to load installations."

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700" : "text-gray-600"}`}>{children}</div>
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}
