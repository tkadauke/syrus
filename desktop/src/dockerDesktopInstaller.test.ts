import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  dockerDesktopInstallArgs,
  dockerDesktopInstallerUrl,
  downloadDockerDesktopInstaller,
  runDockerDesktopInstaller,
  stopDockerDesktopInstaller,
  verifyDockerDesktopInstaller
} from "../electron/installer/dockerDesktopInstaller"

const { execFileAsyncMock, execFileMock } = vi.hoisted(() => {
  const execFileAsyncMock = vi.fn(async (..._args: unknown[]) => ({ stdout: "", stderr: "" }))
  const execFileMock = Object.assign(vi.fn(), {
    [Symbol.for("nodejs.util.promisify.custom")]: execFileAsyncMock
  })
  return { execFileAsyncMock, execFileMock }
})

vi.mock("node:child_process", () => ({
  default: { execFile: execFileMock },
  execFile: execFileMock
}))

afterEach(() => {
  vi.unstubAllGlobals()
  execFileMock.mockReset()
  execFileAsyncMock.mockReset()
})

describe("dockerDesktopInstaller", () => {
  it("installs unattended: license pre-accepted, per-user (no UAC), WSL 2, quiet", () => {
    const args = dockerDesktopInstallArgs()

    expect(args[0]).toBe("install")
    // --accept-license is the whole point: it removes Docker Desktop's
    // first-start service-agreement dialog, so the engine starts with zero
    // user interaction (the field failure this feature kills).
    expect(args).toContain("--accept-license")
    // --user installs to %LOCALAPPDATA%\Programs\DockerDesktop with no admin
    // elevation — no UAC prompt, and dockerRuntime.ts already probes there.
    expect(args).toContain("--user")
    expect(args).toContain("--backend=wsl-2")
    expect(args).toContain("--quiet")
  })

  it("downloads the amd64 installer by default", () => {
    expect(dockerDesktopInstallerUrl({}, "x64")).toBe("https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe")
  })

  it("detects arm64 hardware through PROCESSOR_ARCHITEW6432 under x64 emulation", () => {
    // The Syrus app ships x64-only, so on arm64 Windows it runs emulated and
    // process.arch reports x64 — the env var carries the real machine arch,
    // and Docker Desktop must match the hardware.
    expect(dockerDesktopInstallerUrl({ PROCESSOR_ARCHITEW6432: "ARM64" }, "x64")).toBe(
      "https://desktop.docker.com/win/main/arm64/Docker%20Desktop%20Installer.exe"
    )
  })

  it("throttles indeterminate progress", async () => {
    const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "syrus-installer-test-"))
    const destination = path.join(tempDir, "installer.exe")
    const progress = vi.fn()
    vi.stubGlobal(
      "fetch",
      vi.fn(
        async () =>
          new Response(
            new ReadableStream({
              start(controller) {
                controller.enqueue(new Uint8Array([1]))
                controller.enqueue(new Uint8Array([2]))
                controller.close()
              }
            })
          )
      )
    )

    await downloadDockerDesktopInstaller(destination, progress)
    expect(progress).toHaveBeenCalledTimes(1)
    expect(progress).toHaveBeenCalledWith(null)
    await fs.rm(tempDir, { recursive: true, force: true })
  })

  it("removes a partial download on failure", async () => {
    const tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "syrus-installer-test-"))
    const destination = path.join(tempDir, "installer.exe")
    await fs.writeFile(destination, "partial")
    vi.stubGlobal("fetch", vi.fn(async () => new Response(null, { status: 503 })))

    await expect(downloadDockerDesktopInstaller(destination, vi.fn())).rejects.toThrow("HTTP 503")
    await expect(fs.stat(destination)).rejects.toMatchObject({ code: "ENOENT" })
    await fs.rm(tempDir, { recursive: true, force: true })
  })

  it("accepts only a valid Docker Inc Authenticode signature", async () => {
    execFileAsyncMock.mockResolvedValueOnce({
      stdout: JSON.stringify({ Status: "Valid", Publisher: "Docker Inc" }),
      stderr: ""
    })
    await expect(verifyDockerDesktopInstaller("C:\\Temp\\installer.exe")).resolves.toBeUndefined()

    execFileAsyncMock.mockResolvedValueOnce({
      stdout: JSON.stringify({ Status: "Valid", Publisher: "Someone Else" }),
      stderr: ""
    })
    await expect(verifyDockerDesktopInstaller("C:\\Temp\\installer.exe")).rejects.toThrow("Docker Inc")
  })

  it("passes cancellation through while the installer is running", async () => {
    execFileMock.mockImplementationOnce((_file, _args, _options, callback) => {
      callback(null, "", "")
      return { pid: 1234 }
    })
    const controller = new AbortController()
    const onChild = vi.fn()
    await runDockerDesktopInstaller("C:\\Temp\\installer.exe", controller.signal, onChild)

    expect(execFileMock).toHaveBeenCalledWith(
      "C:\\Temp\\installer.exe",
      dockerDesktopInstallArgs(),
      expect.objectContaining({ signal: controller.signal }),
      expect.any(Function)
    )
    expect(onChild).toHaveBeenCalledWith({ pid: 1234 })
  })

  it("kills the installer tree before aborting the parent process", async () => {
    let taskkillFinished: (() => void) | undefined
    execFileMock.mockImplementationOnce((_file, _args, _options, callback) => {
      taskkillFinished = () => callback(null, "", "")
      return { pid: 4321 }
    })
    const controller = new AbortController()

    const stopping = stopDockerDesktopInstaller({ pid: 1234 } as Parameters<typeof stopDockerDesktopInstaller>[0], controller)
    expect(execFileMock).toHaveBeenCalledWith(
      "taskkill",
      ["/pid", "1234", "/T", "/F"],
      { windowsHide: true, timeout: 15_000 },
      expect.any(Function)
    )
    expect(controller.signal.aborted).toBe(false)

    taskkillFinished?.()
    await stopping
    expect(controller.signal.aborted).toBe(true)
  })
})
