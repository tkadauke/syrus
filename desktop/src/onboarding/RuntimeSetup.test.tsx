import { fireEvent, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { RuntimeSetup } from "./RuntimeSetup"

type RuntimeSetupProps = Parameters<typeof RuntimeSetup>[0]

function renderRuntimeSetup(overrides: Partial<RuntimeSetupProps> = {}) {
  const props: RuntimeSetupProps = {
    mode: "missing",
    polling: false,
    onInstallWsl: vi.fn(),
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

    expect(screen.getByRole("button", { name: /Download Docker Desktop/ })).toBeTruthy()
    expect(screen.queryByText(/Podman/)).toBeNull()
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
