import fs from "node:fs/promises"
import os from "node:os"
import path from "node:path"
import { afterEach, describe, expect, it, vi } from "vitest"
import {
  downloadDockerDesktopInstaller,
  dockerDesktopInstallArgs,
  dockerDesktopInstallerUrl,
  validDockerDesktopSignature
} from "../electron/installer/dockerDesktopInstaller"

let tempDir: string | null = null

afterEach(async () => {
  vi.useRealTimers()
  vi.unstubAllGlobals()
  if (tempDir) await fs.rm(tempDir, { recursive: true, force: true })
  tempDir = null
})

const destination = async () => {
  tempDir = await fs.mkdtemp(path.join(os.tmpdir(), "syrus-docker-installer-test-"))
  return path.join(tempDir, "installer.exe")
}

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
    expect(dockerDesktopInstallerUrl({}, "x64")).toBe(
      "https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe"
    )
  })

  it("detects arm64 hardware through PROCESSOR_ARCHITEW6432 under x64 emulation", () => {
    // The Syrus app ships x64-only, so on arm64 Windows it runs emulated and
    // process.arch reports x64 — the env var carries the real machine arch,
    // and Docker Desktop must match the hardware.
    expect(dockerDesktopInstallerUrl({ PROCESSOR_ARCHITEW6432: "ARM64" }, "x64")).toBe(
      "https://desktop.docker.com/win/main/arm64/Docker%20Desktop%20Installer.exe"
    )
  })

  it("accepts only a valid Authenticode signature from Docker Inc.", () => {
    expect(validDockerDesktopSignature({ Status: "Valid", Subject: "CN=Docker Inc, O=Docker Inc, L=Palo Alto" })).toBe(
      true
    )
    expect(validDockerDesktopSignature({ Status: "HashMismatch", Subject: "CN=Docker Inc, O=Docker Inc" })).toBe(false)
    expect(validDockerDesktopSignature({ Status: "Valid", Subject: "CN=Attacker, O=Not Docker Inc" })).toBe(false)
  })

  it("removes a partial installer when the response stream fails", async () => {
    const destPath = await destination()
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]))
        controller.error(new Error("connection dropped"))
      }
    })
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(body, { status: 200 })))

    await expect(downloadDockerDesktopInstaller(destPath, () => {})).rejects.toThrow("connection dropped")
    await expect(fs.stat(destPath)).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("aborts a stalled download and removes its partial file", async () => {
    vi.useFakeTimers()
    const destPath = await destination()
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        controller.enqueue(new Uint8Array([1, 2, 3]))
      }
    })
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(body, { status: 200 })))

    const download = downloadDockerDesktopInstaller(destPath, () => {}, undefined, 1_000)
    await vi.advanceTimersByTimeAsync(1_001)

    await expect(download).rejects.toThrow("installer download stalled")
    await expect(fs.stat(destPath)).rejects.toMatchObject({ code: "ENOENT" })
  })

  it("throttles indeterminate progress for responses without Content-Length", async () => {
    const destPath = await destination()
    const body = new ReadableStream<Uint8Array>({
      start(controller) {
        for (let index = 0; index < 100; index += 1) controller.enqueue(new Uint8Array([index]))
        controller.close()
      }
    })
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(new Response(body, { status: 200 })))
    const onProgress = vi.fn()

    await downloadDockerDesktopInstaller(destPath, onProgress)

    expect(onProgress).toHaveBeenCalledTimes(1)
    expect(onProgress).toHaveBeenCalledWith(null)
  })
})
