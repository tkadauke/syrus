import { app, BrowserWindow, Menu, ipcMain, shell } from "electron"
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
let cachedCredentials: Credentials | null = null

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

const createMainWindow = async () => {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 720,
    minWidth: 640,
    minHeight: 480,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      preload: path.join(__dirname, "preload.js")
    }
  })

  mainWindow.once("ready-to-show", () => {
    mainWindow?.show()
  })

  if (app.isPackaged) {
    await mainWindow.loadFile(path.join(__dirname, "../dist/index.html"))
  } else {
    await mainWindow.loadURL("http://127.0.0.1:5173")
    mainWindow.webContents.openDevTools({ mode: "detach" })
  }
}

const showSetupWindow = async () => {
  if (!mainWindow) {
    await createMainWindow()
    return
  }

  if (mainWindow.isMinimized()) {
    mainWindow.restore()
  }

  mainWindow.show()
  mainWindow.focus()
  mainWindow.webContents.send("credentials-cleared")
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
  createMenu()
  await loadCredentials()
  await createMainWindow()

  app.on("activate", async () => {
    if (BrowserWindow.getAllWindows().length === 0) {
      await createMainWindow()
    }
  })
})

app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit()
  }
})
