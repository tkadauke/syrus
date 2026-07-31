import { Notification, shell } from "electron"

type Credentials = {
  url: string
  token: string
}

type NativeNotificationPayload = {
  kind: string
  body: string
  jobId: string | null
  prUrl: string | null
}

const KIND_LABELS: Record<string, string> = {
  ci_failed: "CI failed",
  ci_failure: "CI failed",
  job_failed: "Job failed",
  job_finished: "Job finished",
  job_succeeded: "Job succeeded",
  job_needs_attention: "Job needs attention",
  epic_failed: "Feature needs attention",
  epic_feedback_queued: "Feature update started",
  epic_review_ready: "Feature ready for review",
  pr_closed: "PR closed",
  pr_failed: "PR failed",
  pr_merged: "PR merged",
  pr_opened: "PR ready for review",
  pr_ready: "PR ready for review",
  pr_ready_for_review: "PR ready for review",
  pull_request_closed: "PR closed",
  pull_request_failed: "PR failed",
  pull_request_merged: "PR merged",
  pull_request_opened: "PR ready for review",
  pull_request_ready_for_review: "PR ready for review"
}

const isRecord = (value: unknown): value is Record<string, unknown> =>
  Boolean(value) && typeof value === "object" && !Array.isArray(value)

const stringValue = (value: unknown) => (typeof value === "string" ? value.trim() : "")

const jobIdValue = (value: unknown) => {
  if (typeof value === "number" && Number.isFinite(value)) {
    return String(value)
  }

  return stringValue(value) || null
}

const httpUrlValue = (value: unknown) => {
  const raw = stringValue(value)
  if (!raw || !URL.canParse(raw)) {
    return null
  }

  const url = new URL(raw)
  return ["http:", "https:"].includes(url.protocol) ? url.toString() : null
}

const notificationPayloadRecord = (event: unknown) => {
  if (!isRecord(event) || event.type !== "notification_created") {
    return null
  }

  const payload = isRecord(event.payload) ? event.payload : event
  return isRecord(payload.notification) ? payload.notification : payload
}

const notificationPayload = (event: unknown): NativeNotificationPayload | null => {
  const payload = notificationPayloadRecord(event)
  if (!payload) {
    return null
  }

  const kind = stringValue(payload.kind)
  const body = stringValue(payload.body)
  if (!kind || !body) {
    return null
  }

  return {
    kind,
    body,
    jobId: jobIdValue(payload.job_id ?? payload.jobId),
    prUrl: httpUrlValue(payload.pr_url ?? payload.prUrl)
  }
}

export const nativeNotificationTitle = (kind: string) => {
  const normalized = kind.trim().toLowerCase()
  const label = KIND_LABELS[normalized]
  if (label) {
    return label
  }

  const words = normalized.split(/[_\-. ]+/).filter(Boolean)
  if (words.length === 0) {
    return "Syrus notification"
  }

  const firstWord = words[0] === "pr" ? "PR" : words[0][0].toUpperCase() + words[0].slice(1)
  return [firstWord, ...words.slice(1)].join(" ")
}

export const nativeNotificationClickUrl = (
  payload: Pick<NativeNotificationPayload, "jobId" | "prUrl">,
  credentials: Credentials | null
) => {
  if (payload.prUrl) {
    return payload.prUrl
  }

  if (!payload.jobId || !credentials) {
    return null
  }

  const baseUrl = httpUrlValue(credentials.url)
  if (!baseUrl) {
    return null
  }

  return new URL(`/jobs/${encodeURIComponent(payload.jobId)}`, `${baseUrl}/`).toString()
}

export const dispatchNativeNotification = (event: unknown, credentials: Credentials | null) => {
  if (!Notification.isSupported()) {
    return false
  }

  const payload = notificationPayload(event)
  if (!payload) {
    return false
  }

  const notification = new Notification({
    title: nativeNotificationTitle(payload.kind),
    body: payload.body
  })
  const clickUrl = nativeNotificationClickUrl(payload, credentials)
  if (clickUrl) {
    notification.on("click", () => {
      void shell.openExternal(clickUrl)
    })
  }

  notification.show()
  return true
}
