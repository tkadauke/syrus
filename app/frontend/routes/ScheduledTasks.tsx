import { RelativeTimestamp } from "../components/RelativeTimestamp"
import { PageHeading } from "../components/Heading"
import { inputClass } from "../lib/formClasses"
import { routePrefix, withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import type { UseMutationResult } from "@tanstack/react-query"
import type { FormEvent, ReactNode } from "react"
import { useEffect, useState } from "react"
import { Link, useLocation, useNavigate, useParams } from "react-router-dom"
import { buttonClass } from "../lib/buttonClasses"
import { Button, buttonClasses } from "../components/Button"
import { CopyableSlug } from "../components/CopyableSlug"
import { Input } from "../components/Input"
import { NoticeToast } from "../components/NoticeToast"
import { PanelMessage } from "../components/PanelMessage"
import { Select } from "../components/Select"
import { SlugHoverCard } from "../components/SlugHoverCard"
import { useT } from "../hooks/useT"
import { usePageTitle } from "../hooks/usePageTitle"
import { useConfirm } from "../hooks/useConfirm"
import {
  archiveScheduledTask,
  createScheduledTask,
  fetchNewScheduledTaskForm,
  fetchScheduledTask,
  fetchScheduledTasks,
  fetchScheduledTaskRepositoryOptions,
  fireScheduledTask,
  pauseScheduledTask,
  previewScheduledTaskSchedule,
  resumeScheduledTask,
  updateScheduledTask,
  type ScheduledTaskDetail,
  type ScheduledTaskDetailPayload,
  type ScheduledTaskInput,
  type ScheduledTaskOptions,
  type ScheduledTaskRepository,
  type ScheduledTasksIndexPayload,
  type ScheduledTaskRow
} from "../api/scheduledTasks"
import { fetchRepositorySkills, type SkillSummary } from "../api/skills"
import { initialArgs, SkillOption, SkillParameterInput } from "./RepositorySkillNew"
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
  usePageTitle(t("page_title_schedules"))
  const location = useLocation()
  const prefix = routePrefix(location.pathname)
  const tasks = useQuery({
    queryKey: ["scheduled_tasks"],
    queryFn: fetchScheduledTasks
  })

  return (
    <main aria-label={t("scheduled_tasks.aria_index")} className="mx-auto max-w-[96rem] space-y-6 p-6">
      <header className="flex flex-wrap items-start justify-between gap-3">
        <div>
          <PageHeading>{t("scheduled_tasks.heading")}</PageHeading>
          <p className="mt-1 max-w-2xl text-sm text-gray-600 dark:text-gray-400">{t("scheduled_tasks.description")}</p>
        </div>
        <Link className={buttonClasses("primary")} to={`${tasksBase(location.pathname)}/new`}>{t("scheduled_tasks.new_task")}</Link>
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
  const routeRepositoryId = params.repositoryId || ""
  const [pickedRepositoryId, setPickedRepositoryId] = useState("")
  const repositoryId = routeRepositoryId || pickedRepositoryId
  // The top-level /scheduled_tasks/new route has no :repositoryId param, so
  // that entry point must gate the form behind a mandatory repository pick
  // before it can even fetch the (per-repository) new-task form payload.
  const needsRepositoryPick = mode === "new" && !routeRepositoryId
  const fromTemplate = new URLSearchParams(location.search).get("from_template")
  const basePath = tasksBase(location.pathname)

  const repositoryOptions = useQuery({
    queryKey: ["scheduled_tasks", "new_repository_options"],
    queryFn: fetchScheduledTaskRepositoryOptions,
    enabled: needsRepositoryPick && repositoryId.length === 0
  })
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
  const skillsRepositoryId = repository ? String(repository.id) : repositoryId
  const showRepositoryPicker = needsRepositoryPick && repositoryId.length === 0

  return (
    <main aria-label={mode === "new" ? t("scheduled_tasks.new_heading") : t("scheduled_tasks.edit_heading")} className="mx-auto max-w-3xl space-y-6 p-6">
      <header>
        <PageHeading>{mode === "new" ? t("scheduled_tasks.new_heading") : t("scheduled_tasks.edit_heading")}</PageHeading>
        {repository ? (
          <p className="mt-1 font-mono text-sm text-gray-600 dark:text-gray-400">{repository.slug}</p>
        ) : null}
      </header>

      {showRepositoryPicker ? (
        <RepositoryPicker
          error={repositoryOptions.error}
          loading={repositoryOptions.isPending}
          onSelect={setPickedRepositoryId}
          repositories={repositoryOptions.data?.repositories || []}
        />
      ) : (
        <>
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
              skillsRepositoryId={skillsRepositoryId}
            />
          ) : null}
        </>
      )}
    </main>
  )
}

function RepositoryPicker({
  repositories,
  loading,
  error,
  onSelect
}: {
  repositories: ScheduledTaskRepository[]
  loading: boolean
  error: Error | null
  onSelect: (repositoryId: string) => void
}) {
  const { t } = useT("settings")
  const [value, setValue] = useState("")

  if (loading) return <PanelMessage>{t("scheduled_tasks.loading_form")}</PanelMessage>
  if (error) return <ScheduledTasksError error={error} />

  return (
    <form
      className="space-y-4 rounded border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4"
      onSubmit={(event) => {
        event.preventDefault()
        if (value) onSelect(value)
      }}
    >
      <Field label={t("scheduled_tasks.field_repository")}>
        <Select onChange={(event) => setValue(event.target.value)} required value={value}>
          <option value="">{t("scheduled_tasks.repository_placeholder")}</option>
          {repositories.map((repository) => (
            <option key={repository.id} value={repository.id}>{repository.slug}</option>
          ))}
        </Select>
      </Field>
      <Button disabled={!value} type="submit" variant="primary">{t("scheduled_tasks.repository_continue")}</Button>
    </form>
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
                  <td className="px-4 py-3 text-xs">{task.schedule_label || t("scheduled_tasks.none")}</td>
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
            <PageHeading>{payload.task.name}</PageHeading>
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
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.field_schedule")}</dt>
          <dd>{payload.task.schedule_explanation || payload.task.cron_expression || t("scheduled_tasks.none")}</dd>
          <dt className="text-gray-500 dark:text-gray-400">{t("scheduled_tasks.cron_expression_label")}</dt>
          <dd className="font-mono text-xs">{payload.task.schedule_expression || payload.task.cron_expression || t("scheduled_tasks.none")}</dd>
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
        <h2 className="mb-2 text-sm font-semibold uppercase text-gray-500 dark:text-gray-400">
          {payload.task.skill_name ? t("scheduled_tasks.skill_heading") : t("scheduled_tasks.prompt_heading")}
        </h2>
        {payload.task.skill_name ? (
          <div className="space-y-2 text-sm">
            <p className="font-mono">{payload.task.skill_name}</p>
            {Object.keys(payload.task.skill_args).length > 0 ? (
              <pre className="whitespace-pre-wrap rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 p-3 font-mono text-xs">
                {JSON.stringify(payload.task.skill_args, null, 2)}
              </pre>
            ) : null}
          </div>
        ) : (
          <pre className="whitespace-pre-wrap rounded border border-gray-200 dark:border-gray-700 bg-gray-50 dark:bg-gray-800 p-3 font-mono text-xs">{payload.task.prompt}</pre>
        )}
      </section>

      <RecentJobs jobs={payload.recent_jobs} />
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
  const { confirm, dialog } = useConfirm()
  return (
    <div className="flex flex-wrap items-center gap-2">
      {task.editable ? <Link className={buttonClasses("secondary")} to={`${basePath}/${task.id}/edit`}>{t("scheduled_tasks.action_edit")}</Link> : null}
      {task.pausable ? (
        <Button disabled={command.isPending} onClick={() => command.mutate("pause")} variant="secondary">{t("scheduled_tasks.action_pause")}</Button>
      ) : null}
      {task.resumable ? (
        <Button disabled={command.isPending} onClick={() => command.mutate("resume")} variant="secondary">{t("scheduled_tasks.action_resume")}</Button>
      ) : null}
      {task.fireable ? (
        <Button disabled={command.isPending} onClick={() => command.mutate("fire")} variant="secondary">{t("scheduled_tasks.action_fire")}</Button>
      ) : null}
      {task.editable ? (
        <button
          className={buttonClass("danger-outline")}
          disabled={archive.isPending}
          onClick={async () => {
            if (await confirm({ message: t("scheduled_tasks.confirm_archive"), destructive: true })) archive.mutate()
          }}
          type="button"
        >
          {t("scheduled_tasks.action_archive")}
        </button>
      ) : null}
      {dialog}
    </div>
  )
}

function RecentJobs({ jobs }: { jobs: ScheduledTaskDetailPayload["recent_jobs"] }) {
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
                <td className="px-2 py-2">
                  <SlugHoverCard id={job.id} kind="job">
                    <CopyableSlug slug={`JOB-${job.id}`} />
                  </SlugHoverCard>
                </td>
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
  skillsRepositoryId,
  fromTemplate,
  initial,
  options,
  basePath
}: {
  mode: "new" | "edit"
  id: number
  repositoryId: string
  skillsRepositoryId: string
  fromTemplate: string | null
  initial: ScheduledTaskInput
  options: ScheduledTaskOptions
  basePath: string
}) {
  const { t } = useT("settings")
  const { t: tJobs } = useT("jobs")
  const queryClient = useQueryClient()
  const navigate = useNavigate()
  const [values, setValues] = useState<ScheduledTaskInput>(initial)
  const [taskSource, setTaskSource] = useState<"prompt" | "skill">(initial.skill_name ? "skill" : "prompt")
  const skills = useQuery({
    queryKey: ["repositories", skillsRepositoryId, "skills"],
    queryFn: () => fetchRepositorySkills(skillsRepositoryId),
    enabled: taskSource === "skill" && skillsRepositoryId.length > 0
  })
  const selectedSkill = skills.data?.skills.find((skill) => skill.name === values.skill_name) || null

  function selectTaskSource(source: "prompt" | "skill") {
    setTaskSource(source)
    if (source === "prompt") setValues((current) => ({ ...current, skill_name: "", skill_args: {} }))
  }

  function selectSkill(skill: SkillSummary) {
    setValues((current) => ({ ...current, skill_name: skill.name, skill_args: initialArgs(skill) }))
  }

  const save = useMutation({
    mutationFn: (structuredIntent: Record<string, unknown> | null) => mode === "new"
      ? createScheduledTask(repositoryId, submitInput(values, structuredIntent), fromTemplate)
      : updateScheduledTask(id, submitInput(values, structuredIntent)),
    onSuccess: (payload) => {
      queryClient.setQueryData(["scheduled_tasks", String(payload.task.id)], payload)
      void queryClient.invalidateQueries({ queryKey: ["scheduled_tasks"] })
      navigate(`${basePath}/${payload.task.id}`)
    }
  })
  const preview = useMutation({
    mutationFn: previewScheduledTaskSchedule
  })
  // The preview result only reflects values.schedule_input once it resolves for
  // that exact string — while the debounce timer or the request itself is
  // still in flight, a stale (possibly unrelated) explanation must not linger
  // next to newly-typed, unvalidated input. Before any preview has run yet,
  // fall back to the persisted explanation (edit mode's initial render).
  const previewMatchesInput = preview.data?.schedule_input === values.schedule_input
  const previewErrors = previewMatchesInput ? preview.data?.errors || [] : []
  const previewExplanation = preview.data ? (previewMatchesInput ? preview.data.schedule_explanation : null) : values.schedule_explanation
  const previewSource = previewMatchesInput ? preview.data?.source : null

  useEffect(() => {
    setValues(initial)
    setTaskSource(initial.skill_name ? "skill" : "prompt")
  }, [initial])

  useEffect(() => {
    if (values.kind !== "cron" || !values.schedule_input.trim()) return

    const timer = window.setTimeout(() => preview.mutate(values.schedule_input), 300)
    return () => window.clearTimeout(timer)
  }, [values.kind, values.schedule_input])

  function submit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault()
    save.mutate(previewMatchesInput ? preview.data?.structured_intent ?? null : null)
  }

  const autoApproval = options.auto_approve_modes.find((option) => option.value === values.auto_approve_mode)

  return (
    <form className="space-y-5" onSubmit={submit}>
      {save.isError ? <PanelMessage tone="error">{errorMessage(save.error, t("scheduled_tasks.error_save"))}</PanelMessage> : null}
      <Field label={t("scheduled_tasks.name")}>
        <Input onChange={(event) => setValues({ ...values, name: event.target.value })} type="text" value={values.name} />
      </Field>
      <Field label={t("scheduled_tasks.field_kind")}>
        <Select onChange={(event) => setValues({ ...values, kind: event.target.value })} value={values.kind}>
          {options.kinds.map((kind) => <option key={kind} value={kind}>{kind}</option>)}
        </Select>
      </Field>
      {values.kind === "one_shot" ? (
        <Field label={t("scheduled_tasks.field_fire_at")}>
          <Input onChange={(event) => setValues({ ...values, fire_at: event.target.value })} type="datetime-local" value={values.fire_at} />
        </Field>
      ) : (
        <Field label={t("scheduled_tasks.field_schedule")}>
          <Input onChange={(event) => setValues({ ...values, schedule_input: event.target.value, cron_expression: event.target.value })} placeholder={t("scheduled_tasks.schedule_placeholder")} type="text" value={values.schedule_input} />
          <SchedulePreviewState errors={previewErrors} explanation={previewExplanation} loading={preview.isPending} source={previewSource} />
          <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("scheduled_tasks.schedule_help")}</p>
        </Field>
      )}
      <Field label={t("scheduled_tasks.field_pileup")}>
        <Select onChange={(event) => setValues({ ...values, pr_pileup_policy: event.target.value })} value={values.pr_pileup_policy}>
          {options.pr_pileup_policies.map((policy) => <option key={policy} value={policy}>{policy}</option>)}
        </Select>
      </Field>
      <Field label={t("scheduled_tasks.field_auto_approve")}>
        <Select onChange={(event) => setValues({ ...values, auto_approve_mode: event.target.value })} value={values.auto_approve_mode}>
          {options.auto_approve_modes.map((option) => <option key={option.value} value={option.value}>{option.label}</option>)}
        </Select>
        <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{autoApproval?.preview}</p>
      </Field>
      <Field label={t("scheduled_tasks.field_task_source")}>
        <div className="flex gap-4 text-sm text-gray-700 dark:text-gray-300">
          <label className="flex items-center gap-2">
            <Input checked={taskSource === "prompt"} onChange={() => selectTaskSource("prompt")} type="radio" value="prompt" />
            {t("scheduled_tasks.task_source_prompt")}
          </label>
          <label className="flex items-center gap-2">
            <Input checked={taskSource === "skill"} onChange={() => selectTaskSource("skill")} type="radio" value="skill" />
            {t("scheduled_tasks.task_source_skill")}
          </label>
        </div>
      </Field>
      {taskSource === "prompt" ? (
        <Field label={t("scheduled_tasks.prompt_heading")}>
          <textarea className={`${inputClass()} font-mono`} onChange={(event) => setValues({ ...values, prompt: event.target.value })} rows={8} value={values.prompt} />
        </Field>
      ) : (
        <>
          {skills.isPending ? <PanelMessage>{tJobs("skill_job_loading")}</PanelMessage> : null}
          {skills.isError ? <PanelMessage tone="error">{errorMessage(skills.error, tJobs("skill_job_load_error"))}</PanelMessage> : null}
          {skills.data && skills.data.skills.length === 0 ? <PanelMessage>{tJobs("skill_job_no_skills")}</PanelMessage> : null}
          {skills.data && skills.data.skills.length > 0 ? (
            <>
              <Field label={tJobs("skill_job_section_pick")}>
                <div className="space-y-2">
                  {skills.data.skills.map((skill) => (
                    <SkillOption key={skill.name} onSelect={() => selectSkill(skill)} selected={skill.name === values.skill_name} skill={skill} />
                  ))}
                </div>
              </Field>
              {selectedSkill && selectedSkill.parameters.length > 0 ? (
                <Field label={tJobs("skill_job_section_parameters")}>
                  <div className="space-y-4">
                    {selectedSkill.parameters.map((field) => (
                      <SkillParameterInput
                        field={field}
                        key={field.key}
                        onChange={(value) => setValues((current) => ({ ...current, skill_args: { ...current.skill_args, [field.key]: value } }))}
                        value={values.skill_args[field.key]}
                      />
                    ))}
                  </div>
                </Field>
              ) : null}
            </>
          ) : null}
        </>
      )}
      <div className="flex items-center gap-3">
        <Button
          disabled={save.isPending || (taskSource === "skill" && !values.skill_name)}
          type="submit"
          variant="primary"
        >
          {save.isPending ? t("scheduled_tasks.saving") : mode === "new" ? t("scheduled_tasks.create_task") : t("scheduled_tasks.save")}
        </Button>
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

function SchedulePreviewState({ explanation, errors, loading, source }: { explanation?: string | null; errors: string[]; loading: boolean; source?: string | null }) {
  const { t } = useT("settings")
  if (loading) return <p className="mt-1 text-xs text-gray-500 dark:text-gray-400">{t("scheduled_tasks.preview_loading")}</p>
  if (errors.length > 0) return <p className="mt-1 text-xs text-red-600 dark:text-red-400">{errors.join(", ")}</p>
  if (explanation) {
    return (
      <p className="mt-1 text-xs text-emerald-700 dark:text-emerald-300">
        {explanation}
        {source === "structured_intent" ? <span className="ml-1 text-emerald-600 dark:text-emerald-400">{t("scheduled_tasks.preview_via_ai")}</span> : null}
      </p>
    )
  }
  return null
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
    skill_name: input.skill_name || "",
    skill_args: input.skill_args || {},
    kind: input.kind || "cron",
    cron_expression: input.cron_expression || "0 9 * * 1",
    schedule_input: input.schedule_input || input.cron_expression || "Every Monday at 9:00 AM",
    schedule_expression: input.schedule_expression || "",
    schedule_timezone: input.schedule_timezone || "UTC",
    fire_at: toDatetimeLocal(input.fire_at),
    pr_pileup_policy: input.pr_pileup_policy || "skip",
    auto_approve_mode: input.auto_approve_mode || "never"
  }
}

function detailInput(task: ScheduledTaskDetail): ScheduledTaskInput {
  return formInput({
    name: task.name,
    prompt: task.prompt,
    skill_name: task.skill_name || "",
    skill_args: task.skill_args || {},
    kind: task.kind,
    cron_expression: task.cron_expression || "",
    schedule_input: task.schedule_input || task.cron_expression || "",
    schedule_expression: task.schedule_expression || "",
    schedule_timezone: task.schedule_timezone || "UTC",
    fire_at: task.fire_at || "",
    pr_pileup_policy: task.pr_pileup_policy,
    auto_approve_mode: task.auto_approve_mode
  })
}

function submitInput(values: ScheduledTaskInput, structuredIntent: Record<string, unknown> | null): ScheduledTaskInput {
  const isSkillTask = values.skill_name.trim().length > 0
  return {
    ...values,
    cron_expression: values.kind === "cron" ? values.cron_expression : "",
    schedule_input: values.kind === "cron" ? values.schedule_input : "",
    fire_at: values.kind === "one_shot" ? values.fire_at : "",
    structured_intent: values.kind === "cron" ? structuredIntent : null,
    prompt: isSkillTask ? "" : values.prompt,
    skill_args: isSkillTask ? values.skill_args : {}
  }
}

function toDatetimeLocal(value: string | null) {
  if (!value) return ""
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value
  const pad = (number: number) => String(number).padStart(2, "0")
  return `${date.getFullYear()}-${pad(date.getMonth() + 1)}-${pad(date.getDate())}T${pad(date.getHours())}:${pad(date.getMinutes())}`
}
