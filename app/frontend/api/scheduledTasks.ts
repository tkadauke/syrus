import { deleteJson, getJson, patchJson, postJson } from "./client"
import type { RepositoryTab } from "./repositories"

export type ScheduledTaskRepository = {
  id: number
  slug: string
  repository_path: string
}

export type ScheduledTaskRow = {
  id: number
  name: string
  kind: string
  state: string
  repository: ScheduledTaskRepository
  schedule_label: string | null
  schedule_explanation: string | null
  schedule_timezone: string | null
  schedule_expression: string | null
  last_fired_at: string | null
  archived_at: string | null
  consecutive_failure_count: number
  scheduled_task_path: string
}

export type ScheduledTaskDetail = ScheduledTaskRow & {
  prompt: string
  cron_expression: string | null
  hourly_cron_expression: string | null
  schedule_input: string | null
  schedule_format: string | null
  legacy_cron_expression: string | null
  fire_at: string | null
  next_fire_at: string | null
  pr_pileup_policy: string
  auto_approve_mode: string
  auto_approve_preview: string
  last_successful_fire_at: string | null
  archived: boolean
  fireable: boolean
  pausable: boolean
  resumable: boolean
  editable: boolean
}

export type ScheduledTaskInput = {
  name: string
  prompt: string
  kind: string
  cron_expression: string
  schedule_input: string
  schedule_expression: string
  schedule_explanation?: string | null
  schedule_timezone: string
  fire_at: string
  pr_pileup_policy: string
  auto_approve_mode: string
  structured_intent?: Record<string, unknown> | null
}

export type ScheduledTaskOptions = {
  kinds: string[]
  pr_pileup_policies: string[]
  auto_approve_modes: Array<{
    value: string
    label: string
    preview: string
  }>
}

export type ScheduledTaskJob = {
  id: number
  state: string
  closure_reason: string | null
  pr_number: number | null
  external_pr_number: number | null
  created_at: string
  job_path: string
}

export type ScheduledTasksIndexPayload = {
  active_tasks: ScheduledTaskRow[]
  fired_one_shots: ScheduledTaskRow[]
  archived_tasks: ScheduledTaskRow[]
  options: ScheduledTaskOptions
  message?: string
}

export type ScheduledTaskDetailPayload = {
  task: ScheduledTaskDetail
  recent_jobs: ScheduledTaskJob[]
  options: ScheduledTaskOptions
  message?: string
  fire_result?: {
    fired: boolean
    skipped: boolean
    reason: string | null
    job_id: number | null
  }
}

export type RepositoryScheduledTask = ScheduledTaskDetail & {
  active: boolean
}

export type RepositoryScheduledTasksPayload = {
  repository: ScheduledTaskRepository
  tabs: RepositoryTab[]
  tasks: RepositoryScheduledTask[]
  new_scheduled_task_path: string
  options: ScheduledTaskOptions
  message?: string
}

export type ScheduledTaskFormPayload = {
  task: ScheduledTaskInput & { id: number | null; cron_template_id: number | null }
  repository: ScheduledTaskRepository
  from_template: { id: number; name: string; cron_template_path: string } | null
  options: ScheduledTaskOptions
}

export type SchedulePreview = {
  valid: boolean
  schedule_input: string
  schedule_format: string
  schedule_expression: string | null
  schedule_timezone: string
  schedule_explanation: string | null
  next_fire_at: string | null
  cron_expression: string | null
  errors: string[]
  source: string | null
  structured_intent: Record<string, unknown> | null
}

export function fetchScheduledTasks() {
  return getJson<ScheduledTasksIndexPayload>("/api/v1/app/scheduled_tasks")
}

export function fetchScheduledTask(id: string) {
  return getJson<ScheduledTaskDetailPayload>(`/api/v1/app/scheduled_tasks/${id}`)
}

export function fetchNewScheduledTaskForm(repositoryId: string, fromTemplate?: string | null) {
  const query = fromTemplate ? `?${new URLSearchParams({ from_template: fromTemplate }).toString()}` : ""
  return getJson<ScheduledTaskFormPayload>(`/api/v1/app/repositories/${repositoryId}/scheduled_tasks/new${query}`)
}

export function fetchRepositoryScheduledTasks(repositoryId: string) {
  return getJson<RepositoryScheduledTasksPayload>(`/api/v1/app/repositories/${repositoryId}/scheduled_tasks`)
}

export function createScheduledTask(repositoryId: string, values: ScheduledTaskInput, fromTemplate?: string | null) {
  const query = fromTemplate ? `?${new URLSearchParams({ from_template: fromTemplate }).toString()}` : ""
  return postJson<ScheduledTaskDetailPayload>(`/api/v1/app/repositories/${repositoryId}/scheduled_tasks${query}`, {
    scheduled_task: values
  })
}

export function updateScheduledTask(id: number, values: ScheduledTaskInput) {
  return patchJson<ScheduledTaskDetailPayload>(`/api/v1/app/scheduled_tasks/${id}`, {
    scheduled_task: values
  })
}

export function previewScheduledTaskSchedule(scheduleInput: string) {
  return postJson<SchedulePreview>("/api/v1/app/scheduled_tasks/preview_schedule", {
    schedule_input: scheduleInput
  })
}

export function archiveScheduledTask(id: number) {
  return deleteJson<ScheduledTasksIndexPayload>(`/api/v1/app/scheduled_tasks/${id}`)
}

export function pauseScheduledTask(id: number) {
  return postJson<ScheduledTaskDetailPayload>(`/api/v1/app/scheduled_tasks/${id}/pause`)
}

export function resumeScheduledTask(id: number) {
  return postJson<ScheduledTaskDetailPayload>(`/api/v1/app/scheduled_tasks/${id}/resume`)
}

export function fireScheduledTask(id: number) {
  return postJson<ScheduledTaskDetailPayload>(`/api/v1/app/scheduled_tasks/${id}/fire_now`)
}

export function updateRepositoryScheduledTask(repositoryId: number, id: number, enabled: boolean) {
  return patchJson<RepositoryScheduledTasksPayload>(`/api/v1/app/repositories/${repositoryId}/scheduled_tasks/${id}`, {
    enabled
  })
}

export function deleteRepositoryScheduledTask(repositoryId: number, id: number) {
  return deleteJson<RepositoryScheduledTasksPayload>(`/api/v1/app/repositories/${repositoryId}/scheduled_tasks/${id}`)
}
