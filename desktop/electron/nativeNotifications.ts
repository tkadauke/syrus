import { Notification, shell } from "electron"
import { t } from "./i18n.js"

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
  ci_failed: "notification.ci_failed",
  ci_failure: "notification.ci_failed",
  job_failed: "notification.job_failed",
  job_finished: "notification.job_finished",
  job_succeeded: "notification.job_succeeded",
  job_needs_attention: "notification.job_attention",
  pr_closed: "notification.pr_closed",
  pr_failed: "notification.pr_failed",
  pr_merged: "notification.pr_merged",
  pr_opened: "notification.pr_ready",
  pr_ready: "notification.pr_ready",
  pr_ready_for_review: "notification.pr_ready",
  pull_request_closed: "notification.pr_closed",
  pull_request_failed: "notification.pr_failed",
  pull_request_merged: "notification.pr_merged",
  pull_request_opened: "notification.pr_ready",
  pull_request_ready_for_review: "notification.pr_ready",
  investigation_escalated: "notification.investigation"
}

const isRecord = (value: unknown): value is Record<string, unknown> => Boolean(value) && typeof value === "object" && !Array.isArray(value)

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
    return t(label)
  }

  const words = normalized.split(/[_\-. ]+/).filter(Boolean)
  if (words.length === 0) {
    return t("notification.default")
  }

  const firstWord = words[0] === "pr" ? "PR" : words[0][0].toUpperCase() + words[0].slice(1)
  return [firstWord, ...words.slice(1)].join(" ")
}

export const nativeNotificationClickUrl = (payload: Pick<NativeNotificationPayload, "jobId" | "prUrl">, credentials: Credentials | null) => {
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
