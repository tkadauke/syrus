import { useMutation, useQuery } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useMemo, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import {
  createRepository,
  fetchEditRepositoryForm,
  fetchLinearSource,
  fetchLinearTeams,
  fetchNewRepositoryForm,
  fetchRepositoryBranches,
  fetchRepositoryOptions,
  fetchRepositoryOwners,
  type GitHubRepositoryOption,
  type LinearSourceInput,
  type LinearTeam,
  type RepositoryFormPayload,
  type RepositoryInput,
  saveLinearSource,
  updateRepository
} from "../api/repositories"
import { useT } from "../hooks/useT"

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
    <main aria-label={mode === "new" ? "Add Repository" : "Edit Repository"} className="mx-auto max-w-3xl space-y-6 p-6">
      {form.isPending ? <PanelMessage>{t('repository_form.loading')}</PanelMessage> : null}
      {form.isError ? <PanelMessage tone="error">{errorMessage(form.error, "Unable to load repository form.")}</PanelMessage> : null}
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
  const [repoNotice, setRepoNotice] = useState<string | null>(null)
  const [branchOptions, setBranchOptions] = useState<string[]>([])
  const save = useMutation({
    mutationFn: () => {
      if (mode === "new") return createRepository(values)
      return updateRepository(Number(payload.repository.id), values)
    },
    onSuccess: (saved) => navigate(withRoutePrefix(saved.redirect_to, prefix))
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
      setOwnerNotice(ownerErrorMessage(owners.data.error))
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
        setRepoNotice(repoErrorMessage(data.error))
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
      setRepoNotice("Unable to load repositories. Enter the name manually.")
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
          if (data.error === "not_found") setRepoNotice("Repository not found or not accessible.")
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

  const title = mode === "new" ? "Add repository" : `Edit ${payload.repository.slug || `${payload.repository.owner}/${payload.repository.name}`}`

  return (
    <>
      <header className="flex flex-col gap-2 sm:flex-row sm:items-start sm:justify-between">
        <h1 className="break-words text-3xl font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
        {mode === "edit" && payload.repository.repository_path ? <Link className="text-sm text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(payload.repository.repository_path, prefix)}>
          {t('repository_form.back')}
        </Link> : null}
      </header>

      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save repository.")}</PanelMessage> : null}
      {ownerNotice ? <PanelMessage>{ownerNotice}</PanelMessage> : null}
      {repoNotice ? <PanelMessage tone={repoNotice.includes("not found") ? "error" : "muted"}>{repoNotice}</PanelMessage> : null}

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
            <Field label="Working owner">
              {ownerMode === "select" && ownerOptions.length > 0 ? (
                <SelectWithManual
                  label="Working owner"
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
                  aria-label="Working owner"
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

            <Field label="Working name">
              {repoMode === "select" && repoOptions.length > 0 ? (
                <SelectWithManual
                  label="Working name"
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
                  aria-label="Working name"
                  className={`${inputClass()} font-mono`}
                  onChange={(event) => setValues({ ...values, name: event.target.value, github_owner_id: "", github_repository_id: "" })}
                  required
                  type="text"
                  value={values.name}
                />
              )}
            </Field>
          </div>

          <Field label="Default branch">
            {branchMode === "select" && branchOptions.length > 0 ? (
              <select
                aria-label="Default branch"
                className={`${inputClass()} font-mono`}
                onChange={(event) => setValues({ ...values, default_branch: event.target.value })}
                required
                value={values.default_branch}
              >
                {branchOptions.map((branch) => <option key={branch} value={branch}>{branch}</option>)}
              </select>
            ) : (
              <input
                aria-label="Default branch"
                className={`${inputClass()} font-mono`}
                onChange={(event) => setValues({ ...values, default_branch: event.target.value })}
                required
                type="text"
                value={values.default_branch}
              />
            )}
          </Field>

          <Field label="Trigger label">
            <input
              aria-label="Trigger label"
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
            <Field label="Upstream owner">
              <input
                aria-label="Upstream owner"
                className={`${inputClass()} font-mono`}
                onChange={(event) => updateUpstream("upstream_owner", event.target.value)}
                type="text"
                value={values.upstream_owner}
              />
            </Field>

            <Field label="Upstream name">
              <input
                aria-label="Upstream name"
                className={`${inputClass()} font-mono`}
                onChange={(event) => updateUpstream("upstream_name", event.target.value)}
                type="text"
                value={values.upstream_name}
              />
            </Field>
          </div>

          <Field label="Upstream default branch">
            <input
              aria-label="Upstream default branch"
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
          <Field label="Default agent">
            <select
              aria-label="Default agent"
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

          <Field label="Auto-approval fallback">
            <select
              aria-label="Auto-approval fallback"
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

          <Checkbox label="Polling enabled" onChange={(checked) => setValues({ ...values, polling_enabled: checked })} value={values.polling_enabled} />
          <Checkbox label="Run prepare step on this repository's Workflows" onChange={(checked) => setValues({ ...values, prepare_enabled: checked })} value={values.prepare_enabled} />
          <Checkbox label="Add Syrus cost footer to PR descriptions" onChange={(checked) => setValues({ ...values, pr_cost_footer_enabled: checked })} value={values.pr_cost_footer_enabled} />
          <Checkbox label="Auto-merge approved Syrus PRs" onChange={(checked) => setValues({ ...values, auto_merge_enabled: checked })} value={values.auto_merge_enabled} />
          <Checkbox label="Trust clean rebases (skip re-grading after a conflict-free rebase)" onChange={(checked) => setValues({ ...values, trust_clean_rebase_grade: checked })} value={values.trust_clean_rebase_grade} />
          <Checkbox label="Pause work when the main branch is broken" onChange={(checked) => setValues({ ...values, main_branch_health_enabled: checked })} value={values.main_branch_health_enabled} />
          <Checkbox label="Automatically create a fix job when main breaks" onChange={(checked) => {
            setRepairTouched(true)
            setValues({ ...values, main_branch_repair_enabled: checked })
          }} value={values.main_branch_repair_enabled} />
          <Checkbox
            label="Treat grader timeouts as failures"
            onChange={(checked) => setValues({ ...values, treat_grader_timeouts_as_failures: checked })}
            value={values.treat_grader_timeouts_as_failures}
          />
          <p className="-mt-2 text-xs text-gray-500 dark:text-gray-400">
            When off, timeout-only grader results mark main branch health inconclusive instead of broken.
          </p>

          <Field label="Feedback policy">
            <select
              aria-label="Feedback policy"
              className={inputClass()}
              onChange={(event) => setValues({ ...values, feedback_policy: event.target.value })}
              value={values.feedback_policy}
            >
              <option value="confirm">Confirm — require job owner approval before acting on external/member comments</option>
              <option value="auto">Auto — immediately queue a workflow for any actionable comment</option>
            </select>
            <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
              Job owner comments always trigger automatically regardless of this setting.
            </p>
          </Field>
        </section>

        {mode === "edit" && payload.repository.id ? (
          <LinearSourceSection repositoryId={payload.repository.id} />
        ) : null}

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

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
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
    treat_grader_timeouts_as_failures: payload.repository.treat_grader_timeouts_as_failures,
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

function LinearSourceSection({ repositoryId }: { repositoryId: number }) {
  const { t } = useT("settings")
  const [values, setValues] = useState<LinearSourceInput>({
    api_key: "",
    team_id: "",
    label_filter: "",
    polling_enabled: false
  })
  const [message, setMessage] = useState<string | null>(null)
  const [errorMsg, setErrorMsg] = useState<string | null>(null)

  const sourceQuery = useQuery({
    queryKey: ["linear_source", repositoryId],
    queryFn: () => fetchLinearSource(repositoryId)
  })

  useEffect(() => {
    if (!sourceQuery.isSuccess || !sourceQuery.data.linear_source) return
    const s = sourceQuery.data.linear_source
    setValues({
      api_key: "",
      team_id: s.team_id,
      label_filter: s.label_filter,
      polling_enabled: s.polling_enabled
    })
  }, [sourceQuery.isSuccess, sourceQuery.data])

  const save = useMutation({
    mutationFn: () => saveLinearSource(repositoryId, values),
    onSuccess: (data) => {
      setMessage(data.message ?? t("linear_source.saved"))
      setErrorMsg(null)
      sourceQuery.refetch()
    },
    onError: (error) => {
      setMessage(null)
      setErrorMsg(error instanceof ApiError ? error.message : t("linear_source.save_error"))
    }
  })

  const plausibleApiKey = values.api_key.startsWith("lin_api_") ? values.api_key : ""

  const teamsQuery = useQuery({
    queryKey: ["linear_teams", plausibleApiKey],
    queryFn: () => fetchLinearTeams(plausibleApiKey),
    enabled: plausibleApiKey.length > 0,
    retry: false
  })

  const teams: LinearTeam[] = teamsQuery.data?.teams ?? []

  const existing = sourceQuery.data?.linear_source

  return (
    <section className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <div>
        <h2 className="text-sm font-semibold text-gray-900 dark:text-gray-100">
          {t("linear_source.section_heading")}
        </h2>
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
          {t("linear_source.section_description")}
        </p>
      </div>

      {existing ? (
        <div className="text-xs text-gray-500 dark:text-gray-400 space-y-0.5">
          {existing.last_poll_started_at ? (
            <p>{t("linear_source.last_polled_at", { time: new Date(existing.last_poll_started_at).toLocaleString() })}</p>
          ) : null}
          <p>{t("linear_source.issues_ingested", { count: existing.issues_ingested_count })}</p>
        </div>
      ) : null}

      {message ? <div className="rounded border border-green-200 dark:border-green-800 bg-green-50 dark:bg-green-950/40 p-3 text-sm text-green-700 dark:text-green-300">{message}</div> : null}
      {errorMsg ? <div className="rounded border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 p-3 text-sm text-red-700 dark:text-red-300">{errorMsg}</div> : null}

      <div className="space-y-4">
        <Field label={t("linear_source.api_key_label")}>
          <input
            aria-label={t("linear_source.api_key_label")}
            autoComplete="off"
            className={inputClass()}
            onChange={(e) => setValues({ ...values, api_key: e.target.value })}
            placeholder={existing ? t("linear_source.api_key_placeholder_set") : t("linear_source.api_key_placeholder")}
            type="password"
            value={values.api_key}
          />
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {t("linear_source.api_key_hint")}
          </p>
        </Field>

        {plausibleApiKey.length > 0 ? (
          <Field label={t("linear_source.team_label")}>
            {teamsQuery.isPending ? (
              <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("linear_source.team_loading")}</p>
            ) : teamsQuery.isError ? (
              <p className="mt-1 text-xs text-red-600 dark:text-red-400">{t("linear_source.team_error")}</p>
            ) : (
              <select
                aria-label={t("linear_source.team_label")}
                className={`${inputClass()} cursor-pointer`}
                onChange={(e) => setValues({ ...values, team_id: e.target.value })}
                value={values.team_id}
              >
                <option value="">{t("linear_source.team_placeholder")}</option>
                {teams.map((team) => (
                  <option key={team.id} value={team.id}>{team.name}</option>
                ))}
              </select>
            )}
          </Field>
        ) : null}

        <Field label={t("linear_source.label_filter_label")}>
          <input
            aria-label={t("linear_source.label_filter_label")}
            className={`${inputClass()} font-mono`}
            onChange={(e) => setValues({ ...values, label_filter: e.target.value })}
            placeholder={t("linear_source.label_filter_placeholder")}
            type="text"
            value={values.label_filter}
          />
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">
            {t("linear_source.label_filter_hint")}
          </p>
        </Field>

        <Checkbox
          label={t("linear_source.polling_enabled_label")}
          onChange={(checked) => setValues({ ...values, polling_enabled: checked })}
          value={values.polling_enabled}
        />

        <button
          className="rounded bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900"
          disabled={save.isPending}
          onClick={() => {
            setMessage(null)
            setErrorMsg(null)
            save.mutate()
          }}
          type="button"
        >
          {save.isPending ? t("linear_source.saving") : t("linear_source.save")}
        </button>
      </div>
    </section>
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

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  const { t } = useT("settings")
  const colors = {
    error: "border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    muted: "border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 text-gray-600 dark:text-gray-400"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 dark:border-gray-700 bg-white dark:bg-gray-900 px-3 py-2 text-sm text-gray-900 dark:text-gray-100 dark:placeholder:text-gray-500 shadow-sm focus:outline-blue-600"
}

function ownerErrorMessage(error: string) {
  if (error === "no_token") return "No GitHub token configured. Enter the repository manually or add a token in Credentials."
  if (error === "unauthorized") return "GitHub rejected the configured credentials. Enter the repository manually or update Credentials."
  return "Unable to load GitHub owners. Enter the repository manually."
}

function repoErrorMessage(error: string) {
  if (error === "no_token") return "No GitHub token configured. Enter the repository name manually."
  if (error === "not_found") return "Repository owner not found or not accessible."
  return "Unable to load repositories. Enter the name manually."
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
