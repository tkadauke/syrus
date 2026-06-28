import "./styles.css"
import { FormEvent, type KeyboardEvent as ReactKeyboardEvent, type RefObject, useEffect, useRef, useState } from "react"
import { useQuery, useQueryClient } from "@tanstack/react-query"
import { RepoPicker } from "./RepoPicker"
import syrusIconUrl from "../assets/syrusIcon.png"

type AuthState = "loading" | "authenticated" | "setup"
type PreferencesTab = "account" | "projects"
type PopoverNavigationState =
  | { view: "inbox" }
  | { view: "job-detail"; jobId: number }
  | { view: "feedback"; jobId: number }
  | { view: "notifications" }
type CheckoutStatusByRepo = Record<string, SyrusCheckoutAvailability>
type ToastState = {
  kind: "success" | "error"
  message: string
  copyCommand?: string
  actionLabel?: string
  actionUrl?: string
}
type RepoPathDraft = {
  id: string
  repoSlug: string
  localPath: string
}

const REFRESH_INTERVAL_MS = 30_000
const EMPTY_JOBS: SyrusJobItem[] = []
const INBOX_COLLAPSED_REPOS_KEY = "syrus.desktop.inbox.collapsed-repos"

const normalizeInstanceUrl = (url: string) => url.trim().replace(/\/+$/, "")

const jobTitle = (job: SyrusJobItem) => job.title || job.issue_title || `JOB-${job.id}`

const compareInboxJobs = (a: SyrusJobItem, b: SyrusJobItem) => {
  const repositoryComparison = (a.repository_slug || "").localeCompare(b.repository_slug || "")
  if (repositoryComparison !== 0) {
    return repositoryComparison
  }

  const epicComparison = (a.epic_id ?? Infinity) - (b.epic_id ?? Infinity)
  if (!Number.isNaN(epicComparison) && epicComparison !== 0) {
    return epicComparison
  }

  return b.id - a.id
}

const unreadBadgeLabel = (count: number) => count > 9 ? "9+" : String(count)

const relativeTimestamp = (value: string) => {
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

const notificationKindIconClass = (kind: string) => {
  if (kind.includes("failed")) return "bg-red-50 text-red-600"
  if (kind.includes("merged") || kind.includes("completed")) return "bg-emerald-50 text-emerald-600"
  if (kind.includes("implemented") || kind.includes("addressed")) return "bg-blue-50 text-blue-600"
  return "bg-slate-100 text-slate-500"
}

const groupJobsByRepository = (jobs: SyrusJobItem[]) => {
  const groups = new Map<string, { repositorySlug: string; repositoryId?: number; jobs: SyrusJobItem[] }>()

  for (const job of [...jobs].sort(compareInboxJobs)) {
    const repositorySlug = job.repository_slug || "Unknown repository"
    const group = groups.get(repositorySlug)
    if (group) {
      group.jobs.push(job)
    } else {
      groups.set(repositorySlug, { repositorySlug, repositoryId: job.repository_id, jobs: [job] })
    }
  }

  return Array.from(groups.values()).sort((a, b) => a.repositorySlug.localeCompare(b.repositorySlug))
}

function readCollapsedRepos(): Set<string> {
  try {
    const raw = localStorage.getItem(INBOX_COLLAPSED_REPOS_KEY)
    if (!raw) return new Set()

    const parsed = JSON.parse(raw)
    if (Array.isArray(parsed)) return new Set(parsed as string[])
  } catch {
    // Ignore unavailable storage or malformed persisted state.
  }

  return new Set()
}

const isMacPlatform = () => /Mac|iPhone|iPad|iPod/.test(navigator.platform)

const modifierLabels: Record<string, string> = {
  Command: "⌘",
  Cmd: "⌘",
  CommandOrControl: isMacPlatform() ? "⌘" : "Ctrl+",
  Control: isMacPlatform() ? "⌃" : "Ctrl+",
  Ctrl: isMacPlatform() ? "⌃" : "Ctrl+",
  Shift: isMacPlatform() ? "⇧" : "Shift+",
  Alt: isMacPlatform() ? "⌥" : "Alt+",
  Option: isMacPlatform() ? "⌥" : "Alt+"
}

const keyLabels: Record<string, string> = {
  Backspace: "⌫",
  Delete: "⌦",
  Enter: "↵",
  Esc: "Esc",
  Escape: "Esc",
  Space: "Space",
  Up: "↑",
  Down: "↓",
  Left: "←",
  Right: "→",
  Plus: "+"
}

const displayHotkey = (hotkey: string) => {
  const trimmedHotkey = hotkey.trim()
  if (trimmedHotkey === "") {
    return "Not set"
  }

  return trimmedHotkey
    .split("+")
    .filter(Boolean)
    .map((part) => modifierLabels[part] ?? keyLabels[part] ?? part)
    .join(isMacPlatform() ? "" : "")
}

const acceleratorKeyFromEvent = (event: ReactKeyboardEvent<HTMLElement>) => {
  if (["Control", "Shift", "Alt", "Meta"].includes(event.key)) {
    return ""
  }

  if (event.code === "Space") {
    return "Space"
  }

  if (/^Key[A-Z]$/.test(event.code)) {
    return event.code.slice(3)
  }

  if (/^Digit[0-9]$/.test(event.code)) {
    return event.code.slice(5)
  }

  if (/^F([1-9]|1[0-9]|2[0-4])$/.test(event.code)) {
    return event.code
  }

  const keyMap: Record<string, string> = {
    ArrowUp: "Up",
    ArrowDown: "Down",
    ArrowLeft: "Left",
    ArrowRight: "Right",
    Escape: "Esc",
    " ": "Space",
    "+": "Plus"
  }

  if (keyMap[event.key]) {
    return keyMap[event.key]
  }

  if (event.key.length === 1) {
    return event.key.toUpperCase()
  }

  return event.key
}

const acceleratorFromEvent = (event: ReactKeyboardEvent<HTMLElement>) => {
  const key = acceleratorKeyFromEvent(event)
  if (!key) {
    return ""
  }

  const modifiers: string[] = []
  if (event.metaKey) {
    modifiers.push("Command")
  }
  if (event.ctrlKey) {
    modifiers.push("Control")
  }
  if (event.altKey) {
    modifiers.push("Alt")
  }
  if (event.shiftKey) {
    modifiers.push("Shift")
  }

  return [...modifiers, key].join("+")
}

function RefreshIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M21 12a9 9 0 0 1-15.4 6.4L3 16" />
      <path d="M3 21v-5h5" />
      <path d="M3 12a9 9 0 0 1 15.4-6.4L21 8" />
      <path d="M21 3v5h-5" />
    </svg>
  )
}

function ExternalIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M15 3h6v6" />
      <path d="M10 14 21 3" />
      <path d="M18 13v6a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V8a2 2 0 0 1 2-2h6" />
    </svg>
  )
}

function GitPullRequestIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <circle cx="18" cy="18" r="3" />
      <circle cx="6" cy="6" r="3" />
      <path d="M6 9v12" />
      <path d="M18 15V8a2 2 0 0 0-2-2h-5" />
      <path d="m14 9-3-3 3-3" />
    </svg>
  )
}

function TerminalIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="m4 17 6-6-6-6" />
      <path d="M12 19h8" />
    </svg>
  )
}

function ComposeIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="M12 5v14" />
      <path d="M5 12h14" />
    </svg>
  )
}

function BellIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" fill="none" viewBox="0 0 24 24">
      <path d="M6.75 10.75a5.25 5.25 0 0 1 10.5 0v3.5l1.5 2.25h-13.5l1.5-2.25v-3.5ZM10 19.25h4" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}

function NotificationBadge({ children }: { children: string }) {
  return <span className="notification-badge">{children}</span>
}

function CheckIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.25">
      <path d="M20 6 9 17l-5-5" />
    </svg>
  )
}

function MoreIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <circle cx="12" cy="12" r="1" />
      <circle cx="19" cy="12" r="1" />
      <circle cx="5" cy="12" r="1" />
    </svg>
  )
}

function BackIcon() {
  return (
    <svg aria-hidden="true" className="h-4 w-4" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2">
      <path d="m15 18-6-6 6-6" />
    </svg>
  )
}

function CopyIcon({ className = "" }: { className?: string }) {
  return (
    <svg aria-hidden="true" className={className} fill="none" viewBox="0 0 20 20">
      <rect height="11" rx="2" stroke="currentColor" strokeWidth="1.8" width="11" x="6" y="3" />
      <path d="M3 7v8a2 2 0 0 0 2 2h8" stroke="currentColor" strokeLinecap="round" strokeLinejoin="round" strokeWidth="1.8" />
    </svg>
  )
}

function DisclosureIcon({ collapsed }: { collapsed: boolean }) {
  return (
    <svg
      aria-hidden="true"
      className={["job-group__chevron", collapsed ? "job-group__chevron--collapsed" : ""].filter(Boolean).join(" ")}
      viewBox="0 0 24 24"
      fill="none"
      stroke="currentColor"
      strokeWidth="2"
    >
      <path d="m6 9 6 6 6-6" />
    </svg>
  )
}

function HeaderBrand({ title, instanceUrl }: { title: string; instanceUrl: string }) {
  const normalizedUrl = normalizeInstanceUrl(instanceUrl)

  return (
    <button
      type="button"
      className="header-brand"
      title={`Open ${normalizedUrl}`}
      aria-label={`Open ${title} in Syrus`}
      onClick={() => void window.syrusDesktop.openExternal(normalizedUrl)}
    >
      <img alt="" className="header-brand__logo" src={syrusIconUrl} />
      <span className="min-w-0">
        <span className="block truncate text-sm font-bold leading-5 text-slate-950">{title}</span>
        <span className="block truncate text-xs text-slate-500">{normalizedUrl}</span>
      </span>
    </button>
  )
}

const statusTone = (state: string) => {
  switch (state) {
    case "approved":
    case "closed":
    case "implemented":
    case "succeeded":
      return "bg-emerald-50 text-emerald-700 ring-emerald-200"
    case "failed":
      return "bg-red-50 text-red-700 ring-red-200"
    case "landing":
    case "queued":
    case "running":
      return "bg-blue-50 text-blue-700 ring-blue-200"
    default:
      return "bg-slate-100 text-slate-700 ring-slate-200"
  }
}

const statusLabel = (state: string) => state.replace(/_/g, " ")

function StatusPill({ state, className = "" }: { state: string; className?: string }) {
  const classes = [
    "inline-flex items-center whitespace-nowrap rounded-full px-1.5 py-0.5 text-[11px] font-medium capitalize leading-4 ring-1",
    statusTone(state),
    className
  ].filter(Boolean).join(" ")

  return (
    <span className={classes}>
      {statusLabel(state)}
    </span>
  )
}

function InboxView({ instanceUrl }: { instanceUrl: string }) {
  const queryClient = useQueryClient()
  const [navigation, setNavigation] = useState<PopoverNavigationState>({ view: "inbox" })
  const [checkoutStatusByRepo, setCheckoutStatusByRepo] = useState<CheckoutStatusByRepo>({})
  const [pendingApprovals, setPendingApprovals] = useState<Set<number>>(() => new Set())
  const [toast, setToast] = useState<ToastState | null>(null)
  const [isComposeOpen, setIsComposeOpen] = useState(false)
  const [collapsedRepositorySlugs, setCollapsedRepositorySlugs] = useState<Set<string>>(readCollapsedRepos)
  const [retryingJobID, setRetryingJobID] = useState<number | null>(null)
  const [feedbackBody, setFeedbackBody] = useState("")
  const [feedbackSubmitting, setFeedbackSubmitting] = useState(false)
  const [feedbackError, setFeedbackError] = useState<string | null>(null)
  const toastTimerRef = useRef<number | null>(null)
  const [isMarkingAllNotificationsRead, setIsMarkingAllNotificationsRead] = useState(false)
  const composeRef = useRef<HTMLElement>(null)
  const composeButtonRef = useRef<HTMLButtonElement>(null)
  const feedbackSubmitButtonRef = useRef<HTMLButtonElement>(null)
  const inboxQuery = useQuery({
    queryKey: ["inbox-jobs", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchInboxJobs(),
    refetchInterval: REFRESH_INTERVAL_MS
  })
  const cliStatusQuery = useQuery({
    queryKey: ["syrus-cli-status"],
    queryFn: () => window.syrusDesktop.syrusCliStatus()
  })
  const bootstrapQuery = useQuery({
    queryKey: ["bootstrap", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchBootstrap(),
    staleTime: REFRESH_INTERVAL_MS
  })
  const unreadCountQuery = useQuery({
    queryKey: ["notification-unread-count", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchNotificationUnreadCount(),
    refetchInterval: REFRESH_INTERVAL_MS,
    staleTime: REFRESH_INTERVAL_MS
  })
  const isAdmin = bootstrapQuery.data?.current_user?.admin === true
  const adminControlsQuery = useQuery({
    queryKey: ["admin-controls", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchAdminControls(),
    enabled: isAdmin,
    refetchInterval: isAdmin ? REFRESH_INTERVAL_MS : false
  })
  const jobs = inboxQuery.data ?? EMPTY_JOBS
  const detailJobId = navigation.view === "job-detail" || navigation.view === "feedback" ? navigation.jobId : null
  const detailQuery = useQuery({
    queryKey: ["job-detail", instanceUrl, detailJobId],
    queryFn: () => window.syrusDesktop.fetchJobDetail(detailJobId ?? 0),
    enabled: detailJobId !== null,
    refetchInterval: detailJobId !== null ? REFRESH_INTERVAL_MS : false
  })
  const notificationsQuery = useQuery({
    queryKey: ["notifications", instanceUrl],
    queryFn: () => window.syrusDesktop.fetchNotifications(),
    enabled: navigation.view === "notifications",
    refetchOnMount: "always",
    staleTime: 15_000
  })
  const unreadCount = notificationsQuery.data?.unread_count ??
    unreadCountQuery.data ??
    bootstrapQuery.data?.unread_notifications_count ??
    0

  const clearToastTimer = () => {
    if (toastTimerRef.current) {
      window.clearTimeout(toastTimerRef.current)
      toastTimerRef.current = null
    }
  }

  const clearToast = () => {
    clearToastTimer()
    setToast(null)
  }

  const showToast = (nextToast: ToastState, durationMs = nextToast.kind === "success" ? 2800 : 5000) => {
    clearToastTimer()
    setToast(nextToast)
    toastTimerRef.current = window.setTimeout(() => {
      toastTimerRef.current = null
      setToast(null)
    }, durationMs)
  }

  const showErrorToast = (message: string) => {
    showToast({ kind: "error", message })
  }

  useEffect(() => () => clearToastTimer(), [])

  useEffect(() => {
    try {
      localStorage.setItem(INBOX_COLLAPSED_REPOS_KEY, JSON.stringify([...collapsedRepositorySlugs]))
    } catch {
      // Ignore unavailable storage, private mode, or quota errors.
    }
  }, [collapsedRepositorySlugs])

  useEffect(() => {
    const count = notificationsQuery.data?.unread_count
    if (typeof count === "number") {
      queryClient.setQueryData(["notification-unread-count", instanceUrl], count)
    }
  }, [instanceUrl, notificationsQuery.data?.unread_count, queryClient])

  useEffect(() => {
    const unsubscribe = window.syrusDesktop.onNotificationEvent(() => {
      void unreadCountQuery.refetch()
      if (navigation.view === "notifications") {
        void notificationsQuery.refetch()
      }
    })

    return unsubscribe
  }, [navigation.view, notificationsQuery, unreadCountQuery])

  useEffect(() => {
    if (jobs.length === 0) {
      setCheckoutStatusByRepo({})
      return
    }

    let isMounted = true
    const repoSlugs = Array.from(new Set(jobs.map((job) => job.repository_slug).filter(Boolean)))

    Promise.all(
      repoSlugs.map(async (repoSlug) => {
        const status = await window.syrusDesktop.checkoutAvailability(repoSlug)
        return [repoSlug, status] as const
      })
    )
      .then((entries) => {
        if (isMounted) {
          setCheckoutStatusByRepo(Object.fromEntries(entries))
        }
      })
      .catch(() => {
        if (isMounted) {
          setCheckoutStatusByRepo({})
        }
      })

    return () => {
      isMounted = false
    }
  }, [jobs])

  useEffect(() => {
    const unsubscribe = window.syrusDesktop.onDesktopSettingsUpdated(() => {
      void cliStatusQuery.refetch()
      void inboxQuery.refetch()
    })

    return unsubscribe
  }, [cliStatusQuery, inboxQuery])

  const openJob = (job: SyrusJobItem) => {
    void window.syrusDesktop.openExternal(`${normalizeInstanceUrl(instanceUrl)}/jobs/${job.id}`)
  }

  const openJobDetail = (job: SyrusJobItem) => {
    setNavigation({ view: "job-detail", jobId: job.id })
    setIsComposeOpen(false)
  }

  const openNotifications = () => {
    setNavigation({ view: "notifications" })
    setIsComposeOpen(false)
    void notificationsQuery.refetch()
  }

  const openFeedback = (job: SyrusJobItem) => {
    clearToast()
    setFeedbackBody("")
    setFeedbackError(null)
    setNavigation({ view: "feedback", jobId: job.id })
    setIsComposeOpen(false)
  }

  const openPullRequest = (job: SyrusJobItem) => {
    if (job.pr_url) {
      void window.syrusDesktop.openExternal(job.pr_url)
    }
  }

  const openRepository = (repositoryId?: number) => {
    if (repositoryId) {
      void window.syrusDesktop.openExternal(`${normalizeInstanceUrl(instanceUrl)}/repositories/${repositoryId}`)
    }
  }

  const updateNotificationsCache = (payload: SyrusNotificationsPayload) => {
    queryClient.setQueryData(["notifications", instanceUrl], payload)
    queryClient.setQueryData(["notification-unread-count", instanceUrl], payload.unread_count)
  }

  const updateNotificationReadCache = (payload: SyrusNotificationPayload) => {
    queryClient.setQueryData<SyrusNotificationsPayload>(["notifications", instanceUrl], (current) => {
      if (!current) return current

      return {
        ...current,
        unread_count: payload.unread_count,
        notifications: current.notifications.map((notification) =>
          notification.id === payload.notification.id ? payload.notification : notification
        )
      }
    })
    queryClient.setQueryData(["notification-unread-count", instanceUrl], payload.unread_count)
  }

  const markAllNotificationsRead = async () => {
    setIsMarkingAllNotificationsRead(true)

    try {
      updateNotificationsCache(await window.syrusDesktop.markAllNotificationsRead())
    } catch (error) {
      showErrorToast(error instanceof Error ? error.message : "Could not mark notifications read.")
    } finally {
      setIsMarkingAllNotificationsRead(false)
    }
  }

  const openNotification = async (notification: SyrusNotificationRecord) => {
    try {
      updateNotificationReadCache(await window.syrusDesktop.markNotificationRead(notification.id))
    } catch (error) {
      showErrorToast(error instanceof Error ? error.message : "Could not mark notification read.")
    }

    if (notification.job_id) {
      setNavigation({ view: "job-detail", jobId: notification.job_id })
    } else if (notification.pr_url) {
      void window.syrusDesktop.openExternal(notification.pr_url)
    }
  }

  const toggleRepositoryGroup = (repositorySlug: string) => {
    setCollapsedRepositorySlugs((current) => {
      const next = new Set(current)
      if (next.has(repositorySlug)) {
        next.delete(repositorySlug)
      } else {
        next.add(repositorySlug)
      }
      return next
    })
  }

  const checkoutJob = async (job: SyrusJobItem) => {
    const command = `syrus checkout JOB-${job.id}`
    clearToast()

    try {
      const result = await window.syrusDesktop.checkoutJob({
        jobRef: `JOB-${job.id}`,
        repoSlug: job.repository_slug,
        branchName: job.branch_name
      })
      showToast({ kind: "success", message: `Checked out ${result.branchName}` })
      setNavigation({ view: "job-detail", jobId: job.id })
    } catch (checkoutError) {
      showToast({
        kind: "error",
        message: checkoutError instanceof Error ? checkoutError.message : "Local checkout failed.",
        copyCommand: command
      }, 7000)
    }
  }

  const approveJob = async (job: SyrusJobItem) => {
    clearToast()

    try {
      const confirmed = await window.syrusDesktop.confirmApproveJob(job.id)
      if (!confirmed) {
        return
      }

      setPendingApprovals((current) => new Set(current).add(job.id))
      await window.syrusDesktop.approveJob(job.id)
      queryClient.setQueryData<SyrusJobItem[]>(["inbox-jobs", instanceUrl], (currentJobs = []) =>
        currentJobs.map((currentJob) => currentJob.id === job.id ? { ...currentJob, state: "approved", summary_state: "approved" } : currentJob)
      )
      showToast({ kind: "success", message: `JOB-${job.id} approved` })
      void inboxQuery.refetch()
    } catch (approvalError) {
      showToast({
        kind: "error",
        message: approvalError instanceof Error ? approvalError.message : `Could not approve JOB-${job.id}.`
      })
    } finally {
      setPendingApprovals((current) => {
        const next = new Set(current)
        next.delete(job.id)
        return next
      })
    }
  }

  const retryJob = async (job: SyrusJobItem) => {
    clearToast()
    setRetryingJobID(job.id)

    try {
      await window.syrusDesktop.retryJob(job.id)
      showToast({ kind: "success", message: `JOB-${job.id} queued for retry` })
      window.setTimeout(() => {
        void inboxQuery.refetch()
      }, 900)
    } catch (retryError) {
      showToast({
        kind: "error",
        message: retryError instanceof Error ? retryError.message : `Could not retry JOB-${job.id}.`
      })
    } finally {
      setRetryingJobID(null)
    }
  }

  const submitFeedback = async () => {
    if (navigation.view !== "feedback") {
      return
    }

    const jobId = navigation.jobId
    const body = feedbackBody.trim()
    if (!body || feedbackSubmitting) {
      return
    }

    setFeedbackSubmitting(true)
    setFeedbackError(null)

    try {
      await window.syrusDesktop.submitJobFeedback(jobId, body)
      showToast({ kind: "success", message: "Feedback submitted" }, 1800)
      setFeedbackBody("")
      void detailQuery.refetch()
      void inboxQuery.refetch()
      window.setTimeout(() => {
        setNavigation({ view: "job-detail", jobId })
      }, 800)
    } catch (submitError) {
      setFeedbackError(submitError instanceof Error ? submitError.message : "Could not submit feedback.")
    } finally {
      setFeedbackSubmitting(false)
    }
  }

  const copyToastCommand = () => {
    if (toast?.copyCommand) {
      void window.syrusDesktop.copyText(toast.copyCommand)
    }
  }

  const openToastAction = () => {
    if (toast?.actionUrl) {
      void window.syrusDesktop.openExternal(toast.actionUrl)
    }
  }

  useEffect(() => {
    if (!isComposeOpen) {
      return
    }

    const collapseOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setIsComposeOpen(false)
      }
    }

    const collapseOnOutsideClick = (event: MouseEvent) => {
      const target = event.target as Node
      if (!composeRef.current?.contains(target) && !composeButtonRef.current?.contains(target)) {
        setIsComposeOpen(false)
      }
    }

    const collapseOnBlur = () => setIsComposeOpen(false)

    document.addEventListener("keydown", collapseOnEscape)
    document.addEventListener("mousedown", collapseOnOutsideClick)
    window.addEventListener("blur", collapseOnBlur)

    return () => {
      document.removeEventListener("keydown", collapseOnEscape)
      document.removeEventListener("mousedown", collapseOnOutsideClick)
      window.removeEventListener("blur", collapseOnBlur)
    }
  }, [isComposeOpen])

  const handleComposeSuccess = (result: SyrusCreateJobResponse, repoSlug: string) => {
    setIsComposeOpen(false)
    showToast({
      kind: "success",
      message: `Job queued in ${repoSlug}`,
      actionLabel: "Open in Syrus",
      actionUrl: `${normalizeInstanceUrl(instanceUrl)}${result.redirect_to}`
    }, 7000)
    void inboxQuery.refetch()
  }

  const cliMissing = cliStatusQuery.data?.available === false

  return (
    <main className="relative flex h-screen min-h-screen flex-col bg-slate-50 text-slate-950">
      <header className={navigation.view === "feedback" ? "relative flex items-center justify-between border-b border-slate-200 bg-white px-4 py-3" : "flex items-center justify-between border-b border-slate-200 bg-white px-4 py-3"}>
        {navigation.view === "feedback" ? (
          <>
            <button
              type="button"
              className="icon-button"
              title="Back"
              aria-label="Back"
              onClick={() => setNavigation({ view: "job-detail", jobId: navigation.jobId })}
            >
              <BackIcon />
            </button>
            <div className="absolute left-1/2 -translate-x-1/2 text-sm font-semibold leading-5 text-slate-900">Feedback</div>
            <button
              type="button"
              className="feedback-submit-button"
              disabled={feedbackBody.trim() === "" || feedbackSubmitting}
              ref={feedbackSubmitButtonRef}
              onClick={() => void submitFeedback()}
            >
              {feedbackSubmitting ? "Sending…" : "Submit"}
            </button>
          </>
        ) : navigation.view === "notifications" ? (
          <>
            <div className="flex w-24 items-center">
              <button
                type="button"
                className="icon-button"
                title="Back"
                aria-label="Back"
                onClick={() => setNavigation({ view: "inbox" })}
              >
                <BackIcon />
              </button>
            </div>
            <div className="min-w-0 flex-1 truncate text-center text-sm font-semibold leading-5 text-slate-950">Notifications</div>
            <div className="flex min-w-24 justify-end">
              <button
                type="button"
                className="notification-header-action"
                disabled={isMarkingAllNotificationsRead || unreadCount <= 0 || (notificationsQuery.data?.notifications.length ?? 0) === 0}
                onClick={() => void markAllNotificationsRead()}
              >
                Mark all read
              </button>
            </div>
          </>
        ) : (
          <>
            <div className="flex min-w-0 items-center gap-2">
              {navigation.view === "job-detail" ? (
                <button
                  type="button"
                  className="icon-button"
                  title="Back"
                  aria-label="Back"
                  onClick={() => setNavigation({ view: "inbox" })}
                >
                  <BackIcon />
                </button>
              ) : null}
              <HeaderBrand title="Syrus" instanceUrl={instanceUrl} />
            </div>
            <div className="flex shrink-0 items-center gap-1">
              {navigation.view === "inbox" ? (
                <>
                  <button
                    type="button"
                    className="icon-button"
                    title={isComposeOpen ? "Close compose" : "Compose job"}
                    aria-label={isComposeOpen ? "Close job compose" : "Compose job"}
                    aria-pressed={isComposeOpen}
                    ref={composeButtonRef}
                    onClick={() => setIsComposeOpen((open) => !open)}
                  >
                    <ComposeIcon />
                  </button>
                  <button
                    type="button"
                    className="icon-button icon-button--badged"
                    title={unreadCount > 0 ? `Notifications, ${unreadCount} unread` : "Notifications"}
                    aria-label={unreadCount > 0 ? `Notifications, ${unreadCount} unread` : "Notifications"}
                    onClick={openNotifications}
                  >
                    <BellIcon />
                    {unreadCount > 0 ? <NotificationBadge>{unreadBadgeLabel(unreadCount)}</NotificationBadge> : null}
                  </button>
                </>
              ) : null}
              <button
                type="button"
                className="icon-button"
                title={navigation.view === "job-detail" ? "Refresh job" : "Refresh inbox"}
                aria-label={navigation.view === "job-detail" ? "Refresh job" : "Refresh inbox"}
                disabled={navigation.view === "job-detail" ? detailQuery.isFetching : inboxQuery.isFetching}
                onClick={() => {
                  if (navigation.view === "job-detail") {
                    void detailQuery.refetch()
                  } else {
                    void inboxQuery.refetch()
                  }
                }}
              >
                <RefreshIcon />
              </button>
            </div>
          </>
        )}
      </header>

      {cliMissing ? (
        <div className="border-b border-amber-200 bg-amber-50 px-4 py-3 text-sm leading-5 text-amber-900">
          <span>Install the Syrus CLI to enable local branch checkout.</span>{" "}
          <button type="button" className="inline-link" onClick={() => window.syrusDesktop.openTokenDocs()}>
            Install docs
          </button>
        </div>
      ) : null}

      {toast ? (
        <div
          className={[
            "pointer-events-none absolute left-3 right-3 top-[76px] z-30 rounded-md border px-3 py-2 text-sm leading-5 shadow-lg",
            toast.kind === "success"
              ? "border-emerald-200 bg-emerald-50 text-emerald-800"
              : "border-red-200 bg-red-50 text-red-800"
          ].join(" ")}
          role="status"
        >
          <div className="pointer-events-auto flex items-start justify-between gap-3">
            <span className="min-w-0 overflow-wrap-anywhere">{toast.message}</span>
            {toast.copyCommand ? (
              <button type="button" className="toast-action" onClick={copyToastCommand}>
                Copy command
              </button>
            ) : null}
            {toast.actionLabel && toast.actionUrl ? (
              <button type="button" className="toast-action" onClick={openToastAction}>
                {toast.actionLabel}
              </button>
            ) : null}
          </div>
        </div>
      ) : null}

      <section className={navigation.view === "feedback" ? "min-h-0 flex-1 overflow-hidden" : "min-h-0 flex-1 overflow-y-auto"}>
        {navigation.view === "feedback" ? (
          <FeedbackView
            body={feedbackBody}
            error={feedbackError}
            submitButtonRef={feedbackSubmitButtonRef}
            onBodyChange={(value) => {
              setFeedbackBody(value)
              setFeedbackError(null)
            }}
          />
        ) : navigation.view === "job-detail" ? (
          <JobDetailView
            detail={detailQuery.data}
            error={detailQuery.error}
            fallbackJob={jobs.find((job) => job.id === navigation.jobId)}
            isError={detailQuery.isError}
            isLoading={detailQuery.isLoading}
            checkoutStatusByRepo={checkoutStatusByRepo}
            cliAvailable={cliStatusQuery.data?.available ?? false}
            retryingJobID={retryingJobID}
            pendingApprovals={pendingApprovals}
            onOpenJob={openJob}
            onOpenPullRequest={openPullRequest}
            onCheckout={(job) => void checkoutJob(job)}
            onApprove={(job) => void approveJob(job)}
            onRetry={(job) => void retryJob(job)}
            onFeedback={openFeedback}
            onRetryLoad={() => void detailQuery.refetch()}
          />
        ) : navigation.view === "notifications" ? (
          <NotificationsView
            error={notificationsQuery.error}
            isError={notificationsQuery.isError}
            isLoading={notificationsQuery.isLoading}
            notifications={notificationsQuery.data?.notifications ?? []}
            onOpenNotification={(notification) => void openNotification(notification)}
            onRetryLoad={() => void notificationsQuery.refetch()}
          />
        ) : isComposeOpen ? (
          <ComposePanel
            panelRef={composeRef}
            onCancel={() => setIsComposeOpen(false)}
            onSuccess={handleComposeSuccess}
          />
        ) : inboxQuery.isLoading ? (
          <StatusPanel title="Loading inbox" />
        ) : inboxQuery.isError ? (
          <StatusPanel
            title="Could not load inbox"
            detail={inboxQuery.error instanceof Error ? inboxQuery.error.message : "Try again in a moment."}
            actionLabel="Retry"
            onAction={() => void inboxQuery.refetch()}
          />
        ) : jobs.length === 0 ? (
          <StatusPanel title="Nothing in your inbox" detail="Implemented and failed jobs will appear here." />
        ) : (
          <ul className="job-list">
            {groupJobsByRepository(jobs).map((group) => {
              const isCollapsed = collapsedRepositorySlugs.has(group.repositorySlug)
              const jobsId = `repo-group-${group.repositorySlug.replace(/[^a-zA-Z0-9_-]/g, "-")}`

              return (
                <li className="job-group" key={group.repositorySlug}>
                  <div className="job-group__header">
                    <button
                      type="button"
                      className="job-group__toggle"
                      aria-label={`${isCollapsed ? "Expand" : "Collapse"} ${group.repositorySlug}`}
                      aria-expanded={!isCollapsed}
                      aria-controls={jobsId}
                      onClick={() => toggleRepositoryGroup(group.repositorySlug)}
                    >
                      <DisclosureIcon collapsed={isCollapsed} />
                    </button>
                    <button
                      type="button"
                      className="job-group__repository"
                      disabled={!group.repositoryId}
                      title={group.repositoryId ? `Open ${group.repositorySlug} in Syrus` : "Repository page unavailable"}
                      onClick={() => openRepository(group.repositoryId)}
                    >
                      {group.repositorySlug}
                    </button>
                    <span className="job-group__count">{group.jobs.length}</span>
                  </div>
                  {isCollapsed ? null : (
                    <ul className="job-group__jobs" id={jobsId}>
                      {group.jobs.map((job) => (
                        <JobRow
                          key={`${job.state}-${job.id}`}
                          job={job}
                          checkoutStatus={checkoutStatusByRepo[job.repository_slug]}
                          cliAvailable={cliStatusQuery.data?.available ?? false}
                          retrying={retryingJobID === job.id}
                          onOpenDetail={() => openJobDetail(job)}
                          onOpenJob={() => openJob(job)}
                          onOpenPullRequest={() => openPullRequest(job)}
                          onCheckout={() => void checkoutJob(job)}
                          onApprove={() => void approveJob(job)}
                          onRetry={() => void retryJob(job)}
                          approving={pendingApprovals.has(job.id)}
                          optimisticState={pendingApprovals.has(job.id) ? "approved" : undefined}
                        />
                      ))}
                    </ul>
                  )}
                </li>
              )
            })}
          </ul>
        )}
      </section>

      {isAdmin ? (
        <AdminControlsFooter
          controls={adminControlsQuery.data}
          disabled={adminControlsQuery.isLoading || adminControlsQuery.isFetching}
          onError={showErrorToast}
          onRefresh={() => void adminControlsQuery.refetch()}
        />
      ) : null}
    </main>
  )
}

function NotificationsView({
  error,
  isError,
  isLoading,
  notifications,
  onOpenNotification,
  onRetryLoad
}: {
  error: unknown
  isError: boolean
  isLoading: boolean
  notifications: SyrusNotificationRecord[]
  onOpenNotification: (notification: SyrusNotificationRecord) => void
  onRetryLoad: () => void
}) {
  if (isLoading) {
    return <StatusPanel title="Loading notifications" />
  }

  if (isError) {
    return (
      <StatusPanel
        title="Could not load notifications"
        detail={error instanceof Error ? error.message : "Try again in a moment."}
        actionLabel="Retry"
        onAction={onRetryLoad}
      />
    )
  }

  if (notifications.length === 0) {
    return <StatusPanel title="No notifications" />
  }

  return (
    <ul className="notification-list">
      {notifications.map((notification) => (
        <NotificationRow
          key={notification.id}
          notification={notification}
          onOpen={() => onOpenNotification(notification)}
        />
      ))}
    </ul>
  )
}

function NotificationRow({ notification, onOpen }: { notification: SyrusNotificationRecord; onOpen: () => void }) {
  const read = Boolean(notification.read_at)

  return (
    <li>
      <button
        type="button"
        className={["notification-row", read ? "" : "notification-row--unread"].filter(Boolean).join(" ")}
        onClick={onOpen}
      >
        <span className={`notification-kind ${notificationKindIconClass(notification.kind)}`} aria-hidden="true">
          <span className="notification-kind__dot" />
        </span>
        <span className="notification-row__content">
          <span className={["notification-row__body", read ? "notification-row__body--read" : "notification-row__body--unread"].join(" ")}>
            {notification.body}
          </span>
          <span className="notification-row__time">{relativeTimestamp(notification.created_at)}</span>
        </span>
      </button>
    </li>
  )
}

function InlineMarkdown({ text }: { text: string }) {
  const parts: React.ReactNode[] = []
  let remaining = text
  let key = 0

  while (remaining.length > 0) {
    const codeStart = remaining.indexOf("`")
    if (codeStart === -1) {
      parts.push(remaining)
      break
    }

    if (codeStart > 0) {
      parts.push(remaining.slice(0, codeStart))
    }

    const codeEnd = remaining.indexOf("`", codeStart + 1)
    if (codeEnd === -1) {
      parts.push(remaining.slice(codeStart))
      break
    }

    parts.push(<code key={key++}>{remaining.slice(codeStart + 1, codeEnd)}</code>)
    remaining = remaining.slice(codeEnd + 1)
  }

  return <>{parts}</>
}

function JobDetailView({
  detail,
  fallbackJob,
  error,
  isError,
  isLoading,
  checkoutStatusByRepo,
  cliAvailable,
  retryingJobID,
  pendingApprovals,
  onOpenJob,
  onOpenPullRequest,
  onCheckout,
  onApprove,
  onRetry,
  onFeedback,
  onRetryLoad
}: {
  detail?: SyrusJobDetail
  fallbackJob?: SyrusJobItem
  error: unknown
  isError: boolean
  isLoading: boolean
  checkoutStatusByRepo: CheckoutStatusByRepo
  cliAvailable: boolean
  retryingJobID: number | null
  pendingApprovals: Set<number>
  onOpenJob: (job: SyrusJobItem) => void
  onOpenPullRequest: (job: SyrusJobItem) => void
  onCheckout: (job: SyrusJobItem) => void
  onApprove: (job: SyrusJobItem) => void
  onRetry: (job: SyrusJobItem) => void
  onFeedback: (job: SyrusJobItem) => void
  onRetryLoad: () => void
}) {
  const [copyState, setCopyState] = useState<"idle" | "success" | "error">("idle")
  const job = detail?.job ?? fallbackJob

  useEffect(() => {
    if (copyState === "idle") {
      return
    }

    const timeout = window.setTimeout(() => setCopyState("idle"), 900)
    return () => window.clearTimeout(timeout)
  }, [copyState])

  if (!job && isLoading) {
    return <StatusPanel title="Loading job" />
  }

  if (!job && isError) {
    return (
      <StatusPanel
        title="Could not load job"
        detail={error instanceof Error ? error.message : "Try again in a moment."}
        actionLabel="Retry"
        onAction={onRetryLoad}
      />
    )
  }

  if (!job) {
    return <StatusPanel title="Job unavailable" />
  }

  const command = `syrus checkout JOB-${job.id}`
  const testPlan = detail?.test_plan ?? null
  const displayState = pendingApprovals.has(job.id) ? "approved" : job.state

  const copyCommand = async () => {
    try {
      await window.syrusDesktop.copyText(command)
      setCopyState("success")
    } catch {
      setCopyState("error")
    }
  }

  return (
    <article className="job-detail">
      <section className="job-detail__summary" aria-label={`JOB-${job.id}`}>
        <div className="min-w-0">
          <h1 className="job-detail__title">{jobTitle(job)}</h1>
          <p className="job-detail__meta">{job.repository_slug}</p>
        </div>
        <StatusPill state={displayState} />
      </section>

      <section className="job-detail__section" aria-label="Test plan">
        <div className="checkout-command">
          <code>{command}</code>
          <button
            type="button"
            className="icon-button"
            title={copyState === "success" ? "Copied" : copyState === "error" ? "Could not copy command" : "Copy checkout command"}
            aria-label="Copy checkout command"
            onClick={() => void copyCommand()}
          >
            <CopyIcon className="h-4 w-4" />
          </button>
        </div>

        {testPlan ? (
          <div className="test-plan">
            <ul className="test-plan__steps">
              {testPlan.steps.map((step, index) => (
                <li className="test-plan__step" key={`${index}-${step}`}>
                  <span className="test-plan__checkbox" aria-hidden="true" />
                  <span><InlineMarkdown text={step} /></span>
                </li>
              ))}
            </ul>
            {testPlan.notes ? <p className="test-plan__notes">{testPlan.notes}</p> : null}
          </div>
        ) : (
          <p className="job-detail__placeholder">{isLoading ? "Loading test plan..." : "Test plan not yet available"}</p>
        )}
      </section>

      <section className="job-detail__actions" aria-label="Actions">
        <JobActionButtons
          job={job}
          checkoutStatus={checkoutStatusByRepo[job.repository_slug]}
          cliAvailable={cliAvailable}
          retrying={retryingJobID === job.id}
          approving={pendingApprovals.has(job.id)}
          onOpenJob={() => onOpenJob(job)}
          onOpenPullRequest={() => onOpenPullRequest(job)}
          onCheckout={() => onCheckout(job)}
          onApprove={() => onApprove(job)}
          onRetry={() => onRetry(job)}
          onFeedback={() => onFeedback(job)}
        />
      </section>
    </article>
  )
}

function FeedbackView({
  body,
  error,
  submitButtonRef,
  onBodyChange
}: {
  body: string
  error: string | null
  submitButtonRef: RefObject<HTMLButtonElement | null>
  onBodyChange: (value: string) => void
}) {
  return (
    <form className="feedback-form" aria-label="Job feedback">
      <textarea
        className="feedback-textarea"
        value={body}
        placeholder="What should be changed?"
        onChange={(event) => onBodyChange(event.target.value)}
        onKeyDown={(event) => {
          if (event.key === "Tab" && !event.shiftKey) {
            event.preventDefault()
            submitButtonRef.current?.focus()
          }
        }}
      />
      {error ? <p className="feedback-error" role="alert">{error}</p> : null}
    </form>
  )
}

function JobActionButtons({
  job,
  checkoutStatus,
  cliAvailable,
  retrying,
  approving,
  onOpenJob,
  onOpenPullRequest,
  onCheckout,
  onApprove,
  onRetry,
  onFeedback
}: {
  job: SyrusJobItem
  checkoutStatus?: SyrusCheckoutAvailability
  cliAvailable: boolean
  retrying: boolean
  approving: boolean
  onOpenJob: () => void
  onOpenPullRequest: () => void
  onCheckout: () => void
  onApprove: () => void
  onRetry: () => void
  onFeedback: () => void
}) {
  const isFailed = job.state === "failed"
  const isImplemented = job.state === "implemented"
  const checkoutEnabled = cliAvailable && Boolean(checkoutStatus?.localPath)
  const checkoutTitle = !cliAvailable
    ? "Install the Syrus CLI to enable local branch checkout"
    : checkoutStatus?.localPath
      ? `Checkout in ${checkoutStatus.localPath}`
      : "Configure local projects root in Preferences"

  return (
    <div className="detail-actions">
      {isFailed ? (
        <button type="button" className="detail-action-button" disabled={retrying} onClick={onRetry}>
          {retrying ? "Retrying" : "Retry"}
        </button>
      ) : null}
      {isImplemented ? (
        <button type="button" className="detail-action-button" disabled={approving} onClick={onApprove}>
          {approving ? "Approving" : "Approve"}
        </button>
      ) : null}
      {isImplemented || isFailed ? (
        <button type="button" className="detail-action-button" onClick={onFeedback}>
          Give feedback
        </button>
      ) : null}
      <button type="button" className="detail-action-button" onClick={onOpenJob}>
        <ExternalIcon />
        <span>Open in Syrus</span>
      </button>
      <button type="button" className="detail-action-button" disabled={!job.pr_url} onClick={onOpenPullRequest}>
        <GitPullRequestIcon />
        <span>{job.pr_url ? "Open PR" : "No PR"}</span>
      </button>
      <button type="button" className="detail-action-button" disabled={!checkoutEnabled} title={checkoutTitle} onClick={onCheckout}>
        <TerminalIcon />
        <span>Checkout locally</span>
      </button>
    </div>
  )
}

function AdminControlsFooter({
  controls,
  disabled,
  onError,
  onRefresh
}: {
  controls?: SyrusAdminControls
  disabled: boolean
  onError: (message: string) => void
  onRefresh: () => void
}) {
  const [pendingControl, setPendingControl] = useState<SyrusAdminControl | null>(null)

  const toggle = async (control: SyrusAdminControl, pause: boolean) => {
    setPendingControl(control)

    try {
      const result = await window.syrusDesktop.toggleAdminControl(control, pause)
      if (!result.cancelled) {
        onRefresh()
      }
    } catch (error) {
      onError(error instanceof Error ? error.message : "Could not update admin controls.")
    } finally {
      setPendingControl(null)
    }
  }

  return (
    <footer className="border-t border-slate-200 bg-white/95 px-4 py-2">
      <div className="flex items-center justify-between gap-3">
        <p className="text-[11px] font-semibold uppercase leading-4 text-slate-400">Admin</p>
        <div className="flex min-w-0 items-center gap-2">
          <AdminControlToggle
            disabled={disabled || pendingControl !== null}
            isPending={pendingControl === "polling"}
            label="Polling"
            paused={controls?.polling_paused}
            onToggle={() => void toggle("polling", controls?.polling_paused !== true)}
          />
          <AdminControlToggle
            disabled={disabled || pendingControl !== null}
            isPending={pendingControl === "runs"}
            label="Runs"
            paused={controls?.runs_paused}
            onToggle={() => void toggle("runs", controls?.runs_paused !== true)}
          />
        </div>
      </div>
    </footer>
  )
}

function AdminControlToggle({
  label,
  paused,
  disabled,
  isPending,
  onToggle
}: {
  label: string
  paused?: boolean
  disabled: boolean
  isPending: boolean
  onToggle: () => void
}) {
  const isPaused = paused === true
  const isUnknown = paused == null

  return (
    <button
      type="button"
      className={[
        "admin-toggle",
        isPaused ? "admin-toggle--paused" : "admin-toggle--running"
      ].join(" ")}
      disabled={disabled || isUnknown}
      onClick={onToggle}
      title={isUnknown ? `${label} status loading` : isPaused ? `Resume ${label.toLowerCase()}` : `Pause ${label.toLowerCase()}`}
    >
      <span>{label}</span>
      <span className="admin-toggle__state">
        {isPending ? "Saving" : isUnknown ? "Loading" : isPaused ? "Paused" : "Running"}
      </span>
    </button>
  )
}

function StatusPanel({
  title,
  detail,
  actionLabel,
  onAction
}: {
  title: string
  detail?: string
  actionLabel?: string
  onAction?: () => void
}) {
  return (
    <div className="grid min-h-[360px] place-items-center px-6 text-center">
      <div className="max-w-64">
        <p className="text-sm font-semibold text-slate-800">{title}</p>
        {detail ? <p className="mt-2 text-sm leading-5 text-slate-500">{detail}</p> : null}
        {actionLabel && onAction ? (
          <button type="button" className="mt-4 rounded-md border border-slate-300 px-3 py-1.5 text-sm font-semibold text-slate-700 hover:bg-white" onClick={onAction}>
            {actionLabel}
          </button>
        ) : null}
      </div>
    </div>
  )
}

function JobRow({
  job,
  checkoutStatus,
  cliAvailable,
  retrying,
  onOpenDetail,
  onOpenJob,
  onOpenPullRequest,
  onCheckout,
  onApprove,
  onRetry,
  approving,
  optimisticState
}: {
  job: SyrusJobItem
  checkoutStatus?: SyrusCheckoutAvailability
  cliAvailable: boolean
  retrying: boolean
  onOpenDetail: () => void
  onOpenJob: () => void
  onOpenPullRequest: () => void
  onCheckout: () => void
  onApprove: () => void
  onRetry: () => void
  approving: boolean
  optimisticState?: string
}) {
  const [isMenuOpen, setIsMenuOpen] = useState(false)
  const [copyState, setCopyState] = useState<"idle" | "success" | "error">("idle")
  const menuRef = useRef<HTMLDivElement>(null)
  const displayState = optimisticState ?? job.state
  const isFailed = displayState === "failed"
  const isImplemented = job.state === "implemented"
  const checkoutEnabled = cliAvailable && Boolean(checkoutStatus?.localPath)
  const checkoutTitle = !cliAvailable
    ? "Install the Syrus CLI to enable local branch checkout"
    : checkoutStatus?.localPath
      ? `Checkout in ${checkoutStatus.localPath}`
      : "Configure local projects root in Preferences"

  useEffect(() => {
    if (!isMenuOpen) {
      return
    }

    const closeOnOutsideClick = (event: MouseEvent) => {
      if (!menuRef.current?.contains(event.target as Node)) {
        setIsMenuOpen(false)
      }
    }

    const closeOnEscape = (event: KeyboardEvent) => {
      if (event.key === "Escape") {
        setIsMenuOpen(false)
      }
    }

    document.addEventListener("mousedown", closeOnOutsideClick)
    document.addEventListener("keydown", closeOnEscape)
    return () => {
      document.removeEventListener("mousedown", closeOnOutsideClick)
      document.removeEventListener("keydown", closeOnEscape)
    }
  }, [isMenuOpen])

  useEffect(() => {
    if (copyState === "idle") {
      return
    }

    const timeout = window.setTimeout(() => setCopyState("idle"), 900)
    return () => window.clearTimeout(timeout)
  }, [copyState])

  const runAction = (action: () => void) => {
    setIsMenuOpen(false)
    action()
  }

  const showCopyFeedback = (nextCopyState: "success" | "error") => {
    setCopyState("idle")
    window.requestAnimationFrame(() => setCopyState(nextCopyState))
  }

  const copySlug = async () => {
    try {
      await window.syrusDesktop.copyText(`JOB-${job.id}`)
      showCopyFeedback("success")
    } catch {
      showCopyFeedback("error")
    }
  }

  const copyIconClassName = [
    "job-row__copy-icon",
    copyState === "success" ? "job-row__copy-icon--success" : "",
    copyState === "error" ? "job-row__copy-icon--error" : ""
  ].filter(Boolean).join(" ")

  return (
    <li
      className="job-row"
      onClick={(event) => {
        if ((event.target as HTMLElement).closest("button")) {
          return
        }

        onOpenDetail()
      }}
    >
      <div className="job-row__content">
        <button type="button" className="job-row__title" onClick={onOpenDetail}>
          {jobTitle(job)}
        </button>
        <span className="job-row__meta">
          <button
            type="button"
            className="job-row__slug"
            aria-label={`Copy JOB-${job.id} to clipboard`}
            title={copyState === "success" ? "Copied" : copyState === "error" ? `Could not copy JOB-${job.id}` : `Copy JOB-${job.id}`}
            onClick={() => void copySlug()}
          >
            <span>JOB-{job.id}</span>
            <CopyIcon className={copyIconClassName} />
          </button>
          {job.pr_number ? (
            <button
              type="button"
              className="job-row__meta-link"
              disabled={!job.pr_url}
              onClick={onOpenPullRequest}
              title={job.pr_url ? `Open PR #${job.pr_number} on GitHub` : "No PR URL available"}
            >
              PR #{job.pr_number}
            </button>
          ) : null}
          <StatusPill state={displayState} className="job-row__state" />
        </span>
      </div>

      <div className="job-row__actions" ref={menuRef}>
        {isFailed ? (
          <button
            type="button"
            className="row-primary-action"
            title="Retry job"
            aria-label={`Retry JOB-${job.id}`}
            disabled={retrying}
            onClick={onRetry}
          >
            {retrying ? "Retrying" : "Retry"}
          </button>
        ) : null}
        <button
          type="button"
          className="icon-button"
          title="Job actions"
          aria-label={`Open actions for JOB-${job.id}`}
          aria-expanded={isMenuOpen}
          aria-haspopup="menu"
          onClick={() => setIsMenuOpen((open) => !open)}
        >
          <MoreIcon />
        </button>
        {isMenuOpen ? (
          <div className="desktop-menu" role="menu">
            {isImplemented ? (
              <MenuAction
                disabled={approving}
                label={approving ? "Approving" : "Approve for landing"}
                icon={<CheckIcon />}
                onSelect={() => runAction(onApprove)}
              />
            ) : null}
            <MenuAction label="Open in Syrus" icon={<ExternalIcon />} onSelect={() => runAction(onOpenJob)} />
            <MenuAction
              disabled={!job.pr_url}
              label={job.pr_url ? "Open pull request" : "No pull request yet"}
              icon={<GitPullRequestIcon />}
              onSelect={() => runAction(onOpenPullRequest)}
            />
            <MenuAction
              disabled={!checkoutEnabled}
              label="Checkout locally"
              icon={<TerminalIcon />}
              title={checkoutTitle}
              onSelect={() => runAction(onCheckout)}
            />
          </div>
        ) : null}
      </div>
    </li>
  )
}

function MenuAction({
  label,
  icon,
  disabled = false,
  title,
  onSelect
}: {
  label: string
  icon: JSX.Element
  disabled?: boolean
  title?: string
  onSelect: () => void
}) {
  return (
    <button className="desktop-menu__item" disabled={disabled} onClick={onSelect} role="menuitem" title={title} type="button">
      {icon}
      <span>{label}</span>
    </button>
  )
}

function ComposePanel({
  panelRef,
  onCancel,
  onSuccess
}: {
  panelRef?: RefObject<HTMLElement>
  onCancel: () => void
  onSuccess: (result: SyrusCreateJobResponse, repoSlug: string) => void
}) {
  const [repoSlug, setRepoSlug] = useState("")
  const [prompt, setPrompt] = useState("")
  const [error, setError] = useState("")
  const [isSubmitting, setIsSubmitting] = useState(false)
  const promptRef = useRef<HTMLTextAreaElement>(null)
  const repositoriesQuery = useQuery({
    queryKey: ["repositories"],
    queryFn: () => window.syrusDesktop.fetchRepositories()
  })
  const repositories = repositoriesQuery.data ?? []
  const selectedRepository = repositories.find((repository) => repository.slug === repoSlug) ?? null

  useEffect(() => {
    window.requestAnimationFrame(() => promptRef.current?.focus())
  }, [])

  const resetAndCancel = () => {
    setPrompt("")
    setRepoSlug("")
    setError("")
    onCancel()
  }

  const submitJob = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setError("")

    const trimmedPrompt = prompt.trim()
    if (!selectedRepository) {
      setError("Choose a repository.")
      return
    }

    if (trimmedPrompt === "") {
      setError("Prompt can't be blank.")
      return
    }

    setIsSubmitting(true)
    try {
      const result = await window.syrusDesktop.createDirectJob({
        repositoryId: selectedRepository.id,
        prompt: trimmedPrompt
      })
      setPrompt("")
      setRepoSlug("")
      onSuccess(result, selectedRepository.slug)
    } catch (submitError) {
      setError(submitError instanceof Error ? submitError.message : "Could not create job.")
    } finally {
      setIsSubmitting(false)
    }
  }

  return (
    <section className="compose-panel" aria-label="Compose direct job" ref={panelRef}>
      <form className="compose-form" onSubmit={submitJob}>
        <label className="compose-field">
          <span>Prompt</span>
          <textarea
            className="compose-prompt"
            disabled={isSubmitting}
            onChange={(event) => setPrompt(event.target.value)}
            placeholder="Describe the job..."
            ref={promptRef}
            required
            rows={5}
            value={prompt}
          />
        </label>

        <label className="compose-field">
          <span>Repository</span>
          <RepoPicker value={repoSlug} onChange={setRepoSlug} disabled={isSubmitting} />
        </label>

        {repositoriesQuery.isError ? <p className="form-error">Could not load repositories.</p> : null}
        {error ? <p className="form-error">{error}</p> : null}

        <div className="form-actions form-actions--end">
          <button type="button" className="secondary-button" disabled={isSubmitting} onClick={resetAndCancel}>
            Cancel
          </button>
          <button type="submit" className="primary-button" disabled={isSubmitting || repositoriesQuery.isLoading}>
            {isSubmitting ? "Submitting..." : "Submit"}
          </button>
        </div>
      </form>
    </section>
  )
}

function ComposeView({ instanceUrl }: { instanceUrl: string }) {
  const [toast, setToast] = useState<ToastState | null>(null)

  const handleSuccess = (result: SyrusCreateJobResponse, repoSlug: string) => {
    setToast({
      kind: "success",
      message: `Job queued in ${repoSlug}`,
      actionLabel: "Open in Syrus",
      actionUrl: `${normalizeInstanceUrl(instanceUrl)}${result.redirect_to}`
    })
  }

  return (
    <main className="flex h-screen min-h-screen flex-col bg-slate-50 text-slate-950">
      <header className="border-b border-slate-200 bg-white px-4 py-3">
        <HeaderBrand title="New job" instanceUrl={instanceUrl} />
      </header>

      {toast ? (
        <div className="mx-3 mt-3 rounded-md border border-emerald-200 bg-emerald-50 px-3 py-2 text-sm leading-5 text-emerald-800" role="status">
          <div className="flex items-start justify-between gap-3">
            <span className="min-w-0 overflow-wrap-anywhere">{toast.message}</span>
            {toast.actionLabel && toast.actionUrl ? (
              <button type="button" className="toast-action" onClick={() => window.syrusDesktop.openExternal(toast.actionUrl!)}>
                {toast.actionLabel}
              </button>
            ) : null}
          </div>
        </div>
      ) : null}

      <section className="min-h-0 flex-1 overflow-y-auto">
        <ComposePanel onCancel={() => setToast(null)} onSuccess={handleSuccess} />
      </section>
    </main>
  )
}

export function App() {
  const view = new URLSearchParams(window.location.search).get("view")
  const isPreferencesView = view === "preferences"
  const isComposeView = view === "compose"
  const [authState, setAuthState] = useState<AuthState>("loading")
  const [url, setUrl] = useState("")
  const [token, setToken] = useState("")
  const [error, setError] = useState("")
  const [isSaving, setIsSaving] = useState(false)
  const [preferencesTab, setPreferencesTab] = useState<PreferencesTab>("account")
  const [localProjectsRoot, setLocalProjectsRoot] = useState("")
  const [repoPathDrafts, setRepoPathDrafts] = useState<RepoPathDraft[]>([])
  const [settingsError, setSettingsError] = useState("")
  const [settingsSaved, setSettingsSaved] = useState(false)
  const [isSavingSettings, setIsSavingSettings] = useState(false)
  const [globalHotkey, setGlobalHotkey] = useState("")
  const [hotkeyDraft, setHotkeyDraft] = useState("")
  const [hotkeyStatus, setHotkeyStatus] = useState("")
  const [hotkeyError, setHotkeyError] = useState("")
  const [isRecordingHotkey, setIsRecordingHotkey] = useState(false)
  const [isSavingHotkey, setIsSavingHotkey] = useState(false)
  const hotkeyRecorderRef = useRef<HTMLDivElement | null>(null)

  useEffect(() => {
    let isMounted = true

    Promise.all([window.syrusDesktop.getCredentials(), window.syrusDesktop.getDesktopSettings(), window.syrusDesktop.getGlobalHotkey()])
      .then(([credentials, desktopSettings, savedGlobalHotkey]) => {
        if (!isMounted) {
          return
        }

        setLocalProjectsRoot(desktopSettings.localProjectsRoot)
        setGlobalHotkey(savedGlobalHotkey)
        setHotkeyDraft(savedGlobalHotkey)
        setRepoPathDrafts(
          Object.entries(desktopSettings.localRepoPaths).map(([repoSlug, localPath]) => ({
            id: `${repoSlug}-${localPath}`,
            repoSlug,
            localPath
          }))
        )

        if (credentials) {
          setUrl(credentials.url)
          setToken(credentials.token)
          setAuthState(isPreferencesView ? "setup" : "authenticated")
        } else {
          setAuthState("setup")
        }
      })
      .catch(() => {
        if (isMounted) {
          setAuthState("setup")
        }
      })

    const unsubscribe = window.syrusDesktop.onCredentialsCleared(() => {
      setToken("")
      setError("")
      setAuthState("setup")
    })

    return () => {
      isMounted = false
      unsubscribe()
    }
  }, [isPreferencesView])

  useEffect(() => {
    if (isRecordingHotkey) {
      hotkeyRecorderRef.current?.focus()
    }
  }, [isRecordingHotkey])

  const saveCredentials = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    setError("")
    setIsSaving(true)

    try {
      const credentials = await window.syrusDesktop.saveCredentials({ url, token })
      setUrl(credentials.url)
      setToken(credentials.token)
      setAuthState(isPreferencesView ? "setup" : "authenticated")
    } catch (saveError) {
      setError(saveError instanceof Error ? saveError.message : "Could not save credentials.")
    } finally {
      setIsSaving(false)
    }
  }

  const chooseLocalProjectsRoot = async () => {
    const selectedPath = await window.syrusDesktop.chooseLocalProjectsRoot()
    if (selectedPath) {
      setLocalProjectsRoot(selectedPath)
      setSettingsSaved(false)
    }
  }

  const addRepoPathDraft = () => {
    setRepoPathDrafts((drafts) => [...drafts, { id: crypto.randomUUID(), repoSlug: "", localPath: "" }])
    setSettingsSaved(false)
  }

  const updateRepoPathDraft = (id: string, field: "repoSlug" | "localPath", value: string) => {
    setRepoPathDrafts((drafts) => drafts.map((draft) => (draft.id === id ? { ...draft, [field]: value } : draft)))
    setSettingsSaved(false)
  }

  const removeRepoPathDraft = (id: string) => {
    setRepoPathDrafts((drafts) => drafts.filter((draft) => draft.id !== id))
    setSettingsSaved(false)
  }

  const saveDesktopSettings = async () => {
    setSettingsError("")
    setSettingsSaved(false)
    setIsSavingSettings(true)

    try {
      const settings = await window.syrusDesktop.saveDesktopSettings({
        localProjectsRoot,
        localRepoPaths: Object.fromEntries(
          repoPathDrafts
            .map((draft) => [draft.repoSlug.trim(), draft.localPath.trim()] as const)
            .filter(([repoSlug, localPath]) => repoSlug !== "" && localPath !== "")
        )
      })
      setLocalProjectsRoot(settings.localProjectsRoot)
      setRepoPathDrafts(
        Object.entries(settings.localRepoPaths).map(([repoSlug, localPath]) => ({
          id: `${repoSlug}-${localPath}`,
          repoSlug,
          localPath
        }))
      )
      setSettingsSaved(true)
    } catch (settingsSaveError) {
      setSettingsError(settingsSaveError instanceof Error ? settingsSaveError.message : "Could not save local checkout settings.")
    } finally {
      setIsSavingSettings(false)
    }
  }

  const beginHotkeyRecording = () => {
    setHotkeyDraft(globalHotkey)
    setHotkeyStatus("")
    setHotkeyError("")
    setIsRecordingHotkey(true)
  }

  const recordHotkey = (event: ReactKeyboardEvent<HTMLDivElement>) => {
    event.preventDefault()
    event.stopPropagation()

    const accelerator = acceleratorFromEvent(event)
    if (accelerator) {
      setHotkeyDraft(accelerator)
    }
  }

  const cancelHotkeyRecording = () => {
    setHotkeyDraft(globalHotkey)
    setHotkeyError("")
    setIsRecordingHotkey(false)
  }

  const saveHotkey = async (nextHotkey = hotkeyDraft) => {
    setHotkeyError("")
    setHotkeyStatus("")
    setIsSavingHotkey(true)

    try {
      const result = await window.syrusDesktop.saveGlobalHotkey(nextHotkey)
      setGlobalHotkey(result.globalHotkey)
      setHotkeyDraft(result.globalHotkey)
      setIsRecordingHotkey(false)
      setHotkeyStatus(result.globalHotkey === "" ? "Keyboard shortcut cleared." : "Keyboard shortcut saved.")
    } catch (saveError) {
      setHotkeyError(saveError instanceof Error ? saveError.message : "Could not save keyboard shortcut.")
    } finally {
      setIsSavingHotkey(false)
    }
  }

  if (authState === "loading") {
    return (
      <main className="shell">
        <section className="panel panel--status" aria-label="Loading Syrus Desktop">
          <p className="eyebrow">Syrus Desktop</p>
          <h1>Loading</h1>
        </section>
      </main>
    )
  }

  if (authState === "setup") {
    const tabClass = (tab: PreferencesTab) => [
      "preferences-tab",
      preferencesTab === tab ? "preferences-tab--active" : ""
    ].join(" ")

    return (
      <main className="shell">
        <section className="panel" aria-label="Syrus Desktop settings">
          <div>
            <p className="eyebrow">Syrus Desktop</p>
            <h1>Connect Syrus</h1>
          </div>

          <div className="preferences-tabs" role="tablist" aria-label="Preferences sections">
            <button
              type="button"
              className={tabClass("account")}
              role="tab"
              aria-selected={preferencesTab === "account"}
              aria-controls="preferences-account-panel"
              id="preferences-account-tab"
              onClick={() => setPreferencesTab("account")}
            >
              Account
            </button>
            <button
              type="button"
              className={tabClass("projects")}
              role="tab"
              aria-selected={preferencesTab === "projects"}
              aria-controls="preferences-projects-panel"
              id="preferences-projects-tab"
              onClick={() => setPreferencesTab("projects")}
            >
              Projects
            </button>
          </div>

          {preferencesTab === "account" ? (
            <form
              className="settings-form"
              id="preferences-account-panel"
              role="tabpanel"
              aria-labelledby="preferences-account-tab"
              onSubmit={saveCredentials}
            >
              <label>
                <span>Syrus instance URL</span>
                <input
                  autoFocus
                  required
                  type="url"
                  value={url}
                  placeholder="https://your-syrus-instance.com"
                  onChange={(event) => setUrl(event.target.value)}
                />
              </label>

              <label>
                <span>API token</span>
                <input
                  required
                  type="password"
                  value={token}
                  autoComplete="off"
                  onChange={(event) => setToken(event.target.value)}
                />
              </label>

              {error ? <p className="form-error">{error}</p> : null}

              <div className="form-actions">
                <button type="button" className="link-button" onClick={() => window.syrusDesktop.openTokenDocs()}>
                  Generate a token
                </button>
                <button type="submit" className="primary-button" disabled={isSaving}>
                  {isSaving ? "Saving..." : "Save"}
                </button>
              </div>

              <section className="settings-section" aria-label="Keyboard shortcut settings">
                <div>
                  <h2>Keyboard shortcut</h2>
                </div>

                <div className="shortcut-row">
                  <div className="shortcut-details">
                    <span className={globalHotkey ? "shortcut-pill" : "shortcut-pill shortcut-pill--empty"}>
                      {displayHotkey(globalHotkey)}
                    </span>
                    {isRecordingHotkey ? (
                      <div
                        ref={hotkeyRecorderRef}
                        className="shortcut-recorder"
                        aria-label="Keyboard shortcut recorder"
                        tabIndex={0}
                        onKeyDown={recordHotkey}
                      >
                        <span>Press a shortcut</span>
                        <strong>{hotkeyDraft ? displayHotkey(hotkeyDraft) : "Waiting for keys"}</strong>
                      </div>
                    ) : null}
                  </div>

                  {isRecordingHotkey ? (
                    <div className="shortcut-actions">
                      <button type="button" className="primary-button" disabled={isSavingHotkey || hotkeyDraft.trim() === ""} onClick={() => saveHotkey()}>
                        {isSavingHotkey ? "Saving..." : "Save"}
                      </button>
                      <button type="button" className="secondary-button" disabled={isSavingHotkey} onClick={cancelHotkeyRecording}>
                        Cancel
                      </button>
                    </div>
                  ) : (
                    <div className="shortcut-actions">
                      <button type="button" className="secondary-button" onClick={beginHotkeyRecording}>
                        Edit
                      </button>
                      <button type="button" className="secondary-button" disabled={isSavingHotkey || globalHotkey === ""} onClick={() => saveHotkey("")}>
                        Clear
                      </button>
                    </div>
                  )}
                </div>

                {hotkeyError ? <p className="form-error">{hotkeyError}</p> : null}
                {hotkeyStatus ? <p className="form-success">{hotkeyStatus}</p> : null}
              </section>
            </form>
          ) : (
            <div className="settings-form">
              <section
                className="settings-section settings-section--flush"
                id="preferences-projects-panel"
                role="tabpanel"
                aria-labelledby="preferences-projects-tab"
                aria-label="Local checkout settings"
              >
                <div>
                  <h2>Local checkout</h2>
                </div>

                <label>
                  <span>Local projects root</span>
                  <div className="input-with-button">
                    <input
                      type="text"
                      value={localProjectsRoot}
                      placeholder="/Users/you/src"
                      onChange={(event) => {
                        setLocalProjectsRoot(event.target.value)
                        setSettingsSaved(false)
                      }}
                    />
                    <button type="button" className="secondary-button" onClick={chooseLocalProjectsRoot}>
                      Choose
                    </button>
                  </div>
                </label>

                <div className="repo-paths-header">
                  <span>Per-repo overrides</span>
                  <button type="button" className="secondary-button" onClick={addRepoPathDraft}>
                    Add row
                  </button>
                </div>

                {repoPathDrafts.length > 0 ? (
                  <div className="repo-paths-table">
                    {repoPathDrafts.map((draft) => (
                      <div className="repo-path-row" key={draft.id}>
                        <input
                          type="text"
                          value={draft.repoSlug}
                          placeholder="owner/repo"
                          aria-label="Repository slug"
                          onChange={(event) => updateRepoPathDraft(draft.id, "repoSlug", event.target.value)}
                        />
                        <input
                          type="text"
                          value={draft.localPath}
                          placeholder="/absolute/path/to/repo"
                          aria-label="Repository local path"
                          onChange={(event) => updateRepoPathDraft(draft.id, "localPath", event.target.value)}
                        />
                        <button
                          type="button"
                          className="remove-row-button"
                          aria-label={`Remove ${draft.repoSlug || "repository override"}`}
                          onClick={() => removeRepoPathDraft(draft.id)}
                        >
                          Remove
                        </button>
                      </div>
                    ))}
                  </div>
                ) : null}

                {settingsError ? <p className="form-error">{settingsError}</p> : null}
                {settingsSaved ? <p className="form-success">Local checkout settings saved.</p> : null}

                <div className="form-actions form-actions--end">
                  <button type="button" className="primary-button" disabled={isSavingSettings} onClick={saveDesktopSettings}>
                    {isSavingSettings ? "Saving..." : "Save local checkout settings"}
                  </button>
                </div>
              </section>
            </div>
          )}
        </section>
      </main>
    )
  }

  return isComposeView ? <ComposeView instanceUrl={url} /> : <InboxView instanceUrl={url} />
}
