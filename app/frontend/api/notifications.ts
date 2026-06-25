import { getJson, patchJson, postJson } from "./client"

export type NotificationRecord = {
  id: number
  kind: string
  body: string
  read_at: string | null
  pr_url: string | null
  job_id: number | null
  created_at: string
}

export type NotificationsPagination = {
  page: number
  per_page: number
  total: number
  total_pages: number
}

export type NotificationsPayload = {
  notifications: NotificationRecord[]
  unread_count: number
  pagination: NotificationsPagination
}

export type NotificationPayload = {
  notification: NotificationRecord
  unread_count: number
}

export function fetchNotifications(options: { page?: number; unread?: boolean } = {}) {
  const params = new URLSearchParams()

  if (options.page && options.page > 1) params.set("page", String(options.page))
  if (options.unread) params.set("unread", "true")

  const search = params.toString()
  return getJson<NotificationsPayload>(`/api/v1/app/notifications${search ? `?${search}` : ""}`)
}

export function markAllNotificationsRead() {
  return postJson<NotificationsPayload>("/api/v1/app/notifications/mark_all_read")
}

export function markNotificationRead(id: string | number) {
  return patchJson<NotificationPayload>(`/api/v1/app/notifications/${id}/mark_read`)
}
