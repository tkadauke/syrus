import { postForm } from "./client"

export type BugReportInput = {
  title: string
  description: string
  screenshot?: File | null
  attachments?: File[]
}

export type BugReportPayload = {
  message: string
  job_id?: number
  issue_url?: string
}

export function createBugReport(input: BugReportInput) {
  const form = new FormData()
  form.set("title", input.title)
  form.set("description", input.description)
  if (input.screenshot) form.set("screenshot", input.screenshot)
  for (const file of input.attachments ?? []) {
    form.append("attachments[]", file)
  }

  return postForm<BugReportPayload>("/api/v1/app/bug_reports", form)
}
