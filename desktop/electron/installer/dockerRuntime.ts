import { execFile } from "node:child_process"
import fs from "node:fs"
import net from "node:net"
import os from "node:os"
import path from "node:path"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)

// GUI-launched apps get a minimal PATH (/usr/bin:/bin:...), so `docker` from
// OrbStack, Homebrew, or Docker Desktop is invisible without help. Every
// docker/compose invocation in the app must go through execEnv() or an
// absolute binary path from findDockerBinary().
// Windows note: probing these FIXED paths (not just PATH) is load-bearing. A
// long-running Electron process copies its environment at spawn and never
// sees the PATH additions Docker Desktop's installer makes afterwards (they
// go to the registry + a WM_SETTINGCHANGE broadcast that only new shells
// pick up) — which is why `docker ps` can work in a fresh cmd while the app
// still says "no docker". Both install modes are covered: the default
// all-users location under Program Files AND the `--user` per-user install
// under %LOCALAPPDATA%\Programs\DockerDesktop.
const dockerCandidateDirs = () => {
  if (process.platform !== "win32") {
    return [
      path.join(os.homedir(), ".orbstack", "bin"),
      "/opt/homebrew/bin",
      "/usr/local/bin",
      "/Applications/Docker.app/Contents/Resources/bin"
    ]
  }

  const localAppData = process.env["LOCALAPPDATA"] ?? ""
  const dirs = [path.join(process.env["ProgramFiles"] ?? "C:\\Program Files", "Docker", "Docker", "resources", "bin")]
  if (localAppData !== "") {
    dirs.push(path.join(localAppData, "Programs", "DockerDesktop", "resources", "bin"))
    dirs.push(path.join(localAppData, "Programs", "RedHat", "Podman"))
  }
  return dirs
}

export const augmentedPath = () => {
  const extras = dockerCandidateDirs().filter((dir) => fs.existsSync(dir))
  const current = (process.env.PATH ?? "").split(path.delimiter).filter(Boolean)
  const merged = [...current]
  for (const dir of extras) {
    if (!merged.includes(dir)) {
      merged.push(dir)
    }
  }
  return merged.join(path.delimiter)
}

export const execEnv = (): NodeJS.ProcessEnv => ({ ...process.env, PATH: augmentedPath() })

let cachedDockerBinary: string | null | undefined

export const findDockerBinary = async (): Promise<string | null> => {
  if (cachedDockerBinary !== undefined && cachedDockerBinary !== null) {
    return cachedDockerBinary
  }

  const binaryName = process.platform === "win32" ? "docker.exe" : "docker"
  for (const dir of dockerCandidateDirs()) {
    const candidate = path.join(dir, binaryName)
    try {
      fs.accessSync(candidate, fs.constants.X_OK)
      cachedDockerBinary = candidate
      return candidate
    } catch {
      // Try the next candidate location.
    }
  }

  try {
    const lookup = process.platform === "win32" ? ["where", ["docker"]] as const : ["/usr/bin/which", ["docker"]] as const
    const { stdout } = await execFileAsync(lookup[0], [...lookup[1]], { env: execEnv() })
    const found = stdout.split(/\r?\n/)[0]?.trim() ?? ""
    cachedDockerBinary = found === "" ? null : found
  } catch {
    cachedDockerBinary = null
  }

  return cachedDockerBinary
}

export const daemonUp = async (timeoutMs = 10_000): Promise<boolean> => {
  const binary = await findDockerBinary()
  if (!binary) {
    return false
  }

  try {
    await execFileAsync(binary, ["info"], { env: execEnv(), timeout: timeoutMs })
    return true
  } catch {
    return false
  }
}

// Docker Desktop on Windows runs on WSL 2. When WSL itself is missing, its
// installer punts to a manual "run wsl --install in PowerShell" step — the
// exact clunk the guided setup exists to remove, so the app preflights it
// and offers the elevated install itself (installWsl below).
export const wslReady = async (): Promise<boolean> => {
  if (process.platform !== "win32") {
    return true
  }

  try {
    await execFileAsync("wsl.exe", ["--status"], { timeout: 10_000, windowsHide: true })
    return true
  } catch {
    return false
  }
}

// One-click WSL 2 install: elevates via UAC (unavoidable — feature install
// needs admin) and skips the default distro (Docker Desktop brings its own).
// Fire-and-forget by design: the caller polls wslReady()/daemonUp() and the
// UI warns that Windows may require a restart afterwards.
export const installWsl = async (): Promise<void> => {
  await execFileAsync(
    "powershell.exe",
    [
      "-NoProfile",
      "-NonInteractive",
      "-Command",
      "Start-Process wsl.exe -ArgumentList '--install','--no-distribution' -Verb RunAs"
    ],
    { timeout: 30_000, windowsHide: true }
  )
}

// Detecting and starting an ALREADY-INSTALLED Podman Desktop (Docker
// socket enabled) is supported below; the guided setup's download
// recommendation is Docker-Desktop-only — Podman compose isn't supported,
// so the UI never suggests installing it (windows_scaffold_spec pins this).
export type RuntimeApp = "OrbStack" | "Docker Desktop" | "Colima" | "Podman Desktop"

const colimaBinary = (): string | null => {
  for (const dir of ["/opt/homebrew/bin", "/usr/local/bin"]) {
    const candidate = path.join(dir, "colima")
    if (fs.existsSync(candidate)) {
      return candidate
    }
  }

  return null
}

// Docker Desktop.exe lives under Program Files for the default all-users
// install and under %LOCALAPPDATA%\Programs\DockerDesktop for a `--user`
// install — check both, or a per-user install reads as "no runtime".
const dockerDesktopExePath = (): string | null => {
  const candidates = [
    path.join(process.env["ProgramFiles"] ?? "C:\\Program Files", "Docker", "Docker", "Docker Desktop.exe"),
    ...(process.env["LOCALAPPDATA"]
      ? [path.join(process.env["LOCALAPPDATA"], "Programs", "DockerDesktop", "Docker Desktop.exe")]
      : [])
  ]
  return candidates.find((exe) => fs.existsSync(exe)) ?? null
}

export const installedRuntimeApp = (): RuntimeApp | null => {
  if (process.platform === "win32") {
    if (dockerDesktopExePath()) {
      return "Docker Desktop"
    }
    if (fs.existsSync(path.join(process.env["LOCALAPPDATA"] ?? "", "Programs", "podman-desktop", "Podman Desktop.exe"))) {
      return "Podman Desktop"
    }
    return null
  }

  if (fs.existsSync("/Applications/OrbStack.app")) {
    return "OrbStack"
  }

  if (fs.existsSync("/Applications/Docker.app")) {
    return "Docker Desktop"
  }

  // App-less runtime: a stopped Colima should be started, not treated as
  // "no runtime installed" (which pushes its user to download OrbStack).
  if (colimaBinary()) {
    return "Colima"
  }

  return null
}

export const startRuntimeApp = async (runtimeApp: RuntimeApp) => {
  if (runtimeApp === "Colima") {
    const binary = colimaBinary()
    if (binary) {
      await execFileAsync(binary, ["start"], { env: execEnv(), timeout: 180_000 })
    }
    return
  }

  if (process.platform === "win32") {
    const exe = runtimeApp === "Docker Desktop"
      ? dockerDesktopExePath()
      : path.join(process.env["LOCALAPPDATA"] ?? "", "Programs", "podman-desktop", "Podman Desktop.exe")
    if (!exe) {
      return
    }
    await execFileAsync("cmd.exe", ["/c", "start", "", exe])
    return
  }

  const appName = runtimeApp === "OrbStack" ? "OrbStack" : "Docker"
  await execFileAsync("open", ["-a", appName])
}

// ["/abs/docker", "compose"] for the v2 plugin, ["docker-compose"] for the
// standalone v1 binary, null when neither is available.
export const composeCommand = async (): Promise<string[] | null> => {
  const binary = await findDockerBinary()
  if (binary) {
    try {
      await execFileAsync(binary, ["compose", "version"], { env: execEnv(), timeout: 10_000 })
      return [binary, "compose"]
    } catch {
      // Fall through to the standalone binary.
    }
  }

  try {
    const lookup = process.platform === "win32" ? ["where", ["docker-compose"]] as const : ["/usr/bin/which", ["docker-compose"]] as const
    await execFileAsync(lookup[0], [...lookup[1]], { env: execEnv() })
    return ["docker-compose"]
  } catch {
    return null
  }
}

export const volumeExists = async (name: string): Promise<boolean> => {
  const binary = await findDockerBinary()
  if (!binary) {
    return false
  }

  try {
    await execFileAsync(binary, ["volume", "inspect", name], { env: execEnv(), timeout: 10_000 })
    return true
  } catch {
    return false
  }
}

export const portInUse = (port: number): Promise<boolean> =>
  new Promise((resolve) => {
    const socket = net.connect({ port, host: "127.0.0.1" })
    const finish = (result: boolean) => {
      socket.destroy()
      resolve(result)
    }

    socket.setTimeout(1_000)
    socket.on("connect", () => finish(true))
    socket.on("timeout", () => finish(false))
    socket.on("error", () => finish(false))
  })

export const syrusHealthy = async (port: number): Promise<boolean> => {
  try {
    const response = await fetch(`http://localhost:${port}/up`, { signal: AbortSignal.timeout(2_000) })
    return response.ok
  } catch {
    return false
  }
}
