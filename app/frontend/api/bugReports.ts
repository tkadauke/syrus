import { postForm } from "./client"

export type BugReportInput = {
  title: string
  description: string
  screenshot?: File | null
  attachments?: File[]
  context?: string
}

export type BugReportPayload = {
  message: string
  job_id?: number
  issue_url?: string
}

export type BugReportChatPayload = {
  message: string
  chat_id: number
  redirect_to: string
}

export function createBugReport(input: BugReportInput) {
  return postForm<BugReportPayload>("/api/v1/app/bug_reports", bugReportForm(input))
}

export function startBugReportChat(input: BugReportInput) {
  return postForm<BugReportChatPayload>("/api/v1/app/bug_reports/chat", bugReportForm(input))
}

function bugReportForm(input: BugReportInput) {
  const form = new FormData()
  form.set("title", input.title)
  form.set("description", input.description)
  if (input.screenshot) form.set("screenshot", input.screenshot)
  for (const file of input.attachments ?? []) {
    form.append("attachments[]", file)
  }
  if (input.context) form.set("context", input.context)

  return form
}
