import { RelativeTimestamp } from "./RelativeTimestamp"
import { withRoutePrefix } from "../lib/routing"
import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { type MouseEvent, type ReactNode, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import { fetchNotifications, markAllNotificationsRead, markNotificationRead, type NotificationRecord, type NotificationsPayload } from "../api/notifications"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"
import { requestNativeNotificationPermission } from "../lib/nativeNotifications"
import { useT } from "../hooks/useT"
import { ACTIVITY_MOBILE_QUERY, useMediaQuery } from "../hooks/useMediaQuery"
import { useActivity } from "./activity/ActivityContext"
import { ActivityState } from "./activity/ActivityState"
import { Button } from "./Button"
import { noticePopoverSurfaceClass } from "./noticeStyles"

export const notificationsQueryKey = ["notifications"] as const

export function NotificationsBell({ initialUnreadCount, prefix, onNavigate }: { initialUnreadCount?: number; prefix: string; onNavigate?: () => void }) {
  const { t } = useT("nav")
  const [open, setOpen] = useState(false)
  const activity = useActivity()
  const isMobile = useMediaQuery(ACTIVITY_MOBILE_QUERY)
  const panelRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const notifications = useNotificationsQuery({ enabled: open || initialUnreadCount == null })
  const unreadCount = notifications.data?.unread_count ?? initialUnreadCount ?? 0
  const badge = unreadCount > 9 ? "9+" : String(unreadCount)
  const label = unreadCount > 0 ? t("notifications.aria_unread", { count: unreadCount }) : t("notifications.title")

  if (isMobile && activity) {
    return (
      <button
        aria-haspopup="dialog"
        aria-label={label}
        className={bellButtonClass()}
        onClick={(event) => {
          void requestNativeNotificationPermission()
          activity.openActivity("notifications", { invoker: event.currentTarget, onNavigate })
        }}
        type="button"
      >
        <BellIcon />
        {unreadCount > 0 ? <NotificationBadge>{badge}</NotificationBadge> : null}
      </button>
    )
  }

  if (isMobile) {
    return (
      <Link
        aria-label={label}
        className={bellButtonClass()}
        onClick={() => {
          void requestNativeNotificationPermission()
          setOpen(false)
          onNavigate?.()
        }}
        to={withRoutePrefix("/notifications", prefix)}
      >
        <BellIcon />
        {unreadCount > 0 ? <NotificationBadge>{badge}</NotificationBadge> : null}
      </Link>
    )
  }

  return (
    <div className="relative" ref={panelRef}>
      <button
        aria-expanded={open}
        aria-haspopup="dialog"
        aria-label={label}
        className={bellButtonClass()}
        onClick={() => {
          void requestNativeNotificationPermission()
          setOpen((current) => !current)
        }}
        type="button"
      >
        <BellIcon />
        {unreadCount > 0 ? <NotificationBadge>{badge}</NotificationBadge> : null}
      </button>
      {open ? (
        <div className={noticePopoverSurfaceClass()}>
          <NotificationsPanel
            loading={notifications.isPending}
            notifications={notifications.data?.notifications ?? []}
            onNavigate={() => {
              setOpen(false)
              onNavigate?.()
            }}
            prefix={prefix}
            title={t("notifications.title")}
          />
        </div>
      ) : null}
    </div>
  )
}

export function NotificationsRoute() {
  const { t } = useT("nav")
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const notifications = useNotificationsQuery({ enabled: true })

  return (
    <main aria-label={t("notifications.title")} className="min-h-full bg-gray-50 p-4 dark:bg-gray-900 sm:p-6">
      <div className="mx-auto max-w-3xl">
        <Button className="mb-4" onClick={() => navigate(-1)} variant="secondary">
          <BackIcon />
          <span>{t("notifications.back")}</span>
        </Button>
        <section className="rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
          <NotificationsPanel
            loading={notifications.isPending}
            notifications={notifications.data?.notifications ?? []}
            prefix={prefix}
            title={t("notifications.title")}
          />
        </section>
      </div>
    </main>
  )
}

/** Notifications tab content for the shared mobile Activity shell. */
export function NotificationsActivityPanel({ navigateTo, prefix }: { navigateTo: (to: string) => void; prefix: string }) {
  const { t } = useT("nav")
  const notifications = useNotificationsQuery({ enabled: true })
  return (
    <NotificationsPanel
      embedded
      error={notifications.isError}
      loading={notifications.isPending}
      notifications={notifications.data?.notifications ?? []}
      navigateTo={navigateTo}
      prefix={prefix}
      title={t("notifications.title")}
    />
  )
}

function NotificationsPanel({
  loading = false,
  notifications,
  navigateTo,
  onNavigate,
  prefix,
  title,
  embedded = false,
  error = false
}: {
  embedded?: boolean
  error?: boolean
  loading?: boolean
  navigateTo?: (to: string) => void
  notifications: NotificationRecord[]
  onNavigate?: () => void
  prefix: string
  title: string
}) {
  const { t } = useT("nav")
  const queryClient = useQueryClient()
  const markAll = useMutation({
    mutationFn: markAllNotificationsRead,
    onSuccess(payload) {
      queryClient.setQueryData<NotificationsPayload>(notificationsQueryKey, (current) => current ? {
        ...current,
        unread_count: payload.unread_count,
        notifications: current.notifications.map((notification) => ({
          ...notification,
          read_at: notification.read_at ?? new Date().toISOString()
        }))
      } : current)
    }
  })

  return (
    <div>
      <div className="flex items-center justify-between gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-800">
        {embedded ? (
          <span className="text-xs text-text-muted">{title}</span>
        ) : (
          <h1 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
        )}
        <button
          className="rounded px-2 py-1 text-xs font-medium text-brand-emphasis hover:bg-brand/10 disabled:cursor-not-allowed disabled:text-gray-400 dark:disabled:text-gray-600"
          disabled={markAll.isPending || notifications.length === 0}
          onClick={() => markAll.mutate()}
          type="button"
        >
          {t("notifications.mark_all_read")}
        </button>
      </div>
      {loading ? (
        embedded ? (
          <ActivityState kind="loading" />
        ) : (
          <div className="px-4 py-6 text-sm text-gray-500 dark:text-gray-400">{t("notifications.loading")}</div>
        )
      ) : error && notifications.length === 0 ? (
        <ActivityState kind="error" />
      ) : notifications.length > 0 ? (
        <div className={embedded ? undefined : "max-h-[28rem] overflow-y-auto"}>
          {notifications.map((notification) => (
            <NotificationRow key={notification.id} navigateTo={navigateTo} notification={notification} onNavigate={onNavigate} prefix={prefix} />
          ))}
        </div>
      ) : embedded ? (
        <ActivityState kind="empty" message={t("notifications.empty")} />
      ) : (
        <div className="px-4 py-8 text-center text-sm text-gray-500 dark:text-gray-400">{t("notifications.empty")}</div>
      )}
    </div>
  )
}

function NotificationRow({
  navigateTo,
  notification,
  onNavigate,
  prefix
}: {
  navigateTo?: (to: string) => void
  notification: NotificationRecord
  onNavigate?: () => void
  prefix: string
}) {
  const { t } = useT("nav")
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const read = Boolean(notification.read_at)
  const jobTarget = notification.job_id ? withRoutePrefix(`/jobs/${notification.job_id}`, prefix) : null
  const target = notification.target_path ? withRoutePrefix(notification.target_path, prefix) : jobTarget
  const prNumber = notification.pr_url?.match(/\/pull\/(\d+)/)?.[1]
  const showJobTitle = Boolean(notification.job_title && !bodyIncludesJobTitle(notification.body, notification.job_title))
  const markRead = useMutation({
    mutationFn: () => markNotificationRead(notification.id),
    onSuccess(payload) {
      queryClient.setQueryData<NotificationsPayload>(notificationsQueryKey, (current) => {
        if (!current) return current
        return {
          ...current,
          unread_count: payload.unread_count,
          notifications: current.notifications.map((item) => (item.id === payload.notification.id ? payload.notification : item))
        }
      })
    }
  })

  function openNotification() {
    markRead.mutate(undefined, {
      onSettled() {
        if (navigateTo) {
          if (target) navigateTo(target)
          else onNavigate?.()
          return
        }
        onNavigate?.()
        if (target) navigate(target)
      }
    })
  }

  function openPullRequest(event: MouseEvent<HTMLAnchorElement>) {
    event.stopPropagation()
    event.preventDefault()
    markRead.mutate()
    if (notification.pr_url) window.open(notification.pr_url, "_blank", "noopener")
  }

  return (
    <div
      className={`flex w-full min-w-0 items-start gap-3 border-b border-gray-100 px-4 py-3 text-left last:border-b-0 ${target ? "cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-900" : ""} ${read ? "" : "bg-brand/10"}`}
      onClick={openNotification}
      onKeyDown={(event) => {
        if (!target) return
        if (event.target !== event.currentTarget) return
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault()
          openNotification()
        }
      }}
      role={target ? "button" : undefined}
      tabIndex={target ? 0 : undefined}
    >
      <KindIcon kind={notification.kind} />
      <span className="min-w-0 flex-1">
        <span className={`block text-sm leading-5 ${read ? "font-medium text-gray-700 dark:text-gray-300" : "font-semibold text-gray-950 dark:text-gray-100"}`}>
          {notification.body}
        </span>
        {showJobTitle ? <span className="mt-0.5 block truncate text-xs text-gray-500 dark:text-gray-400">{notification.job_title}</span> : null}
        <span className="mt-1 flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
          {notification.pr_url ? (
            <>
              <a
                className="font-medium text-brand-emphasis hover:underline"
                href={notification.pr_url}
                onClick={openPullRequest}
                rel="noopener"
                target="_blank"
              >
                PR #{prNumber ?? t("notifications.pr_link")}
              </a>
              <span aria-hidden="true">·</span>
            </>
          ) : null}
          <span>
            <RelativeTimestamp value={notification.created_at} />
          </span>
        </span>
      </span>
    </div>
  )
}

export function useNotificationsQuery({ enabled }: { enabled: boolean }) {
  return useQuery({
    queryKey: notificationsQueryKey,
    queryFn: () => fetchNotifications({ pagination: false }),
    enabled,
    staleTime: 30_000
  })
}

function bodyIncludesJobTitle(body: string, jobTitle: string | null) {
  if (!jobTitle) return false
  if (body.includes(jobTitle)) return true

  return jobTitle.length > 77 && body.includes(`${jobTitle.slice(0, 77)}...`)
}

function KindIcon({ kind }: { kind: string }) {
  const className = `mt-0.5 flex h-7 w-7 shrink-0 items-center justify-center rounded-full ${kindIconClass(kind)}`
  return (
    <span className={className}>
      <span className="h-2.5 w-2.5 rounded-full bg-current" />
    </span>
  )
}

function kindIconClass(kind: string) {
  if (kind.includes("failed")) return "bg-red-50 text-red-600 dark:bg-red-950 dark:text-red-300"
  if (kind.includes("merged") || kind.includes("completed")) return "bg-green-50 text-green-600 dark:bg-green-950 dark:text-green-300"
  if (kind.includes("implemented") || kind.includes("addressed")) return "bg-brand/10 text-brand-emphasis"
  return "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-300"
}

function bellButtonClass() {
  return "relative inline-flex h-9 w-9 items-center justify-center rounded text-gray-700 hover:bg-gray-100 hover:text-brand-emphasis dark:text-gray-300 dark:hover:bg-gray-800"
}

function NotificationBadge({ children }: { children: ReactNode }) {
  return (
    <span className="absolute -right-1 -top-1 min-w-5 rounded-full bg-red-600 px-1.5 py-0.5 text-center text-2xs font-semibold leading-none text-white">
      {children}
    </span>
  )
}

function BellIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
      <path
        d="M6.75 10.75a5.25 5.25 0 0 1 10.5 0v3.5l1.5 2.25h-13.5l1.5-2.25v-3.5ZM10 19.25h4"
        stroke="currentColor"
        strokeLinecap="round"
        strokeLinejoin="round"
        strokeWidth="1.8"
      />
    </svg>
  )
}

function BackIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M15.25 5.75 9 12l6.25 6.25" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}
