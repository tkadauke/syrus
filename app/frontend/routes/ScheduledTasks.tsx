import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { UseMutationResult } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { ApiError } from "../api/client"
import { NoticeToast } from "../components/NoticeToast"
import {
  archiveScheduledTask,
  createScheduledTask,
  fetchNewScheduledTaskForm,
  fetchScheduledTask,
  fetchScheduledTasks,
  fireScheduledTask,
  pauseScheduledTask,
  resumeScheduledTask,
  updateScheduledTask,
  type ScheduledTaskDetail,
  type ScheduledTaskDetailPayload,
  type ScheduledTaskInput,
  type ScheduledTaskOptions,
  type ScheduledTasksIndexPayload,
  type ScheduledTaskRow
} from "../api/scheduledTasks"

const fallbackOptions: ScheduledTaskOptions = {
  kinds: ["cron", "one_shot"],
  pr_pileup_policies: ["skip", "pile", "replace"],
  auto_approve_modes: [
    { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
    { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." },
    { value: "if_graders_pass_and_tagged_safe", label: "If graders pass and tagged safe", preview: "Jobs using this rule also need the safe tag before landing." }
  ]
}
const cronHelpText = "Five fields in UTC: minute hour day-of-month month day-of-week. Examples: 0 9 * * 1 for Mondays at 09:00; 30 14 * * * for every day at 14:30."

export function ScheduledTasksIndex() {
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const tasks = useQuery({
    queryKey: ["scheduled_tasks"],
    queryFn: fetchScheduledTasks
  })

  return (
    <main aria-label="Scheduled tasks" className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900">Scheduled tasks</h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-600">Recurring and one-shot agent prompts attached to repositories.</p>
      </header>

      {tasks.isPending ? <PanelMessage>Loading scheduled tasks...</PanelMessage> : null}
      {tasks.isError ? <ScheduledTasksError error={tasks.error} /> : null}
      {tasks.isSuccess ? (
        <>
          <TaskSection basePath={tasksBase(location.pathname)} empty="No active scheduled tasks." prefix={prefix} tasks={tasks.data.active_tasks} title="Active" />
          <TaskSection basePath={tasksBase(location.pathname)} empty="No fired one-shot tasks." prefix={prefix} tasks={tasks.data.fired_one_shots} title="Fired one-shots" />
          <TaskSection basePath={tasksBase(location.pathname)} empty="No archived scheduled tasks." prefix={prefix} tasks={tasks.data.archived_tasks} title="Archived" />
        </>
      ) : null}
    </main>
  )
}

export function ScheduledTaskDetailRoute() {
  const location = useLocation()
  const params = useParams()
  const id = params.id || ""
  const prefix = routePrefix(location.pathname)
  const detail = useQuery({
    queryKey: ["scheduled_tasks", id],
    queryFn: () => fetchScheduledTask(id),
    enabled: id.length > 0
  })

  return (
    <main aria-label="Scheduled task detail" className="mx-auto max-w-[96rem] space-y-6 p-6">
      {detail.isPending ? <PanelMessage>Loading scheduled task...</PanelMessage> : null}
      {detail.isError ? <ScheduledTasksError error={detail.error} /> : null}
      {detail.isSuccess ? <TaskDetail basePath={tasksBase(location.pathname)} payload={detail.data} prefix={prefix} /> : null}
    </main>
  )
}

export function ScheduledTaskFormRoute({ mode }: { mode: "new" | "edit" }) {
  const location = useLocation()
  const params = useParams()
  const id = params.id || ""
  const repositoryId = params.repositoryId || ""
  const fromTemplate = new URLSearchParams(location.search).get("from_template")
  const basePath = tasksBase(location.pathname)

  const form = useQuery({
    queryKey: ["scheduled_tasks", "new", repositoryId, fromTemplate],
    queryFn: () => fetchNewScheduledTaskForm(repositoryId, fromTemplate),
    enabled: mode === "new" && repositoryId.length > 0
  })
  const detail = useQuery({
    queryKey: ["scheduled_tasks", id],
    queryFn: () => fetchScheduledTask(id),
    enabled: mode === "edit" && id.length > 0
  })

  const loading = mode === "new" ? form.isPending : detail.isPending
  const error = form.error || detail.error
  const initial = mode === "new" && form.data ? formInput(form.data.task) : detail.data ? detailInput(detail.data.task) : null
  const options = form.data?.options || detail.data?.options || fallbackOptions
  const repository = form.data?.repository || detail.data?.task.repository

  return (
    <main aria-label={mode === "new" ? "New scheduled task" : "Edit scheduled task"} className="mx-auto max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900">{mode === "new" ? "New scheduled task" : "Edit scheduled task"}</h1>
        {repository ? (
          <p className="mt-1 font-mono text-sm text-gray-600">{repository.slug}</p>
        ) : null}
      </header>

      {loading ? <PanelMessage>Loading scheduled task form...</PanelMessage> : null}
      {error ? <ScheduledTasksError error={error} /> : null}
      {!loading && !error && initial ? (
        <ScheduledTaskForm
          basePath={basePath}
          fromTemplate={fromTemplate}
          id={Number(id)}
          initial={initial}
          mode={mode}
          options={options}
          repositoryId={repositoryId}
        />
      ) : null}
    </main>
  )
}

function TaskSection({ title, tasks, empty, basePath, prefix }: { title: string; tasks: ScheduledTaskRow[]; empty: string; basePath: string; prefix: string }) {
  return (
    <section className="rounded border border-gray-200 bg-white">
      <div className="border-b border-gray-200 px-4 py-3">
        <h2 className="text-sm font-semibold uppercase text-gray-500">{title}</h2>
      </div>
      {tasks.length === 0 ? (
        <p className="p-4 text-sm text-gray-500">{empty}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200">
            <thead className="bg-gray-50 text-left text-xs font-medium uppercase text-gray-500">
              <tr>
                <th className="px-4 py-2">Task</th>
                <th className="px-4 py-2">Repository</th>
                <th className="px-4 py-2">Schedule</th>
                <th className="px-4 py-2">State</th>
                <th className="px-4 py-2">Last fired</th>
                <th className="px-4 py-2"><span className="sr-only">Actions</span></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 text-sm">
              {tasks.map((task) => (
                <tr key={task.id}>
                  <td className="px-4 py-3 font-medium">
                    <Link className="text-blue-600 underline hover:no-underline" to={`${basePath}/${task.id}`}>{task.name}</Link>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs">
                    <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(task.repository.repository_path, prefix)}>{task.repository.slug}</Link>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs">{task.schedule_label || "none"}</td>
                  <td className="px-4 py-3"><StatePill state={task.state} /></td>
                  <td className="px-4 py-3 text-xs text-gray-500">{formatDate(task.last_fired_at) || "never"}</td>
                  <td className="px-4 py-3 text-right">
                    <Link className="text-blue-600 underline hover:no-underline" to={`${basePath}/${task.id}`}>Open</Link>
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        </div>
      )}
    </section>
  )
}

function TaskDetail({ payload, basePath, prefix }: { payload: ScheduledTaskDetailPayload; basePath: string; prefix: string }) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [notice, setNotice] = useState<string | null>(payload.message || null)

  const command = useMutation({
    mutationFn: (action: "pause" | "resume" | "fire") => {
      if (action === "pause") return pauseScheduledTask(payload.task.id)
      if (action === "resume") return resumeScheduledTask(payload.task.id)
      return fireScheduledTask(payload.task.id)
    },
    onSuccess: (updated) => {
      setNotice(updated.message || null)
      queryClient.setQueryData(["scheduled_tasks", String(updated.task.id)], updated)
      void queryClient.invalidateQueries({ queryKey: ["scheduled_tasks"] })
    }
  })
  const archive = useMutation({
    mutationFn: () => archiveScheduledTask(payload.task.id),
    onSuccess: (updated) => {
      queryClient.setQueryData(["scheduled_tasks"], updated)
      navigate(basePath)
    }
  })

  return (
    <>
      <header className="flex flex-col gap-3 sm:flex-row sm:items-start sm:justify-between">
        <div>
          <div className="flex flex-wrap items-center gap-3">
            <h1 className="text-2xl font-semibold text-gray-900">{payload.task.name}</h1>
            <StatePill state={payload.task.state} />
          </div>
          <p className="mt-1 font-mono text-sm text-gray-600">
            <Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(payload.task.repository.repository_path, prefix)}>{payload.task.repository.slug}</Link>
          </p>
        </div>
        <TaskActions archive={archive} basePath={basePath} command={command} task={payload.task} />
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, "Unable to update scheduled task.")}</PanelMessage> : null}
      {archive.isError ? <PanelMessage tone="error">{errorMessage(archive.error, "Unable to archive scheduled task.")}</PanelMessage> : null}

      <section className="rounded border border-gray-200 bg-white p-4">
        <h2 className="mb-3 text-sm font-semibold uppercase text-gray-500">Schedule</h2>
        <dl className="grid gap-y-2 text-sm sm:grid-cols-2">
          <dt className="text-gray-500">Kind</dt>
          <dd>{payload.task.kind}</dd>
          <dt className="text-gray-500">Cron expression</dt>
          <dd className="font-mono">{payload.task.cron_expression || "none"}</dd>
          <dt className="text-gray-500">Fire at</dt>
          <dd>{formatDate(payload.task.fire_at) || "none"}</dd>
          <dt className="text-gray-500">Next fire</dt>
          <dd>{formatDate(payload.task.next_fire_at) || "none"}</dd>
          <dt className="text-gray-500">PR pileup policy</dt>
          <dd>{payload.task.pr_pileup_policy}</dd>
          <dt className="text-gray-500">Auto-approval</dt>
          <dd>{payload.task.auto_approve_preview}</dd>
        </dl>
      </section>

      <section className="rounded border border-gray-200 bg-white p-4">
        <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500">Prompt</h2>
        <pre className="whitespace-pre-wrap rounded border border-gray-200 bg-gray-50 p-3 font-mono text-xs">{payload.task.prompt}</pre>
      </section>

      <RecentJobs jobs={payload.recent_jobs} prefix={prefix} />
    </>
  )
}

function TaskActions({
  task,
  basePath,
  command,
  archive
}: {
  task: ScheduledTaskDetail
  basePath: string
  command: UseMutationResult<ScheduledTaskDetailPayload, Error, "pause" | "resume" | "fire">
  archive: UseMutationResult<ScheduledTasksIndexPayload, Error, void>
}) {
  return (
    <div className="flex flex-wrap items-center gap-2">
      {task.editable ? <Link className={secondaryButton()} to={`${basePath}/${task.id}/edit`}>Edit</Link> : null}
      {task.pausable ? (
        <button className={secondaryButton()} disabled={command.isPending} onClick={() => command.mutate("pause")} type="button">Pause</button>
      ) : null}
      {task.resumable ? (
        <button className={secondaryButton()} disabled={command.isPending} onClick={() => command.mutate("resume")} type="button">Resume</button>
      ) : null}
      {task.fireable ? (
        <button className={secondaryButton()} disabled={command.isPending} onClick={() => command.mutate("fire")} type="button">Fire now</button>
      ) : null}
      {task.editable ? (
        <button
          className="rounded border border-gray-300 px-3 py-1.5 text-sm text-red-700 hover:bg-red-50 disabled:cursor-not-allowed disabled:text-red-300"
          disabled={archive.isPending}
          onClick={() => {
            if (window.confirm("Archive this scheduled task?")) archive.mutate()
          }}
          type="button"
        >
          Archive
        </button>
      ) : null}
    </div>
  )
}

function RecentJobs({ jobs, prefix }: { jobs: ScheduledTaskDetailPayload["recent_jobs"]; prefix: string }) {
  return (
    <section className="rounded border border-gray-200 bg-white p-4">
      <h2 className="mb-3 text-sm font-semibold uppercase text-gray-500">Recent jobs</h2>
      {jobs.length === 0 ? (
        <p className="text-sm text-gray-600">No jobs yet.</p>
      ) : (
        <table className="min-w-full divide-y divide-gray-200">
          <thead className="text-left text-xs font-medium uppercase text-gray-500">
            <tr>
              <th className="px-2 py-2">Job</th>
              <th className="px-2 py-2">State</th>
              <th className="px-2 py-2">PR</th>
              <th className="px-2 py-2">Created</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 text-sm">
            {jobs.map((job) => (
              <tr key={job.id}>
                <td className="px-2 py-2"><Link className="text-blue-600 underline hover:no-underline" to={withRoutePrefix(job.job_path, prefix)}>#{job.id}</Link></td>
                <td className="px-2 py-2">{job.closure_reason || job.state}</td>
                <td className="px-2 py-2">{job.pr_number || job.external_pr_number || "none"}</td>
                <td className="px-2 py-2 text-xs text-gray-500">{formatDate(job.created_at)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  )
}

function ScheduledTaskForm({
  mode,
  id,
  repositoryId,
  fromTemplate,
  initial,
  options,
  basePath
}: {
  mode: "new" | "edit"
  id: number
  repositoryId: string
  fromTemplate: string | null
  initial: ScheduledTaskInput
  options: ScheduledTaskOptions
  basePath: string
}) {
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [values, setValues] = useState<ScheduledTaskInput>(initial)
  const save = useMutation({
    mutationFn: () => mode === "new"
      ? createScheduledTask(repositoryId, submitInput(values), fromTemplate)
      : updateScheduledTask(id, submitInput(values)),
    onSuccess: (payload) => {
      queryClient.setQueryData(["scheduled_tasks", String(payload.task.id)], payload)
      void queryClient.invalidateQueries({ queryKey: ["scheduled_tasks"] })
      navigate(`${basePath}/${payload.task.id}`)
    }
  })

  useEffect(() => {
    setValues(initial)
  }, [initial])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    save.mutate()
  }

  const autoApproval = options.auto_approve_modes.find((option) => option.value === values.auto_approve_mode)

  return (
    <form className="space-y-5" onSubmit={submit}>
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, "Unable to save scheduled task.")}</PanelMessage> : null}
      <Field label="Name">
        <input className={inputClass()} onChange={(event) => setValues({ ...values, name: event.target.value })} type="text" value={values.name} />
      </Field>
      <Field label="Kind">
        <select className={inputClass()} onChange={(event) => setValues({ ...values, kind: event.target.value })} value={values.kind}>
          {options.kinds.map((kind) => <option key={kind} value={kind}>{kind}</option>)}
        </select>
      </Field>
      {values.kind === "one_shot" ? (
        <Field label="Fire at">
          <input className={inputClass()} onChange={(event) => setValues({ ...values, fire_at: event.target.value })} type="datetime-local" value={values.fire_at} />
        </Field>
      ) : (
        <Field label="Cron expression">
          <input className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, cron_expression: event.target.value })} placeholder="0 9 * * 1" type="text" value={values.cron_expression} />
          <p className="mt-1 text-xs text-gray-500">{cronHelpText}</p>
        </Field>
      )}
      <Field label="PR pileup policy">
        <select className={inputClass()} onChange={(event) => setValues({ ...values, pr_pileup_policy: event.target.value })} value={values.pr_pileup_policy}>
          {options.pr_pileup_policies.map((policy) => <option key={policy} value={policy}>{policy}</option>)}
        </select>
      </Field>
      <Field label="Auto-approval">
        <select className={inputClass()} onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })} value={values.auto_approve_mode}>
          {options.auto_approve_modes.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
        </select>
        <p className="mt-1 text-xs text-gray-500">{autoApproval?.preview}</p>
      </Field>
      <Field label="Prompt">
        <textarea className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, prompt: event.target.value })} rows={8} value={values.prompt} />
      </Field>
      <div className="flex items-center gap-3">
        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300" disabled={save.isPending} type="submit">
          {save.isPending ? "Saving..." : mode === "new" ? "Create task" : "Save"}
        </button>
        <Link className="text-sm text-gray-600 hover:text-gray-900" to={mode === "new" ? basePath : `${basePath}/${id}`}>Cancel</Link>
      </div>
    </form>
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

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    scheduled: "bg-green-100 text-green-700",
    paused: "bg-gray-100 text-gray-600",
    auto_paused: "bg-red-100 text-red-700",
    fired: "bg-blue-100 text-blue-700"
  }
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 text-gray-700"}`}>{state}</span>
}

function ScheduledTasksError({ error }: { error: Error }) {
  return <PanelMessage tone="error">{errorMessage(error, "Unable to load scheduled tasks.")}</PanelMessage>
}

function PanelMessage({ children, tone = "muted" }: { children: ReactNode; tone?: "muted" | "error" | "success" }) {
  const colors = {
    error: "border-red-200 bg-red-50 text-red-700",
    success: "border-green-200 bg-green-50 text-green-700",
    muted: "border-gray-200 bg-white text-gray-600"
  }
  return <div className={`rounded border p-4 text-sm ${colors[tone]}`}>{children}</div>
}

function inputClass() {
  return "block w-full rounded border border-gray-300 px-3 py-2 text-sm shadow-sm focus:outline-blue-600"
}

function secondaryButton() {
  return "rounded border border-gray-300 px-3 py-1.5 text-sm hover:bg-gray-50 disabled:cursor-not-allowed disabled:text-gray-300"
}

function tasksBase(pathname: string) {
  return `${routePrefix(pathname)}/scheduled_tasks`
}

function routePrefix(pathname: string) {
  return pathname.startsWith("/app-shell") ? "/app-shell" : ""
}

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}

function formatDate(value: string | null) {
  return value ? new Date(value).toLocaleString() : null
}

function formInput(input: ScheduledTaskInput): ScheduledTaskInput {
  return {
    name: input.name || "",
    prompt: input.prompt || "",
    kind: input.kind || "cron",
    cron_expression: input.cron_expression || "0 9 * * 1",
    fire_at: toDatetimeLocal(input.fire_at),
    pr_pileup_policy: input.pr_pileup_policy || "skip",
    auto_approve_mode: input.auto_approve_mode || "never"
  }
}

function detailInput(task: ScheduledTaskDetail): ScheduledTaskInput {
  return formInput({
    name: task.name,
    prompt: task.prompt,
    kind: task.kind,
    cron_expression: task.cron_expression || "",
    fire_at: task.fire_at || "",
    pr_pileup_policy: task.pr_pileup_policy,
    auto_approve_mode: task.auto_approve_mode
  })
}

function submitInput(values: ScheduledTaskInput): ScheduledTaskInput {
  return {
    ...values,
    cron_expression: values.kind === "cron" ? values.cron_expression : "",
    fire_at: values.kind === "one_shot" ? values.fire_at : ""
  }
}

function toDatetimeLocal(value: string | null) {
  if (!value) return ""
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  const pad = (number: number) => String(number).padStart(2, "0")
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}

function errorMessage(error: Error, fallback: string) {
  return error instanceof ApiError ? error.message : fallback
}
