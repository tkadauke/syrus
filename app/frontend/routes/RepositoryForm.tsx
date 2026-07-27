import { routePrefix, withRoutePrefix } from "../lib/routing"
import { inputClass } from "../lib/formClasses"
import { useMutation, useQuery } from "@tanstack/react-query"
import type { TFunction } from "i18next"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useMemo, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import {
  createRepository,
  fetchEditRepositoryForm,
  fetchNewRepositoryForm,
  fetchRepositoryBranches,
  fetchRepositoryOptions,
  fetchRepositoryOwners,
  type GitHubRepositoryOption,
  type RepositoryFormPayload,
  type RepositoryInput,
  syncFork,
  updateRepository
} from "../api/repositories"
import { useT } from "../hooks/useT"
import { errorMessage } from "../lib/errorMessage"
import { PanelMessage } from "../components/PanelMessage"

type OwnerOption = {
  login: string
  type: "user" | "org"
}

export function RepositoryFormRoute({ mode }: { mode: "new" | "edit" }) {
  const { t } = useT("settings")
  const params = useParams()
  const location = useLocation()
  const id = params.id || ""
  const prefix = routePrefix(location.pathname)
  const form = useQuery({
    queryKey: ["repositories", mode, id],
    queryFn: () => mode === "new" ? fetchNewRepositoryForm() : fetchEditRepositoryForm(id),
    enabled: mode === "new" || id.length > 0
  })

  return (
    <main aria-label={mode === "new" ? t('repository_form.aria_new') : t('repository_form.aria_edit')} className="mx-auto max-w-3xl space-y-6 p-6">
      {form.isPending ? <PanelMessage>{t('repository_form.loading')}</PanelMessage> : null}
      {form.isError ? <PanelMessage tone="error">{errorMessage(form.error, t('repository_form.error_load'))}</PanelMessage> : null}
      {form.isSuccess ? <RepositoryForm mode={mode} payload={form.data} prefix={prefix} /> : null}
    </main>
  )
}

function RepositoryForm({ mode, payload, prefix }: { mode: "new" | "edit"; payload: RepositoryFormPayload; prefix: string }) {
  const { t } = useT("settings")
  const navigate = useNavigate()
  const [values, setValues] = useState<RepositoryInput>(() => inputFromPayload(payload))
  const [repairTouched, setRepairTouched] = useState(mode === "edit")
  const [ownerMode, setOwnerMode] = useState<"select" | "manual">("manual")
  const [repoMode, setRepoMode] = useState<"select" | "manual">("manual")
  const [branchMode, setBranchMode] = useState<"select" | "manual">("manual")
  const [ownerOptions, setOwnerOptions] = useState<OwnerOption[]>([])
  const [ownerNotice, setOwnerNotice] = useState<string | null>(null)
  const [repoOptions, setRepoOptions] = useState<GitHubRepositoryOption[]>([])
  const [repoNotice, setRepoNotice] = useState<{ text: string; tone: "error" | "muted" } | null>(null)
  const [branchOptions, setBranchOptions] = useState<string[]>([])
  const save = useMutation({
    mutationFn: () => {
      if (mode === "new") return createRepository(values)
      return updateRepository(Number(payload.repository.id), values)
    },
    onSuccess: (saved) => navigate(withRoutePrefix(saved.redirect_to, prefix))
  })

  const syncNow = useMutation({
    mutationFn: () => syncFork(Number(payload.repository.id))
  })

  const owners = useQuery({
    queryKey: ["repositories", "owners"],
    queryFn: fetchRepositoryOwners,
    staleTime: 60_000
  })

  const selectedOwnerType = useMemo(() => (
    ownerOptions.find((owner) => owner.login === values.owner)?.type || "org"
  ), [ownerOptions, values.owner])

  useEffect(() => {
    setValues(inputFromPayload(payload))
    setRepairTouched(mode === "edit")
    setRepoOptions([])
    setBranchOptions([])
    setRepoNotice(null)
  }, [mode, payload])

  useEffect(() => {
    if (!owners.isSuccess) return
    if (owners.data.error) {
      setOwnerNotice(ownerErrorMessage(t, owners.data.error))
      setOwnerMode("manual")
      return
    }

    const options = [
      owners.data.user ? { login: owners.data.user, type: "user" as const } : null,
      ...(owners.data.orgs || []).map((org) => ({ login: org, type: "org" as const }))
    ].filter((owner): owner is OwnerOption => owner !== null)

    setOwnerOptions(options)
    if (options.length > 0) {
      setOwnerMode("select")
      setOwnerNotice(null)
    }
  }, [owners.isSuccess, owners.data])

  useEffect(() => {
    if (ownerMode !== "select" || !values.owner) return

    let active = true
    fetchRepositoryOptions(values.owner, selectedOwnerType).then((data) => {
      if (!active) return
      if (data.error) {
        setRepoNotice(repoErrorMessage(t, data.error))
        setRepoMode("manual")
        setRepoOptions([])
        return
      }

      const options = (data.repos || []).map((repo) => typeof repo === "string" ? {
        name: repo,
        github_owner_id: null,
        github_repository_id: null
      } : repo)

      setRepoOptions(options)
      setRepoNotice(null)
      if (options.length > 0) setRepoMode("select")
    }).catch(() => {
      if (!active) return
      setRepoNotice({ text: t('repository_form.repo_err_generic'), tone: "muted" })
      setRepoMode("manual")
      setRepoOptions([])
    })

    return () => { active = false }
  }, [ownerMode, selectedOwnerType, values.owner])

  useEffect(() => {
    if (!values.owner || !values.name) return

    let active = true
    const timer = window.setTimeout(() => {
      fetchRepositoryBranches(values.owner, values.name).then((data) => {
        if (!active) return
        if (data.error) {
          if (data.error === "not_found") setRepoNotice({ text: t('repository_form.repo_branch_not_found'), tone: "error" })
          setBranchMode("manual")
          setBranchOptions([])
          return
        }

        setRepoNotice(null)
        setBranchOptions(data.branches || [])
        if ((data.branches || []).length > 0) {
          setBranchMode("select")
          setValues((current) => ({
            ...current,
            default_branch: current.default_branch || data.default_branch || data.branches?.[0] || "main"
          }))
        }
      }).catch(() => {
        if (!active) return
        setBranchMode("manual")
        setBranchOptions([])
      })
    }, 350)

    return () => {
      active = false
      window.clearTimeout(timer)
    }
  }, [values.owner, values.name])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    save.mutate()
  }

  function chooseOwner(owner: string) {
    setValues({
      ...values,
      owner,
      name: "",
      github_owner_id: "",
      github_repository_id: "",
      default_branch: "main"
    })
    setRepoOptions([])
    setBranchOptions([])
    setRepoNotice(null)
  }

  function chooseRepository(name: string) {
    const selected = repoOptions.find((repo) => repo.name === name)
    setValues({
      ...values,
      name,
      github_owner_id: selected?.github_owner_id == null ? "" : String(selected.github_owner_id),
      github_repository_id: selected?.github_repository_id == null ? "" : String(selected.github_repository_id),
      default_branch: ""
    })
    setBranchOptions([])
  }

  function updateUpstream(field: "upstream_owner" | "upstream_name" | "upstream_default_branch", value: string) {
    const next = { ...values, [field]: value }
    if (!repairTouched && next.upstream_owner.trim() && next.upstream_name.trim()) {
      next.main_branch_repair_enabled = false
    }
    setValues(next)
  }

  const title = mode === "new"
    ? t('repository_form.heading_new')
    : t('repository_form.heading_edit', { slug: payload.repository.slug || `${payload.repository.owner}/${payload.repository.name}` })

  return (
    <>
      <header className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <h1 className="break-words text-3xl font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
        {mode === "edit" && payload.repository.repository_path ? <Link className="text-sm text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(payload.repository.repository_path, prefix)}>
          {t('repository_form.back')}
        </Link> : null}
      </header>

      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, t('repository_form.error_save'))}</PanelMessage> : null}
      {ownerNotice ? <PanelMessage>{ownerNotice}</PanelMessage> : null}
      {repoNotice ? <PanelMessage tone={repoNotice.tone}>{repoNotice.text}</PanelMessage> : null}

      <form className="space-y-5" onSubmit={submit}>
        <section className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
          <div>
            <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
              {t('repository_form.working_section')}
            </h2>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              {t('repository_form.working_description')}
            </p>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label={t('repository_form.label_working_owner')}>
              {ownerMode === "select" && ownerOptions.length > 0 ? (
                <SelectWithManual
                  label={t('repository_form.label_working_owner')}
                  onManual={() => setOwnerMode("manual")}
                  onChange={chooseOwner}
                  value={values.owner}
                >
                  <option value="">
                    {t('repository_form.select_owner')}
                  </option>
                  {ownerOptions.map((owner) => <option key={owner.login} value={owner.login}>{owner.login}</option>)}
                </SelectWithManual>
              ) : (
                <input
                  aria-label={t('repository_form.label_working_owner')}
                  className={`${inputClass()} font-mono`}
                  onChange={(event) => {
                    setValues({ ...values, owner: event.target.value, github_owner_id: "", github_repository_id: "" })
                    setRepoMode("manual")
                  }}
                  required
                  type="text"
                  value={values.owner}
                />
              )}
            </Field>

            <Field label={t('repository_form.label_working_name')}>
              {repoMode === "select" && repoOptions.length > 0 ? (
                <SelectWithManual
                  label={t('repository_form.label_working_name')}
                  onManual={() => {
                    setRepoMode("manual")
                    setValues({ ...values, github_owner_id: "", github_repository_id: "" })
                  }}
                  onChange={chooseRepository}
                  value={values.name}
                >
                  <option value="">
                    {t('repository_form.select_repo')}
                  </option>
                  {repoOptions.map((repo) => <option key={repo.name} value={repo.name}>{repo.name}</option>)}
                </SelectWithManual>
              ) : (
                <input
                  aria-label={t('repository_form.label_working_name')}
                  className={`${inputClass()} font-mono`}
                  onChange={(event) => setValues({ ...values, name: event.target.value, github_owner_id: "", github_repository_id: "" })}
                  required
                  type="text"
                  value={values.name}
                />
              )}
            </Field>
          </div>

          <Field label={t('repository_form.label_default_branch')}>
            {branchMode === "select" && branchOptions.length > 0 ? (
              <select
                aria-label={t('repository_form.label_default_branch')}
                className={`${inputClass()} font-mono`}
                onChange={(event) => setValues({ ...values, default_branch: event.target.value })}
                required
                value={values.default_branch}
              >
                {branchOptions.map((branch) => <option key={branch} value={branch}>{branch}</option>)}
              </select>
            ) : (
              <input
                aria-label={t('repository_form.label_default_branch')}
                className={`${inputClass()} font-mono`}
                onChange={(event) => setValues({ ...values, default_branch: event.target.value })}
                required
                type="text"
                value={values.default_branch}
              />
            )}
          </Field>

          <Field label={t('repository_form.label_trigger')}>
            <input
              aria-label={t('repository_form.label_trigger')}
              className={`${inputClass()} font-mono`}
              onChange={(event) => setValues({ ...values, trigger_label: event.target.value })}
              required
              type="text"
              value={values.trigger_label}
            />
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              {t('repository_form.trigger_hint')}
            </p>
          </Field>
        </section>

        <section className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
          <div>
            <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
              {t('repository_form.upstream_section')}
            </h2>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              {t('repository_form.upstream_description')}
            </p>
          </div>
          <div className="grid gap-4 sm:grid-cols-2">
            <Field label={t('repository_form.label_upstream_owner')}>
              <input
                aria-label={t('repository_form.label_upstream_owner')}
                className={`${inputClass()} font-mono`}
                onChange={(event) => updateUpstream("upstream_owner", event.target.value)}
                type="text"
                value={values.upstream_owner}
              />
            </Field>

            <Field label={t('repository_form.label_upstream_name')}>
              <input
                aria-label={t('repository_form.label_upstream_name')}
                className={`${inputClass()} font-mono`}
                onChange={(event) => updateUpstream("upstream_name", event.target.value)}
                type="text"
                value={values.upstream_name}
              />
            </Field>
          </div>

          <Field label={t('repository_form.label_upstream_branch')}>
            <input
              aria-label={t('repository_form.label_upstream_branch')}
              className={`${inputClass()} font-mono`}
              onChange={(event) => updateUpstream("upstream_default_branch", event.target.value)}
              type="text"
              value={values.upstream_default_branch}
            />
          </Field>
        </section>

        <section className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
            {t('repository_form.automation_section')}
          </h2>
          <Field label={t('repository_form.label_default_agent')}>
            <select
              aria-label={t('repository_form.label_default_agent')}
              className={inputClass()}
              onChange={(event) => setValues({ ...values, agent_provider: event.target.value })}
              value={values.agent_provider}
            >
              <option value="">
                {t('repository_form.agent_default', { provider: payload.user_agent_provider_label })}
              </option>
              {payload.configured_agent_providers.map((provider) => (
                <option key={provider.value} value={provider.value}>{provider.label}</option>
              ))}
            </select>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              {t('repository_form.agent_hint')}
            </p>
          </Field>

          <Field label={t('repository_form.label_auto_approve')}>
            <select
              aria-label={t('repository_form.label_auto_approve')}
              className={inputClass()}
              onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })}
              value={values.auto_approve_mode}
            >
              {payload.auto_approve_modes.map((modeOption) => (
                <option key={modeOption.value} value={modeOption.value}>{modeOption.label}</option>
              ))}
            </select>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{payload.auto_approve_modes.find((option) => option.value === values.auto_approve_mode)?.preview}</p>
          </Field>

          <Checkbox label={t('repository_form.check_polling')} onChange={(checked) => setValues({ ...values, polling_enabled: checked })} value={values.polling_enabled} />
          <Checkbox label={t('repository_form.check_prepare')} onChange={(checked) => setValues({ ...values, prepare_enabled: checked })} value={values.prepare_enabled} />
          <Checkbox label={t('repository_form.check_cost_footer')} onChange={(checked) => setValues({ ...values, pr_cost_footer_enabled: checked })} value={values.pr_cost_footer_enabled} />
          <Checkbox label={t('repository_form.check_auto_merge')} onChange={(checked) => setValues({ ...values, auto_merge_enabled: checked })} value={values.auto_merge_enabled} />
          <Checkbox label={t('repository_form.check_trust_rebase')} onChange={(checked) => setValues({ ...values, trust_clean_rebase_grade: checked })} value={values.trust_clean_rebase_grade} />
          <Checkbox label={t('repository_form.check_main_health')} onChange={(checked) => setValues({ ...values, main_branch_health_enabled: checked })} value={values.main_branch_health_enabled} />
          <Checkbox label={t('repository_form.check_main_repair')} onChange={(checked) => {
            setRepairTouched(true)
            setValues({ ...values, main_branch_repair_enabled: checked })
          }} value={values.main_branch_repair_enabled} />
          <Checkbox label={t('repository_form.check_repair_auto_approve')} onChange={(checked) => setValues({ ...values, main_branch_repair_auto_approve: checked })} value={values.main_branch_repair_auto_approve} />
          <Checkbox
            label={t('repository_form.check_timeout_failures')}
            onChange={(checked) => setValues({ ...values, treat_grader_timeouts_as_failures: checked })}
            value={values.treat_grader_timeouts_as_failures}
          />
          <p className="-mt-2 text-xs text-gray-500 dark:text-gray-400">
            {t('repository_form.timeout_hint')}
          </p>

          {mode === "edit" && payload.repository.fork_syncable ? (
            <div className="space-y-2 rounded border border-gray-200 dark:border-gray-700 p-3">
              <Checkbox
                label={t('repository_form.fork_auto_sync_label')}
                onChange={(checked) => setValues({ ...values, fork_auto_sync_enabled: checked })}
                value={values.fork_auto_sync_enabled}
              />
              <p className="text-xs text-gray-500 dark:text-gray-400">{t('repository_form.fork_auto_sync_hint')}</p>
              <div className="flex items-center gap-3">
                <button
                  className="rounded border border-gray-300 px-3 py-1 text-sm hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-300 dark:border-gray-600 dark:hover:bg-gray-800"
                  disabled={syncNow.isPending}
                  onClick={() => syncNow.mutate()}
                  type="button"
                >
                  {syncNow.isPending ? t('repository_form.fork_sync_syncing') : t('repository_form.fork_sync_now')}
                </button>
                {syncNow.isSuccess ? (
                  <span className="text-xs text-emerald-600 dark:text-emerald-400">{syncNow.data?.message || t('repository_form.fork_sync_started')}</span>
                ) : null}
                {syncNow.isError ? (
                  <span className="text-xs text-red-600 dark:text-red-400">{t('repository_form.fork_sync_failed')}</span>
                ) : null}
              </div>
            </div>
          ) : null}

          <Field label={t('repository_form.label_feedback_policy')}>
            <select
              aria-label={t('repository_form.label_feedback_policy')}
              className={inputClass()}
              onChange={(event) => setValues({ ...values, feedback_policy: event.target.value })}
              value={values.feedback_policy}
            >
              <option value="confirm">{t('repository_form.feedback_confirm')}</option>
              <option value="auto">{t('repository_form.feedback_auto')}</option>
            </select>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              {t('repository_form.feedback_hint')}
            </p>
          </Field>
        </section>

        <section className="space-y-3">
          <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
            {t('repository_form.credential_section')}
          </h2>
          <CredentialModeComparison />
        </section>

        <div className="flex items-center gap-3">
          <button className="rounded bg-blue-600 px-3.5 py-2.5 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900" disabled={save.isPending} type="submit">
            {save.isPending ? t('repository_form.saving') : mode === "new" ? t('repository_form.create') : t('repository_form.save')}
          </button>
          <Link className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-100" to={withRoutePrefix(payload.repositories_path, prefix)}>
            {t('repository_form.cancel')}
          </Link>
        </div>
      </form>
    </>
  )
}

function inputFromPayload(payload: RepositoryFormPayload): RepositoryInput {
  return {
    owner: payload.repository.owner,
    name: payload.repository.name,
    default_branch: payload.repository.default_branch,
    upstream_owner: payload.repository.upstream_owner,
    upstream_name: payload.repository.upstream_name,
    upstream_default_branch: payload.repository.upstream_default_branch,
    trigger_label: payload.repository.trigger_label,
    polling_enabled: payload.repository.polling_enabled,
    prepare_enabled: payload.repository.prepare_enabled,
    pr_cost_footer_enabled: payload.repository.pr_cost_footer_enabled,
    auto_merge_enabled: payload.repository.auto_merge_enabled,
    trust_clean_rebase_grade: payload.repository.trust_clean_rebase_grade,
    main_branch_health_enabled: payload.repository.main_branch_health_enabled,
    main_branch_repair_enabled: payload.repository.main_branch_repair_enabled,
    main_branch_repair_auto_approve: payload.repository.main_branch_repair_auto_approve,
    treat_grader_timeouts_as_failures: payload.repository.treat_grader_timeouts_as_failures,
    fork_auto_sync_enabled: payload.repository.fork_auto_sync_enabled,
    agent_provider: payload.repository.agent_provider,
    auto_approve_mode: payload.repository.auto_approve_mode,
    feedback_policy: payload.repository.feedback_policy,
    github_owner_id: payload.repository.github_owner_id == null ? "" : String(payload.repository.github_owner_id),
    github_repository_id: payload.repository.github_repository_id == null ? "" : String(payload.repository.github_repository_id)
  }
}

function SelectWithManual({
  children,
  label,
  onChange,
  onManual,
  value
}: {
  children: ReactNode
  label: string
  onChange: (value: string) => void
  onManual: () => void
  value: string
}) {
  const { t } = useT("settings")
  return (
    <div>
      <select aria-label={label} className={`${inputClass()} font-mono`} onChange={(event) => onChange(event.target.value)} value={value}>
        {children}
      </select>
      <button className="mt-1 text-xs text-gray-500 dark:text-gray-400 underline hover:no-underline" onClick={onManual} type="button">
        {t('repository_form.enter_manually')}
      </button>
    </div>
  )
}

function Checkbox({ label, onChange, value }: { label: string; onChange: (checked: boolean) => void; value: boolean }) {
  const { t } = useT("settings")
  return (
    <label className="flex items-center gap-2 text-sm text-gray-700 dark:text-gray-300">
      <input className="rounded border-gray-400" checked={value} onChange={(event) => onChange(event.target.checked)} type="checkbox" />
      {label}
    </label>
  )
}

function CredentialModeComparison() {
  const { t } = useT("settings")
  const rows = [
    ["All actions appear as you", "Actions appear as bot"],
    ["Cannot approve your own PRs via normal flow", "Normal GitHub approve works"],
    ["Shares your personal API rate limit", "Independent App rate limit"],
    ["Lose access if PAT rotated or revoked", "Auto-refresh; no rotation drama"]
  ]

  return (
    <div className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
        <thead className="bg-gray-50 dark:bg-gray-800 text-xs uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2 text-left">
              {t('repository_form.pat_only')}
            </th>
            <th className="px-4 py-2 text-left">
              {t('repository_form.app_installed')}
            </th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800">
          {rows.map(([pat, app]) => (
            <tr key={pat}>
              <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{pat}</td>
              <td className="px-4 py-3 text-gray-700 dark:text-gray-300">{app}</td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  const { t } = useT("settings")
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function ownerErrorMessage(t: TFunction, error: string) {
  if (error === "no_token") return t('repository_form.owner_err_no_token')
  if (error === "unauthorized") return t('repository_form.owner_err_unauthorized')
  return t('repository_form.owner_err_generic')
}

// Returns text + tone so the caller never has to infer severity by
// substring-matching the (now translated) message. "not found" is the
// only hard error (red); other notices are informational (muted).
function repoErrorMessage(t: TFunction, error: string): { text: string; tone: "error" | "muted" } {
  if (error === "no_token") return { text: t('repository_form.repo_err_no_token'), tone: "muted" }
  if (error === "not_found") return { text: t('repository_form.repo_err_not_found'), tone: "error" }
  return { text: t('repository_form.repo_err_generic'), tone: "muted" }
}

