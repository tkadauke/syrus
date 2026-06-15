import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
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

const defaultPolicies = ["skip", "pile", "replace"]
const emptyTemplate: CronTemplateInput = {
  name: "",
  description: "",
  cron_expression: "0 9 * * 1",
  pr_pileup_policy: "skip",
  prompt: "",
  enabled: true
}
const cronHelpText = "Five fields in UTC: minute hour day-of-month month day-of-week. Examples: 0 9 * * 1 for Mondays at 09:00; 30 14 * * * for every day at 14:30."

export function CronTemplatesIndex() {
  const location = useLocation()
  const basePath = routeBase(location.pathname)
  const templates = useQuery({
    queryKey: ["cron_templates"],
    queryFn: fetchCronTemplates
  })

  return (
    <main aria-label="Cron templates" className="mx-auto max-w-6xl space-y-6 p-6">
      <header className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <h1 className="text-2xl font-semibold text-gray-900">Cron templates</h1>
          <p className="mt-1 max-w-2xl text-sm text-gray-600">Reusable recurring-task blueprints. Apply one to a repository to create a scheduled task with the template settings pre-filled.</p>
        </div>
        <Link className="self-start rounded bg-blue-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500" to={`${basePath}/new`}>New</Link>
      </header>

      {templates.isPending ? <PanelMessage>Loading templates...</PanelMessage> : null}
      {templates.isError ? <CronTemplatesError error={templates.error} /> : null}
      {templates.isSuccess ? <TemplatesTable basePath={basePath} templates={templates.data.templates} /> : null}
    </main>
  )
}

export function CronTemplateDetailRoute() {
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
    <main aria-label="Cron template detail" className="mx-auto max-w-6xl space-y-6 p-6">
      {detail.isPending ? <PanelMessage>Loading template...</PanelMessage> : null}
      {detail.isError ? <CronTemplatesError error={detail.error} /> : null}
      {detail.isSuccess ? <TemplateDetail basePath={basePath} payload={detail.data} prefix={prefix} /> : null}
    </main>
  )
}

export function CronTemplateFormRoute({ mode }: { mode: "new" | "edit" }) {
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
        <h1 className="text-2xl font-semibold text-gray-900">{mode === "new" ? "New cron template" : "Edit template"}</h1>
        <p className="mt-1 text-sm text-gray-600">
          {mode === "new" ? "Define a reusable recurring-task blueprint." : "Changes here do not propagate to existing scheduled tasks that were applied from this template."}
        </p>
      </header>

      {loading ? <PanelMessage>Loading template form...</PanelMessage> : null}
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
  if (templates.length === 0) {
    return (
      <section className="rounded border border-gray-200 bg-white p-8 text-center">
        <p className="text-gray-600">No templates yet.</p>
        <p className="mt-2 text-sm text-gray-500">Create a template to define a reusable recurring-task blueprint, then apply it to any of your repositories.</p>
        <Link className="mt-4 inline-block rounded bg-blue-600 px-3.5 py-2 text-sm font-medium text-white hover:bg-blue-500" to={`${basePath}/new`}>Create your first template</Link>
      </section>
    )
  }

  return (
    <section className="overflow-hidden rounded border border-gray-200 bg-white">
      <table className="min-w-full divide-y divide-gray-200">
        <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500">
          <tr>
            <th className="px-4 py-2">Name</th>
            <th className="px-4 py-2">Schedule</th>
            <th className="px-4 py-2">Pileup policy</th>
            <th className="px-4 py-2">Applied to</th>
            <th className="px-4 py-2">Status</th>
            <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
          </tr>
        </thead>
        <tbody className="divide-y divide-gray-100 text-sm">
          {templates.map((template) => (
            <tr key={template.id}>
              <td className="px-4 py-3 font-medium">
                <Link className="text-blue-600 underline hover:no-underline" to={`${basePath}/${template.id}`}>{template.name}</Link>
                {template.description ? <p className="mt-0.5 text-xs font-normal text-gray-500">{template.description}</p> : null}
              </td>
              <td className="px-4 py-3 font-mono text-xs">{template.cron_expression}</td>
              <td className="px-4 py-3 text-xs">{template.pr_pileup_policy}</td>
              <td className="px-4 py-3 text-xs text-gray-600">{template.applied_tasks_count} {template.applied_tasks_count === 1 ? "repo" : "repos"}</td>
              <td className="px-4 py-3"><StatusPill enabled={template.enabled} /></td>
              <td className="px-4 py-3 text-right"><Link className="text-blue-600 underline hover:no-underline" to={`${basePath}/${template.id}`}>Open</Link></td>
            </tr>
          ))}
        </tbody>
      </table>
    </section>
  )
}

function TemplateDetail({ payload, basePath, prefix }: { payload: Awaited<ReturnType<typeof fetchCronTemplate>>; basePath: string; prefix: string }) {
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
            <h1 className="text-2xl font-semibold text-gray-900">{payload.template.name}</h1>
            <StatusPill enabled={payload.template.enabled} />
          </div>
          {payload.template.description ? <p className="mt-1 text-sm text-gray-600">{payload.template.description}</p> : null}
        </div>
        <div className="flex items-center gap-2">
          <Link className="rounded border border-gray-300 px-3 py-1.5 text-sm hover:bg-gray-50" to={`${basePath}/${payload.template.id}/edit`}>Edit</Link>
          <button
            className="rounded border border-gray-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:text-red-300"
            disabled={destroy.isPending}
            onClick={() => {
              if (window.confirm("Delete this template? Existing scheduled tasks created from it will remain.")) {
                destroy.mutate()
              }
            }}
            type="button"
          >
            {destroy.isPending ? "Deleting..." : "Delete"}
          </button>
        </div>
      </header>

      {destroy.isError ? <PanelMessage tone="error">{errorMessage(destroy.error, "Unable to delete template.")}</PanelMessage> : null}

      <section className="rounded border border-gray-200 bg-white p-4">
        <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500">Schedule</h2>
        <dl className="grid grid-cols-2 gap-y-2 text-sm">
          <dt className="text-gray-500">Cron expression</dt>
          <dd className="font-mono">{payload.template.cron_expression}</dd>
          <dt className="text-gray-500">Semantics</dt>
          <dd>Minute ignored; fires by UTC hour window.</dd>
          <dt className="text-gray-500">PR pileup policy</dt>
          <dd>{payload.template.pr_pileup_policy}</dd>
        </dl>
      </section>

      <section className="rounded border border-gray-200 bg-white p-4">
        <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500">Prompt</h2>
        <pre className="whitespace-pre-wrap rounded border border-gray-200 bg-gray-50 p-3 font-mono text-xs">{payload.template.prompt}</pre>
      </section>

      <AppliedTasks prefix={prefix} tasks={payload.applied_tasks} />
      <RepositoryApplyLinks prefix={prefix} repositories={payload.repositories} />
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
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save template.")}</PanelMessage> : null}
      <Field label="Name">
        <input className={inputClass()} onChange={(event) => setValues({ ...values, name: event.target.value })} type="text" value={values.name} />
      </Field>
      <Field label="Description">
        <input className={inputClass()} onChange={(event) => setValues({ ...values, description: event.target.value })} type="text" value={values.description} />
      </Field>
      <Field label="Cron expression">
        <input className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, cron_expression: event.target.value })} placeholder="0 9 * * 1" type="text" value={values.cron_expression} />
        <p className="mt-1 text-xs text-gray-500">{cronHelpText}</p>
      </Field>
      <Field label="PR pileup policy">
        <select className={inputClass()} onChange={(event) => setValues({ ...values, pr_pileup_policy: event.target.value })} value={values.pr_pileup_policy}>
          {policies.map((policy) => <option key={policy} value={policy}>{policy}</option>)}
        </select>
      </Field>
      <Field label="Prompt">
        <textarea className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, prompt: event.target.value })} rows={8} value={values.prompt} />
      </Field>
      <label className="flex items-center gap-2">
        <input checked={values.enabled} className="rounded border-gray-400" onChange={(event) => setValues({ ...values, enabled: event.target.checked })} type="checkbox" />
        <span className="text-sm font-medium text-gray-700">Enabled</span>
      </label>
      <div className="flex items-center gap-3">
        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300" disabled={save.isPending} type="submit">
          {save.isPending ? "Saving..." : mode === "new" ? "Create template" : "Save"}
        </button>
        <Link className="text-sm text-gray-600 hover:text-gray-900" to={mode === "new" ? basePath : `${basePath}/${id}`}>Cancel</Link>
      </div>
    </form>
  )
}

function AppliedTasks({ tasks, prefix }: { tasks: Awaited<ReturnType<typeof fetchCronTemplate>>["applied_tasks"]; prefix: string }) {
  return (
    <section className="rounded border border-gray-200 bg-white p-4">
      <h2 className="mb-3 text-sm font-semibold uppercase text-gray-500">Applied to repositories</h2>
      {tasks.length === 0 ? (
        <p className="text-sm text-gray-600">Not applied to any repositories yet.</p>
      ) : (
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="text-left text-xs font-medium uppercase text-gray-500">
            <tr>
              <th className="px-2 py-2">Repository</th>
              <th className="px-2 py-2">Task</th>
              <th className="px-2 py-2">State</th>
              <th className="px-2 py-2">Last fired</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 text-sm">
            {tasks.map((task) => (
              <tr key={task.id}>
                <td className="px-2 py-2 font-mono text-xs"><Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(task.repository_path, prefix)}>{task.repository_slug}</Link></td>
                <td className="px-2 py-2"><Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(task.scheduled_task_path, prefix)}>{task.name}</Link></td>
                <td className="px-2 py-2"><StatePill state={task.state} /></td>
                <td className="px-2 py-2 text-xs text-gray-500">{task.last_fired_at ? new Date(task.last_fired_at).toLocaleString() : "never"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function RepositoryApplyLinks({ repositories, prefix }: { repositories: Awaited<ReturnType<typeof fetchCronTemplate>>["repositories"]; prefix: string }) {
  if (repositories.length === 0) return null

  return (
    <section className="rounded border border-gray-200 bg-white p-4">
      <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500">Apply to a repository</h2>
      <div className="flex flex-wrap gap-2">
        {repositories.map((repository) => (
          <Link className="inline-block rounded border border-gray-300 px-2.5 py-1 font-mono text-xs hover:border-blue-300 hover:bg-blue-50 hover:text-blue-700" to={withRoutePrefix(repository.new_scheduled_task_path, prefix)} key={repository.id}>{repository.slug}</Link>
        ))}
      </div>
    </section>
  )
}

function Field({ label, children }: { label: string; children: ReactNode }) {
  return (
    <label className="block text-sm font-medium text-gray-700">
      {label}
      <div className="mt-2">{children}</div>
    </label>
  )
}

function StatusPill({ enabled }: { enabled: boolean }) {
  return enabled ? (
    <span className="inline-block rounded bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700">enabled</span>
  ) : (
    <span className="inline-block rounded bg-gray-100 px-2 py-0.5 text-xs font-medium text-gray-500">disabled</span>
  )
}

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    scheduled: "bg-green-100 text-green-700",
    paused: "bg-gray-100 text-gray-600",
    auto_paused: "bg-red-100 text-red-700",
    fired: "bg-blue-100 text-blue-700"
  }
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 text-gray-700"}`}>{state}</span>
}

function CronTemplatesError({ error }: { error: Error }) {
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load cron templates.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" }) {
  return <div className={`p-4 text-sm ${tone === "error" ? "text-red-700" : "text-gray-600"}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:outline-blue-600"
}

function routeBase(pathname: string) {
  return `${routePrefix(pathname)}/cron_templates`
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
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

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
