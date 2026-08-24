import { inputClass } from "../lib/formClasses"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { Link, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { AdminFiltersLayout } from "../components/AdminFiltersLayout"
import { NoticeToast } from "../components/NoticeToast"
import { PanelMessage } from "../components/PanelMessage"
import { errorMessage } from "../lib/errorMessage"
import { useConfirm } from "../hooks/useConfirm"
import {
  addTeamMember,
  createAdminTeam,
  deleteAdminTeam,
  fetchAdminTeam,
  fetchAdminTeams,
  removeTeamMember,
  renameAdminTeam,
  updateTeamMemberRole,
  TEAM_MEMBERSHIP_ROLES,
  type AdminTeamDetailPayload,
  type AdminTeamRow,
  type TeamMembership,
  type TeamMembershipRole
} from "../api/adminTeams"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"

export function AdminTeamsIndex() {
  const { t } = useT("admin")
  usePageTitle(t("page_title_teams"))
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(null)
  const teams = useQuery({
    queryKey: ["admin", "teams"],
    queryFn: () => fetchAdminTeams()
  })

  const create = useMutation({
    mutationFn: (name: string) => createAdminTeam(name),
    onSuccess: (payload) => {
      queryClient.setQueryData(["admin", "teams"], payload)
      setNotice(payload.message || null)
    }
  })

  return (
    <main aria-label={t("teams.aria_index")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <div>
          <p className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{t("section_label")}</p>
          <h1 className="mt-1 text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("teams.heading")}</h1>
        </div>
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />

      {teams.isPending ? <PanelMessage>{t("teams.loading")}</PanelMessage> : null}
      {teams.isError ? <TeamsError error={teams.error} /> : null}
      {teams.isSuccess ? (
        <AdminFiltersLayout>
          <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
            <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3 text-sm text-gray-600 dark:text-gray-300">{t("teams.matching", { count: teams.data.teams.length })}</div>
            <TeamsTable teams={teams.data.teams} />
          </section>

          <CreateTeamForm
            error={create.isError ? errorMessage(create.error, t("teams.error_create")) : null}
            onSubmit={(name) => create.mutate(name)}
            pending={create.isPending}
          />
        </AdminFiltersLayout>
      ) : null}
    </main>
  )
}

function TeamsTable({ teams }: { teams: AdminTeamRow[] }) {
  const { t } = useT("admin")
  if (teams.length === 0) return <PanelMessage>{t("teams.no_match")}</PanelMessage>

  return (
    <div className="overflow-x-auto">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("teams.col_name")}</th>
            <th className="px-4 py-2">{t("teams.col_members")}</th>
            <th className="px-4 py-2">{t("teams.col_repositories")}</th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {teams.map((team) => (
            <tr className="hover:bg-gray-50 dark:hover:bg-gray-800" key={team.id}>
              <td className="px-4 py-2">
                <Link className="text-blue-600 dark:text-blue-300 underline hover:no-underline" to={`/admin/teams/${team.id}`}>{team.name}</Link>
              </td>
              <td className="px-4 py-2">{team.member_count}</td>
              <td className="px-4 py-2">{team.repository_count}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function CreateTeamForm({ onSubmit, pending, error }: { onSubmit: (name: string) => void; pending: boolean; error: string | null }) {
  const { t } = useT("admin")
  const [name, setName] = useState("")

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!name.trim()) return
    onSubmit(name.trim())
    setName("")
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("teams.create_team")}</h2>
      {error ? <div className="mt-2"><PanelMessage tone="error">{error}</PanelMessage></div> : null}
      <form className="mt-3 flex flex-wrap items-end gap-3" onSubmit={submit}>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("teams.name_label")}
          <div className="mt-1">
            <input
              className={inputClass()}
              onChange={(event) => setName(event.target.value)}
              placeholder={t("teams.name_placeholder")}
              required
              type="text"
              value={name}
            />
          </div>
        </label>
        <button className={primaryButton()} disabled={pending} type="submit">
          {pending ? t("teams.creating") : t("teams.create")}
        </button>
      </form>
    </section>
  )
}

export function AdminTeamDetailRoute() {
  const { t } = useT("admin")
  const params = useParams()
  const id = params.id || ""
  const team = useQuery({
    queryKey: ["admin", "teams", id],
    queryFn: () => fetchAdminTeam(id),
    enabled: id.length > 0
  })

  return (
    <main aria-label={t("teams.aria_detail")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="border-b border-gray-200 dark:border-gray-700 pb-4">
        <Link className="text-sm text-blue-600 dark:text-blue-300 underline hover:no-underline" to="/admin/teams">{t("teams.heading")}</Link>
        <h1 className="mt-2 text-2xl font-semibold text-gray-900 dark:text-gray-100">{team.data?.team.name || `Team #${id}`}</h1>
      </header>

      {team.isPending ? <PanelMessage>{t("teams.loading_team")}</PanelMessage> : null}
      {team.isError ? <TeamsError error={team.error} /> : null}
      {team.isSuccess ? <TeamDetail payload={team.data} /> : null}
    </main>
  )
}

function TeamDetail({ payload }: { payload: AdminTeamDetailPayload }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const teamId = payload.team.id
  const queryKey = ["admin", "teams", String(teamId)] as const

  const rename = useMutation({
    mutationFn: (name: string) => renameAdminTeam(teamId, name),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
    }
  })

  const destroy = useMutation({
    mutationFn: () => deleteAdminTeam(teamId),
    onSuccess: () => {
      void queryClient.invalidateQueries({ queryKey: ["admin", "teams"] })
      window.location.assign("/admin/teams")
    }
  })

  return (
    <>
      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {!payload.can_manage ? <PanelMessage>{t("teams.cannot_manage")}</PanelMessage> : null}
      {rename.isError ? <PanelMessage tone="error">{errorMessage(rename.error, t("teams.error_rename"))}</PanelMessage> : null}
      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, t("teams.error_delete"))}</PanelMessage> : null}

      {payload.can_manage ? (
        <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
          <h2 className="text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("teams.heading")}</h2>
          <RenameTeamForm disabled={rename.isPending} initialName={payload.team.name} onSubmit={(name) => rename.mutate(name)} />
          <div className="mt-4 border-t border-gray-100 dark:border-gray-800 pt-4">
            <button
              className="rounded bg-red-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-red-500 disabled:cursor-not-allowed disabled:bg-red-300"
              disabled={destroy.isPending}
              onClick={async () => {
                if (await confirm({ message: t("teams.confirm_delete", { name: payload.team.name }), destructive: true })) {
                  destroy.mutate()
                }
              }}
              type="button"
            >
              {destroy.isPending ? t("teams.deleting") : t("teams.delete")}
            </button>
          </div>
        </section>
      ) : null}

      <TeamMembers canManage={payload.can_manage} memberships={payload.memberships} teamId={teamId} />
      <TeamRepositoryGrants payload={payload} />
      {dialog}
    </>
  )
}

function RenameTeamForm({ initialName, onSubmit, disabled }: { initialName: string; onSubmit: (name: string) => void; disabled: boolean }) {
  const { t } = useT("admin")
  const [name, setName] = useState(initialName)

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    if (!name.trim() || name.trim() === initialName) return
    onSubmit(name.trim())
  }

  return (
    <form className="mt-3 flex flex-wrap items-end gap-3" onSubmit={submit}>
      <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
        {t("teams.name_label")}
        <div className="mt-1">
          <input className={inputClass()} disabled={disabled} onChange={(event) => setName(event.target.value)} required type="text" value={name} />
        </div>
      </label>
      <button className={primaryButton()} disabled={disabled} type="submit">
        {disabled ? t("teams.renaming") : t("teams.rename")}
      </button>
    </form>
  )
}

function TeamMembers({ teamId, memberships, canManage }: { teamId: number; memberships: TeamMembership[]; canManage: boolean }) {
  const { t } = useT("admin")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const queryKey = ["admin", "teams", String(teamId)] as const

  const updateRole = useMutation({
    mutationFn: ({ membershipId, role }: { membershipId: number; role: TeamMembershipRole }) => updateTeamMemberRole(teamId, membershipId, role),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })

  const destroy = useMutation({
    mutationFn: (membership: TeamMembership) => removeTeamMember(teamId, membership.id),
    onSuccess: (updated) => queryClient.setQueryData(queryKey, updated)
  })

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("teams.members")}</h2>
      </div>

      {updateRole.isError ? <div className="m-4"><PanelMessage tone="error">{errorMessage(updateRole.error, t("teams.error_update_role"))}</PanelMessage></div> : null}
      {destroy.isError ? <div className="m-4"><PanelMessage tone="error">{errorMessage(destroy.error, t("teams.error_remove_member"))}</PanelMessage></div> : null}

      {memberships.length === 0 ? (
        <div className="m-4 rounded border border-dashed border-gray-300 dark:border-gray-600 px-4 py-8 text-center text-sm text-gray-600 dark:text-gray-400">
          {t("teams.no_members")}
        </div>
      ) : (
        <ul className="divide-y divide-gray-100 dark:divide-gray-800 px-4">
          {memberships.map((membership) => (
            <li className="flex items-center gap-3 py-3" key={membership.id}>
              <div className="min-w-0 flex-1">
                <div className="break-words text-sm font-medium text-gray-900 dark:text-gray-100">{membership.user.name}</div>
                <div className="break-all text-xs text-gray-500 dark:text-gray-400">{membership.user.email_address}</div>
                <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                  {t("teams.added_at")} <RelativeTimestamp value={membership.created_at} />
                </div>
              </div>
              {canManage ? (
                <>
                  <TeamRoleSelect
                    disabled={updateRole.isPending}
                    onChange={(role) => updateRole.mutate({ membershipId: membership.id, role })}
                    value={membership.role}
                  />
                  <button
                    className="shrink-0 rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:text-gray-300 dark:disabled:text-gray-600"
                    disabled={destroy.isPending}
                    onClick={async () => {
                      if (await confirm({ message: t("teams.confirm_remove_member", { email: membership.user.email_address }), destructive: true })) {
                        destroy.mutate(membership)
                      }
                    }}
                    type="button"
                  >
                    {t("teams.remove")}
                  </button>
                </>
              ) : (
                <span className="text-xs text-gray-500 dark:text-gray-400">{t(`teams.role_${membership.role}`)}</span>
              )}
            </li>
          ))}
        </ul>
      )}

      {canManage ? <AddMemberForm teamId={teamId} /> : null}
      {dialog}
    </section>
  )
}

function TeamRoleSelect({ value, onChange, disabled }: { value: TeamMembershipRole; onChange: (role: TeamMembershipRole) => void; disabled: boolean }) {
  const { t } = useT("admin")
  return (
    <select
      className={inputClass({ fullWidth: false })}
      disabled={disabled}
      onChange={(event) => onChange(event.target.value as TeamMembershipRole)}
      value={value}
    >
      {TEAM_MEMBERSHIP_ROLES.map((role) => (
        <option key={role} value={role}>
          {t(`teams.role_${role}`)}
        </option>
      ))}
    </select>
  )
}

function AddMemberForm({ teamId }: { teamId: number }) {
  const { t } = useT("admin")
  const queryClient = useQueryClient()
  const queryKey = ["admin", "teams", String(teamId)] as const
  const [email, setEmail] = useState("")
  const [role, setRole] = useState<TeamMembershipRole>("member")

  const create = useMutation({
    mutationFn: () => addTeamMember(teamId, { email, role }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setEmail("")
      setRole("member")
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    create.mutate()
  }

  return (
    <div className="border-t border-gray-100 dark:border-gray-800 p-4">
      <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("teams.add_member")}</h3>
      {create.isError ? <div className="mt-2"><PanelMessage tone="error">{errorMessage(create.error, t("teams.error_add_member"))}</PanelMessage></div> : null}
      <form className="mt-3 flex flex-wrap items-end gap-3" onSubmit={submit}>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("teams.email_label")}
          <div className="mt-1">
            <input
              className={inputClass()}
              onChange={(event) => setEmail(event.target.value)}
              placeholder={t("teams.email_placeholder")}
              required
              type="email"
              value={email}
            />
          </div>
        </label>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("teams.role_label")}
          <div className="mt-1">
            <TeamRoleSelect disabled={create.isPending} onChange={setRole} value={role} />
          </div>
        </label>
        <button className={primaryButton()} disabled={create.isPending} type="submit">
          {create.isPending ? t("teams.adding") : t("teams.add")}
        </button>
      </form>
    </div>
  )
}

function TeamRepositoryGrants({ payload }: { payload: AdminTeamDetailPayload }) {
  const { t } = useT("admin")
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("teams.repository_grants")}</h2>
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("teams.repository_grants_description")}</p>
      </div>
      {payload.repository_grants.length === 0 ? (
        <div className="m-4 rounded border border-dashed border-gray-300 dark:border-gray-600 px-4 py-8 text-center text-sm text-gray-600 dark:text-gray-400">
          {t("teams.no_repository_grants")}
        </div>
      ) : (
        <ul className="divide-y divide-gray-100 dark:divide-gray-800 px-4">
          {payload.repository_grants.map((grant) => (
            <li className="flex items-center justify-between gap-3 py-3" key={grant.id}>
              <span className="text-sm font-mono text-gray-900 dark:text-gray-100">{grant.repository.slug}</span>
              <span className="text-xs font-medium uppercase text-gray-500 dark:text-gray-400">{grant.role}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  )
}

function TeamsError({ error }: { error: Error }) {
  const { t } = useT("admin")
  const message = error instanceof ApiError ? error.message : t("teams.error_load")

  return <PanelMessage tone="error">{message}</PanelMessage>
}

function primaryButton() {
  return "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
}
