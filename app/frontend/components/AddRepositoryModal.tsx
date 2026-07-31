import { useEffect, useMemo, useState } from "react"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import {
  createRepository,
  fetchNewRepositoryForm,
  fetchRepositoryBranches,
  fetchRepositoryDetail,
  fetchRepositoryOptions,
  fetchRepositoryOwners,
  type GitHubRepositoryOption,
  type RepositoryInput,
  type RepositorySavedPayload
} from "../api/repositories"
import { syncAdminGithubAppInstallations } from "../api/adminGithubApp"
import { ApiError } from "../api/client"
import { openInNewTab } from "../lib/desktopShell"
import { CloseIcon } from "./CloseIcon"
import { useT } from "../hooks/useT"

type OwnerOption = { login: string; type: "user" | "org" }

export function AddRepositoryModal({ onClose, onSaved }: { onClose: () => void; onSaved?: () => void }) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const form = useQuery({ queryKey: ["repositories", "new"], queryFn: fetchNewRepositoryForm })
  const owners = useQuery({ queryKey: ["repositories", "owners"], queryFn: fetchRepositoryOwners })

  const [values, setValues] = useState<RepositoryInput | null>(null)
  const [ownerOptions, setOwnerOptions] = useState<OwnerOption[]>([])
  const [repoOptions, setRepoOptions] = useState<GitHubRepositoryOption[]>([])
  const [branchOptions, setBranchOptions] = useState<string[]>([])
  const [loadingRepos, setLoadingRepos] = useState(false)
  const [loadingBranches, setLoadingBranches] = useState(false)
  const [ownersNotice, setOwnersNotice] = useState<string | null>(null)
  const [reposNotice, setReposNotice] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    function onKeyDown(event: KeyboardEvent) {
      if (event.key === "Escape") onClose()
    }
    document.addEventListener("keydown", onKeyDown)
    return () => document.removeEventListener("keydown", onKeyDown)
  }, [onClose])

  // Seed defaults from the standard new-repository form, then apply the
  // onboarding overrides: auto-merge on, inherit the user's default agent,
  // keep the syrus trigger label, and no upstream.
  useEffect(() => {
    if (!form.isSuccess || values) return
    const r = form.data.repository
    setValues({
      owner: "",
      name: "",
      default_branch: r.default_branch || "main",
      upstream_owner: "",
      upstream_name: "",
      upstream_default_branch: "",
      trigger_label: r.trigger_label || "syrus",
      polling_enabled: r.polling_enabled,
      prepare_enabled: r.prepare_enabled,
      pr_cost_footer_enabled: r.pr_cost_footer_enabled,
      auto_merge_enabled: true,
      trust_clean_rebase_grade: r.trust_clean_rebase_grade,
      main_branch_health_enabled: r.main_branch_health_enabled,
      main_branch_repair_enabled: r.main_branch_repair_enabled,
      main_branch_repair_auto_approve: r.main_branch_repair_auto_approve,
      treat_grader_timeouts_as_failures: r.treat_grader_timeouts_as_failures,
      fork_auto_sync_enabled: r.fork_auto_sync_enabled,
      agent_provider: "",
      auto_approve_mode: r.auto_approve_mode,
      feedback_policy: r.feedback_policy,
      epic_dependency_policy: r.epic_dependency_policy,
      github_owner_id: "",
      github_repository_id: ""
    })
  }, [form.isSuccess, form.data, values])

  // Build the User/Org dropdown from the viewer + their orgs.
  useEffect(() => {
    if (!owners.isSuccess) return
    if (owners.data.error) {
      setOwnersNotice(ownerErrorMessage(owners.data.error, t))
      return
    }
    setOwnerOptions([
      owners.data.user ? ({ login: owners.data.user, type: "user" } as OwnerOption) : null,
      ...(owners.data.orgs || []).map((org) => ({ login: org, type: "org" } as OwnerOption))
    ].filter((o): o is OwnerOption => o !== null))
  }, [owners.isSuccess, owners.data])

  const selectedOwnerType = useMemo(
    () => ownerOptions.find((o) => o.login === values?.owner)?.type || "org",
    [ownerOptions, values?.owner]
  )

  // Load repositories once a User/Org is picked.
  useEffect(() => {
    if (!values?.owner) return
    let cancelled = false
    setLoadingRepos(true)
    setReposNotice(null)
    fetchRepositoryOptions(values.owner, selectedOwnerType).then((data) => {
      if (cancelled) return
      setLoadingRepos(false)
      if (data.error || !data.repos) {
        setRepoOptions([])
        setReposNotice(repoErrorMessage(data.error, t))
        return
      }
      const options = data.repos.map((repo) =>
        typeof repo === "string" ? { name: repo, github_repository_id: null, github_owner_id: null } : repo
      )
      setRepoOptions(options)
      if (options.length === 0) setReposNotice(t('add_repository.no_repositories'))
    }).catch(() => {
      if (cancelled) return
      setLoadingRepos(false)
      setRepoOptions([])
      setReposNotice(t('add_repository.load_repos_error'))
    })
    return () => {
      cancelled = true
    }
  }, [selectedOwnerType, values?.owner])

  // Load branches once a repository is picked, then suggest main/master.
  useEffect(() => {
    if (!values?.owner || !values?.name) return
    let cancelled = false
    setLoadingBranches(true)
    fetchRepositoryBranches(values.owner, values.name).then((data) => {
      if (cancelled) return
      setLoadingBranches(false)
      const branches = data.error ? [] : data.branches || []
      setBranchOptions(branches)
      if (branches.length > 0) {
        setValues((current) => (current ? { ...current, default_branch: suggestBranch(branches, data.default_branch) } : current))
      }
    }).catch(() => {
      if (cancelled) return
      setLoadingBranches(false)
      setBranchOptions([])
    })
    return () => {
      cancelled = true
    }
  }, [values?.owner, values?.name])

  const save = useMutation({
    mutationFn: () => createRepository(values as RepositoryInput),
    onSuccess: async (payload) => {
      await queryClient.invalidateQueries({ queryKey: ["bootstrap"] })
      await queryClient.invalidateQueries({ queryKey: ["repositories"] })
      // The App install link is offered exactly when it's actionable: the
      // repo was added, the App is registered, but the owner has no active
      // installation yet. Everything else closes as before — an owner
      // already covered by an installation needs no extra step.
      if (payload.credential_status?.mode === "pat" && payload.credential_status.install_url) {
        setSaved(payload)
        return
      }
      onSaved?.()
      onClose()
    },
    onError: (err) => {
      setError(err instanceof ApiError ? err.message : t('add_repository.save_error'))
    }
  })

  const [saved, setSaved] = useState<RepositorySavedPayload | null>(null)
  const [awaitingInstall, setAwaitingInstall] = useState(false)

  // While the user is on GitHub's install page, watch for the installation
  // to land (SyncInstallationsJob links it) and flip the panel to a green
  // check the moment the App covers the repo.
  const installWatch = useQuery({
    queryKey: ["repositories", "install-watch", saved?.repository.id],
    queryFn: () => fetchRepositoryDetail(String(saved!.repository.id)),
    enabled: awaitingInstall && !!saved,
    refetchInterval: awaitingInstall ? 3000 : false
  })
  const installedNow = installWatch.data?.credential_status.mode === "app"

  // Syrus discovers installations by polling GitHub (no webhooks) — nudge
  // the server to sync while we wait so this takes seconds, not the
  // 5-minute recurring sweep. Server-side throttled; 403s for non-admins
  // are fine to ignore (the recurring sync still covers them).
  useEffect(() => {
    if (!awaitingInstall || installedNow) return
    syncAdminGithubAppInstallations().catch(() => {})
  }, [awaitingInstall, installedNow, installWatch.dataUpdatedAt])

  function chooseOwner(owner: string) {
    setRepoOptions([])
    setBranchOptions([])
    setReposNotice(null)
    setValues((current) => (current ? { ...current, owner, name: "", github_owner_id: "", github_repository_id: "" } : current))
  }

  function chooseRepo(name: string) {
    const selected = repoOptions.find((r) => r.name === name)
    setBranchOptions([])
    setValues((current) => (current ? {
      ...current,
      name,
      github_owner_id: selected?.github_owner_id == null ? "" : String(selected.github_owner_id),
      github_repository_id: selected?.github_repository_id == null ? "" : String(selected.github_repository_id)
    } : current))
  }

  function submit(event: React.FormEvent) {
    event.preventDefault()
    setError(null)
    if (!values || !values.owner || !values.name) {
      setError(t('add_repository.validation_choose'))
      return
    }
    save.mutate()
  }

  const ownersLoading = !owners.isSuccess && !ownersNotice

  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4" onClick={onClose}>
      <section
        aria-labelledby="add-repository-title"
        aria-modal="true"
        className="max-h-[calc(100vh-2rem)] w-full max-w-lg overflow-y-auto rounded-lg bg-white dark:bg-gray-900 shadow-xl"
        role="dialog"
        onClick={(event) => event.stopPropagation()}
      >
        {saved ? (
          <div className="space-y-5 p-5 sm:p-6">
            <div className="flex items-start justify-between gap-4">
              <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="add-repository-title">
                {t('add_repository.title_added')}
              </h2>
              <button
                aria-label={t('add_repository.close')}
                className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-300 focus:outline-none focus:ring-2 focus:ring-blue-500"
                onClick={() => { onSaved?.(); onClose() }}
                type="button"
              >
                <CloseIcon className="h-7 w-7" />
              </button>
            </div>

            <Box tone="ok">{t('add_repository.repository_ready', { slug: saved.repository.slug })}</Box>

            {installedNow ? (
              <Box tone="ok">
                {t('add_repository.app_connected', { owner: saved.repository.owner })}
              </Box>
            ) : (
              <>
                <p className="text-sm text-gray-600 dark:text-gray-400">
                  {t('add_repository.install_optional', { owner: saved.repository.owner })}
                </p>
                {awaitingInstall ? (
                  <p className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
                    <Spinner /> {t('add_repository.waiting_for_install')}
                  </p>
                ) : null}
                {!awaitingInstall && saved.credential_status.generic_install_url ? (
                  <p className="text-xs text-gray-500 dark:text-gray-400">
                    {t('add_repository.install_all_prefix')}{" "}
                    <button
                      className="font-medium text-blue-700 dark:text-blue-300 underline hover:no-underline"
                      type="button"
                      onClick={() => {
                        openInNewTab(saved.credential_status.generic_install_url as string)
                        setAwaitingInstall(true)
                      }}
                    >
                      {t('add_repository.install_all_button')}
                    </button>{" "}
                    {t('add_repository.install_all_suffix')}
                  </p>
                ) : null}
              </>
            )}

            <div className="flex items-center justify-end gap-3">
              {!installedNow && saved.credential_status.install_url ? (
                <button
                  className="inline-flex items-center gap-1 rounded bg-gray-900 px-3 py-2 text-sm font-medium text-white hover:bg-gray-700 dark:bg-gray-100 dark:text-gray-900 dark:hover:bg-white"
                  type="button"
                  onClick={() => {
                    openInNewTab(saved.credential_status.install_url as string)
                    setAwaitingInstall(true)
                  }}
                >
                  {t('add_repository.install_on_github')} <span aria-hidden="true">↗</span>
                </button>
              ) : null}
              <button
                className="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700"
                onClick={() => { onSaved?.(); onClose() }}
                type="button"
              >
                {t('add_repository.done')}
              </button>
            </div>
          </div>
        ) : (
        <form className="space-y-5 p-5 sm:p-6" onSubmit={submit}>
          <div className="flex items-start justify-between gap-4">
            <div>
              <h2 className="text-lg font-semibold text-gray-900 dark:text-gray-100" id="add-repository-title">
                {t('add_repository.title')}
              </h2>
              <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
                {t('add_repository.description')}
              </p>
            </div>
            <button
              aria-label={t('add_repository.close')}
              className="flex h-10 w-10 shrink-0 items-center justify-center rounded-lg text-gray-500 dark:text-gray-400 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-300 focus:outline-none focus:ring-2 focus:ring-blue-500"
              onClick={onClose}
              type="button"
            >
              <CloseIcon className="h-7 w-7" />
            </button>
          </div>

          {!values ? (
            <p className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
              <Spinner /> {t('add_repository.loading')}
            </p>
          ) : (
            <>
              <Field label={t('add_repository.field_user_org')}>
                {ownersNotice ? (
                  <Box tone="error">{ownersNotice}</Box>
                ) : ownersLoading ? (
                  <Loading>{t('add_repository.loading_accounts')}</Loading>
                ) : (
                  <select aria-label={t('add_repository.field_user_org')} className={selectClass()} onChange={(event) => chooseOwner(event.target.value)} value={values.owner}>
                    <option value="">{t('add_repository.select_user_org')}</option>
                    {ownerOptions.map((o) => <option key={o.login} value={o.login}>{o.login}</option>)}
                  </select>
                )}
              </Field>

              {values.owner ? (
                <Field label={t('add_repository.field_repository')}>
                  {loadingRepos ? (
                    <Loading>{t('add_repository.loading_repositories')}</Loading>
                  ) : reposNotice ? (
                    <Box tone="error">{reposNotice}</Box>
                  ) : (
                    <select aria-label={t('add_repository.field_repository')} className={selectClass()} onChange={(event) => chooseRepo(event.target.value)} value={values.name}>
                      <option value="">{t('add_repository.select_repository')}</option>
                      {repoOptions.map((r) => <option key={r.name} value={r.name}>{r.name}</option>)}
                    </select>
                  )}
                </Field>
              ) : null}

              {values.name ? (
                <Field label={t('add_repository.field_default_branch')}>
                  {loadingBranches ? (
                    <Loading>{t('add_repository.loading_branches')}</Loading>
                  ) : (
                    <select aria-label={t('add_repository.field_default_branch')} className={selectClass()} onChange={(event) => setValues((c) => (c ? { ...c, default_branch: event.target.value } : c))} value={values.default_branch}>
                      {branchOptions.map((branch) => <option key={branch} value={branch}>{branch}</option>)}
                    </select>
                  )}
                </Field>
              ) : null}

              <Box tone="muted">
                {t('add_repository.defaults_info_prefix', { agent: form.data?.user_agent_provider_label || t('add_repository.defaults_agent_default') })}{" "}
                <code className="rounded bg-gray-100 px-1 py-0.5 font-mono text-xs dark:bg-gray-800">{values.trigger_label}</code>{" "}
                {t('add_repository.defaults_info_suffix')}
              </Box>

              {error ? <Box tone="error">{error}</Box> : null}

              <div className="flex items-center justify-end gap-2">
                <button className="rounded-md border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm text-gray-700 dark:text-gray-300 hover:bg-gray-50 dark:hover:bg-gray-800" onClick={onClose} type="button">
                  {t('add_repository.cancel')}
                </button>
                <button className="inline-flex items-center gap-2 rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-60" disabled={save.isPending || !values.owner || !values.name} type="submit">
                  {save.isPending ? <><Spinner light /> {t('add_repository.adding')}</> : t('add_repository.add_repository')}
                </button>
              </div>
            </>
          )}
        </form>
        )}
      </section>
    </div>
  )
}

function suggestBranch(branches: string[], defaultBranch: string | undefined) {
  if (defaultBranch && branches.includes(defaultBranch)) return defaultBranch
  if (branches.includes("main")) return "main"
  if (branches.includes("master")) return "master"
  return branches[0] || "main"
}

function Field({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function Loading({ children }: { children: React.ReactNode }) {
  return (
    <p className="flex items-center gap-2 text-sm text-gray-500 dark:text-gray-400" role="status">
      <Spinner /> {children}
    </p>
  )
}

function Box({ tone, children }: { tone: "muted" | "error" | "ok"; children: React.ReactNode }) {
  const toneClass = tone === "error"
    ? "border-red-200 bg-red-50 text-red-700 dark:border-red-900 dark:bg-red-950/40 dark:text-red-300"
    : tone === "ok"
      ? "border-green-200 bg-green-50 text-green-800 dark:border-green-900 dark:bg-green-950/40 dark:text-green-300"
      : "border-gray-200 bg-gray-50 text-gray-600 dark:border-gray-700 dark:bg-gray-800/50 dark:text-gray-400"
  const role = tone === "error" ? "alert" : tone === "ok" ? "status" : undefined
  return <p className={`rounded border px-3 py-2 text-sm ${toneClass}`} role={role}>{children}</p>
}

function Spinner({ light }: { light?: boolean }) {
  return (
    <svg aria-hidden="true" className={`h-4 w-4 animate-spin ${light ? "text-white" : "text-gray-400"}`} fill="none" viewBox="0 0 24 24">
      <circle className="opacity-25" cx="12" cy="12" r="10" stroke="currentColor" strokeWidth="4" />
      <path className="opacity-75" d="M4 12a8 8 0 018-8" fill="currentColor" />
    </svg>
  )
}

function selectClass() {
  return "block w-full rounded border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-2 text-sm font-mono shadow-sm focus:outline-blue-600"
}

type TFunction = (key: string) => string

function ownerErrorMessage(error: string, t: TFunction) {
  if (error === "no_token") return t('add_repository.owner_error_no_token')
  if (error === "unauthorized") return t('add_repository.owner_error_unauthorized')
  return t('add_repository.owner_error_default')
}

function repoErrorMessage(error: string | undefined, t: TFunction) {
  if (error === "no_token") return t('add_repository.repo_error_no_token')
  if (error === "not_found") return t('add_repository.repo_error_not_found')
  return t('add_repository.repo_error_default')
}
