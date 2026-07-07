import { describe, expect, it } from "vitest"
import { dockerDesktopInstallArgs, dockerDesktopInstallerUrl } from "../electron/installer/dockerDesktopInstaller"

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
})
