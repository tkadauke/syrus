import { postJson } from "./client"

export type EventAction = {
  id: "file_job" | string
  label: string
  event_type?: string
}

export type FileEventJobInput = {
  event_type: string
  event_id: number
}

export type FileEventJobPayload = {
  message: string
  job_id?: number
  issue_url?: string
}

export function fileEventJob(input: FileEventJobInput) {
  return postJson<FileEventJobPayload>("/api/v1/app/event_actions/file_job", input)
}
