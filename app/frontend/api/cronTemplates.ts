import { deleteJson, getJson, patchJson, postJson } from "./client"

export type CronTemplateRow = {
  id: number
  name: string
  description: string | null
  cron_expression: string
  schedule_input: string | null
  schedule_format: string | null
  schedule_expression: string | null
  schedule_explanation: string | null
  schedule_timezone: string | null
  next_fire_at: string | null
  legacy_cron_expression: string | null
  pr_pileup_policy: string
  enabled: boolean
  applied_tasks_count: number
  created_at: string
  updated_at: string
}

export type CronTemplateDetail = CronTemplateRow & {
  prompt: string
}

export type CronTemplateRepository = {
  id: number
  slug: string
  new_scheduled_task_path: string
}

export type CronTemplateAppliedTask = {
  id: number
  name: string
  state: string
  repository_id: number
  repository_slug: string
  last_fired_at: string | null
  scheduled_task_path: string
  repository_path: string
}

export type CronTemplatesIndexPayload = {
  templates: CronTemplateRow[]
  pr_pileup_policies: string[]
  message?: string
}

export type CronTemplateDetailPayload = {
  template: CronTemplateDetail
  pr_pileup_policies: string[]
  repositories: CronTemplateRepository[]
  applied_tasks: CronTemplateAppliedTask[]
  message?: string
}

export type CronTemplateInput = {
  name: string
  description: string
  cron_expression: string
  schedule_input: string
  schedule_expression: string
  schedule_explanation?: string | null
  schedule_timezone: string
  pr_pileup_policy: string
  prompt: string
  enabled: boolean
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
}

export function fetchCronTemplates() {
  return getJson<CronTemplatesIndexPayload>("/api/v1/app/cron_templates")
}

export function fetchCronTemplate(id: string) {
  return getJson<CronTemplateDetailPayload>(`/api/v1/app/cron_templates/${id}`)
}

export function createCronTemplate(values: CronTemplateInput) {
  return postJson<CronTemplateDetailPayload>("/api/v1/app/cron_templates", {
    cron_template: values
  })
}

export function updateCronTemplate(id: number, values: CronTemplateInput) {
  return patchJson<CronTemplateDetailPayload>(`/api/v1/app/cron_templates/${id}`, {
    cron_template: values
  })
}

export function previewCronTemplateSchedule(scheduleInput: string) {
  return postJson<SchedulePreview>("/api/v1/app/cron_templates/preview_schedule", {
    schedule_input: scheduleInput
  })
}

export function deleteCronTemplate(id: number) {
  return deleteJson<CronTemplatesIndexPayload>(`/api/v1/app/cron_templates/${id}`)
}
