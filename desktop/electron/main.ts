import { app, BrowserWindow, Menu, Tray, ipcMain, nativeImage, shell } from "electron"
import fs from "node:fs/promises"
import os from "node:os"
import { fileURLToPath } from "node:url"
import path from "node:path"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)
const TOKEN_DOCS_URL = "https://syrus.dev/docs/cli/"

type Credentials = {
  url: string
  token: string
}

let mainWindow: BrowserWindow | null = null
let preferencesWindow: BrowserWindow | null = null
let tray: Tray | null = null
let cachedCredentials: Credentials | null = null
let isQuitting = false

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

const trayIconPath = () => path.join(app.getAppPath(), "assets", "trayTemplate.png")

const createTray = () => {
  const icon = nativeImage.createFromPath(trayIconPath())
  icon.setTemplateImage(true)

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
ipcMain.handle("open-token-docs", async () => {
  await shell.openExternal(TOKEN_DOCS_URL)
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
