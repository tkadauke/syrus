import { inputClass } from "../lib/formClasses"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { routePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent } from "react"
import { useState } from "react"
import { Link, useLocation, useParams } from "react-router-dom"
import { NoticeToast } from "../components/NoticeToast"
import { TonePill } from "../components/StatusPill"
import {
  createRepositoryMembership,
  deleteRepositoryMembership,
  fetchRepositoryMemberships,
  updateRepositoryMembershipRole,
  REPOSITORY_MEMBERSHIP_ROLES,
  type GithubCollaboratorDiscrepancy,
  type RepositoryMembership,
  type RepositoryMembershipRole,
  type RepositoryMembershipsPayload
} from "../api/repositoryMemberships"
import {
  createRepositoryTeamGrant,
  deleteRepositoryTeamGrant,
  updateRepositoryTeamGrantRole,
  type TeamRepositoryGrant
} from "../api/repositoryTeamGrants"
import { RepositoryTabs } from "../components/RepositoryTabs"
import { useT } from "../hooks/useT"
import { PanelMessage } from "../components/PanelMessage"
import { errorMessage } from "../lib/errorMessage"
import { useConfirm } from "../hooks/useConfirm"

export function RepositoryMembersRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  const params = useParams()
  const repositoryId = params.repositoryId || ""
  const memberships = useQuery({
    queryKey: ["repositories", repositoryId, "memberships"],
    queryFn: () => fetchRepositoryMemberships(repositoryId),
    enabled: repositoryId.length > 0
  })

  return (
    <main aria-label={t("aria_repo_memberships")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {memberships.isPending ? <PanelMessage>{t("repository_memberships.loading")}</PanelMessage> : null}
      {memberships.isError ? <PanelMessage tone="error">{errorMessage(memberships.error, t("repository_memberships.unable_to_load"))}</PanelMessage> : null}
      {memberships.isSuccess ? <RepositoryMembersView payload={memberships.data} prefix={routePrefix(location.pathname)} /> : null}
    </main>
  )
}

function RepositoryMembersView({ payload, prefix }: { payload: RepositoryMembershipsPayload; prefix: string }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const [notice, setNotice] = useState<string | null>(payload.message || null)
  const queryKey = ["repositories", String(payload.repository.id), "memberships"] as const

  const updateRole = useMutation({
    mutationFn: ({ membershipId, role }: { membershipId: number; role: RepositoryMembershipRole }) =>
      updateRepositoryMembershipRole(payload.repository.id, membershipId, role),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
    }
  })

  const destroy = useMutation({
    mutationFn: (membership: RepositoryMembership) => deleteRepositoryMembership(payload.repository.id, membership.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setNotice(updated.message || null)
    }
  })

  return (
    <>
      <header>
        <h1 className="break-words font-mono text-3xl font-semibold text-gray-900 dark:text-gray-100">
          <Link className="hover:underline" to={`${prefix}${payload.repository.repository_path}`}>{payload.repository.slug}</Link>
        </h1>
      </header>

      <RepositoryTabs active="members" prefix={prefix} tabs={payload.tabs} />
      <p className="text-sm text-gray-600 dark:text-gray-400">{t("repository_memberships.description")}</p>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {updateRole.isError ? <PanelMessage tone="error">{errorMessage(updateRole.error, "Unable to update role.")}</PanelMessage> : null}
      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to remove member.")}</PanelMessage> : null}

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
        <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("repository_memberships.members")}</h2>
        </div>

        {payload.memberships.length === 0 ? (
          <div className="m-4 rounded border border-dashed border-gray-300 dark:border-gray-600 px-4 py-8 text-center text-sm text-gray-600 dark:text-gray-400">
            {t("repository_memberships.empty")}
          </div>
        ) : (
          <ul className="divide-y divide-gray-100 dark:divide-gray-800 px-4">
            {payload.memberships.map((membership) => (
              <li className="flex items-center gap-3 py-3" key={membership.id}>
                <div className="min-w-0 flex-1">
                  <div className="flex flex-wrap items-center gap-2">
                    <div className="break-words text-sm font-medium text-gray-900 dark:text-gray-100">{membership.user.name}</div>
                    {membership.github_permission_mismatch_reason ? (
                      <TonePill title={t(`repository_memberships.github_mismatch_hint.${membership.github_permission_mismatch_reason}`)} tone="amber">
                        {t("repository_memberships.github_mismatch_badge")}
                      </TonePill>
                    ) : null}
                  </div>
                  <div className="break-all text-xs text-gray-500 dark:text-gray-400">{membership.user.email_address}</div>
                  <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                    {t("repository_memberships.added_at")} <RelativeTimestamp value={membership.created_at} />
                  </div>
                  {membership.github_permission_mismatch_reason ? (
                    <div className="mt-1 text-xs text-amber-700 dark:text-amber-400">
                      {t(`repository_memberships.github_mismatch_reason.${membership.github_permission_mismatch_reason}`)}
                    </div>
                  ) : null}
                </div>
                <RoleSelect
                  disabled={updateRole.isPending}
                  onChange={(role) => updateRole.mutate({ membershipId: membership.id, role })}
                  value={membership.role}
                />
                <button
                  className="shrink-0 rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:text-gray-300 dark:disabled:text-gray-600"
                  disabled={destroy.isPending}
                  onClick={async () => {
                    if (await confirm({ message: t("repository_memberships.confirm_remove", { email: membership.user.email_address }), destructive: true })) {
                      destroy.mutate(membership)
                    }
                  }}
                  type="button"
                >
                  {t("repository_memberships.remove")}
                </button>
              </li>
            ))}
          </ul>
        )}
      </section>

      <AddMemberForm onNotice={setNotice} payload={payload} />

      <TeamGrants onNotice={setNotice} payload={payload} />

      <GithubCollaboratorDiscrepancies discrepancies={payload.github_collaborator_discrepancies} />
      {dialog}
    </>
  )
}

// Direction 2 of the GitHub permission-parity check (JOB-3577): GitHub
// collaborators with write+ access and no corresponding Syrus access at
// all. Warning-severity, read-only -- Syrus never grants or revokes GitHub
// access from here. See GithubPermissionSyncer.
function GithubCollaboratorDiscrepancies({ discrepancies }: { discrepancies: GithubCollaboratorDiscrepancy[] }) {
  const { t } = useT("settings")

  if (discrepancies.length === 0) return null

  return (
    <section className="rounded border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950/30">
      <div className="border-b border-amber-200 dark:border-amber-800 px-4 py-3">
        <h2 className="text-sm font-semibold text-amber-900 dark:text-amber-200">{t("repository_memberships.github_only_collaborators")}</h2>
        <p className="mt-1 text-xs text-amber-800 dark:text-amber-300">{t("repository_memberships.github_only_collaborators_description")}</p>
      </div>
      <ul className="divide-y divide-amber-100 dark:divide-amber-900 px-4">
        {discrepancies.map((discrepancy) => (
          <li className="flex items-center gap-3 py-3" key={discrepancy.id}>
            <div className="min-w-0 flex-1">
              <div className="break-words text-sm font-medium text-amber-900 dark:text-amber-100">@{discrepancy.github_login}</div>
              <div className="mt-1 text-xs text-amber-700 dark:text-amber-400">
                {t(`repository_memberships.role_${discrepancy.github_permission}`)} {t("repository_memberships.github_only_on_github")}
              </div>
            </div>
          </li>
        ))}
      </ul>
    </section>
  )
}

function TeamGrants({ payload, onNotice }: { payload: RepositoryMembershipsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const queryKey = ["repositories", String(payload.repository.id), "memberships"] as const

  const updateRole = useMutation({
    mutationFn: ({ grantId, role }: { grantId: number; role: RepositoryMembershipRole }) =>
      updateRepositoryTeamGrantRole(payload.repository.id, grantId, role),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  const destroy = useMutation({
    mutationFn: (grant: TeamRepositoryGrant) => deleteRepositoryTeamGrant(payload.repository.id, grant.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      onNotice(updated.message || null)
    }
  })

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("repository_memberships.team_grants")}</h2>
      </div>
      <p className="px-4 pt-3 text-sm text-gray-600 dark:text-gray-400">{t("repository_memberships.team_grants_description")}</p>

      {updateRole.isError ? <div className="m-4"><PanelMessage tone="error">{errorMessage(updateRole.error, "Unable to update role.")}</PanelMessage></div> : null}
      {destroy.isError ? <div className="m-4"><PanelMessage tone="error">{errorMessage(destroy.error, "Unable to remove team grant.")}</PanelMessage></div> : null}

      {payload.team_grants.length === 0 ? (
        <div className="m-4 rounded border border-dashed border-gray-300 dark:border-gray-600 px-4 py-8 text-center text-sm text-gray-600 dark:text-gray-400">
          {t("repository_memberships.team_grants_empty")}
        </div>
      ) : (
        <ul className="divide-y divide-gray-100 dark:divide-gray-800 px-4">
          {payload.team_grants.map((grant) => (
            <li className="flex items-center gap-3 py-3" key={grant.id}>
              <div className="min-w-0 flex-1">
                <div className="break-words text-sm font-medium text-gray-900 dark:text-gray-100">{grant.team.name}</div>
                <div className="mt-1 text-xs text-gray-500 dark:text-gray-400">
                  {t("repository_memberships.added_at")} <RelativeTimestamp value={grant.created_at} />
                </div>
              </div>
              <RoleSelect
                disabled={updateRole.isPending}
                onChange={(role) => updateRole.mutate({ grantId: grant.id, role })}
                value={grant.role}
              />
              <button
                className="shrink-0 rounded bg-gray-100 dark:bg-gray-800 px-2 py-1 text-xs font-medium text-gray-700 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:text-gray-300 dark:disabled:text-gray-600"
                disabled={destroy.isPending}
                onClick={async () => {
                  if (await confirm({ message: t("repository_memberships.confirm_remove_team", { name: grant.team.name }), destructive: true })) {
                    destroy.mutate(grant)
                  }
                }}
                type="button"
              >
                {t("repository_memberships.remove")}
              </button>
            </li>
          ))}
        </ul>
      )}

      <AddTeamGrantForm onNotice={onNotice} payload={payload} />
      {dialog}
    </section>
  )
}

function AddTeamGrantForm({ payload, onNotice }: { payload: RepositoryMembershipsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const queryKey = ["repositories", String(payload.repository.id), "memberships"] as const
  const [teamName, setTeamName] = useState("")
  const [role, setRole] = useState<RepositoryMembershipRole>("read")

  const create = useMutation({
    mutationFn: () => createRepositoryTeamGrant(payload.repository.id, { team_name: teamName, role }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setTeamName("")
      setRole("read")
      onNotice(updated.message || null)
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="border-t border-gray-100 dark:border-gray-800 p-4">
      <h3 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("repository_memberships.add_team_grant")}</h3>
      {create.isError ? <div className="mt-2"><PanelMessage tone="error">{errorMessage(create.error, "Unable to add team grant.")}</PanelMessage></div> : null}
      <form className="mt-3 flex flex-wrap items-end gap-3" onSubmit={submit}>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("repository_memberships.team_name_label")}
          <div className="mt-1">
            <input
              className={inputClass()}
              onChange={(event) => setTeamName(event.target.value)}
              placeholder={t("repository_memberships.team_name_placeholder")}
              required
              type="text"
              value={teamName}
            />
          </div>
        </label>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("repository_memberships.role_label")}
          <div className="mt-1">
            <RoleSelect disabled={create.isPending} onChange={setRole} value={role} />
          </div>
        </label>
        <button className={primaryButton()} disabled={create.isPending} type="submit">
          {create.isPending ? t("repository_memberships.adding") : t("repository_memberships.add")}
        </button>
      </form>
    </section>
  )
}

function RoleSelect({ value, onChange, disabled }: { value: RepositoryMembershipRole; onChange: (role: RepositoryMembershipRole) => void; disabled: boolean }) {
  const { t } = useT("settings")
  return (
    <select
      className={`${inputClass()} w-auto`}
      disabled={disabled}
      onChange={(event) => onChange(event.target.value as RepositoryMembershipRole)}
      value={value}
    >
      {REPOSITORY_MEMBERSHIP_ROLES.map((role) => (
        <option key={role} value={role}>
          {t(`repository_memberships.role_${role}`)}
        </option>
      ))}
    </select>
  )
}

function AddMemberForm({ payload, onNotice }: { payload: RepositoryMembershipsPayload; onNotice: (message: string | null) => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const queryKey = ["repositories", String(payload.repository.id), "memberships"] as const
  const [email, setEmail] = useState("")
  const [role, setRole] = useState<RepositoryMembershipRole>("read")

  const create = useMutation({
    mutationFn: () => createRepositoryMembership(payload.repository.id, { email, role }),
    onSuccess: (updated) => {
      queryClient.setQueryData(queryKey, updated)
      setEmail("")
      setRole("read")
      onNotice(updated.message || null)
    }
  })

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    onNotice(null)
    create.mutate()
  }

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{t("repository_memberships.add_member")}</h2>
      {create.isError ? <div className="mt-2"><PanelMessage tone="error">{errorMessage(create.error, "Unable to add member.")}</PanelMessage></div> : null}
      <form className="mt-3 flex flex-wrap items-end gap-3" onSubmit={submit}>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("repository_memberships.email_label")}
          <div className="mt-1">
            <input
              className={inputClass()}
              onChange={(event) => setEmail(event.target.value)}
              placeholder={t("repository_memberships.email_placeholder")}
              required
              type="email"
              value={email}
            />
          </div>
        </label>
        <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
          {t("repository_memberships.role_label")}
          <div className="mt-1">
            <RoleSelect disabled={create.isPending} onChange={setRole} value={role} />
          </div>
        </label>
        <button className={primaryButton()} disabled={create.isPending} type="submit">
          {create.isPending ? t("repository_memberships.adding") : t("repository_memberships.add")}
        </button>
      </form>
    </section>
  )
}

function primaryButton() {
  return "rounded bg-blue-600 px-3 py-1.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
}
