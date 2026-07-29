import { inputClass } from "../lib/formClasses"
import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import {
  createCronTemplate,
  deleteCronTemplate,
  fetchCronTemplate,
  fetchCronTemplates,
  updateCronTemplate,
  type CronTemplateDetail,
  type CronTemplateInput,
  type CronTemplateRow
} from "../api/cronTemplates"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { errorMessage } from "../lib/errorMessage"
import { useConfirm } from "../hooks/useConfirm"

const defaultPolicies = ["skip", "pile", "replace"]
const emptyTemplate: CronTemplateInput = {
  name: "",
  description: "",
  cron_expression: "0 9 * * 1",
  pr_pileup_policy: "skip",
  prompt: "",
  enabled: true
}
export function CronTemplatesIndex() {
  const { t } = useT("settings")
  usePageTitle(t("cron_templates.heading"))
  const location = useLocation()
  const basePath = routeBase(location.pathname)
  const templates = useQuery({
    queryKey: ["cron_templates"],
    queryFn: fetchCronTemplates
  })

  return (
    <main aria-label={t("aria_cron_templates")} className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("cron_templates.heading")}</h1>
          <p className="mt-1 max-w-2xl text-sm text-gray-600 dark:text-gray-400">{t("cron_templates.description")}</p>
        </div>
        <Link className="self-start rounded bg-blue-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500" to={`${basePath}/new`}>{t("cron_templates.new")}</Link>
      </header>

      {templates.isPending ? <PanelMessage>{t("cron_templates.loading")}</PanelMessage> : null}
      {templates.isError ? <CronTemplatesError error={templates.error} /> : null}
      {templates.isSuccess ? <TemplatesTable basePath={basePath} templates={templates.data.templates} /> : null}
    </main>
  )
}

export function CronTemplateDetailRoute() {
  const { t } = useT("settings")
  const location = useLocation()
  const params = useParams()
  const id = params.id || ""
  const basePath = routeBase(location.pathname)
  const prefix = routePrefix(location.pathname)
  const detail = useQuery({
    queryKey: ["cron_templates", id],
    queryFn: () => fetchCronTemplate(id),
    enabled: id.length > 0
  })

  return (
    <main aria-label={t("aria_cron_template_detail")} className="mx-auto max-w-6xl space-y-6 p-6">
      {detail.isPending ? <PanelMessage>{t("cron_templates.loading_template")}</PanelMessage> : null}
      {detail.isError ? <CronTemplatesError error={detail.error} /> : null}
      {detail.isSuccess ? <TemplateDetail basePath={basePath} payload={detail.data} prefix={prefix} /> : null}
    </main>
  )
}

export function CronTemplateFormRoute({ mode }: { mode: "new" | "edit" }) {
  const { t } = useT("settings")
  const location = useLocation()
  const params = useParams()
  const id = params.id || ""
  const basePath = routeBase(location.pathname)
  const index = useQuery({
    queryKey: ["cron_templates"],
    queryFn: fetchCronTemplates
  })
  const detail = useQuery({
    queryKey: ["cron_templates", id],
    queryFn: () => fetchCronTemplate(id),
    enabled: mode === "edit" && id.length > 0
  })

  const loading = index.isPending || (mode === "edit" && detail.isPending)
  const error = index.error || detail.error
  const policies = index.data?.pr_pileup_policies || detail.data?.pr_pileup_policies || defaultPolicies
  const initial = mode === "edit" && detail.data ? inputFromTemplate(detail.data.template) : emptyTemplate

  return (
    <main aria-label={mode === "new" ? "New cron template" : "Edit cron template"} className="mx-auto max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{mode === "new" ? t("cron_templates.new_heading") : t("cron_templates.edit_heading")}</h1>
        <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">
          {mode === "new" ? t("cron_templates.new_description") : t("cron_templates.edit_description")}
        </p>
      </header>

      {loading ? <PanelMessage>{t("cron_templates.loading_form")}</PanelMessage> : null}
      {error ? <CronTemplatesError error={error} /> : null}
      {!loading && !error ? (
        <CronTemplateForm
          basePath={basePath}
          id={Number(id)}
          initial={initial}
          mode={mode}
          policies={policies}
        />
      ) : null}
    </main>
  )
}

function TemplatesTable({ templates, basePath }: { templates: CronTemplateRow[]; basePath: string }) {
  const { t } = useT("settings")

  if (templates.length === 0) {
    return (
      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-8 text-center">
        <p className="text-gray-600 dark:text-gray-400">{t("cron_templates.no_templates_heading")}</p>
        <p className="mt-2 text-sm text-gray-500 dark:text-gray-400">{t("cron_templates.no_templates_description")}</p>
        <Link className="mt-4 inline-block rounded bg-blue-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500" to={`${basePath}/new`}>{t("cron_templates.create_first")}</Link>
      </section>
    )
  }

  return (
    <section className="overflow-hidden rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
        <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
          <tr>
            <th className="px-4 py-2">{t("cron_templates.col_name")}</th>
            <th className="px-4 py-2">{t("cron_templates.col_schedule")}</th>
            <th className="px-4 py-2">{t("cron_templates.col_pileup")}</th>
            <th className="px-4 py-2">{t("cron_templates.col_applied")}</th>
            <th className="px-4 py-2">{t("cron_templates.col_status")}</th>
            <th className="px-4 py-2"><span className="sr-only">{t("cron_templates.col_open")}</span></th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
          {templates.map((template) => (
            <tr key={template.id}>
              <td className="px-4 py-3 font-medium">
                <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={`${basePath}/${template.id}`}>{template.name}</Link>
                {template.description ? <p className="mt-0.5 text-xs font-normal text-gray-500 dark:text-gray-400">{template.description}</p> : null}
              </td>
              <td className="px-4 py-3 font-mono text-xs">{template.cron_expression}</td>
              <td className="px-4 py-3 text-xs">{template.pr_pileup_policy}</td>
              <td className="px-4 py-3 text-xs text-gray-600 dark:text-gray-400">{t("cron_templates.repos", { count: template.applied_tasks_count })}</td>
              <td className="px-4 py-3"><StatusPill enabled={template.enabled} /></td>
              <td className="px-4 py-3 text-right"><Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={`${basePath}/${template.id}`}>{t("cron_templates.col_open")}</Link></td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function TemplateDetail({ payload, basePath, prefix }: { payload: Awaited<ReturnType<typeof fetchCronTemplate>>; basePath: string; prefix: string }) {
  const { t } = useT("settings")
  const { confirm, dialog } = useConfirm()
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const destroy = useMutation({
    mutationFn: () => deleteCronTemplate(payload.template.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(["cron_templates"], updated)
      navigate(basePath)
    }
  })

  return (
    <>
      <header className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex items-center gap-3">
            <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{payload.template.name}</h1>
            <StatusPill enabled={payload.template.enabled} />
          </div>
          {payload.template.description ? <p className="mt-1 text-sm text-gray-600 dark:text-gray-400">{payload.template.description}</p> : null}
        </div>
        <div className="flex items-center gap-2">
          <Link className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm hover:bg-gray-50 dark:hover:bg-gray-800" to={`${basePath}/${payload.template.id}/edit`}>{t("cron_templates.edit")}</Link>
          <button
            className="rounded border border-gray-300 dark:border-gray-600 px-3 py-1.5 text-sm text-red-700 dark:text-red-300 hover:bg-red-50 dark:hover:bg-red-950/50 disabled:cursor-not-allowed disabled:text-red-300 dark:disabled:text-red-500"
            disabled={destroy.isPending}
            onClick={async () => {
              if (await confirm({ message: t("cron_templates.confirm_delete"), destructive: true })) {
                destroy.mutate()
              }
            }}
            type="button"
          >
            {destroy.isPending ? t("cron_templates.deleting") : t("cron_templates.delete")}
          </button>
        </div>
      </header>

      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, t("cron_templates.error_delete"))}</PanelMessage> : null}

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("cron_templates.section_schedule")}</h2>
        <dl className="grid grid-cols-2 gap-y-2 text-sm">
          <dt className="text-gray-500 dark:text-gray-400">{t("cron_templates.cron_expression_label")}</dt>
          <dd className="font-mono">{payload.template.cron_expression}</dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("cron_templates.semantics_label")}</dt>
          <dd>{t("cron_templates.semantics_value")}</dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("cron_templates.pr_pileup_policy_label")}</dt>
          <dd>{payload.template.pr_pileup_policy}</dd>
        </dl>
      </section>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("cron_templates.section_prompt")}</h2>
        <pre className="whitespace-pre-wrap rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 p-3 font-mono text-xs">{payload.template.prompt}</pre>
      </section>

      <AppliedTasks prefix={prefix} tasks={payload.applied_tasks} />
      <RepositoryApplyLinks prefix={prefix} repositories={payload.repositories} />
      {dialog}
    </>
  )
}

function CronTemplateForm({
  id,
  mode,
  initial,
  policies,
  basePath
}: {
  id: number
  mode: "new" | "edit"
  initial: CronTemplateInput
  policies: string[]
  basePath: string
}) {
  const { t } = useT("settings")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [values, setValues] = useState<CronTemplateInput>(initial)
  const save = useMutation({
    mutationFn: () => mode === "new" ? createCronTemplate(values) : updateCronTemplate(id, values),
    onSuccess: (payload) => {
      queryClient.setQueryData(["cron_templates", String(payload.template.id)], payload)
      void queryClient.invalidateQueries({ queryKey: ["cron_templates"] })
      navigate(`${basePath}/${payload.template.id}`)
    }
  })

  useEffect(() => {
    setValues(initial)
  }, [initial])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    save.mutate()
  }

  return (
    <form className="space-y-5" onSubmit={submit}>
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, t("cron_templates.error_save"))}</PanelMessage> : null}
      <Field label={t("cron_templates.field_name")}>
        <input className={inputClass()} onChange={(event) => setValues({ ...values, name: event.target.value })} type="text" value={values.name} />
      </Field>
      <Field label={t("cron_templates.field_description")}>
        <input className={inputClass()} onChange={(event) => setValues({ ...values, description: event.target.value })} type="text" value={values.description} />
      </Field>
      <Field label={t("cron_templates.field_cron")}>
        <input className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, cron_expression: event.target.value })} placeholder="0 9 * * 1" type="text" value={values.cron_expression} />
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("cron_templates.cron_help")}</p>
      </Field>
      <Field label={t("cron_templates.field_pileup")}>
        <select className={inputClass()} onChange={(event) => setValues({ ...values, pr_pileup_policy: event.target.value })} value={values.pr_pileup_policy}>
          {policies.map((policy) => <option key={policy} value={policy}>{policy}</option>)}
        </select>
      </Field>
      <Field label={t("cron_templates.field_prompt")}>
        <textarea className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, prompt: event.target.value })} rows={8} value={values.prompt} />
      </Field>
      <label className="flex items-center gap-2">
        <input checked={values.enabled} className="rounded border-gray-400" onChange={(event) => setValues({ ...values, enabled: event.target.checked })} type="checkbox" />
        <span className="text-sm font-medium text-gray-700 dark:text-gray-300">{t("cron_templates.field_enabled")}</span>
      </label>
      <div className="flex items-center gap-3">
        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900" disabled={save.isPending} type="submit">
          {save.isPending ? t("cron_templates.saving") : mode === "new" ? t("cron_templates.create") : t("cron_templates.save")}
        </button>
        <Link className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-100" to={mode === "new" ? basePath : `${basePath}/${id}`}>{t("cron_templates.cancel")}</Link>
      </div>
    </form>
  )
}

function AppliedTasks({ tasks, prefix }: { tasks: Awaited<ReturnType<typeof fetchCronTemplate>>["applied_tasks"]; prefix: string }) {
  const { t } = useT("settings")
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="mb-3 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("cron_templates.section_applied")}</h2>
      {tasks.length === 0 ? (
        <p className="text-sm text-gray-600 dark:text-gray-400">{t("cron_templates.not_applied")}</p>
      ) : (
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead className="text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-2 py-2">{t("cron_templates.applied_tasks_col_repo")}</th>
              <th className="px-2 py-2">{t("cron_templates.applied_tasks_col_task")}</th>
              <th className="px-2 py-2">{t("cron_templates.applied_tasks_col_state")}</th>
              <th className="px-2 py-2">{t("cron_templates.applied_tasks_col_fired")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
            {tasks.map((task) => (
              <tr key={task.id}>
                <td className="px-2 py-2 font-mono text-xs"><Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(task.repository_path, prefix)}>{task.repository_slug}</Link></td>
                <td className="px-2 py-2"><Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(task.scheduled_task_path, prefix)}>{task.name}</Link></td>
                <td className="px-2 py-2"><StatePill state={task.state} /></td>
                <td className="px-2 py-2 text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp fallback={t("cron_templates.never")} value={task.last_fired_at} /></td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function RepositoryApplyLinks({ repositories, prefix }: { repositories: Awaited<ReturnType<typeof fetchCronTemplate>>["repositories"]; prefix: string }) {
  const { t } = useT("settings")
  if (repositories.length === 0) return null

  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("cron_templates.section_apply")}</h2>
      <div className="flex flex-wrap gap-2">
        {repositories.map((repository) => (
          <Link className="inline-block rounded border border-gray-300 dark:border-gray-600 px-2.5 py-1 font-mono text-xs hover:border-blue-300 hover:bg-blue-50 dark:hover:bg-blue-950/50 hover:text-blue-700 dark:hover:text-blue-300" to={withRoutePrefix(repository.new_scheduled_task_path, prefix)} key={repository.id}>{repository.slug}</Link>
        ))}
      </div>
    </section>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700 dark:text-gray-300">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function StatusPill({ enabled }: { enabled: boolean }) {
  const { t } = useT("settings")
  return enabled ? (
    <span className="inline-block rounded bg-green-100 dark:bg-green-950/40 px-2 py-0.5 text-xs font-medium text-green-700 dark:text-green-300">{t("cron_templates.enabled")}</span>
  ) : (
    <span className="inline-block rounded bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs font-medium text-gray-500 dark:text-gray-400">{t("cron_templates.disabled")}</span>
  )
}

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    scheduled: "bg-green-100 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    paused: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400",
    auto_paused: "bg-red-100 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    fired: "bg-blue-100 dark:bg-blue-950/40 text-blue-700 dark:text-blue-300"
  }
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300"}`}>{state}</span>
}

function CronTemplatesError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, t("cron_templates.error_load"))}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700 dark:text-red-300" : "text-gray-600 dark:text-gray-400"}`}>{children}</div>
}

function routeBase(pathname: string) {
  return `${routePrefix(pathname)}/cron_templates`
}

function inputFromTemplate(template: CronTemplateDetail): CronTemplateInput {
  return {
    name: template.name,
    description: template.description || "",
    cron_expression: template.cron_expression,
    pr_pileup_policy: template.pr_pileup_policy,
    prompt: template.prompt,
    enabled: template.enabled
  }
}

