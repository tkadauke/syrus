import { useMutation, useQuery, useQueryClient } from "@tanstack/react-query"
import { type MouseEvent, type ReactNode, useEffect, useState } from "react"
import { Link, useLocation, useNavigate } from "react-router-dom"
import {
  fetchNotifications,
  markAllNotificationsRead,
  markNotificationRead,
  type NotificationRecord,
  type NotificationsPayload
} from "../api/notifications"
import { useDismissiblePopup } from "../lib/useDismissiblePopup"

const notificationsQueryKey = ["notifications"] as const

export function NotificationsBell({ initialUnreadCount, prefix, onNavigate }: { initialUnreadCount?: number; prefix: string; onNavigate?: () => void }) {
  const [open, setOpen] = useState(false)
  const isMobile = useMediaQuery("(max-width: 767px)")
  const panelRef = useDismissiblePopup<HTMLDivElement>(open, () => setOpen(false))
  const notifications = useNotificationsQuery({ enabled: open || initialUnreadCount == null })
  const unreadCount = notifications.data?.unread_count ?? initialUnreadCount ?? 0
  const badge = unreadCount > 9 ? "9+" : String(unreadCount)
  const label = unreadCount > 0 ? `Notifications, ${unreadCount} unread` : "Notifications"

  if (isMobile) {
    return (
      <Link
        aria-label={label}
        className={bellButtonClass()}
        onClick={() => {
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
        onClick={() => setOpen((current) => !current)}
        type="button"
      >
        <BellIcon />
        {unreadCount > 0 ? <NotificationBadge>{badge}</NotificationBadge> : null}
      </button>
      {open ? (
        <div className="absolute left-0 top-full z-30 mt-2 w-80 rounded border border-gray-200 bg-white shadow-lg dark:border-gray-700 dark:bg-gray-950">
          <NotificationsPanel
            loading={notifications.isPending}
            notifications={notifications.data?.notifications ?? []}
            onNavigate={() => {
              setOpen(false)
              onNavigate?.()
            }}
            prefix={prefix}
            title="Notifications"
          />
        </div>
      ) : null}
    </div>
  )
}

export function NotificationsRoute() {
  const location = useLocation()
  const navigate = useNavigate()
  const prefix = location.pathname.startsWith("/app-shell") ? "/app-shell" : ""
  const notifications = useNotificationsQuery({ enabled: true })

  return (
    <main aria-label="Notifications" className="min-h-full bg-gray-50 p-4 dark:bg-gray-900 sm:p-6">
      <div className="mx-auto max-w-3xl">
        <button
          className="mb-4 inline-flex items-center gap-2 rounded border border-gray-300 bg-white px-3 py-2 text-sm font-medium text-gray-700 hover:bg-gray-50 dark:border-gray-700 dark:bg-gray-950 dark:text-gray-200 dark:hover:bg-gray-900"
          onClick={() => navigate(-1)}
          type="button"
        >
          <BackIcon />
          <span>Back</span>
        </button>
        <section className="rounded border border-gray-200 bg-white dark:border-gray-800 dark:bg-gray-950">
          <NotificationsPanel
            loading={notifications.isPending}
            notifications={notifications.data?.notifications ?? []}
            prefix={prefix}
            title="Notifications"
          />
        </section>
      </div>
    </main>
  )
}

function NotificationsPanel({
  loading = false,
  notifications,
  onNavigate,
  prefix,
  title
}: {
  loading?: boolean
  notifications: NotificationRecord[]
  onNavigate?: () => void
  prefix: string
  title: string
}) {
  const queryClient = useQueryClient()
  const markAll = useMutation({
    mutationFn: markAllNotificationsRead,
    onSuccess(payload) {
      queryClient.setQueryData(notificationsQueryKey, payload)
    }
  })

  return (
    <div>
      <div className="flex items-center justify-between gap-3 border-b border-gray-200 px-4 py-3 dark:border-gray-800">
        <h1 className="text-sm font-semibold text-gray-900 dark:text-gray-100">{title}</h1>
        <button
          className="rounded px-2 py-1 text-xs font-medium text-blue-700 hover:bg-blue-50 disabled:cursor-not-allowed disabled:text-gray-400 dark:text-blue-300 dark:hover:bg-blue-950 dark:disabled:text-gray-600"
          disabled={markAll.isPending || notifications.length === 0}
          onClick={() => markAll.mutate()}
          type="button"
        >
          Mark all read
        </button>
      </div>
      {loading ? (
        <div className="px-4 py-6 text-sm text-gray-500 dark:text-gray-400">Loading...</div>
      ) : notifications.length > 0 ? (
        <div className="max-h-[28rem] overflow-y-auto">
          {notifications.map((notification) => (
            <NotificationRow
              key={notification.id}
              notification={notification}
              onNavigate={onNavigate}
              prefix={prefix}
            />
          ))}
        </div>
      ) : (
        <div className="px-4 py-8 text-center text-sm text-gray-500 dark:text-gray-400">No notifications</div>
      )}
    </div>
  )
}

function NotificationRow({ notification, onNavigate, prefix }: { notification: NotificationRecord; onNavigate?: () => void; prefix: string }) {
  const navigate = useNavigate()
  const queryClient = useQueryClient()
  const read = Boolean(notification.read_at)
  const jobTarget = notification.job_id ? withRoutePrefix(`/jobs/${notification.job_id}`, prefix) : null
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
          notifications: current.notifications.map((item) => item.id === payload.notification.id ? payload.notification : item)
        }
      })
    }
  })

  function openNotification() {
    markRead.mutate(undefined, {
      onSettled() {
        onNavigate?.()
        if (jobTarget) navigate(jobTarget)
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
      className={`flex w-full min-w-0 items-start gap-3 border-b border-gray-100 px-4 py-3 text-left last:border-b-0 ${jobTarget ? "cursor-pointer hover:bg-gray-50 dark:hover:bg-gray-900" : ""} ${read ? "" : "bg-blue-50/50 dark:bg-blue-950/20"}`}
      onClick={openNotification}
      onKeyDown={(event) => {
        if (!jobTarget) return
        if (event.key === "Enter" || event.key === " ") {
          event.preventDefault()
          openNotification()
        }
      }}
      role={jobTarget ? "button" : undefined}
      tabIndex={jobTarget ? 0 : undefined}
    >
      <KindIcon kind={notification.kind} />
      <span className="min-w-0 flex-1">
        <span className={`block text-sm leading-5 ${read ? "font-medium text-gray-700 dark:text-gray-300" : "font-semibold text-gray-950 dark:text-gray-100"}`}>
          {notification.body}
        </span>
        {showJobTitle ? (
          <span className="mt-0.5 block truncate text-xs text-gray-500 dark:text-gray-400">{notification.job_title}</span>
        ) : null}
        <span className="mt-1 flex items-center gap-1.5 text-xs text-gray-500 dark:text-gray-400">
          {notification.pr_url ? (
            <>
              <a
                className="font-medium text-blue-700 hover:underline dark:text-blue-300"
                href={notification.pr_url}
                onClick={openPullRequest}
                rel="noopener"
                target="_blank"
              >
                PR #{prNumber ?? "link"}
              </a>
              <span aria-hidden="true">·</span>
            </>
          ) : null}
          <span>{relativeTimestamp(notification.created_at)}</span>
        </span>
      </span>
    </div>
  )
}

function useNotificationsQuery({ enabled }: { enabled: boolean }) {
  return useQuery({
    queryKey: notificationsQueryKey,
    queryFn: () => fetchNotifications(),
    enabled,
    staleTime: 30_000
  })
}

function bodyIncludesJobTitle(body: string, jobTitle: string | null) {
  if (!jobTitle) return false
  if (body.includes(jobTitle)) return true

  return jobTitle.length > 77 && body.includes(`${jobTitle.slice(0, 77)}...`)
}

function relativeTimestamp(value: string) {
  const timestamp = Date.parse(value)
  if (Number.isNaN(timestamp)) return ""

  const elapsedSeconds = Math.max(0, Math.floor((Date.now() - timestamp) / 1000))
  if (elapsedSeconds < 60) return "just now"

  const elapsedMinutes = Math.floor(elapsedSeconds / 60)
  if (elapsedMinutes < 60) return `${elapsedMinutes}m ago`

  const elapsedHours = Math.floor(elapsedMinutes / 60)
  if (elapsedHours < 24) return `${elapsedHours}h ago`

  const elapsedDays = Math.floor(elapsedHours / 24)
  if (elapsedDays < 30) return `${elapsedDays}d ago`

  return new Date(timestamp).toLocaleDateString()
}

function useMediaQuery(query: string) {
  const [matches, setMatches] = useState(() => {
    if (typeof window.matchMedia !== "function") return false
    return window.matchMedia(query).matches
  })

  useEffect(() => {
    if (typeof window.matchMedia !== "function") return

    const media = window.matchMedia(query)
    setMatches(media.matches)

    function handleChange(event: MediaQueryListEvent) {
      setMatches(event.matches)
    }

    media.addEventListener("change", handleChange)
    return () => media.removeEventListener("change", handleChange)
  }, [query])

  return matches
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
  if (kind.includes("implemented") || kind.includes("addressed")) return "bg-blue-50 text-blue-600 dark:bg-blue-950 dark:text-blue-300"
  return "bg-gray-100 text-gray-500 dark:bg-gray-800 dark:text-gray-300"
}

function bellButtonClass() {
  return "relative inline-flex h-9 w-9 items-center justify-center rounded text-gray-700 hover:bg-gray-100 hover:text-blue-700 dark:text-gray-300 dark:hover:bg-gray-800 dark:hover:text-blue-300"
}

function NotificationBadge({ children }: { children: ReactNode }) {
  return (
    <span className="absolute -right-1 -top-1 min-w-5 rounded-full bg-red-600 px-1.5 py-0.5 text-center text-[0.65rem] font-semibold leading-none text-white">
      {children}
    </span>
  )
}

function BellIcon() {
  return (
    <svg aria-hidden="true" className="h-5 w-5" fill="none" viewBox="0 0 24 24">
      <path d="M6.75 10.75a5.25 5.25 0 0 1 10.5 0v3.5l1.5 2.25h-13.5l1.5-2.25v-3.5ZM10 19.25h4" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
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

function withRoutePrefix(path: string, prefix: string) {
  if (!prefix || path.startsWith(prefix)) return path
  if (!path.startsWith("/")) return path

  return `${prefix}${path}`
}
