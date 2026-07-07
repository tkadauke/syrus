import { app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, screen, shell, dialog, clipboard, globalShortcut, Notification } from "electron"
import type { MessageBoxOptions, NativeImage, OpenDialogOptions } from "electron"
import { execFile } from "node:child_process"
import fs from "node:fs/promises"
import { constants as fsConstants } from "node:fs"
import os from "node:os"
import { fileURLToPath } from "node:url"
import path from "node:path"
import { promisify } from "node:util"
import { DESKTOP_NOTIFICATION_EVENT, desktopNotificationEvents } from "./appUserEvents.js"
import { dispatchNativeNotification } from "./nativeNotifications.js"
import {
  deleteCredentialsFile,
  parseCredentials,
  readCredentialsFile,
  validateCredentialsShape,
  writeCredentialsFile
} from "./credentialsStore.js"
import type { Credentials } from "./credentialsStore.js"
import { clearBackendConfig, DEFAULT_GLOBAL_HOTKEY, getBackendMode, getOnboardingResumeLocal, getServerUrl, localStateDir, migrateBackendConfig, saveBackendConfig, store } from "./settings.js"
import type { DesktopSettings, DesktopSettingsInput } from "./settings.js"
import * as appUpdates from "./appUpdates.js"
import * as backendLifecycle from "./installer/backendLifecycle.js"
import { readBackendManifest } from "./installer/installPaths.js"
import { OnboardingDriver } from "./installer/installerDriver.js"
import { decideOnSecondInstance, takeoverPrompt, type InstanceIdentity } from "./instanceTakeover.js"
import { bundlePathFromExecPath, installBundle, launchInstalledCopy, shouldSelfInstall } from "./selfInstall.js"
import { maybeProvisionDesktopToken } from "./tokenProvisioner.js"
import { paintUnreadDot } from "./trayBadge.js"
import { createOnboardingWindow } from "./windows/onboardingWindow.js"
import { computePopoverPosition } from "./windows/popoverPosition.js"
import { createWebAppWindow, type WebAppWindowHandle } from "./windows/webAppWindow.js"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const TOKEN_DOCS_URL = "https://www.syrus-ai.dev/docs/cli/"
const execFileAsync = promisify(execFile)

type JobItem = {
  id: number
  epic_id: number | null
  epic_title: string | null
  state: string
  summary_state: string
  title: string
  issue_title: string
  repository_id: number
  repository_slug: string
  branch_name: string
  pr_number: number
  pr_url: string
  created_at: string
  updated_at: string
  started_at: string
  finished_at: string
  current_step: string
  latest_run_id: number
}

type JobList = {
  count: number
  jobs: JobItem[]
}

type JobTestPlan = {
  workflow_id: number
  steps: string[]
  notes: string | null
}

type FeedbackHistoryItem = {
  kind: "chat_feedback" | "pr_comment"
  body: string
  created_at: string
  state: string
}

type JobDetail = {
  job: JobItem
  repository: {
    slug: string
  }
  summary: { run_id: number; text: string; finished_at: string } | null
  test_plan: JobTestPlan | null
  feedback_history: FeedbackHistoryItem[]
}

const compareInboxJobs = (a: JobItem, b: JobItem) => {
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

type CreateJobRequest = {
  repositoryId: number
  prompt: string
}

type CreateJobResponse = {
  message: string
  redirect_to: string
  job: JobItem
}

type RepositoryItem = {
  id: number
  slug: string
}

type RepositoryList = {
  repositories?: RepositoryItem[]
  active_repositories?: RepositoryItem[]
  archived_repositories?: RepositoryItem[]
}

type ApiErrorPayload = {
  error?: {
    message?: string
  }
}

type CheckoutAvailability = {
  cliAvailable: boolean
  localPath: string | null
}

type CheckoutRequest = {
  jobRef: string
  repoSlug: string
  branchName: string
  extraArgs?: string[]
}

type LocalStatus = {
  job_id: number
  branch: string
  behind: number
}

type BootstrapPayload = {
  current_user: {
    admin: boolean
    notification_preferences?: {
      desktop_job_implemented?: boolean
      desktop_job_failed?: boolean
    }
  } | null
  unread_notifications_count?: number
}

type NotificationRecord = {
  id: number
  kind: string
  body: string
  read_at: string | null
  pr_url: string | null
  job_id: number | null
  job_title?: string | null
  created_at: string
}

type NotificationsPayload = {
  notifications: NotificationRecord[]
  unread_count: number
  pagination: {
    page: number
    per_page: number
    total: number
    total_pages: number
  }
}

type NotificationPayload = {
  notification: NotificationRecord
  unread_count: number
}

type AdminConsolePayload = {
  settings: {
    polling_paused: boolean
    runs_paused: boolean
  }
}

type AdminControl = "polling" | "runs"

let mainWindow: BrowserWindow | null = null
let preferencesWindow: BrowserWindow | null = null
let onboardingWindow: BrowserWindow | null = null
let onboardingDriver: OnboardingDriver | null = null
let webAppWindow: WebAppWindowHandle | null = null
let backendRecoveryTimer: NodeJS.Timeout | null = null
let tray: Tray | null = null
let cachedCredentials: Credentials | null = null
let isQuitting = false
let cachedCliAvailable: boolean | null = null
let appUserCable: WebSocket | null = null
let appUserCableReconnectTimer: NodeJS.Timeout | null = null
let appUserCableGeneration = 0
let appUserCableCredentialsKey: string | null = null
let plainTrayIcon: NativeImage | null = null
let unreadCount = 0

const APP_USER_CHANNEL_IDENTIFIER = JSON.stringify({ channel: "AppUserChannel" })
const APP_USER_CABLE_INITIAL_RECONNECT_MS = 1_000
const APP_USER_CABLE_MAX_RECONNECT_MS = 30_000
let appUserCableReconnectMs = APP_USER_CABLE_INITIAL_RECONNECT_MS
let registeredGlobalHotkey = ""

// Set when the stored token gets a 401 from its own instance (backend DB
// rebuilt, token revoked). Keyed via credentialsKey (shared with the cable
// code below). The token provisioner treats suspect same-instance
// credentials as absent, so the next signed-in web session re-mints the
// token instead of the app staying wedged on a dead one.
let suspectTokenKey: string | null = null

// The tray renderer matches on this text to swap "Retry" for "Open Syrus"
// (the signed-in web window is what re-mints the token). Keep in sync with
// UNAUTHORIZED_MARKER in desktop/src/App.tsx.
const UNAUTHORIZED_MESSAGE = "Syrus rejected the saved sign-in. Open Syrus to refresh it automatically."

const throwIfUnauthorized = (credentials: Credentials, response: Response) => {
  if (response.status === 401) {
    suspectTokenKey = credentialsKey(credentials)
    throw new Error(UNAUTHORIZED_MESSAGE)
  }
}

const loadCredentials = async (): Promise<Credentials | null> => {
  let contents: string | null

  try {
    contents = await readCredentialsFile()
  } catch (error) {
    cachedCredentials = null
    throw error
  }

  if (contents === null) {
    cachedCredentials = null
    return null
  }

  try {
    const credentials = parseCredentials(contents)
    cachedCredentials = credentials
    return credentials
  } catch {
    cachedCredentials = null
    return null
  }
}

const bootstrapUrl = (baseUrl: string) => {
  const trimmedUrl = baseUrl.trim().replace(/\/+$/, "")
  return `${trimmedUrl}/api/v1/app/bootstrap`
}

const notificationsUrl = (baseUrl: string) => {
  const trimmedUrl = baseUrl.trim().replace(/\/+$/, "")
  return `${trimmedUrl}/api/v1/app/notifications`
}

const appApiUrl = (baseUrl: string, pathName: string, params?: Record<string, string>) => {
  const url = new URL(pathName, `${baseUrl.trim().replace(/\/+$/, "")}/`)
  for (const [key, value] of Object.entries(params ?? {})) {
    url.searchParams.set(key, value)
  }
  return url.toString()
}

const appCableUrl = (baseUrl: string, token: string) => {
  const url = new URL("/cable", `${baseUrl.trim().replace(/\/+$/, "")}/`)
  url.protocol = url.protocol === "https:" ? "wss:" : "ws:"
  url.searchParams.set("api_token", token.trim())
  return url.toString()
}

const credentialsKey = (credentials: Credentials) => `${credentials.url.trim()}\n${credentials.token.trim()}`

const clearAppUserCableReconnect = () => {
  if (appUserCableReconnectTimer) {
    clearTimeout(appUserCableReconnectTimer)
    appUserCableReconnectTimer = null
  }
}

const closeAppUserCable = () => {
  clearAppUserCableReconnect()

  if (appUserCable) {
    const socket = appUserCable
    appUserCable = null
    socket.onopen = null
    socket.onmessage = null
    socket.onerror = null
    socket.onclose = null
    if (socket.readyState === WebSocket.CONNECTING || socket.readyState === WebSocket.OPEN) {
      socket.close()
    }
  }
}

const normalizeUnreadCount = (value: unknown) => {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return null
  }

  return Math.max(0, Math.floor(value))
}

const trayBadgeLabel = (count: number) => count > 9 ? "9+" : String(count)

// The mac menu bar wants the monochrome template glyph; the Windows
// taskbar wants the full-color brand icon (a black template glyph is
// invisible on Win11's dark taskbar).
const trayIconPath = () =>
  path.join(
    app.getAppPath(),
    "assets",
    process.platform === "win32" ? "syrusIcon.png" : "syrusMenubarTemplate.png"
  )

const createPlainTrayIcon = () => {
  const size = process.platform === "win32" ? 16 : 18
  const image = nativeImage.createFromPath(trayIconPath()).resize({ width: size, height: size })

  if (process.platform === "darwin") {
    image.setTemplateImage(true)
  }

  return image
}

// Draw the unread dot straight into the icon's BGRA bitmap. nativeImage
// cannot rasterize SVG data URLs (they decode to an empty image on Windows,
// which blanked the tray icon whenever unread > 0), and shipping a canvas
// just for a red dot is overkill.
const badgedTrayIcon = () => {
  const baseIcon = plainTrayIcon ?? createPlainTrayIcon()
  const size = baseIcon.getSize()
  const bitmap = Buffer.from(baseIcon.toBitmap())

  paintUnreadDot(bitmap, size.width, size.height)

  return nativeImage.createFromBitmap(bitmap, { width: size.width, height: size.height })
}

const updateTrayBadge = () => {
  if (!tray || !plainTrayIcon) {
    return
  }

  if (process.platform === "darwin") {
    tray.setImage(plainTrayIcon)
    tray.setTitle(unreadCount > 0 ? trayBadgeLabel(unreadCount) : "")
    return
  }

  tray.setImage(unreadCount > 0 ? badgedTrayIcon() : plainTrayIcon)
  tray.setToolTip(unreadCount > 0 ? `Syrus — ${trayBadgeLabel(unreadCount)} unread` : "Syrus")
}

const setUnreadCount = (count: number) => {
  unreadCount = Math.max(0, Math.floor(count))
  updateTrayBadge()
}

const seedUnreadCountFromBootstrap = (payload: BootstrapPayload) => {
  const count = normalizeUnreadCount(payload.unread_notifications_count)
  if (count !== null) {
    setUnreadCount(count)
  }
}

const handleNotificationCreated = (event: unknown) => {
  if (!event || typeof event !== "object") {
    return
  }

  const payload = (event as { payload?: unknown }).payload
  if (payload && typeof payload === "object") {
    const payloadCount = normalizeUnreadCount((payload as { unread_count?: unknown }).unread_count)
    if (payloadCount !== null) {
      setUnreadCount(payloadCount)
      return
    }
  }

  setUnreadCount(unreadCount + 1)
}

const stopAppUserCable = () => {
  appUserCableGeneration += 1
  appUserCableCredentialsKey = null
  closeAppUserCable()
}

const scheduleAppUserCableReconnect = (credentials: Credentials, generation: number) => {
  if (isQuitting || generation !== appUserCableGeneration) {
    return
  }

  clearAppUserCableReconnect()
  const delay = appUserCableReconnectMs
  appUserCableReconnectMs = Math.min(appUserCableReconnectMs * 2, APP_USER_CABLE_MAX_RECONNECT_MS)
  appUserCableReconnectTimer = setTimeout(() => {
    appUserCableReconnectTimer = null
    connectAppUserCable(credentials, generation)
  }, delay)
}

const connectAppUserCable = (credentials: Credentials, generation = appUserCableGeneration) => {
  if (isQuitting || generation !== appUserCableGeneration) {
    return
  }

  closeAppUserCable()

  const socket = new WebSocket(appCableUrl(credentials.url, credentials.token), "actioncable-v1-json")
  appUserCable = socket

  socket.onopen = () => {
    appUserCableReconnectMs = APP_USER_CABLE_INITIAL_RECONNECT_MS
    socket.send(JSON.stringify({
      command: "subscribe",
      identifier: APP_USER_CHANNEL_IDENTIFIER
    }))
  }

  socket.onmessage = (event) => {
    if (generation !== appUserCableGeneration) {
      return
    }

    let data: unknown
    try {
      data = JSON.parse(String(event.data))
    } catch {
      return
    }

    if (!data || typeof data !== "object") {
      return
    }

    const message = data as { type?: string; message?: unknown }
    if (message.type === "reject_subscription") {
      socket.close()
      return
    }

    if ("message" in message) {
      desktopNotificationEvents.emit(DESKTOP_NOTIFICATION_EVENT, message.message)
    }
  }

  let socketFinished = false
  const finishSocket = () => {
    if (socketFinished) {
      return
    }

    socketFinished = true
    if (appUserCable === socket) {
      appUserCable = null
    }
    scheduleAppUserCableReconnect(credentials, generation)
  }

  socket.onerror = () => {
    finishSocket()
  }

  socket.onclose = () => {
    finishSocket()
  }
}

const startAppUserCable = (credentials: Credentials | null) => {
  if (!credentials) {
    stopAppUserCable()
    return
  }

  const key = credentialsKey(credentials)
  if (appUserCableCredentialsKey === key && appUserCable) {
    return
  }

  appUserCableGeneration += 1
  appUserCableCredentialsKey = key
  appUserCableReconnectMs = APP_USER_CABLE_INITIAL_RECONNECT_MS
  connectAppUserCable(credentials, appUserCableGeneration)
}

const broadcastNotificationEvent = (event: unknown) => {
  for (const window of BrowserWindow.getAllWindows()) {
    window.webContents.send("notification-event", event)
  }
}

desktopNotificationEvents.on(DESKTOP_NOTIFICATION_EVENT, (event: unknown) => {
  if (event && typeof event === "object" && (event as { type?: unknown }).type === "notification_created") {
    handleNotificationCreated(event)
  }

  dispatchNativeNotification(event, cachedCredentials)
  broadcastNotificationEvent(event)
})

const validateCredentialsWithServer = async (credentials: Credentials) => {
  validateCredentialsShape(credentials)

  let response: Response
  try {
    // Bounded: a black-holed host must not leave the Preferences form (or
    // any other caller) disabled forever with no way out.
    response = await fetch(bootstrapUrl(credentials.url), {
      headers: {
        Authorization: `Bearer ${credentials.token.trim()}`
      },
      signal: AbortSignal.timeout(10_000)
    })
  } catch {
    throw new Error("Could not reach the Syrus instance.")
  }

  if (!response.ok) {
    throw new Error("The Syrus instance rejected those credentials.")
  }
}

const fetchBootstrap = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before loading account details.")
  }

  const response = await fetch(bootstrapUrl(credentials.url), {
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error("Could not load account details.")
  }

  const payload = (await response.json()) as BootstrapPayload
  seedUnreadCountFromBootstrap(payload)
  return payload
}

const syncUnreadCount = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    setUnreadCount(0)
    return 0
  }

  const response = await fetch(notificationsUrl(credentials.url), {
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  if (response.status === 404) {
    return
  }

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error("Could not load notifications.")
  }

  const payload = (await response.json()) as { unread_count?: unknown }
  const count = normalizeUnreadCount(payload.unread_count)
  if (count !== null) {
    setUnreadCount(count)
    return count
  }

  return unreadCount
}

const fetchNotificationUnreadCount = async () => syncUnreadCount()

const fetchNotifications = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before loading notifications.")
  }

  const response = await fetch(notificationsUrl(credentials.url), {
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, "Could not load notifications."))
  }

  const payload = (await response.json()) as NotificationsPayload
  const count = normalizeUnreadCount(payload.unread_count)
  if (count !== null) {
    setUnreadCount(count)
  }
  return payload
}

const markNotificationRead = async (id: number) => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before updating notifications.")
  }

  const response = await fetch(appApiUrl(credentials.url, `/api/v1/app/notifications/${id}/mark_read`), {
    method: "PATCH",
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, "Could not mark notification read."))
  }

  const payload = (await response.json()) as NotificationPayload
  const count = normalizeUnreadCount(payload.unread_count)
  if (count !== null) {
    setUnreadCount(count)
  }
  return payload
}

const markAllNotificationsRead = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before updating notifications.")
  }

  const response = await fetch(appApiUrl(credentials.url, "/api/v1/app/notifications/mark_all_read"), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, "Could not mark notifications read."))
  }

  const payload = (await response.json()) as NotificationsPayload
  const count = normalizeUnreadCount(payload.unread_count)
  if (count !== null) {
    setUnreadCount(count)
  }
  return payload
}

const fetchJobList = async (credentials: Credentials, state: string) => {
  const response = await fetch(
    appApiUrl(credentials.url, "/api/v1/app/jobs", {
      state,
      limit: "100"
    }),
    {
      headers: {
        Authorization: `Bearer ${credentials.token.trim()}`
      }
    }
  )

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(`Could not fetch ${state} jobs.`)
  }

  return (await response.json()) as JobList
}

const fetchInboxJobs = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before loading inbox jobs.")
  }

  const lists = await Promise.all([
    fetchJobList(credentials, "implemented"),
    fetchJobList(credentials, "failed")
  ])

  return lists
    .flatMap((list) => list.jobs)
    .sort(compareInboxJobs)
}

const fetchJobDetail = async (jobID: number) => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before loading jobs.")
  }

  const response = await fetch(appApiUrl(credentials.url, `/api/v1/app/jobs/${jobID}`), {
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, `Could not load JOB-${jobID}.`))
  }

  return (await response.json()) as JobDetail
}

const responseErrorMessage = async (response: Response, fallback: string) => {
  try {
    const payload = (await response.json()) as ApiErrorPayload
    return payload.error?.message || fallback
  } catch {
    return fallback
  }
}

const createDirectJob = async ({ repositoryId, prompt }: CreateJobRequest) => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before creating jobs.")
  }

  const response = await fetch(appApiUrl(credentials.url, "/api/v1/app/jobs"), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({
      repository_id: repositoryId,
      prompt
    })
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, "Could not create job."))
  }

  return (await response.json()) as CreateJobResponse
}

const fetchRepositories = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before loading repositories.")
  }

  const response = await fetch(appApiUrl(credentials.url, "/api/v1/app/repositories"), {
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error("Could not load repositories.")
  }

  const payload = (await response.json()) as RepositoryList
  return payload.active_repositories ?? payload.repositories ?? []
}

const confirmApproveJob = async (sender: Electron.WebContents, jobID: number) => {
  const parentWindow = BrowserWindow.fromWebContents(sender)
  const confirmationOptions: MessageBoxOptions = {
    type: "question",
    buttons: ["Approve", "Cancel"],
    defaultId: 0,
    cancelId: 1,
    message: `Approve JOB-${jobID} for landing?`
  }
  const confirmation = parentWindow
    ? await dialog.showMessageBox(parentWindow, confirmationOptions)
    : await dialog.showMessageBox(confirmationOptions)

  return confirmation.response === 0
}

const approveJob = async (jobID: number) => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before approving jobs.")
  }

  const response = await fetch(appApiUrl(credentials.url, `/api/v1/app/jobs/${jobID}/approve`), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, `Could not approve JOB-${jobID}.`))
  }
}

const retryJob = async (jobID: number) => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before retrying jobs.")
  }

  const response = await fetch(appApiUrl(credentials.url, `/api/v1/app/jobs/${jobID}/run_again`), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, `Could not retry JOB-${jobID}.`))
  }
}

const submitJobFeedback = async (jobID: number, body: string) => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before submitting feedback.")
  }

  const response = await fetch(appApiUrl(credentials.url, `/api/v1/app/jobs/${jobID}/chat_feedback`), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`,
      "Content-Type": "application/json"
    },
    body: JSON.stringify({ body })
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(await responseErrorMessage(response, `Could not submit feedback for JOB-${jobID}.`))
  }
}

const getDesktopSettings = (): DesktopSettings => ({
  localProjectsRoot: store.get("localProjectsRoot", ""),
  localRepoPaths: store.get("localRepoPaths", {}),
  lastUsedRepo: store.get("lastUsedRepo", "")
})

const getGlobalHotkey = () => store.get("globalHotkey", DEFAULT_GLOBAL_HOTKEY).trim()

const saveDesktopSettings = async (settings: DesktopSettingsInput) => {
  const localProjectsRoot = settings.localProjectsRoot.trim()
  const localRepoPaths: Record<string, string> = Object.fromEntries(
    Object.entries(settings.localRepoPaths)
      .map(([repoSlug, repoPath]) => [repoSlug.trim(), repoPath.trim()])
      .filter(([repoSlug, repoPath]) => repoSlug !== "" && repoPath !== "")
  )

  if (localProjectsRoot !== "" && !path.isAbsolute(localProjectsRoot)) {
    throw new Error("Local projects root must be an absolute path.")
  }

  for (const [repoSlug, repoPath] of Object.entries(localRepoPaths)) {
    if (!repoSlug.includes("/")) {
      throw new Error("Repository overrides must use owner/repo slugs.")
    }

    if (!path.isAbsolute(repoPath)) {
      throw new Error(`Local path for ${repoSlug} must be absolute.`)
    }
  }

  store.set("localProjectsRoot", localProjectsRoot)
  store.set("localRepoPaths", localRepoPaths)
  mainWindow?.webContents.send("desktop-settings-updated")
  return getDesktopSettings()
}

const getLastUsedRepo = () => store.get("lastUsedRepo", "")

const setLastUsedRepo = (repoSlug: string) => {
  const normalizedSlug = repoSlug.trim()
  store.set("lastUsedRepo", normalizedSlug)
  return normalizedSlug
}

const commandExists = async (command: string) => {
  const lookupCommand = process.platform === "win32" ? "where" : "which"

  try {
    // windowsHide everywhere a console binary runs from this GUI process —
    // otherwise conhost windows flash on Windows.
    await execFileAsync(lookupCommand, [command], { windowsHide: true })
    return true
  } catch {
    return false
  }
}

// The one-click install target, probed directly because a PATH lookup can
// miss it: on macOS GUI apps get a minimal PATH (so ~/.local/bin is
// invisible to `which`), and on Windows the registry PATH entry we add only
// reaches processes started after this app. Windows installs OUTSIDE the
// NSIS $INSTDIR (%LocalAppData%\Programs\syrus-desktop) on purpose — the
// updater replaces that directory wholesale on every auto-update, which
// would silently delete the CLI.
const localBinSyrus = () =>
  process.platform === "win32"
    ? path.join(process.env.LOCALAPPDATA ?? path.join(os.homedir(), "AppData", "Local"), "Syrus", "bin", "syrus.exe")
    : path.join(os.homedir(), ".local", "bin", "syrus")

const syrusCliBinary = async (): Promise<string | null> => {
  if (await commandExists("syrus")) {
    return "syrus"
  }

  try {
    await fs.access(localBinSyrus(), fsConstants.X_OK)
    return localBinSyrus()
  } catch {
    return null
  }
}

const syrusCliAvailable = async () => {
  if (cachedCliAvailable !== null) {
    return cachedCliAvailable
  }

  cachedCliAvailable = (await syrusCliBinary()) !== null
  return cachedCliAvailable
}

type CliInstallOptions = { withSkill?: boolean }

type CliInstallResult = {
  installed: boolean
  target: string | null
  onPath: boolean
  signedIn: boolean
  skillInstalled: boolean
  skillError: string | null
  error: string | null
}

// Adds the CLI's install dir to the per-user PATH on Windows — the platform
// actually sanctions this (HKCU\Environment), unlike POSIX shell rc files.
// Reads the raw registry value with variable expansion disabled so other
// entries' %VARS% survive the round-trip, appends idempotently, and
// broadcasts WM_SETTINGCHANGE so new terminals pick it up without logoff.
// setx is deliberately avoided: it truncates at 1024 chars and rewrites
// REG_EXPAND_SZ as REG_SZ — the classic PATH-corruption bug.
const addToWindowsUserPath = async (dir: string) => {
  const script = [
    `$dir = '${dir.replace(/'/g, "''")}'`,
    "$key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)",
    "$kind = [Microsoft.Win32.RegistryValueKind]::ExpandString",
    "$current = ''",
    "if ($key.GetValueNames() -contains 'Path') {",
    "  $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)",
    "  $kind = $key.GetValueKind('Path')",
    "}",
    "$entries = $current -split ';' | Where-Object { $_ -ne '' }",
    "if (-not ($entries -contains $dir)) {",
    "  $next = if ($current -eq '') { $dir } else { ($current.TrimEnd(';') + ';' + $dir) }",
    "  $key.SetValue('Path', $next, $kind)",
    "  $signature = '[DllImport(\"user32.dll\", SetLastError = true, CharSet = CharSet.Auto)] public static extern IntPtr SendMessageTimeout(IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);'",
    "  $type = Add-Type -MemberDefinition $signature -Name Win32SendMessage -Namespace SyrusInstall -PassThru",
    "  [UIntPtr]$result = [UIntPtr]::Zero",
    "  $type::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result) | Out-Null",
    "}",
    "$key.Close()"
  ].join("\n")

  await execFileAsync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script], {
    windowsHide: true
  })
}

const bundledCliPath = () => {
  const bundledDir = app.isPackaged
    ? path.join(process.resourcesPath, "cli")
    : path.join(__dirname, "..", "..", "resources", "cli")
  const suffix = process.platform === "win32" ? ".exe" : ""
  return path.join(bundledDir, `syrus-${process.platform}-${process.arch === "arm64" ? "arm64" : "x64"}${suffix}`)
}

const claudeSkillPath = () => path.join(os.homedir(), ".claude", "skills", "syrus", "SKILL.md")

// Where local coding agents keep their config; presence gates the skill
// offer (docs/install-experience-spec.md I4). Directory-based on purpose:
// GUI apps see a minimal PATH on macOS, and the config dir is what the
// skill actually integrates with.
const agentToolPresent = async (): Promise<boolean> => {
  for (const dir of [path.join(os.homedir(), ".claude"), path.join(os.homedir(), ".codex")]) {
    try {
      await fs.access(dir)
      return true
    } catch {
      // keep looking
    }
  }
  return false
}

const fileSha256 = async (filePath: string): Promise<string | null> => {
  try {
    const { createHash } = await import("node:crypto")
    const contents = await fs.readFile(filePath)
    return createHash("sha256").update(contents).digest("hex")
  } catch {
    return null
  }
}

// Batteries included (docs/install-experience-spec.md I1/I2): the CLI is
// product plumbing — installed silently on first launch and re-installed
// whenever the bundled binary differs from what's on disk (content hash;
// the binary carries no version command), which is exactly what happens
// after every app auto-update. A previously installed Claude Code skill
// rides along so its content tracks the binary. Failures are non-fatal:
// the next launch retries, and the tray banner covers a truly absent CLI.
const ensureCliCurrent = async () => {
  const bundledHash = await fileSha256(bundledCliPath())
  if (bundledHash === null) {
    return // dev build without staged binaries — nothing to install from
  }

  const installedHash = await fileSha256(localBinSyrus())
  if (installedHash === bundledHash) {
    return
  }

  const skillPresent = await fs
    .access(claudeSkillPath())
    .then(() => true)
    .catch(() => false)

  await performCliInstall({ withSkill: skillPresent })
}

// One-click CLI install from the bundled per-arch binary. No login step —
// the app already keeps ~/.syrus/credentials in the CLI-shared format
// (credentialsStore.ts owns that file), so the CLI is signed in the moment
// the binary lands. macOS: copy to ~/.local/bin, never mutate PATH (shell
// rc files are personal; callers show the export line). Windows: copy to
// %LocalAppData%\Syrus\bin and add that dir to the per-user PATH registry
// value. The optional Claude Code skill goes through the CLI's own
// `skill install` so clone-based users share the exact same path.
const performCliInstall = async ({ withSkill = false }: CliInstallOptions = {}): Promise<CliInstallResult> => {
  try {
    const source = bundledCliPath()
    await fs.access(source)

    const target = localBinSyrus()
    const binDir = path.dirname(target)
    await fs.mkdir(binDir, { recursive: true })

    if (process.platform === "win32") {
      // A running syrus.exe can't be overwritten (EBUSY), but it CAN be
      // renamed — the .old file gets cleaned up on the next install.
      await fs.unlink(`${target}.old`).catch(() => {})
      await fs.rename(target, `${target}.old`).catch(() => {})
    }

    await fs.copyFile(source, target)
    await fs.chmod(target, 0o755)

    if (process.platform === "win32") {
      // Best-effort: a failed PATH write still leaves a working absolute-
      // path install (the tray execs the absolute path anyway).
      await addToWindowsUserPath(binDir).catch(() => {})
    }

    const signedIn = cachedCredentials !== null

    let skillInstalled = false
    let skillError: string | null = null
    if (withSkill) {
      try {
        await execFileAsync(target, ["skill", "install"], { windowsHide: true })
        skillInstalled = true
      } catch (error) {
        // The binary landed; a failed skill write must not report the whole
        // install as broken.
        skillError = error instanceof Error ? error.message : "Could not install the Claude Code skill."
      }
    }

    // Fresh PATH probe: the copy may or may not be reachable as `syrus`.
    cachedCliAvailable = null
    const onPath = await syrusCliAvailable()
    return { installed: true, target, onPath, signedIn, skillInstalled, skillError, error: null }
  } catch (error) {
    return {
      installed: false,
      target: null,
      onPath: false,
      signedIn: false,
      skillInstalled: false,
      skillError: null,
      error: error instanceof Error ? error.message : "Could not install the Syrus CLI."
    }
  }
}

// The web app window carries no IPC bridge (remote content), so the
// skill-offer setup step is the main process watching for the moment the
// user is signed in and settled on the home surface — i.e. onboarding,
// sign-in, and GitHub/agent connect flows are behind them. The CLI itself
// is never offered — ensureCliCurrent installs it silently (spec I1); the
// skill writes into another tool's config directory, so it gets the one
// explicit ask (spec I4), and only when such a tool is actually present.
let skillOfferInFlight = false

const offerSkillIfAgentDetected = async (window: BrowserWindow) => {
  // cliInstallOffered is the legacy key from when this dialog offered the
  // CLI with a skill checkbox — an install that already answered it was
  // already asked about the skill.
  if (skillOfferInFlight || store.get("skillInstallOffered", false) || store.get("cliInstallOffered", false)) {
    return
  }

  if (!cachedCredentials) {
    return
  }

  let pathname: string
  try {
    pathname = new URL(window.webContents.getURL()).pathname
  } catch {
    return
  }

  // Only the settled home surface — never interrupt onboarding, auth, or a
  // deep-linked page the user is actually working in.
  if (pathname !== "/" && pathname !== "/dashboard") {
    return
  }

  if (!(await agentToolPresent())) {
    // No marker: don't ask, and don't burn the once-only flag — the offer
    // stays live for the launch after Claude Code or Codex shows up.
    return
  }

  const alreadyInstalled = await fs
    .access(claudeSkillPath())
    .then(() => true)
    .catch(() => false)
  if (alreadyInstalled) {
    store.set("skillInstallOffered", true)
    return
  }

  skillOfferInFlight = true
  try {
    const isWindows = process.platform === "win32"
    const { response } = await dialog.showMessageBox(window, {
      type: "question",
      buttons: ["Add skill", "Not now"],
      defaultId: 0,
      cancelId: 1,
      message: "Coding agent detected — teach it Syrus?",
      detail:
        `Claude Code (or Codex) is set up on this ${isWindows ? "PC" : "Mac"}. ` +
        "Adding the Syrus skill lets agent sessions file work, check job status, and drive reviews through the syrus CLI. " +
        "It writes one file under ~/.claude/skills and keeps itself current with app updates. " +
        "You can add or remove it any time from Preferences.",
    })

    // Asked and answered — either way, don't nag on every navigation.
    store.set("skillInstallOffered", true)

    if (response !== 0) {
      return
    }

    // The CLI is normally already present (ensureCliCurrent at launch); a
    // missing binary here just means that install failed, so retry it with
    // the skill in one go.
    let skillError: string | null = null
    try {
      await execFileAsync(localBinSyrus(), ["skill", "install"], { windowsHide: true })
    } catch {
      const result = await performCliInstall({ withSkill: true })
      if (!result.skillInstalled) {
        skillError = result.skillError ?? result.error ?? "Could not install the skill."
      }
    }

    if (skillError) {
      await dialog.showMessageBox(window, {
        type: "warning",
        message: "The Syrus skill could not be added.",
        detail: `${skillError} You can retry from Preferences → Projects.`
      })
      return
    }

    await dialog.showMessageBox(window, {
      type: "info",
      message: "Syrus skill added",
      detail: "New Claude Code sessions can now drive Syrus through the syrus CLI."
    })
  } finally {
    skillOfferInFlight = false
  }
}

const repoNameFromSlug = (repoSlug: string) => repoSlug.split("/").filter(Boolean).at(-1) ?? repoSlug

const resolveLocalPath = (repoSlug: string) => {
  const settings = getDesktopSettings()
  const overridePath = settings.localRepoPaths[repoSlug]?.trim()
  if (overridePath) {
    return overridePath
  }

  const localProjectsRoot = settings.localProjectsRoot.trim()
  if (localProjectsRoot) {
    return path.join(localProjectsRoot, repoNameFromSlug(repoSlug))
  }

  return null
}

const checkoutAvailability = async (repoSlug: string): Promise<CheckoutAvailability> => ({
  cliAvailable: await syrusCliAvailable(),
  localPath: resolveLocalPath(repoSlug)
})

const checkoutJob = async ({ jobRef, repoSlug, branchName, extraArgs }: CheckoutRequest) => {
  const localPath = resolveLocalPath(repoSlug)
  if (!localPath) {
    await showPreferencesWindow()
    throw new Error("Configure a local projects root or repository override in Preferences.")
  }

  if (!(await syrusCliAvailable())) {
    throw new Error("Install the Syrus CLI to enable local branch checkout.")
  }

  try {
    const cliBinary = (await syrusCliBinary()) ?? "syrus"
    await execFileAsync(cliBinary, ["checkout", jobRef, ...(extraArgs ?? [])], { cwd: localPath, windowsHide: true })
    setLastUsedRepo(repoSlug)
    return { branchName }
  } catch (error) {
    const processError = error as NodeJS.ErrnoException & { stderr?: string; stdout?: string }
    const stderr = processError.stderr?.trim()
    const stdout = processError.stdout?.trim()
    throw new Error(stderr || stdout || processError.message || "Local checkout failed.")
  }
}

const localStatusCandidatePaths = () => {
  const settings = getDesktopSettings()
  const candidates: string[] = []
  const lastUsedRepo = settings.lastUsedRepo.trim()
  const lastUsedRepoPath = lastUsedRepo ? resolveLocalPath(lastUsedRepo) : null

  if (lastUsedRepoPath) {
    candidates.push(lastUsedRepoPath)
  }

  for (const localRepoPath of Object.values(settings.localRepoPaths)) {
    const normalizedPath = localRepoPath.trim()
    if (normalizedPath) {
      candidates.push(normalizedPath)
    }
  }

  if (settings.localProjectsRoot.trim()) {
    candidates.push(settings.localProjectsRoot.trim())
  }

  return Array.from(new Set(candidates))
}

const parseLocalStatus = (output: string): LocalStatus | null => {
  const payload = JSON.parse(output) as Partial<LocalStatus>

  if (
    typeof payload.job_id !== "number" ||
    typeof payload.branch !== "string" ||
    typeof payload.behind !== "number"
  ) {
    return null
  }

  return {
    job_id: payload.job_id,
    branch: payload.branch,
    behind: payload.behind
  }
}

const localStatus = async (): Promise<LocalStatus | null> => {
  if (!(await syrusCliAvailable())) {
    return null
  }

  for (const localPath of localStatusCandidatePaths()) {
    try {
      const stats = await fs.stat(localPath)
      if (!stats.isDirectory()) {
        continue
      }

      const statusBinary = (await syrusCliBinary()) ?? "syrus"
      const { stdout } = await execFileAsync(statusBinary, ["status", "--json"], { cwd: localPath, windowsHide: true })
      const status = parseLocalStatus(stdout)
      if (status) {
        return status
      }
    } catch {
      // Try the next configured checkout path; the tray should fail silently.
    }
  }

  return null
}

const fetchAdminControls = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before loading admin controls.")
  }

  const response = await fetch(appApiUrl(credentials.url, "/api/v1/app/admin/console"), {
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error("Could not load admin controls.")
  }

  const payload = (await response.json()) as AdminConsolePayload
  return {
    polling_paused: payload.settings.polling_paused,
    runs_paused: payload.settings.runs_paused
  }
}

const adminControlPath = (control: AdminControl, pause: boolean) => {
  if (control === "polling") {
    return pause ? "/api/v1/app/admin/console/pause_polling" : "/api/v1/app/admin/console/unpause_polling"
  }

  return pause ? "/api/v1/app/admin/console/pause_runs" : "/api/v1/app/admin/console/unpause_runs"
}

const toggleAdminControl = async (sender: Electron.WebContents, control: AdminControl, pause: boolean) => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (!credentials) {
    throw new Error("Connect Syrus before changing admin controls.")
  }

  const label = control === "polling" ? "polling" : "new Run starts"
  const action = pause ? "pause" : "resume"
  const parentWindow = BrowserWindow.fromWebContents(sender)
  const confirmationOptions: MessageBoxOptions = {
    type: "warning",
    buttons: [pause ? "Pause" : "Resume", "Cancel"],
    defaultId: 1,
    cancelId: 1,
    message: `${pause ? "Pause" : "Resume"} ${label}?`,
    detail: pause
      ? `Syrus will stop ${control === "polling" ? "polling repositories" : "starting new Runs"} until an admin resumes it.`
      : `Syrus will resume ${control === "polling" ? "repository polling" : "starting new Runs"}.`
  }
  const confirmation = parentWindow
    ? await dialog.showMessageBox(parentWindow, confirmationOptions)
    : await dialog.showMessageBox(confirmationOptions)

  if (confirmation.response !== 0) {
    return { cancelled: true, controls: await fetchAdminControls() }
  }

  const response = await fetch(appApiUrl(credentials.url, adminControlPath(control, pause)), {
    method: "POST",
    headers: {
      Authorization: `Bearer ${credentials.token.trim()}`
    }
  })

  throwIfUnauthorized(credentials, response)
  if (!response.ok) {
    throw new Error(`Could not ${action} ${label}.`)
  }

  const payload = (await response.json()) as AdminConsolePayload
  return {
    cancelled: false,
    controls: {
      polling_paused: payload.settings.polling_paused,
      runs_paused: payload.settings.runs_paused
    }
  }
}

const saveCredentials = async (credentials: Credentials) => {
  const normalizedCredentials = {
    url: credentials.url.trim(),
    token: credentials.token.trim()
  }

  await validateCredentialsWithServer(normalizedCredentials)
  await writeCredentialsFile(normalizedCredentials)

  cachedCredentials = normalizedCredentials
  suspectTokenKey = null
  startAppUserCable(normalizedCredentials)

  // In remote mode the tray URL and the app window must stay in lockstep:
  // a manual URL change in Preferences retargets the web container too
  // (local mode's URL is owned by its .env, never by credentials). The open
  // window closes so its next open uses the new instance.
  const normalizedServerUrl = normalizedCredentials.url.replace(/\/+$/, "")
  if (getBackendMode() === "remote" && getServerUrl() !== normalizedServerUrl) {
    saveBackendConfig({ mode: "remote", serverUrl: normalizedServerUrl })
    webAppWindow?.window.close()
  }

  await fetchBootstrap()
  mainWindow?.webContents.send("credentials-saved", normalizedCredentials)
  preferencesWindow?.webContents.send("credentials-saved", normalizedCredentials)
  return normalizedCredentials
}

const deleteCredentials = async () => {
  await deleteCredentialsFile()

  cachedCredentials = null
  setUnreadCount(0)
  stopAppUserCable()
}

const rendererUrl = (view?: string) => {
  if (app.isPackaged) {
    const filePath = path.join(__dirname, "../dist/index.html")
    return view ? `file://${filePath}?view=${view}` : `file://${filePath}`
  }

  const url = new URL("http://127.0.0.1:5173")
  if (view) {
    url.searchParams.set("view", view)
  }

  return url.toString()
}

const loadRenderer = async (window: BrowserWindow, view?: string) => {
  if (app.isPackaged) {
    await window.loadFile(path.join(__dirname, "../dist/index.html"), view ? { query: { view } } : undefined)
  } else {
    await window.loadURL(rendererUrl(view))
  }
}

const createPopoverWindow = async () => {
  mainWindow = new BrowserWindow({
    width: 360,
    height: 480,
    show: false,
    frame: false,
    resizable: false,
    fullscreenable: false,
    skipTaskbar: true,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, "preload.cjs")
    }
  })

  mainWindow.on("blur", () => {
    mainWindow?.hide()
  })

  mainWindow.on("close", (event) => {
    if (!isQuitting) {
      event.preventDefault()
      mainWindow?.hide()
    }
  })

  await loadRenderer(mainWindow)
}

const popoverPosition = () => {
  if (!tray || !mainWindow) {
    return
  }

  const trayBounds = tray.getBounds()
  const windowBounds = mainWindow.getBounds()
  const workArea = screen.getDisplayNearestPoint({
    x: Math.round(trayBounds.x + trayBounds.width / 2),
    y: Math.round(trayBounds.y + trayBounds.height / 2)
  }).workArea

  const { x, y } = computePopoverPosition({
    trayBounds,
    windowBounds,
    workArea,
    platform: process.platform
  })

  mainWindow.setPosition(x, y, false)
}

const showPopoverWindow = async () => {
  if (!mainWindow) {
    await createPopoverWindow()
  }

  try {
    await syncUnreadCount()
  } catch {
    // The popover should still open if the badge sync is temporarily unavailable.
  }

  popoverPosition()
  mainWindow?.show()
  mainWindow?.focus()
}

const togglePopoverWindow = async () => {
  if (mainWindow?.isVisible()) {
    mainWindow.hide()
    return
  }

  await showPopoverWindow()
}

const showPreferencesWindow = async () => {
  if (preferencesWindow) {
    if (preferencesWindow.isMinimized()) {
      preferencesWindow.restore()
    }

    preferencesWindow.show()
    preferencesWindow.focus()
    return
  }

  preferencesWindow = new BrowserWindow({
    width: 520,
    height: 620,
    minWidth: 420,
    minHeight: 480,
    title: "Syrus Preferences",
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, "preload.cjs")
    }
  })

  preferencesWindow.on("closed", () => {
    preferencesWindow = null
  })

  await loadRenderer(preferencesWindow, "preferences")
}

const showSetupWindow = async () => {
  await showPreferencesWindow()
  preferencesWindow?.webContents.send("credentials-cleared")
}

// The dock icon appears only while a real window is open; tray-only mode
// (today's behavior) keeps it hidden.
const updateDockVisibility = () => {
  if (process.platform !== "darwin") {
    return
  }

  if (onboardingWindow || webAppWindow) {
    app.dock?.show()
  } else {
    app.dock?.hide()
  }
}

const ensureOnboardingDriver = () => {
  onboardingDriver ??= new OnboardingDriver({
    onState: (state) => {
      onboardingWindow?.webContents.send("onboarding:state-changed", state)
      // Supervision starts the moment a local install completes — not only
      // when the user clicks "Open Syrus". Closing the wizard via the
      // traffic light must not leave the session without the watchdog and
      // Backend menu.
      if (state.phase === "done" && state.mode === "local") {
        createMenu()
        startLocalBackendSupervision()
      }
    },
    onLogLine: (line) => {
      onboardingWindow?.webContents.send("onboarding:log-line", line)
    }
  })
  return onboardingDriver
}

// In-flight guard: the window variable is only assigned after the renderer
// finishes loading, and a second call during that gap (tray "Open Syrus",
// activate, second-instance) would otherwise create a duplicate window that
// stops receiving driver state pushes.
let onboardingWindowOpening: Promise<void> | null = null

const showOnboardingWindow = async () => {
  if (onboardingWindow) {
    onboardingWindow.show()
    onboardingWindow.focus()
    return
  }

  if (onboardingWindowOpening) {
    return onboardingWindowOpening
  }

  onboardingWindowOpening = (async () => {
    ensureOnboardingDriver()
    if (process.platform === "darwin") {
      app.dock?.show()
    }

    onboardingWindow = await createOnboardingWindow({
      preloadPath: path.join(__dirname, "preload.cjs"),
      loadRenderer,
      onClosed: () => {
        onboardingWindow = null
        updateDockVisibility()
      }
    })
  })()

  try {
    await onboardingWindowOpening
  } finally {
    onboardingWindowOpening = null
  }
}

// The web-container fallback page. It carries no IPC bridge on purpose —
// the same window later loads remote content — so it only explains, and
// startBackendRecoveryPolling() swaps the real app back in when /up answers.
const loadBackendStatus = async (window: BrowserWindow, detail: string) => {
  if (app.isPackaged) {
    await window.loadFile(path.join(__dirname, "../dist/index.html"), {
      query: { view: "backend-status", detail }
    })
  } else {
    const url = new URL("http://127.0.0.1:5173")
    url.searchParams.set("view", "backend-status")
    url.searchParams.set("detail", detail)
    await window.loadURL(url.toString())
  }
}

const stopBackendRecoveryPolling = () => {
  if (backendRecoveryTimer) {
    clearInterval(backendRecoveryTimer)
    backendRecoveryTimer = null
  }
}

const startBackendRecoveryPolling = () => {
  stopBackendRecoveryPolling()
  const serverUrl = getServerUrl()
  if (serverUrl === "") {
    return
  }

  backendRecoveryTimer = setInterval(() => {
    void (async () => {
      try {
        const response = await fetch(`${serverUrl}/up`, { signal: AbortSignal.timeout(2_000) })
        if (response.ok) {
          stopBackendRecoveryPolling()
          await webAppWindow?.loadServerUrl()
        }
      } catch {
        // Keep polling; the backend may still be starting.
      }
    })()
  }, 3_000)
}

const showWebAppWindow = async () => {
  if (webAppWindow) {
    if (webAppWindow.window.isMinimized()) {
      webAppWindow.window.restore()
    }

    webAppWindow.window.show()
    webAppWindow.window.focus()
    return
  }

  const serverUrl = getServerUrl()
  if (serverUrl === "") {
    await showOnboardingWindow()
    return
  }

  const manifest = await readBackendManifest()
  webAppWindow = createWebAppWindow({
    serverUrl,
    buildSha: manifest?.appBuild ?? null,
    savedBounds: store.get("webAppWindowBounds", null),
    loadFallback: (window) => loadBackendStatus(window, getBackendMode() === "remote" ? "remote" : "local"),
    onBoundsChanged: (bounds) => store.set("webAppWindowBounds", bounds),
    onLoadFailed: () => startBackendRecoveryPolling(),
    onClosed: () => {
      webAppWindow = null
      stopBackendRecoveryPolling()
      updateDockVisibility()
    }
  })
  updateDockVisibility()

  // Whenever a same-origin page is showing and the tray isn't configured
  // for this instance yet, try to mint its token from the signed-in web
  // session. Cheap no-op once credentials match. Signing in happens via
  // client-side routing (no did-finish-load), so in-page navigations
  // trigger the attempt too.
  const handle = webAppWindow
  const attemptTokenProvisioning = () => {
    let sameOrigin = false
    try {
      sameOrigin = new URL(handle.window.webContents.getURL()).origin === new URL(serverUrl).origin
    } catch {
      sameOrigin = false
    }

    if (!sameOrigin) {
      return
    }

    void maybeProvisionDesktopToken(handle.window.webContents, serverUrl, {
      getCachedCredentials: () => cachedCredentials,
      saveCredentials,
      // A token this instance already rejected (backend DB rebuilt) must
      // not block re-provisioning — see suspectTokenKey.
      credentialsSuspect: (credentials) => suspectTokenKey === credentialsKey(credentials)
    })
  }
  handle.window.webContents.on("did-finish-load", attemptTokenProvisioning)
  handle.window.webContents.on("did-navigate-in-page", attemptTokenProvisioning)

  // One-time post-setup step: once the user is signed in and lands on the
  // home surface (never mid-onboarding), offer the Claude Code skill if a
  // coding agent is set up on this machine. Native dialog because the
  // remote web app deliberately has no IPC bridge.
  const attemptSkillOffer = () => {
    void offerSkillIfAgentDetected(handle.window)
  }
  handle.window.webContents.on("did-finish-load", attemptSkillOffer)
  handle.window.webContents.on("did-navigate-in-page", attemptSkillOffer)

  try {
    await webAppWindow.loadServerUrl()
  } catch {
    // did-fail-load swaps in the backend-status page and starts recovery.
  }
}

const openSyrus = async () => {
  if (getBackendMode() === "") {
    await showOnboardingWindow()
    return
  }

  await showWebAppWindow()
}

// Swap the web window onto the status page and let recovery polling bring
// the app back once /up answers. Used by the watchdog and explicit stops.
const showBackendUnavailable = (detail: string) => {
  if (!webAppWindow) {
    return
  }

  void loadBackendStatus(webAppWindow.window, detail)
  startBackendRecoveryPolling()
}

// Each app release pins its tested backend image (manifest.json, staged at
// build time). After an app auto-update the running stack is still on the
// previous pin — offer the upgrade instead of silently mutating a running
// backend. Dev builds have no manifest, so this is a no-op there.
let offeredBackendImage: string | null = null

const offerBackendUpdateIfPinned = async () => {
  if (getBackendMode() !== "local") {
    return
  }

  const image = (await readBackendManifest())?.image
  if (!image || image === offeredBackendImage) {
    return
  }

  const current = await backendLifecycle.currentImagePin()
  if (current === image) {
    return
  }

  offeredBackendImage = image
  const choice = await dialog.showMessageBox({
    type: "question",
    buttons: ["Update Backend", "Not Now"],
    defaultId: 0,
    cancelId: 1,
    message: "Update the Syrus backend?",
    detail:
      `This version of Syrus was tested with ${image}` +
      `${current ? `, but the local backend is pinned to ${current}` : ""}. ` +
      "Updating pulls the new image and restarts the backend — agent runs pause for a minute or two."
  })

  if (choice.response !== 0) {
    return
  }

  if (await backendLifecycle.updateBackend(image)) {
    new Notification({ title: "Syrus backend updated", body: image }).show()
    void webAppWindow?.loadServerUrl()
  } else {
    await reportBackendActionFailure("update the Syrus backend")
  }
}

const startLocalBackendSupervision = () => {
  if (getBackendMode() !== "local") {
    return
  }

  void backendLifecycle.ensureRunning().then(() => offerBackendUpdateIfPinned())
  backendLifecycle.startWatchdog({
    onHealthyChanged: (healthy, diagnosis) => {
      if (!healthy) {
        showBackendUnavailable(diagnosis ?? "local")
        if (diagnosis === "data-gone") {
          void offerSetupAfterDataLoss()
        }
      }
      // Recovery polling reloads the app when it becomes healthy again.
    }
  })
}

// The escape hatch out of any wedged backend state (instance gone, Docker
// wiped, wrong URL): forget the backend config — never the data or the
// ~/.syrus credentials — and start onboarding over.
const runSetupAgain = async ({ skipConfirmation = false } = {}) => {
  if (!skipConfirmation) {
    const confirmation = await dialog.showMessageBox({
      type: "question",
      buttons: ["Run Setup", "Cancel"],
      defaultId: 0,
      cancelId: 1,
      message: "Set up Syrus again?",
      detail: "Choose again where Syrus runs. Your credentials and any local Syrus data stay untouched."
    })

    if (confirmation.response !== 0) {
      return
    }
  }

  backendLifecycle.stopWatchdog()
  stopBackendRecoveryPolling()
  clearBackendConfig()
  // A leftover driver still holds the previous run's terminal state
  // (done/failed) — without a reset the reopened wizard shows that stale
  // phase instead of Welcome.
  onboardingDriver?.reset()
  webAppWindow?.window.close()
  createMenu() // drops the Backend menu until a new local install exists
  await showOnboardingWindow()
}

// Shown once per app run when the watchdog finds Docker healthy but the
// Syrus data volume missing — the stack can never come back on its own.
let dataLossPromptShown = false
const offerSetupAfterDataLoss = async () => {
  if (dataLossPromptShown) {
    return
  }

  dataLossPromptShown = true
  const choice = await dialog.showMessageBox({
    type: "warning",
    buttons: ["Run Setup Again", "Not Now"],
    defaultId: 0,
    cancelId: 1,
    message: "Your local Syrus data is gone.",
    detail: "Docker is running, but the Syrus data volume no longer exists (it may have been deleted along with your containers). Syrus can't start again until it's set up fresh."
  })

  if (choice.response === 0) {
    await runSetupAgain({ skipConfirmation: true })
  }
}

const confirmStopBackend = async () => {
  const confirmation = await dialog.showMessageBox({
    type: "warning",
    buttons: ["Stop Syrus", "Cancel"],
    defaultId: 1,
    cancelId: 1,
    message: "Stop Syrus?",
    detail: "GitHub polling and agent runs stop until you start it again from the Backend menu."
  })

  if (confirmation.response !== 0) {
    return
  }

  if (await backendLifecycle.stopBackend()) {
    showBackendUnavailable("stopped")
  } else {
    await reportBackendActionFailure("stop Syrus")
  }
}

// Backend-menu actions return false when refused (busy) or failed; silent
// no-ops made the menu look dead.
const reportBackendActionFailure = async (label: string) => {
  await dialog.showMessageBox({
    type: "warning",
    message: `Couldn't ${label}.`,
    detail:
      "Another backend operation may still be in progress, or Docker isn't ready. Check Backend → Open Install Log for details."
  })
}

const runBackendAction = async (label: string, action: () => Promise<boolean>) => {
  if (!(await action())) {
    await reportBackendActionFailure(label)
  }
}

// After onboarding completes: close the wizard, open the app window, and
// (for a fresh local install) pick up lifecycle duties + the Backend menu.
const finishOnboarding = async () => {
  onboardingWindow?.close()
  createMenu()
  startLocalBackendSupervision()
  await showWebAppWindow()
}

// Shared "Restart to update" entry: appears in the app menu and the tray
// context menu once electron-updater has an update staged.
const updateMenuItems = (): Electron.MenuItemConstructorOptions[] => {
  const version = appUpdates.downloadedUpdateVersion()
  if (!version) {
    return []
  }

  return [
    {
      label: `Restart to update Syrus (v${version})`,
      click: () => {
        // quitAndInstall closes windows BEFORE any quit event fires, so the
        // hide-on-close handler would preventDefault and abort the update
        // unless the quit flag is already set.
        isQuitting = true
        appUpdates.quitAndInstallUpdate()
      }
    },
    { type: "separator" }
  ]
}

const checkForUpdatesInteractively = async () => {
  const result = await appUpdates.checkForUpdatesInteractive()
  switch (result.outcome) {
    case "disabled":
      await dialog.showMessageBox({
        type: "info",
        message: "Automatic updates are unavailable in this build.",
        detail:
          process.platform === "win32"
            ? "Updates apply to the packaged app installed with the Syrus setup program."
            : "Updates apply to the packaged, signed app installed from the DMG."
      })
      break
    case "downloaded":
    case "downloading":
      await dialog.showMessageBox({
        type: "info",
        message: `Syrus ${result.version} is on its way.`,
        detail:
          result.outcome === "downloaded"
            ? "The update is ready — restart Syrus from the menu to apply it."
            : "The update is downloading in the background; you'll be offered a restart when it's ready."
      })
      break
    case "up-to-date":
      await dialog.showMessageBox({
        type: "info",
        message: `You're up to date.`,
        detail: `Syrus ${result.version} is the latest version.`
      })
      break
    case "error":
      await dialog.showMessageBox({
        type: "warning",
        message: "Couldn't check for updates.",
        detail: "Check your network connection and try again later."
      })
      break
  }
}

const trayContextMenu = () =>
  Menu.buildFromTemplate([
    ...updateMenuItems(),
    {
      label: "Open Syrus",
      click: () => {
        void openSyrus()
      }
    },
    {
      label: "Preferences",
      click: () => {
        void showPreferencesWindow()
      }
    },
    { type: "separator" },
    { role: "quit", label: "Quit" }
  ])

const showTrayContextMenu = () => {
  mainWindow?.hide()
  tray?.popUpContextMenu(trayContextMenu())
}

const createTray = () => {
  plainTrayIcon = createPlainTrayIcon()

  tray = new Tray(plainTrayIcon)
  tray.setToolTip("Syrus")
  tray.on("click", (event) => {
    if (event.ctrlKey) {
      showTrayContextMenu()
      return
    }

    void togglePopoverWindow()
  })
  tray.on("right-click", showTrayContextMenu)
  updateTrayBadge()
}

const registerGlobalHotkey = (globalHotkey = getGlobalHotkey()) => {
  if (globalHotkey === "") {
    registeredGlobalHotkey = ""
    return
  }

  try {
    const registered = globalShortcut.register(globalHotkey, () => {
      void togglePopoverWindow()
    })

    if (!registered) {
      console.warn(`Could not register global hotkey "${globalHotkey}"; it may already be in use.`)
      registeredGlobalHotkey = ""
      return
    }

    registeredGlobalHotkey = globalHotkey
  } catch (error) {
    console.warn(`Could not register global hotkey "${globalHotkey}"; it may already be in use.`, error)
    registeredGlobalHotkey = ""
  }
}

const saveGlobalHotkey = (globalHotkey: string) => {
  const normalizedHotkey = globalHotkey.trim()
  const previousHotkey = registeredGlobalHotkey

  if (previousHotkey) {
    globalShortcut.unregister(previousHotkey)
    registeredGlobalHotkey = ""
  }

  if (normalizedHotkey === "") {
    store.set("globalHotkey", "")
    return { globalHotkey: "" }
  }

  try {
    const registered = globalShortcut.register(normalizedHotkey, () => {
      void togglePopoverWindow()
    })

    if (!registered) {
      throw new Error("That keyboard shortcut could not be registered. It may already be in use.")
    }

    registeredGlobalHotkey = normalizedHotkey
    store.set("globalHotkey", normalizedHotkey)
    return { globalHotkey: normalizedHotkey }
  } catch (error) {
    if (previousHotkey) {
      registerGlobalHotkey(previousHotkey)
    }

    throw error instanceof Error
      ? error
      : new Error("That keyboard shortcut could not be registered. It may already be in use.")
  }
}

const createMenu = () => {
  const template: Electron.MenuItemConstructorOptions[] = [
    {
      label: app.name,
      submenu: [
        ...updateMenuItems(),
        {
          label: "Check for Updates…",
          click: () => {
            void checkForUpdatesInteractively()
          }
        },
        {
          label: "Run Setup Again…",
          click: () => {
            void runSetupAgain()
          }
        },
        { type: "separator" },
        {
          label: "Sign Out",
          click: async () => {
            await deleteCredentials()
            await showSetupWindow()
          }
        },
        { type: "separator" },
        { role: "quit" }
      ]
    },
    {
      label: "File",
      submenu: [{ role: "close" }]
    },
    {
      label: "Edit",
      submenu: [
        { role: "undo" },
        { role: "redo" },
        { type: "separator" },
        { role: "cut" },
        { role: "copy" },
        { role: "paste" },
        { role: "selectAll" }
      ]
    },
    {
      label: "View",
      submenu: [
        { role: "reload" },
        { role: "toggleDevTools" },
        { type: "separator" },
        { role: "resetZoom" },
        { role: "zoomIn" },
        { role: "zoomOut" },
        { type: "separator" },
        { role: "togglefullscreen" }
      ]
    }
  ]

  // Lifecycle controls only make sense for a stack this app installed;
  // remote mode has nothing to start or stop.
  if (getBackendMode() === "local") {
    template.push({
      label: "Backend",
      submenu: [
        {
          label: "Start Syrus",
          click: () => {
            void runBackendAction("start Syrus", backendLifecycle.startBackend)
          }
        },
        {
          label: "Stop Syrus…",
          click: () => {
            void confirmStopBackend()
          }
        },
        {
          label: "Restart Syrus",
          click: () => {
            void runBackendAction("restart Syrus", backendLifecycle.restartBackend)
          }
        },
        { type: "separator" },
        {
          label: "Open Install Log",
          click: () => {
            void shell.openPath(path.join(localStateDir(), "install.log"))
          }
        },
        {
          label: "Open Data Folder",
          click: () => {
            void shell.openPath(localStateDir())
          }
        }
      ]
    })
  }

  Menu.setApplicationMenu(Menu.buildFromTemplate(template))
}

ipcMain.handle("get-credentials", async () => cachedCredentials ?? (await loadCredentials()))
ipcMain.handle("save-credentials", async (_event, credentials: Credentials) => saveCredentials(credentials))
ipcMain.handle("get-desktop-settings", async () => getDesktopSettings())
ipcMain.handle("save-desktop-settings", async (_event, settings: DesktopSettings) => saveDesktopSettings(settings))
ipcMain.handle("get-global-hotkey", async () => getGlobalHotkey())
ipcMain.handle("save-global-hotkey", async (_event, globalHotkey: string) => saveGlobalHotkey(globalHotkey))
ipcMain.handle("choose-local-projects-root", async () => {
  const browserWindow = preferencesWindow ?? mainWindow
  const options: OpenDialogOptions = {
    properties: ["openDirectory"],
    title: "Choose local projects root"
  }
  const result = browserWindow
    ? await dialog.showOpenDialog(browserWindow, options)
    : await dialog.showOpenDialog(options)

  return result.canceled ? null : result.filePaths[0]
})
ipcMain.handle("syrus-cli-status", async () => ({ available: await syrusCliAvailable() }))
ipcMain.handle("install-syrus-cli", async (_event, options?: CliInstallOptions) => performCliInstall(options))
ipcMain.handle("checkout-availability", async (_event, repoSlug: string) => checkoutAvailability(repoSlug))
ipcMain.handle("checkout-job", async (_event, request: CheckoutRequest) => checkoutJob(request))
ipcMain.handle("syrus:local-status", async () => localStatus())
ipcMain.handle("show-preferences", async () => {
  await showPreferencesWindow()
})
// Tray-popover action bar: the right-click context menu's essentials
// (open, preferences, quit) reachable from a left click too.
ipcMain.handle("open-syrus", async () => {
  await openSyrus()
})
ipcMain.handle("quit-app", () => {
  app.quit()
})
ipcMain.handle("copy-text", async (_event, text: string) => {
  clipboard.writeText(text)
})
ipcMain.handle("syrusDesktop:showNotification", async (_event, opts: { title: string; body: string; jobId: number }) => {
  if (!Notification.isSupported()) {
    return
  }

  const notification = new Notification({ title: opts.title, body: opts.body })
  notification.on("click", () => {
    void showPopoverWindow().then(() => {
      mainWindow?.webContents.send("syrusDesktop:navigateToJob", opts.jobId)
    })
  })
  notification.show()
})
ipcMain.handle("fetch-bootstrap", async () => fetchBootstrap())
ipcMain.handle("fetch-repositories", async () => fetchRepositories())
ipcMain.handle("get-last-used-repo", async () => getLastUsedRepo())
ipcMain.handle("set-last-used-repo", async (_event, repoSlug: string) => setLastUsedRepo(repoSlug))
ipcMain.handle("fetch-admin-controls", async () => fetchAdminControls())
ipcMain.handle("toggle-admin-control", async (event, control: AdminControl, pause: boolean) =>
  toggleAdminControl(event.sender, control, pause)
)
ipcMain.handle("create-direct-job", async (_event, request: CreateJobRequest) => createDirectJob(request))
// "Generate a token" in Preferences: API tokens live on the instance's own
// account-settings page (generate/rotate/revoke), so open that in the
// signed-in app window. The public docs site is only the fallback when no
// instance is configured yet.
ipcMain.handle("open-token-docs", async () => {
  const serverUrl = getServerUrl().replace(/\/+$/, "")
  if (serverUrl !== "") {
    await showWebAppWindow()
    await webAppWindow?.window.loadURL(`${serverUrl}/settings`)
    return
  }

  await shell.openExternal(TOKEN_DOCS_URL)
})
ipcMain.handle("fetch-inbox-jobs", async () => fetchInboxJobs())
ipcMain.handle("fetch-job-detail", async (_event, jobID: number) => fetchJobDetail(jobID))
ipcMain.handle("fetch-notification-unread-count", async () => fetchNotificationUnreadCount())
ipcMain.handle("fetch-notifications", async () => fetchNotifications())
ipcMain.handle("mark-notification-read", async (_event, id: number) => markNotificationRead(id))
ipcMain.handle("mark-all-notifications-read", async () => markAllNotificationsRead())
ipcMain.handle("confirm-approve-job", async (event, jobID: number) => confirmApproveJob(event.sender, jobID))
ipcMain.handle("approve-job", async (_event, jobID: number) => approveJob(jobID))
ipcMain.handle("retry-job", async (_event, jobID: number) => retryJob(jobID))
ipcMain.handle("submit-job-feedback", async (_event, jobID: number, body: string) => submitJobFeedback(jobID, body))
ipcMain.handle("get-app-version", async () => app.getVersion())
ipcMain.handle("get-server-url", async () => getServerUrl())
ipcMain.handle("onboarding:get-state", async () => ensureOnboardingDriver().getState())
ipcMain.handle("onboarding:choose-mode", async (_event, mode: "local" | "remote") => {
  ensureOnboardingDriver().chooseMode(mode)
})
ipcMain.handle("onboarding:connect-remote", async (_event, request: { url: string }) =>
  ensureOnboardingDriver().connectRemote(request)
)
// Advisory: powers the connect form's live "Syrus found here" check.
ipcMain.handle("onboarding:probe-instance", async (_event, request: { url: string }) =>
  ensureOnboardingDriver().probeInstance(request)
)
// One-click WSL 2 install (Windows; elevates via UAC).
ipcMain.handle("onboarding:install-wsl", async () => ensureOnboardingDriver().installWsl())
ipcMain.handle("onboarding:start-install", async (_event, port?: number) =>
  ensureOnboardingDriver().startInstall(port)
)
ipcMain.handle("onboarding:cancel-install", async () => {
  ensureOnboardingDriver().cancelInstall()
})
ipcMain.handle("onboarding:retry", async () => ensureOnboardingDriver().precheck())
ipcMain.handle("onboarding:back", async () => {
  ensureOnboardingDriver().backToWelcome()
})
ipcMain.handle("onboarding:locate-env", async (event) =>
  ensureOnboardingDriver().locateEnv(BrowserWindow.fromWebContents(event.sender))
)
ipcMain.handle("onboarding:wipe-data", async (event) =>
  ensureOnboardingDriver().wipeData(BrowserWindow.fromWebContents(event.sender))
)
ipcMain.handle("onboarding:open-orbstack-download", async () => {
  ensureOnboardingDriver().openOrbStackDownload()
})
ipcMain.handle("onboarding:open-runtime", async () => ensureOnboardingDriver().openRuntimeApp())
ipcMain.handle("onboarding:install-runtime", async () => ensureOnboardingDriver().installRuntime())
ipcMain.handle("onboarding:adopt-running", async () => {
  ensureOnboardingDriver().adoptRunning()
})
ipcMain.handle("onboarding:finish", async () => finishOnboarding())
ipcMain.handle("open-external", async (_event, url: string) => {
  if (!URL.canParse(url)) {
    throw new Error("Invalid URL.")
  }

  const parsedUrl = new URL(url)
  if (!["http:", "https:"].includes(parsedUrl.protocol)) {
    throw new Error("Only HTTP and HTTPS URLs can be opened.")
  }

  await shell.openExternal(parsedUrl.toString())
})

// One Syrus at a time: a second launch focuses the existing instance —
// unless the second launch is a DIFFERENT version or bundle (a fresh DMG
// while a stale copy still runs, or an updated install), in which case the
// running instance offers to quit and hand over instead of silently
// swallowing the launch. app.quit() is asynchronous: the losing instance's
// whenReady handler would still run (racing store writes against the
// primary, flashing a second tray) unless startup is explicitly gated on
// the lock.
const ownInstanceIdentity = (): InstanceIdentity => ({
  version: app.getVersion(),
  bundlePath: process.platform === "darwin" ? bundlePathFromExecPath(process.execPath) : process.execPath
})

const hasSingleInstanceLock = app.requestSingleInstanceLock(ownInstanceIdentity())
if (!hasSingleInstanceLock) {
  app.quit()
}

let takeoverPromptOpen = false
app.on("second-instance", (_event, _argv, _cwd, additionalData) => {
  const incoming = additionalData as Partial<InstanceIdentity> | undefined
  const own = ownInstanceIdentity()
  // Takeover launches the incoming bundle via `open`; that path is
  // macOS-only for now, matching selfInstall.ts.
  // darwin + win32: both platforms can launch the incoming copy directly
  // (open -n / spawn of the exe path); see selfInstall.launchInstalledCopy.
  if (
    (process.platform === "darwin" || process.platform === "win32") &&
    !takeoverPromptOpen &&
    decideOnSecondInstance(own, incoming) === "offer"
  ) {
    takeoverPromptOpen = true
    const prompt = takeoverPrompt(own, incoming as InstanceIdentity)
    void dialog
      .showMessageBox({
        type: "question",
        message: prompt.message,
        detail: prompt.detail,
        buttons: [...prompt.buttons],
        defaultId: prompt.switchIndex,
        cancelId: 1
      })
      .then(async (choice) => {
        takeoverPromptOpen = false
        if (choice.response !== prompt.switchIndex) {
          return
        }
        // Give up the lock BEFORE launching, or the new copy loses the
        // race against this dying instance and quits itself — the exact
        // trap this feature exists to break.
        app.releaseSingleInstanceLock()
        await launchInstalledCopy((incoming as InstanceIdentity).bundlePath)
        app.quit()
      })
    return
  }

  void openSyrus()
})

app.whenReady().then(async () => {
  if (!hasSingleInstanceLock) {
    return
  }

  if (process.platform === "darwin") {
    app.dock?.hide()
  }

  if (process.platform === "win32") {
    // Must match electron-builder.yml appId — NSIS stamps it into the Start
    // Menu shortcut, and Windows only shows Notification toasts when the
    // process AUMID matches the shortcut's.
    app.setAppUserModelId("app.syrus.desktop")
  }

  // Running from the mounted DMG (or Downloads, or anywhere that isn't an
  // Applications folder): install ourselves into ~/Applications and relaunch
  // from there. This is the DMG's double-click install contract — no drag
  // target, no dialog. ~/Applications keeps it admin-free.
  const bundlePath = bundlePathFromExecPath(process.execPath)
  if (shouldSelfInstall({ isPackaged: app.isPackaged, platform: process.platform, bundlePath, homeDir: os.homedir() })) {
    try {
      const installed = await installBundle(bundlePath, os.homedir())
      // Give up the single-instance lock BEFORE the copy starts, or it would
      // lose the lock race against this dying instance and quit itself.
      app.releaseSingleInstanceLock()
      await launchInstalledCopy(installed)
      app.quit()
      return
    } catch {
      // Keep running from the current location — a read-only mount still
      // works for evaluating the app; the next launch retries the install.
    }
  }

  createMenu()
  await loadCredentials()
  // Batteries included: keep the CLI matching this app version. Fire and
  // forget — a failure self-heals next launch, and nothing downstream
  // blocks on it (tray Checkout re-probes availability per click).
  void ensureCliCurrent().catch(() => {})
  await migrateBackendConfig(cachedCredentials?.url ?? null)
  startAppUserCable(cachedCredentials)
  createTray()
  if (cachedCredentials) {
    try {
      await fetchBootstrap()
    } catch {
      // Credentials may be stale or the instance may be offline; setup still handles it.
    }
  }
  registerGlobalHotkey()
  appUpdates.initAutoUpdates({
    onUpdateDownloaded: () => {
      createMenu() // tray menu rebuilds per click; the app menu needs a refresh
    },
    onBeforeQuitForUpdate: () => {
      isQuitting = true
    }
  })

  if (getBackendMode() === "") {
    await showOnboardingWindow()
    // Mid-setup save point (Windows): the user was in the local flow when a
    // Docker Desktop / WSL install forced a reboot. Jump straight back into
    // it — precheck re-evaluates the machine, finds the freshly installed
    // runtime, and carries on — instead of restarting at Welcome. RunOnce
    // launched us at logon; the persisted flag (settings.ts) does the rest,
    // so a manual relaunch resumes identically.
    if (getOnboardingResumeLocal()) {
      ensureOnboardingDriver().chooseMode("local")
    }
  } else {
    startLocalBackendSupervision()
    await showWebAppWindow()
  }

  app.on("activate", async () => {
    await openSyrus()
  })
})

app.on("window-all-closed", () => {
  // Tray apps stay resident until the user chooses Quit.
})

app.on("before-quit", () => {
  isQuitting = true
  stopAppUserCable()
})

app.on("will-quit", () => {
  globalShortcut.unregisterAll()
})
