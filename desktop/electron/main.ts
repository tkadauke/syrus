import { app, BrowserWindow } from "electron"
import { fileURLToPath } from "node:url"
import path from "node:path"

const __filename = fileURLToPath(import.meta.url)
const __dirname = path.dirname(__filename)

let mainWindow: BrowserWindow | null = null

const createMainWindow = async () => {
  mainWindow = new BrowserWindow({
    width: 1100,
    height: 720,
    minWidth: 640,
    minHeight: 480,
    show: false,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false
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

app.whenReady().then(async () => {
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
