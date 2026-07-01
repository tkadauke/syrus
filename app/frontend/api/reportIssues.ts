import { postJson } from "./client"

export type ReportIssueInput = {
  title: string
  body: string
}

export type ReportIssuePayload = {
  issue_url: string
}

export function createReportIssue(input: ReportIssueInput) {
  return postJson<ReportIssuePayload>("/api/v1/app/report_issue", input)
}
