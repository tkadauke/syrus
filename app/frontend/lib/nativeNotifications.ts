// Dispatches native OS notifications from the shared frontend via the
// standard Web Notification API. Works unmodified in both a plain browser
// tab and Electron's webAppWindow (Chromium's renderer supports the
// standard Notification API, so no Electron-specific branching is needed
// here). Mirrors desktop/electron/nativeNotifications.ts's kind->label and
// click-URL conventions conceptually, but that file is Electron-main-only
// code and must not be imported into this bundle.
import { routePrefix, withRoutePrefix } from "./routing"

export type NativeNotificationPayload = {
  kind: string
  body: string
  jobId: number | string | null
  prUrl: string | null
}

const KIND_LABELS: Record<string, string> = {
  ci_failed: "CI failed",
  ci_failure: "CI failed",
  job_failed: "Job failed",
  job_finished: "Job finished",
  job_succeeded: "Job succeeded",
  job_implemented: "Job implemented",
  job_needs_attention: "Job needs attention",
  epic_failed: "Feature needs attention",
  epic_completed: "Feature completed",
  epic_feedback_queued: "Feature update started",
  epic_review_ready: "Feature ready for review",
  pr_closed: "PR closed",
  pr_comment_addressed: "PR feedback addressed",
  pr_failed: "PR failed",
  pr_merged: "PR merged",
  pr_opened: "PR ready for review",
  pr_ready: "PR ready for review",
  pr_ready_for_review: "PR ready for review",
  pull_request_closed: "PR closed",
  pull_request_failed: "PR failed",
  pull_request_merged: "PR merged",
  pull_request_opened: "PR ready for review",
  pull_request_ready_for_review: "PR ready for review",
  main_broken: "Main branch broken",
  main_inconclusive: "Main branch health inconclusive",
  main_recovered: "Main branch recovered",
  upstream_pr_closed: "Upstream PR closed",
  external_pr_feedback: "External PR feedback"
}

export function nativeNotificationTitle(kind: string) {
  const normalized = kind.trim().toLowerCase()
  const label = KIND_LABELS[normalized]
  if (label) return label

  const words = normalized.split(/[_\-. ]+/).filter(Boolean)
  if (words.length === 0) return "Syrus notification"

  const firstWord = words[0] === "pr" ? "PR" : words[0][0].toUpperCase() + words[0].slice(1)
  return [firstWord, ...words.slice(1)].join(" ")
}

export function nativeNotificationClickUrl(payload: Pick<NativeNotificationPayload, "jobId" | "prUrl">) {
  if (payload.prUrl) return payload.prUrl
  if (payload.jobId == null) return null

  const prefix = routePrefix(window.location.pathname)
  return withRoutePrefix(`/jobs/${encodeURIComponent(String(payload.jobId))}`, prefix)
}

export function isNativeNotificationSupported() {
  return typeof window !== "undefined" && typeof window.Notification !== "undefined"
}

// Lazy permission request -- only ever called from an explicit user
// interaction (bell click, settings toggle), never on page load. Resolves
// immediately with the existing permission if it isn't still "default" so
// callers can invoke this unconditionally without re-prompting.
export function requestNativeNotificationPermission() {
  if (!isNativeNotificationSupported()) return Promise.resolve<NotificationPermission>("denied")
  if (window.Notification.permission !== "default") return Promise.resolve(window.Notification.permission)

  return window.Notification.requestPermission()
}

export function dispatchNativeNotification(payload: NativeNotificationPayload) {
  if (!isNativeNotificationSupported()) return false
  if (window.Notification.permission !== "granted") return false

  let notification: Notification
  try {
    notification = new window.Notification(nativeNotificationTitle(payload.kind), { body: payload.body })
  } catch {
    return false
  }

  const clickUrl = nativeNotificationClickUrl(payload)
  if (clickUrl) {
    notification.onclick = () => {
      window.focus()
      window.location.href = clickUrl
      notification.close()
    }
  }

  return true
}
