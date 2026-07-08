import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CliInstallSection } from "./App"

function stubBridge(
  over: Partial<{ available: boolean; bundledAvailable: boolean; install: SyrusCliInstallResult }> = {}
) {
  const bridge = {
    syrusCliStatus: vi.fn().mockResolvedValue({
      available: over.available ?? false,
      bundledAvailable: over.bundledAvailable ?? true
    }),
    installSyrusCli: vi.fn().mockResolvedValue(
      over.install ?? {
        installed: true,
        target: "/Users/op/.local/bin/syrus",
        onPath: false,
        signedIn: true,
        skillInstalled: false,
        skillError: null,
        error: null
      }
    )
  }
  ;(window as unknown as { syrusDesktop: unknown }).syrusDesktop = bridge
  return bridge
}

describe("CliInstallSection", () => {
  afterEach(() => {
    vi.restoreAllMocks()
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("shows the auto-managed installed state with a skill button, never an install button", async () => {
    stubBridge({ available: true })
    render(<CliInstallSection />)
    await waitFor(() => expect(screen.queryByText(/kept current automatically/)).not.toBeNull())
    expect(screen.queryByRole("button", { name: /Reinstall CLI/ })).toBeNull()
    expect(screen.queryByRole("button", { name: "Add Claude Code skill" })).not.toBeNull()
  })

  it("treats a missing CLI as a failed auto-install and offers the reinstall fallback", async () => {
    const bridge = stubBridge({ available: false })
    render(<CliInstallSection />)

    await waitFor(() => expect(screen.queryByText(/normally installs itself/)).not.toBeNull())
    fireEvent.click(await screen.findByRole("button", { name: "Reinstall CLI" }))
    // The skill is a separate ask (its own button / post-setup dialog) —
    // the repair path never smuggles it in.
    expect(bridge.installSyrusCli).toHaveBeenCalledWith(undefined)

    await waitFor(() => expect(screen.queryByText(/Installed to \/Users\/op\/.local\/bin\/syrus/)).not.toBeNull())
    expect(screen.queryByText(/already signed in via this app.s credentials/)).not.toBeNull()
    // ~/.local/bin wasn't on PATH — the export one-liner is offered.
    expect(screen.queryByText(/export PATH=/)).not.toBeNull()
  })

  it("requests the skill from the installed state's skill button", async () => {
    const bridge = stubBridge({
      available: true,
      install: {
        installed: true,
        target: "/Users/op/.local/bin/syrus",
        onPath: true,
        signedIn: true,
        skillInstalled: true,
        skillError: null,
        error: null
      }
    })
    render(<CliInstallSection />)

    fireEvent.click(await screen.findByRole("button", { name: "Add Claude Code skill" }))
    expect(bridge.installSyrusCli).toHaveBeenCalledWith({ withSkill: true })
    await waitFor(() => expect(screen.queryByText(/Claude Code skill added/)).not.toBeNull())
  })

  it("shows manual guidance and disables reinstall when the app bundle carries no CLI", async () => {
    // The 0.1.1/0.1.2 failure mode: the build shipped without Resources/cli,
    // so "Reinstall CLI" could only throw ENOENT. Guidance instead.
    const bridge = stubBridge({ available: false, bundledAvailable: false })
    render(<CliInstallSection />)

    await waitFor(() => expect(screen.queryByText(/carries no bundled CLI/)).not.toBeNull())
    const reinstall = await screen.findByRole("button", { name: "Reinstall CLI" })
    expect((reinstall as HTMLButtonElement).disabled).toBe(true)
    expect(bridge.installSyrusCli).not.toHaveBeenCalled()
  })

  it("surfaces install failures", async () => {
    stubBridge({
      available: false,
      install: {
        installed: false,
        target: null,
        onPath: false,
        signedIn: false,
        skillInstalled: false,
        skillError: null,
        error: "bundled binary missing"
      }
    })
    render(<CliInstallSection />)

    fireEvent.click(await screen.findByRole("button", { name: "Reinstall CLI" }))
    await waitFor(() => expect(screen.queryByText("bundled binary missing")).not.toBeNull())
  })
})
