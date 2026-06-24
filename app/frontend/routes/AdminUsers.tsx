import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { ReactNode } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { AdminSmartFolderNav } from "../components/AdminSmartFolderNav"
import { FilterBar } from "../components/FilterBar"
import {
  fetchAdminUser,
  fetchAdminUsers,
  pauseUserScheduling,
  unpauseUserScheduling,
  type AdminUserDetail,
  type AdminUserRow
} from "../api/adminUsers"

export function AdminUsersIndex() {
  const location = useLocation()
  const queryClient = useQueryClient()
  const prefix = routePrefix(location.pathname)
  const basePath = location.pathname.startsWith("/app-shell") ? "/app-shell/admin/users" : "/admin/users"
  const users = useQuery({
    queryKey: ["admin", "users", location.search],
    queryFn: () => fetchAdminUsers(location.search)
  })

  return (
    <main aria-label="Admin users" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">Admin</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">Users</h1>
        </div>
      </header>

      {users.isPending ? <PanelMessage>Loading users...</PanelMessage> : null}
      {users.isError ? <UsersError error={users.error} /> : null}
      {users.isSuccess ? (
        <AdminFiltersLayout
          filterBar={
            <FilterBar
              filter={users.data.filter}
              filterSchema={users.data.controls.filter_schema}
              legacyFilterKeys={adminUserLegacyFilterKeys}
              pathname={location.pathname}
              search={location.search}
            />
          }
          smartFolders={
            <AdminSmartFolderNav
              activeSmartFolderId={users.data.active_smart_folder_id}
              allLabel="All users"
              allPath={basePath}
              ariaLabel="Admin user smart folders"
              folders={users.data.smart_folders}
              heading="Smart folders"
              onMutationSuccess={() => {
                void queryClient.invalidateQueries({ queryKey: ["admin", "users"] })
              }}
              prefix={prefix}
            />
          }
        >
          <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
            <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-600 dark:text-gray-300">{users.data.count} matching</div>
            <UsersTable basePath={basePath} users={users.data.users} />
          </section>
        </AdminFiltersLayout>
      ) : null}
    </main>
  )
}

const adminUserLegacyFilterKeys = ["email", "admin", "has_github_token", "has_claude_token", "has_codex_token", "gh_rate"]

export function AdminUserDetailRoute() {
  const params = useParams()
  const id = params.id || ""
  const location = useLocation()
  const basePath = location.pathname.startsWith("/app-shell") ? "/app-shell/admin/users" : "/admin/users"
  const user = useQuery({
    queryKey: ["admin", "users", id],
    queryFn: () => fetchAdminUser(id),
    enabled: id.length > 0
  })

  return (
    <main aria-label="Admin user detail" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <Link className="text-sm text-blue-600 dark:text-blue-300 underline hover:no-underline" to={basePath}>Users</Link>
        <h1 className="mt-2 text-2xl font-semibold text-gray-900 dark:text-gray-100">{user.data?.display_name || `User #${id}`}</h1>
      </header>

      {user.isPending ? <PanelMessage>Loading user...</PanelMessage> : null}
      {user.isError ? <UsersError error={user.error} /> : null}
      {user.isSuccess ? <UserDetail user={user.data} /> : null}
    </main>
  )
}

function UsersTable({ users, basePath }: { users: AdminUserRow[]; basePath: string }) {
  if (users.length === 0) return <PanelMessage>No users match these filters.</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">User</th>
            <th className="px-4 py-2">GitHub</th>
            <th className="px-4 py-2">Admin</th>
            <th className="px-4 py-2">Agent</th>
            <th className="px-4 py-2">Scheduling</th>
            <th className="px-4 py-2">Tokens</th>
            <th className="px-4 py-2">GH API</th>
            <th className="px-4 py-2">GH rate</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {users.map((user) => (
            <tr className="hover:bg-gray-50 dark:hover:bg-gray-800" key={user.id}>
              <td className="px-4 py-2">
                <Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={`${basePath}/${user.id}`}>{user.display_name}</Link>
                {user.display_name !== user.email_address ? <div className="text-xs text-gray-500 dark:text-gray-400">{user.email_address}</div> : null}
              </td>
              <td className="px-4 py-2">{user.github_handle ? `@${user.github_handle}` : "-"}</td>
              <td className="px-4 py-2">{user.admin ? "yes" : "-"}</td>
              <td className="px-4 py-2">{user.agent_provider}</td>
              <td className="px-4 py-2">{user.scheduling_paused ? "paused" : "active"}</td>
              <td className="px-4 py-2 font-mono text-xs">{tokenSummary(user)}</td>
              <td className="px-4 py-2">{user.github_api_blocked ? "blocked" : "ok"}</td>
              <td className="px-4 py-2">{rateLimitLabel(user)}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function UserDetail({ user }: { user: AdminUserDetail }) {
  return (
    <>
      <section className="grid gap-4 md:grid-cols-2">
        <InfoPanel title="Identity">
          <Info label="Email" value={user.email_address} />
          <Info label="GitHub" value={user.github_handle ? `@${user.github_handle}` : "-"} />
          <Info label="Admin" value={user.admin ? "yes" : "no"} />
          <Info label="GitHub API blocked" value={user.github_api_blocked ? user.github_api_blocked_reason || "yes" : "no"} />
          <Info label="Created" value={formatDate(user.created_at)} />
        </InfoPanel>
        <InfoPanel title="Agent and Tokens">
          <Info label="Agent provider" value={user.agent_provider} />
          <Info label="Codex auth mode" value={user.codex_auth_mode} />
          <Info label="Max turns" value={String(user.agent_max_turns)} />
          <Info label="Tokens" value={tokenSummary(user)} />
          <Info label="GH rate" value={rateLimitLabel(user)} />
        </InfoPanel>
      </section>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">Scheduling</h2>
        <div className="mt-3 flex items-center gap-4">
          <span className="text-sm text-gray-700 dark:text-gray-200">Status: <strong>{user.scheduling_paused ? "paused" : "active"}</strong></span>
          <SchedulingButton user={user} />
        </div>
      </section>

      <RecentTable title="Recent jobs" rows={user.recent_jobs.map((job) => [`#${job.id}`, job.state, job.kind, formatDate(job.created_at)])} />
      <RecentTable title="Recent runs" rows={user.recent_runs.map((run) => [`#${run.id}`, run.state, run.trigger_kind, formatDate(run.started_at)])} />
    </>
  )
}

function SchedulingButton({ user }: { user: AdminUserDetail }) {
  const queryClient = useQueryClient()
  const mutation = useMutation({
    mutationFn: () => user.scheduling_paused ? unpauseUserScheduling(user.id) : pauseUserScheduling(user.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(["admin", "users", String(user.id)], updated)
      void queryClient.invalidateQueries({ queryKey: ["admin", "users"] })
    }
  })

  return (
    <button
      className="rounded bg-gray-900 dark:bg-gray-100 px-3 py-1.5 text-sm font-medium text-white dark:text-gray-900 hover:bg-gray-700 dark:hover:bg-gray-200 disabled:cursor-not-allowed disabled:bg-gray-400"
      disabled={mutation.isPending}
      onClick={() => mutation.mutate()}
      type="button"
    >
      {mutation.isPending ? "Saving..." : user.scheduling_paused ? "Resume scheduling" : "Pause scheduling"}
    </button>
  )
}

function InfoPanel({ title, children }: { title: string; children: ReactNode }) {
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{title}</h2>
      <dl className="mt-3 space-y-2 text-sm">{children}</dl>
    </section>
  )
}

function Info({ label, value }: { label: string; value: ReactNode }) {
  return (
    <div className="flex justify-between gap-4">
      <dt className="text-gray-600 dark:text-gray-300">{label}</dt>
      <dd className="text-right text-gray-900 dark:text-gray-100">{value}</dd>
    </div>
  )
}

function RecentTable({ title, rows }: { title: string; rows: string[][] }) {
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-2 text-sm font-semibold text-gray-700 dark:text-gray-200">{title}</div>
      {rows.length === 0 ? (
        <PanelMessage>No rows yet.</PanelMessage>
      ) : (
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
              {rows.map((row) => (
                <tr key={row.join("-")}>{row.map((cell) => <td className="px-4 py-2" key={cell}>{cell}</td>)}</tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

function UsersError({ error }: { error: Error }) {
  const message = error instanceof ApiError ? error.message : "Unable to load users."

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-300"}`}>{children}</div>
}

function tokenSummary(user: AdminUserRow) {
  const tokens = []
  if (user.has_github_token) tokens.push("gh")
  if (user.has_claude_token) tokens.push("claude")
  if (user.has_codex_token) tokens.push("codex")
  if (user.has_api_token) tokens.push("api")
  return tokens.length > 0 ? tokens.join(", ") : "-"
}

function rateLimitLabel(user: AdminUserRow) {
  const rate = user.github_rate_limit
  if (!rate) return "-"
  const percent = rate.percent == null ? null : Math.round(rate.percent * 100)
  return `${rate.remaining} / ${rate.limit}${percent == null ? "" : ` (${percent}%)`}`
}

function formatDate(value: string | null) {
  if (!value) return "-"
  return new Date(value).toLocaleString()
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}
