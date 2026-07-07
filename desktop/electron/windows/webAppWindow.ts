import { app, BrowserWindow, shell } from "electron"
import type { WindowBounds } from "../settings.js"
import { decideWindowOpen } from "./windowOpenPolicy.js"

type WebAppWindowOptions = {
  serverUrl: string
  // Build identity of this app (from the staged manifest) — appended to
  // the user agent so the web UI's BuildBadge can display it. Release
  // builds carry the release version here, dev builds the git short sha.
  buildSha?: string | null
  // When this app build was staged (ISO-8601, from the manifest) — appended
  // as a second UA token feeding the BuildBadge's hover tooltip.
  builtAt?: string | null
  savedBounds: WindowBounds | null
  // Loads the packaged renderer's backend-status view. That page is purely
  // informational — this window carries NO preload (the remote web app must
  // never see the IPC bridge), so recovery is driven by the main process
  // polling /up and calling loadServerUrl() again.
  loadFallback: (window: BrowserWindow) => Promise<void>
  onBoundsChanged: (bounds: WindowBounds) => void
  onLoadFailed: () => void
  onClosed: () => void
}

export type WebAppWindowHandle = {
  window: BrowserWindow
  loadServerUrl: () => Promise<void>
}

export const createWebAppWindow = ({
  serverUrl,
  buildSha,
  builtAt,
  savedBounds,
  loadFallback,
  onBoundsChanged,
  onLoadFailed,
  onClosed
}: WebAppWindowOptions): WebAppWindowHandle => {
  const serverOrigin = new URL(serverUrl).origin

  const window = new BrowserWindow({
    width: savedBounds?.width ?? 1280,
    height: savedBounds?.height ?? 860,
    x: savedBounds?.x,
    y: savedBounds?.y,
    minWidth: 720,
    minHeight: 480,
    title: "Syrus",
    webPreferences: {
      // The Syrus web app is remote content: full isolation, no bridge.
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true
    }
  })

  // The web app detects the shell by this marker (see
  // app/frontend/lib/desktopShell.ts) — e.g. to not report an intercepted
  // window.open as a blocked popup. The build token feeds the BuildBadge;
  // the built-at token feeds its hover tooltip. Colons are not valid in UA
  // product-version tokens, so the timestamp is ISO-8601 basic format
  // ("20260707T143200Z") — desktopBuiltAt() restores the extended form.
  // Silently dropped when the manifest timestamp is missing or unparseable.
  const buildToken = buildSha ? ` SyrusDesktopBuild/${buildSha}` : ""
  const builtAtDate = builtAt ? new Date(builtAt) : null
  const builtAtToken =
    builtAtDate && !Number.isNaN(builtAtDate.getTime())
      ? ` SyrusDesktopBuiltAt/${builtAtDate.toISOString().slice(0, 19).replace(/[-:]/g, "")}Z`
      : ""
  window.webContents.setUserAgent(
    `${window.webContents.getUserAgent()} SyrusDesktop/${app.getVersion()}${buildToken}${builtAtToken}`
  )

  // Same-origin navigation stays in the window; everything else (GitHub PRs,
  // issue links, docs) opens in the user's default browser — see
  // windowOpenPolicy.ts for the full routing rules. No file: exemption:
  // will-navigate never fires for the main process's own loadFile/loadURL
  // calls, so any file: navigation seen here is remote content trying to
  // reach local files — deny it.
  window.webContents.on("will-navigate", (event, targetUrl) => {
    const action = decideWindowOpen(targetUrl, serverOrigin)
    if (action === "main") {
      return
    }

    event.preventDefault()
    if (action === "external") {
      void shell.openExternal(targetUrl)
    }
  })

  // No popup is ever allowed: same-origin popups load in this window,
  // everything else web-y goes to the default browser. Flows that need a
  // real logged-in browser (GitHub App registration) mark their same-origin
  // URLs with syrus_external=1 and get handed off too.
  window.webContents.setWindowOpenHandler(({ url }) => {
    const action = decideWindowOpen(url, serverOrigin)
    if (action === "main") {
      void window.loadURL(url)
    } else if (action === "external") {
      void shell.openExternal(url)
    }

    return { action: "deny" }
  })

  window.webContents.on("did-fail-load", (_event, errorCode, _description, validatedURL, isMainFrame) => {
    // ERR_ABORTED (-3) is benign — a load superseded by another navigation
    // or converted into a download (e.g. the web app's transcript download
    // links). Treating it as backend failure would yank the user off their
    // page while the backend is perfectly healthy.
    if (errorCode === -3 || !isMainFrame || !validatedURL.startsWith(serverOrigin)) {
      return
    }

    void loadFallback(window).then(onLoadFailed)
  })

  let boundsTimer: NodeJS.Timeout | null = null
  const scheduleBoundsSave = () => {
    if (boundsTimer) {
      clearTimeout(boundsTimer)
    }

    boundsTimer = setTimeout(() => {
      boundsTimer = null
      if (!window.isDestroyed() && !window.isFullScreen()) {
        onBoundsChanged(window.getBounds())
      }
    }, 500)
  }

  window.on("resize", scheduleBoundsSave)
  window.on("move", scheduleBoundsSave)
  window.on("closed", () => {
    if (boundsTimer) {
      clearTimeout(boundsTimer)
      boundsTimer = null
    }

    onClosed()
  })

  return {
    window,
    loadServerUrl: () => window.loadURL(serverUrl)
  }
}
