import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { inputClass } from "../lib/formClasses"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { UseMutationResult } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { buttonClass } from "../lib/buttonClasses"
import { NoticeToast } from "../components/NoticeToast"
import { PanelMessage } from "../components/PanelMessage"
import { useT } from "../hooks/useT"
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
import { errorMessage } from "../lib/errorMessage"

const fallbackOptions: ScheduledTaskOptions = {
  kinds: ["cron", "one_shot"],
  pr_pileup_policies: ["skip", "pile", "replace"],
  auto_approve_modes: [
    { value: "never", label: "Never", preview: "No direct rule; Jobs can still inherit a repository or user default." },
    { value: "if_graders_pass", label: "If graders pass", preview: "Jobs using this rule enter landing after repo-committed graders pass." },
    { value: "if_graders_pass_and_tagged_safe", label: "If graders pass and tagged safe", preview: "Jobs using this rule also need the safe tag before landing." }
  ]
}

export function ScheduledTasksIndex() {
  const { t } = useT("settings")
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const tasks = useQuery({
    queryKey: ["scheduled_tasks"],
    queryFn: fetchScheduledTasks
  })

  return (
    <main aria-label={t("scheduled_tasks.aria_index")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{t("scheduled_tasks.heading")}</h1>
        <p className="mt-1 max-w-2xl text-sm text-gray-600 dark:text-gray-400">{t("scheduled_tasks.description")}</p>
      </header>

      {tasks.isPending ? <PanelMessage>{t("scheduled_tasks.loading")}</PanelMessage> : null}
      {tasks.isError ? <ScheduledTasksError error={tasks.error} /> : null}
      {tasks.isSuccess ? (
        <>
          <TaskSection basePath={tasksBase(location.pathname)} empty={t("scheduled_tasks.empty_active")} prefix={prefix} tasks={tasks.data.active_tasks} title={t("scheduled_tasks.section_active")} />
          <TaskSection basePath={tasksBase(location.pathname)} empty={t("scheduled_tasks.empty_fired")} prefix={prefix} tasks={tasks.data.fired_one_shots} title={t("scheduled_tasks.section_fired")} />
          <TaskSection basePath={tasksBase(location.pathname)} empty={t("scheduled_tasks.empty_archived")} prefix={prefix} tasks={tasks.data.archived_tasks} title={t("scheduled_tasks.section_archived")} />
        </>
      ) : null}
    </main>
  )
}

export function ScheduledTaskDetailRoute() {
  const { t } = useT("settings")
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
    <main aria-label={t("scheduled_tasks.aria_detail")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      {detail.isPending ? <PanelMessage>{t("scheduled_tasks.loading_detail")}</PanelMessage> : null}
      {detail.isError ? <ScheduledTasksError error={detail.error} /> : null}
      {detail.isSuccess ? <TaskDetail basePath={tasksBase(location.pathname)} payload={detail.data} prefix={prefix} /> : null}
    </main>
  )
}

export function ScheduledTaskFormRoute({ mode }: { mode: "new" | "edit" }) {
  const { t } = useT("settings")
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
    <main aria-label={mode === "new" ? t("scheduled_tasks.new_heading") : t("scheduled_tasks.edit_heading")} className="mx-auto max-w-3xl space-y-6 p-6">
      <header>
        <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{mode === "new" ? t("scheduled_tasks.new_heading") : t("scheduled_tasks.edit_heading")}</h1>
        {repository ? (
          <p className="mt-1 font-mono text-sm text-gray-600 dark:text-gray-400">{repository.slug}</p>
        ) : null}
      </header>

      {loading ? <PanelMessage>{t("scheduled_tasks.loading_form")}</PanelMessage> : null}
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
  const { t } = useT("settings")
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
      <div className="border-b border-gray-200 dark:border-gray-700 px-4 py-3">
        <h2 className="text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{title}</h2>
      </div>
      {tasks.length === 0 ? (
        <p className="p-4 text-sm text-gray-500 dark:text-gray-400">{empty}</p>
      ) : (
        <div className="overflow-x-auto">
          <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
            <thead className="bg-gray-50 dark:bg-gray-800 text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
              <tr>
                <th className="px-4 py-2">{t("scheduled_tasks.col_task")}</th>
                <th className="px-4 py-2">{t("scheduled_tasks.col_repository")}</th>
                <th className="px-4 py-2">{t("scheduled_tasks.schedule")}</th>
                <th className="px-4 py-2">{t("scheduled_tasks.state")}</th>
                <th className="px-4 py-2">{t("scheduled_tasks.col_last_fired")}</th>
                <th className="px-4 py-2"><span className="sr-only">{t("scheduled_tasks.actions")}</span></th>
              </tr>
            </thead>
            <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
              {tasks.map((task) => (
                <tr key={task.id}>
                  <td className="px-4 py-3 font-medium">
                    <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={`${basePath}/${task.id}`}>{task.name}</Link>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs">
                    <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(task.repository.repository_path, prefix)}>{task.repository.slug}</Link>
                  </td>
                  <td className="px-4 py-3 font-mono text-xs">{task.schedule_label || t("scheduled_tasks.none")}</td>
                  <td className="px-4 py-3"><StatePill state={task.state} /></td>
                  <td className="px-4 py-3 text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp fallback={t("scheduled_tasks.never")} value={task.last_fired_at} /></td>
                  <td className="px-4 py-3 text-right">
                    <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={`${basePath}/${task.id}`}>{t("scheduled_tasks.open")}</Link>
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
  const { t } = useT("settings")
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
            <h1 className="text-2xl font-semibold text-gray-900 dark:text-gray-100">{payload.task.name}</h1>
            <StatePill state={payload.task.state} />
          </div>
          <p className="mt-1 font-mono text-sm text-gray-600 dark:text-gray-400">
            <Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(payload.task.repository.repository_path, prefix)}>{payload.task.repository.slug}</Link>
          </p>
        </div>
        <TaskActions archive={archive} basePath={basePath} command={command} task={payload.task} />
      </header>

      <NoticeToast message={notice} onDismiss={() => setNotice(null)} />
      {command.isError ? <PanelMessage tone="error">{errorMessage(command.error, t("scheduled_tasks.error_update"))}</PanelMessage> : null}
      {archive.isError ? <PanelMessage tone="error">{errorMessage(archive.error, t("scheduled_tasks.error_archive"))}</PanelMessage> : null}

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="mb-3 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("scheduled_tasks.schedule")}</h2>
        <dl className="grid gap-y-2 text-sm sm:grid-cols-2">
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.field_kind")}</dt>
          <dd>{payload.task.kind}</dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.field_cron")}</dt>
          <dd className="font-mono">{payload.task.cron_expression || t("scheduled_tasks.none")}</dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.field_fire_at")}</dt>
          <dd><RelativeTimestamp fallback={t("scheduled_tasks.none")} value={payload.task.fire_at} /></dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.field_next_fire")}</dt>
          <dd><RelativeTimestamp fallback={t("scheduled_tasks.none")} value={payload.task.next_fire_at} /></dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.field_pileup")}</dt>
          <dd>{payload.task.pr_pileup_policy}</dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.field_auto_approve")}</dt>
          <dd>{payload.task.auto_approve_preview}</dd>
        </dl>
      </section>

      <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
        <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("scheduled_tasks.prompt_heading")}</h2>
        <pre className="whitespace-pre-wrap rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 p-3 font-mono text-xs">{payload.task.prompt}</pre>
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
  const { t } = useT("settings")
  return (
    <div className="flex flex-wrap items-center gap-2">
      {task.editable ? <Link className={buttonClass("secondary")} to={`${basePath}/${task.id}/edit`}>{t("scheduled_tasks.action_edit")}</Link> : null}
      {task.pausable ? (
        <button className={buttonClass("secondary")} disabled={command.isPending} onClick={() => command.mutate("pause")} type="button">{t("scheduled_tasks.action_pause")}</button>
      ) : null}
      {task.resumable ? (
        <button className={buttonClass("secondary")} disabled={command.isPending} onClick={() => command.mutate("resume")} type="button">{t("scheduled_tasks.action_resume")}</button>
      ) : null}
      {task.fireable ? (
        <button className={buttonClass("secondary")} disabled={command.isPending} onClick={() => command.mutate("fire")} type="button">{t("scheduled_tasks.action_fire")}</button>
      ) : null}
      {task.editable ? (
        <button
          className={buttonClass("danger-outline")}
          disabled={archive.isPending}
          onClick={() => {
            if (window.confirm(t("scheduled_tasks.confirm_archive"))) archive.mutate()
          }}
          type="button"
        >
          {t("scheduled_tasks.action_archive")}
        </button>
      ) : null}
    </div>
  )
}

function RecentJobs({ jobs, prefix }: { jobs: ScheduledTaskDetailPayload["recent_jobs"]; prefix: string }) {
  const { t } = useT("settings")
  return (
    <section className="rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4">
      <h2 className="mb-3 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">{t("scheduled_tasks.recent_jobs")}</h2>
      {jobs.length === 0 ? (
        <p className="text-sm text-gray-600 dark:text-gray-400">{t("scheduled_tasks.no_jobs")}</p>
      ) : (
        <table className="min-w-full divide-y divide-gray-200 dark:divide-gray-700">
          <thead className="text-left text-xs font-medium uppercase text-gray-500 dark:text-gray-400">
            <tr>
              <th className="px-2 py-2">{t("scheduled_tasks.col_job")}</th>
              <th className="px-2 py-2">{t("scheduled_tasks.state")}</th>
              <th className="px-2 py-2">{t("scheduled_tasks.col_pr")}</th>
              <th className="px-2 py-2">{t("scheduled_tasks.col_created")}</th>
            </tr>
          </thead>
          <tbody className="divide-y divide-gray-100 dark:divide-gray-800 text-sm">
            {jobs.map((job) => (
              <tr key={job.id}>
                <td className="px-2 py-2"><Link className="text-blue-600 dark:text-blue-400 underline hover:no-underline" to={withRoutePrefix(job.job_path, prefix)}>#{job.id}</Link></td>
                <td className="px-2 py-2">{job.closure_reason || job.state}</td>
                <td className="px-2 py-2">{job.pr_number || job.external_pr_number || t("scheduled_tasks.none")}</td>
                <td className="px-2 py-2 text-xs text-gray-500 dark:text-gray-400"><RelativeTimestamp value={job.created_at} /></td>
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
  const { t } = useT("settings")
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
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, t("scheduled_tasks.error_save"))}</PanelMessage> : null}
      <Field label={t("scheduled_tasks.name")}>
        <input className={inputClass()} onChange={(event) => setValues({ ...values, name: event.target.value })} type="text" value={values.name} />
      </Field>
      <Field label={t("scheduled_tasks.field_kind")}>
        <select className={inputClass()} onChange={(event) => setValues({ ...values, kind: event.target.value })} value={values.kind}>
          {options.kinds.map((kind) => <option key={kind} value={kind}>{kind}</option>)}
        </select>
      </Field>
      {values.kind === "one_shot" ? (
        <Field label={t("scheduled_tasks.field_fire_at")}>
          <input className={inputClass()} onChange={(event) => setValues({ ...values, fire_at: event.target.value })} type="datetime-local" value={values.fire_at} />
        </Field>
      ) : (
        <Field label={t("scheduled_tasks.field_cron")}>
          <input className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, cron_expression: event.target.value })} placeholder="0 9 * * 1" type="text" value={values.cron_expression} />
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("scheduled_tasks.cron_help")}</p>
        </Field>
      )}
      <Field label={t("scheduled_tasks.field_pileup")}>
        <select className={inputClass()} onChange={(event) => setValues({ ...values, pr_pileup_policy: event.target.value })} value={values.pr_pileup_policy}>
          {options.pr_pileup_policies.map((policy) => <option key={policy} value={policy}>{policy}</option>)}
        </select>
      </Field>
      <Field label={t("scheduled_tasks.field_auto_approve")}>
        <select className={inputClass()} onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })} value={values.auto_approve_mode}>
          {options.auto_approve_modes.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
        </select>
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{autoApproval?.preview}</p>
      </Field>
      <Field label={t("scheduled_tasks.prompt_heading")}>
        <textarea className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, prompt: event.target.value })} rows={8} value={values.prompt} />
      </Field>
      <div className="flex items-center gap-3">
        <button className="rounded bg-blue-600 px-3.5 py-2.5 font-medium text-white hover:bg-blue-500 dark:hover:bg-blue-500 disabled:cursor-not-allowed disabled:bg-blue-300 dark:disabled:bg-blue-900" disabled={save.isPending} type="submit">
          {save.isPending ? t("scheduled_tasks.saving") : mode === "new" ? t("scheduled_tasks.create_task") : t("scheduled_tasks.save")}
        </button>
        <Link className="text-sm text-gray-600 dark:text-gray-400 hover:text-gray-900 dark:hover:text-gray-100" to={mode === "new" ? basePath : `${basePath}/${id}`}>{t("scheduled_tasks.cancel")}</Link>
      </div>
    </form>
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

function StatePill({ state }: { state: string }) {
  const styles: Record<string, string> = {
    scheduled: "bg-green-100 dark:bg-green-950/40 text-green-700 dark:text-green-300",
    paused: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-400",
    auto_paused: "bg-red-100 dark:bg-red-950/40 text-red-700 dark:text-red-300",
    fired: "bg-blue-100 dark:bg-blue-950/40 text-blue-700 dark:text-blue-300"
  }
  return <span className={`inline-block rounded px-2 py-0.5 text-xs font-medium ${styles[state] || "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-300"}`}>{state}</span>
}

function ScheduledTasksError({ error }: { error: Error }) {
  const { t } = useT("settings")
  return <PanelMessage tone="error">{errorMessage(error, t("scheduled_tasks.error_load"))}</PanelMessage>
}


function tasksBase(pathname: string) {
  return `${routePrefix(pathname)}/scheduled_tasks`
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

