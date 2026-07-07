import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { RuntimeSetup } from "./RuntimeSetup"

type RuntimeSetupProps = Parameters<typeof RuntimeSetup>[0]

function renderRuntimeSetup(overrides: Partial<RuntimeSetupProps> = {}) {
  const props: RuntimeSetupProps = {
    mode: "missing",
    polling: false,
    onInstallWsl: vi.fn(),
    onInstallRuntime: vi.fn(),
    onOpenRuntime: vi.fn(),
    onDownload: vi.fn(),
    onRetry: vi.fn(),
    onBack: vi.fn(),
    ...overrides
  }
  render(<RuntimeSetup {...props} />)
  return props
}

describe("RuntimeSetup on Windows", () => {
  beforeEach(() => {
    ;(window as unknown as { syrusDesktop: unknown }).syrusDesktop = { platform: "win32" }
  })

  afterEach(() => {
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("offers the one-click WSL 2 install when WSL is missing", () => {
    const { onInstallWsl } = renderRuntimeSetup({ wslMissing: true })

    expect(screen.getByTestId("wsl-step")).toBeTruthy()
    fireEvent.click(screen.getByRole("button", { name: "Install WSL 2" }))
    expect(onInstallWsl).toHaveBeenCalledTimes(1)
  })

  it("hides the WSL step when WSL is already present", () => {
    renderRuntimeSetup({ wslMissing: false })

    expect(screen.queryByTestId("wsl-step")).toBeNull()
  })

  it("recommends Docker Desktop and never mentions Podman", () => {
    // Shipped product decision: Podman compose is unsupported, so the guided
    // setup must not suggest installing it (install.ps1's exit-10 copy pins
    // the same rule in install_parity_spec).
    renderRuntimeSetup({ wslMissing: true })

    expect(screen.getByRole("button", { name: "Install Docker Desktop" })).toBeTruthy()
    expect(screen.queryByText(/Podman/)).toBeNull()
  })

  it("installs Docker Desktop itself, with manual download demoted to a fallback link", () => {
    // The auto-install replaces the old download-page handoff: Syrus runs the
    // official installer with --accept-license --user (no UAC, no first-run
    // license dialog). Manual download stays available but secondary.
    const { onInstallRuntime, onDownload } = renderRuntimeSetup({ wslMissing: false })

    const card = screen.getByTestId("runtime-auto-install")
    expect(card.textContent).toMatch(/install Docker Desktop for you/)
    expect(card.textContent).toMatch(/No admin permission/)
    expect(card.textContent).toMatch(/service\s*agreement is accepted for you/)
    fireEvent.click(screen.getByRole("button", { name: "Install Docker Desktop" }))
    expect(onInstallRuntime).toHaveBeenCalledTimes(1)

    fireEvent.click(screen.getByRole("button", { name: "download manually instead" }))
    expect(onDownload).toHaveBeenCalledTimes(1)
  })

  it("gates the auto-install behind the WSL 2 step", () => {
    // Docker Desktop runs on WSL 2 — installing it before WSL exists just
    // moves the failure later. The button unlocks once WSL is present.
    renderRuntimeSetup({ wslMissing: true })

    const button = screen.getByRole("button", { name: "Install Docker Desktop" }) as HTMLButtonElement
    expect(button.disabled).toBe(true)
    expect(screen.getByText(/Install WSL 2 above first/)).toBeTruthy()
  })

  it("surfaces a failed auto-install attempt with the retry/manual guidance", () => {
    renderRuntimeSetup({ wslMissing: false, installError: "The download failed. You can retry, or download Docker Desktop manually." })

    expect(screen.getByTestId("runtime-install-error").textContent).toMatch(/download failed/)
  })

  it("shows download progress, then an indeterminate installing state", () => {
    renderRuntimeSetup({ mode: "installing", installStep: "downloading", installPercent: 42 })
    expect(screen.getByTestId("runtime-install-progress").textContent).toMatch(/42%/)
  })

  it("narrates the unattended install (nothing for the user to click)", () => {
    renderRuntimeSetup({ mode: "installing", installStep: "installing", installPercent: null })

    expect(screen.getByText(/Running the installer/)).toBeTruthy()
    expect(screen.getByText(/no clicks needed/i)).toBeTruthy()
  })

  it("keeps the plain starting screen while the daemon is just booting", () => {
    renderRuntimeSetup({ mode: "starting", polling: true, needsAttention: false })

    expect(screen.getByText("Starting your Docker runtime…")).toBeTruthy()
    expect(screen.queryByTestId("runtime-attention")).toBeNull()
  })

  it("tells the user to finish Docker Desktop's first-run setup when the daemon stays quiet", () => {
    // Field failure: Docker Desktop's FIRST start blocks on its service
    // agreement (and offers a sign-in) while Syrus said "Starting…" forever
    // with no hint. The attention state must say exactly what to click —
    // accept the agreement, sign-in is skippable — and offer to open the app.
    const onOpenRuntime = vi.fn()
    renderRuntimeSetup({ mode: "starting", polling: true, needsAttention: true, onOpenRuntime })

    const attention = screen.getByTestId("runtime-attention")
    expect(attention.textContent).toMatch(/Accept/)
    expect(attention.textContent).toMatch(/service agreement/)
    expect(attention.textContent).toMatch(/optional/)
    fireEvent.click(screen.getByRole("button", { name: "Open Docker Desktop" }))
    expect(onOpenRuntime).toHaveBeenCalledTimes(1)
  })
})
