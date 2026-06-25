import { app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, shell, dialog, clipboard } from "electron"
import type { MessageBoxOptions, OpenDialogOptions } from "electron"
import { execFile } from "node:child_process"
import fs from "node:fs/promises"
import os from "node:os"
import { fileURLToPath } from "node:url"
import path from "node:path"
import { promisify } from "node:util"
import Store from "electron-store"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const TOKEN_DOCS_URL = "https://syrus.dev/docs/cli/"
const execFileAsync = promisify(execFile)

type Credentials = {
  url: string
  token: string
}

type JobItem = {
  id: number
  state: string
  summary_state: string
  title: string
  issue_title: string
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

type DesktopSettings = {
  localProjectsRoot: string
  localRepoPaths: Record<string, string>
  lastUsedRepo: string
}

type DesktopSettingsInput = Pick<DesktopSettings, "localProjectsRoot" | "localRepoPaths">

type CheckoutAvailability = {
  cliAvailable: boolean
  localPath: string | null
}

type CheckoutRequest = {
  jobRef: string
  repoSlug: string
  branchName: string
}

type BootstrapPayload = {
  current_user: {
    admin: boolean
  } | null
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
let tray: Tray | null = null
let cachedCredentials: Credentials | null = null
let isQuitting = false
let cachedCliAvailable: boolean | null = null

const store = new Store<DesktopSettings>({
  defaults: {
    localProjectsRoot: "",
    localRepoPaths: {},
    lastUsedRepo: ""
  }
})

const credentialsPath = () => path.join(os.homedir(), ".syrus", "credentials")

const validateCredentialsShape = (credentials: Credentials) => {
  if (credentials.url.trim() === "" || credentials.token.trim() === "") {
    throw new Error("Syrus instance URL and API token are required.")
  }
}

const trimWrappingQuotes = (value: string) => value.replace(/^["']+|["']+$/g, "")

const parseCredentials = (contents: string): Credentials => {
  const credentials: Credentials = { url: "", token: "" }

  for (const rawLine of contents.split(/\r?\n/)) {
    const line = rawLine.trim()
    if (line === "" || line.startsWith("#")) {
      continue
    }

    const separatorIndex = line.indexOf("=")
    if (separatorIndex === -1) {
      throw new Error(`Invalid credentials line: ${line}`)
    }

    const key = line.slice(0, separatorIndex).trim()
    const value = trimWrappingQuotes(line.slice(separatorIndex + 1).trim())

    if (key === "url") {
      credentials.url = value
    } else if (key === "token") {
      credentials.token = value
    }
  }

  validateCredentialsShape(credentials)
  return credentials
}

const loadCredentials = async (): Promise<Credentials | null> => {
  let contents: string

  try {
    contents = await fs.readFile(credentialsPath(), "utf8")
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === "ENOENT") {
      cachedCredentials = null
      return null
    }

    cachedCredentials = null
    throw error
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

const appApiUrl = (baseUrl: string, pathName: string, params?: Record<string, string>) => {
  const url = new URL(pathName, `${baseUrl.trim().replace(/\/+$/, "")}/`)
  for (const [key, value] of Object.entries(params ?? {})) {
    url.searchParams.set(key, value)
  }
  return url.toString()
}

const validateCredentialsWithServer = async (credentials: Credentials) => {
  validateCredentialsShape(credentials)

  let response: Response
  try {
    response = await fetch(bootstrapUrl(credentials.url), {
      headers: {
        Authorization: `Bearer ${credentials.token.trim()}`
      }
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

  if (!response.ok) {
    throw new Error("Could not load account details.")
  }

  return (await response.json()) as BootstrapPayload
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
    fetchJobList(credentials, "queued"),
    fetchJobList(credentials, "running"),
    fetchJobList(credentials, "implemented"),
    fetchJobList(credentials, "failed")
  ])

  return lists
    .flatMap((list) => list.jobs)
    .sort((a, b) => b.updated_at.localeCompare(a.updated_at))
}

const responseErrorMessage = async (response: Response, fallback: string) => {
  try {
    const payload = (await response.json()) as { error?: { message?: string } }
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

  if (!response.ok) {
    throw new Error(`Could not approve JOB-${jobID}.`)
  }
}

const getDesktopSettings = (): DesktopSettings => ({
  localProjectsRoot: store.get("localProjectsRoot", ""),
  localRepoPaths: store.get("localRepoPaths", {}),
  lastUsedRepo: store.get("lastUsedRepo", "")
})

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
    await execFileAsync(lookupCommand, [command])
    return true
  } catch {
    return false
  }
}

const syrusCliAvailable = async () => {
  if (cachedCliAvailable !== null) {
    return cachedCliAvailable
  }

  cachedCliAvailable = await commandExists("syrus")
  return cachedCliAvailable
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

const checkoutJob = async ({ jobRef, repoSlug, branchName }: CheckoutRequest) => {
  const localPath = resolveLocalPath(repoSlug)
  if (!localPath) {
    await showPreferencesWindow()
    throw new Error("Configure a local projects root or repository override in Preferences.")
  }

  if (!(await syrusCliAvailable())) {
    throw new Error("Install the Syrus CLI to enable local branch checkout.")
  }

  try {
    await execFileAsync("syrus", ["checkout", jobRef], { cwd: localPath })
    return { branchName }
  } catch (error) {
    const processError = error as NodeJS.ErrnoException & { stderr?: string; stdout?: string }
    const stderr = processError.stderr?.trim()
    const stdout = processError.stdout?.trim()
    throw new Error(stderr || stdout || processError.message || "Local checkout failed.")
  }
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

  const filePath = credentialsPath()
  await fs.mkdir(path.dirname(filePath), { recursive: true, mode: 0o700 })
  await fs.chmod(path.dirname(filePath), 0o700)
  await fs.writeFile(
    filePath,
    `url=${normalizedCredentials.url}\ntoken=${normalizedCredentials.token}\n`,
    { mode: 0o600 }
  )
  await fs.chmod(filePath, 0o600)

  cachedCredentials = normalizedCredentials
  return normalizedCredentials
}

const deleteCredentials = async () => {
  try {
    await fs.unlink(credentialsPath())
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "ENOENT") {
      throw error
    }
  }

  cachedCredentials = null
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
      preload: path.join(__dirname, "preload.js")
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
  const x = Math.round(trayBounds.x + trayBounds.width / 2 - windowBounds.width / 2)
  const y =
    process.platform === "darwin"
      ? Math.round(trayBounds.y + trayBounds.height)
      : Math.round(trayBounds.y + trayBounds.height + 4)

  mainWindow.setPosition(x, y, false)
}

const showPopoverWindow = async () => {
  if (!mainWindow) {
    await createPopoverWindow()
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
      preload: path.join(__dirname, "preload.js")
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

const openSyrusInBrowser = async () => {
  const credentials = cachedCredentials ?? (await loadCredentials())
  if (credentials) {
    await shell.openExternal(credentials.url)
    return
  }

  await showPreferencesWindow()
}

const trayIconPath = () => path.join(app.getAppPath(), "assets", "syrusIcon.png")

const createTray = () => {
  const icon = nativeImage.createFromPath(trayIconPath()).resize({ width: 18, height: 18 })

  tray = new Tray(icon)
  tray.setToolTip("Syrus")
  tray.on("click", () => {
    void togglePopoverWindow()
  })

  tray.setContextMenu(
    Menu.buildFromTemplate([
      {
        label: "Open Syrus",
        click: () => {
          void openSyrusInBrowser()
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
  )
}

const createMenu = () => {
  const applicationMenu = Menu.buildFromTemplate([
    {
      label: app.name,
      submenu: [
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
    }
  ])

  Menu.setApplicationMenu(applicationMenu)
}

ipcMain.handle("get-credentials", async () => cachedCredentials ?? (await loadCredentials()))
ipcMain.handle("save-credentials", async (_event, credentials: Credentials) => saveCredentials(credentials))
ipcMain.handle("get-desktop-settings", async () => getDesktopSettings())
ipcMain.handle("save-desktop-settings", async (_event, settings: DesktopSettings) => saveDesktopSettings(settings))
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
ipcMain.handle("checkout-availability", async (_event, repoSlug: string) => checkoutAvailability(repoSlug))
ipcMain.handle("checkout-job", async (_event, request: CheckoutRequest) => checkoutJob(request))
ipcMain.handle("show-preferences", async () => {
  await showPreferencesWindow()
})
ipcMain.handle("copy-text", async (_event, text: string) => {
  clipboard.writeText(text)
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
ipcMain.handle("open-token-docs", async () => {
  await shell.openExternal(TOKEN_DOCS_URL)
})
ipcMain.handle("fetch-inbox-jobs", async () => fetchInboxJobs())
ipcMain.handle("confirm-approve-job", async (event, jobID: number) => confirmApproveJob(event.sender, jobID))
ipcMain.handle("approve-job", async (_event, jobID: number) => approveJob(jobID))
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

app.whenReady().then(async () => {
  if (process.platform === "darwin") {
    app.dock?.hide()
  }

  createMenu()
  await loadCredentials()
  createTray()

  if (!app.isPackaged) {
    await showPopoverWindow()
  }

  app.on("activate", async () => {
    await showPopoverWindow()
  })
})

app.on("window-all-closed", () => {
  // Tray apps stay resident until the user chooses Quit.
})

app.on("before-quit", () => {
  isQuitting = true
})
