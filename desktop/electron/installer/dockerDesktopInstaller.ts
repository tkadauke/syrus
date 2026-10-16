import { createWriteStream } from "node:fs"
import fs from "node:fs/promises"
import path from "node:path"
import { pipeline } from "node:stream/promises"
import { execFile } from "node:child_process"
import { promisify } from "node:util"

const execFileAsync = promisify(execFile)
const DOWNLOAD_IDLE_TIMEOUT_MS = 60_000
const INDETERMINATE_PROGRESS_INTERVAL_MS = 1_000

// Guided Docker Desktop acquisition, Windows only. Instead of pointing the
// user at the download page and hoping they survive the installer + the
// first-run service-agreement dialog (the field failure: reboot mid-setup,
// then a modal Syrus couldn't see), Syrus downloads the official installer
// and runs it unattended:
//
//   install --accept-license --backend=wsl-2 --user --quiet
//
// - --accept-license removes the first-start service-agreement dialog
//   entirely (docs.docker.com: accepted "now, rather than requiring it to be
//   accepted when the application is first run"), so the engine can start
//   with zero interaction. Sign-in remains optional and never blocks.
// - --user installs per-user to %LOCALAPPDATA%\Programs\DockerDesktop with
//   NO admin elevation — no UAC prompt. dockerRuntime.ts probes that
//   location, so detection and launch work out of the box.
// - --backend=wsl-2 is the default backend and the only one we support; the
//   one-click WSL preflight (installWsl) runs before this when WSL is absent.
// - --quiet suppresses the installer UI; Syrus's own progress screen is the
//   only surface the user sees.

// Official permanent links (docs.docker.com/desktop/setup/install/windows-install).
const INSTALLER_URL_AMD64 = "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
const INSTALLER_URL_ARM64 = "https://desktop.docker.com/win/main/arm64/Docker%20Desktop%20Installer.exe"

// The Syrus app ships x64-only and runs on arm64 Windows under emulation, so
// process.arch lies there — PROCESSOR_ARCHITEW6432 exposes the real machine
// architecture to emulated processes. Docker Desktop itself must match the
// real hardware.
export const dockerDesktopInstallerUrl = (env: NodeJS.ProcessEnv = process.env, arch: string = process.arch): string => {
  const machineArch = (env["PROCESSOR_ARCHITEW6432"] ?? env["PROCESSOR_ARCHITECTURE"] ?? arch).toLowerCase()
  return machineArch.includes("arm") ? INSTALLER_URL_ARM64 : INSTALLER_URL_AMD64
}

export const dockerDesktopInstallArgs = (): string[] => ["install", "--accept-license", "--backend=wsl-2", "--user", "--quiet"]

// Stream the installer (~600 MB) to disk, reporting progress as 0–100 when
// the server sends Content-Length and null (indeterminate) otherwise. The
// AbortSignal lets the wizard cancel a download the user backed out of.
export const downloadDockerDesktopInstaller = async (
  destPath: string,
  onProgress: (percent: number | null) => void,
  signal?: AbortSignal,
  idleTimeoutMs = DOWNLOAD_IDLE_TIMEOUT_MS
): Promise<void> => {
  const idleAbort = new AbortController()
  const abortFromCaller = () => idleAbort.abort(signal?.reason)
  signal?.addEventListener("abort", abortFromCaller, { once: true })
  if (signal?.aborted) abortFromCaller()
  let idleTimer: NodeJS.Timeout | null = null
  const resetIdleTimer = () => {
    if (idleTimer) clearTimeout(idleTimer)
    idleTimer = setTimeout(() => idleAbort.abort(new Error("installer download stalled")), idleTimeoutMs)
  }

  try {
    resetIdleTimer()
    const response = await fetch(dockerDesktopInstallerUrl(), { signal: idleAbort.signal })
    if (!response.ok || !response.body) {
      throw new Error(`installer download failed (HTTP ${response.status})`)
    }

    const total = Number.parseInt(response.headers.get("content-length") ?? "", 10)
    let received = 0
    let lastReported = -1
    let lastIndeterminateReportAt = 0
    const progress = new TransformStream<Uint8Array, Uint8Array>({
      transform(chunk, controller) {
        resetIdleTimer()
        received += chunk.byteLength
        if (Number.isFinite(total) && total > 0) {
          const percent = Math.floor((received / total) * 100)
          if (percent !== lastReported) {
            lastReported = percent
            onProgress(percent)
          }
        } else {
          const now = Date.now()
          if (lastIndeterminateReportAt === 0 || now - lastIndeterminateReportAt >= INDETERMINATE_PROGRESS_INTERVAL_MS) {
            lastIndeterminateReportAt = now
            onProgress(null)
          }
        }
        controller.enqueue(chunk)
      }
    })

    await fs.mkdir(path.dirname(destPath), { recursive: true })
    await pipeline(response.body.pipeThrough(progress), createWriteStream(destPath), { signal: idleAbort.signal })
  } catch (error) {
    await fs.rm(destPath, { force: true }).catch(() => {})
    throw error
  } finally {
    if (idleTimer) clearTimeout(idleTimer)
    signal?.removeEventListener("abort", abortFromCaller)
  }
}

export const verifyDockerDesktopInstaller = async (installerPath: string): Promise<void> => {
  const script =
    "$signature = Get-AuthenticodeSignature -LiteralPath $args[0]; " +
    "[PSCustomObject]@{ Status = $signature.Status.ToString(); Publisher = $signature.SignerCertificate.GetNameInfo('SimpleName', $false) } | ConvertTo-Json -Compress"
  const { stdout } = await execFileAsync("powershell.exe", ["-NoProfile", "-NonInteractive", "-Command", script, installerPath], {
    windowsHide: true,
    timeout: 60_000
  })
  const signature = JSON.parse(stdout) as { Status?: string; Publisher?: string }
  if (signature.Status !== "Valid" || signature.Publisher?.trim().toLowerCase() !== "docker inc") {
    throw new Error("Docker Desktop installer signature is not valid or was not issued to Docker Inc")
  }
}

// Run the installer unattended and wait for it to finish. Per-user mode needs
// no elevation, so this is a plain child process — no UAC round-trip (unlike
// the WSL preflight, which cannot avoid one). Docker doesn't document
// installer exit codes; anything nonzero is surfaced as a failure and the
// wizard falls back to the manual download path. First installs regularly
// take several minutes (WSL distro import).
export const runDockerDesktopInstaller = async (
  installerPath: string,
  signal?: AbortSignal,
  onChild?: (child: ReturnType<typeof execFile>) => void
): Promise<void> => {
  await new Promise<void>((resolve, reject) => {
    const child = execFile(
      installerPath,
      dockerDesktopInstallArgs(),
      {
        timeout: 20 * 60_000,
        windowsHide: true,
        maxBuffer: 16 * 1024 * 1024,
        signal
      },
      (error) => (error ? reject(error) : resolve())
    )
    onChild?.(child)
  })
}
