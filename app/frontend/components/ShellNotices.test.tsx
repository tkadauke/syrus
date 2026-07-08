import { act, fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { SyrusShellBridge, SyrusShellState } from "../lib/desktopShell"
import { SKILL_INSTALLED_CONFIRMATION_MS, ShellNotices } from "./ShellNotices"

function shellState(overrides: Partial<SyrusShellState> = {}): SyrusShellState {
  return {
    updateReadyVersion: null,
    claudeDetected: false,
    skillInstalled: false,
    skillOfferDismissed: false,
    ...overrides
  }
}

function shellBridge(state: Partial<SyrusShellState> = {}, overrides: Partial<SyrusShellBridge> = {}): SyrusShellBridge {
  return {
    getState: vi.fn().mockResolvedValue(shellState(state)),
    onStateChanged: vi.fn().mockReturnValue(() => {}),
    relaunchToUpdate: vi.fn(),
    installSkill: vi.fn().mockResolvedValue({ ok: true, message: "installed" }),
    dismissSkillOffer: vi.fn(),
    ...overrides
  }
}

function installBridge(state: Partial<SyrusShellState> = {}, overrides: Partial<SyrusShellBridge> = {}) {
  const bridge = shellBridge(state, overrides)
  window.syrusShell = bridge
  return bridge
}

describe("ShellNotices", () => {
  afterEach(() => {
    delete window.syrusShell
    vi.useRealTimers()
    vi.restoreAllMocks()
  })

  it("renders nothing in a plain browser without window.syrusShell", () => {
    render(<ShellNotices />)

    expect(screen.queryByTestId("shell-notices")).not.toBeInTheDocument()
  })

  it("renders nothing when the bridge reports no pending update and no skill offer", async () => {
    const bridge = installBridge()

    render(<ShellNotices />)

    await waitFor(() => expect(bridge.getState).toHaveBeenCalled())
    expect(screen.queryByText("Relaunch to update")).not.toBeInTheDocument()
    expect(screen.queryByText("Claude detected — install Syrus skill?")).not.toBeInTheDocument()
  })

  it("shows the update notice with the version and relaunches on click", async () => {
    const bridge = installBridge({ updateReadyVersion: "0.1.3" })

    render(<ShellNotices />)

    const relaunch = await screen.findByRole("button", { name: /Relaunch to update/ })
    expect(relaunch).toHaveTextContent("Version 0.1.3 ready")

    fireEvent.click(relaunch)
    expect(bridge.relaunchToUpdate).toHaveBeenCalledTimes(1)
  })

  it("offers the Syrus skill when Claude is detected and explains it in the info popover", async () => {
    installBridge({ claudeDetected: true })

    render(<ShellNotices />)

    await screen.findByText("Claude detected — install Syrus skill?")
    fireEvent.click(screen.getByRole("button", { name: "About the Syrus skill" }))
    expect(screen.getByText(/delegate work to Syrus from any terminal/)).toBeInTheDocument()
  })

  it.each([
    ["already installed", { claudeDetected: true, skillInstalled: true }],
    ["previously dismissed", { claudeDetected: true, skillOfferDismissed: true }],
    ["Claude not detected", { claudeDetected: false }]
  ])("does not offer the skill when %s", async (_label, state) => {
    const bridge = installBridge(state)

    render(<ShellNotices />)

    await waitFor(() => expect(bridge.getState).toHaveBeenCalled())
    expect(screen.queryByText("Claude detected — install Syrus skill?")).not.toBeInTheDocument()
  })

  it("installs the skill, shows a brief confirmation, then removes the notice", async () => {
    vi.useFakeTimers()
    const bridge = installBridge({ claudeDetected: true })

    render(<ShellNotices />)
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0)
    })

    fireEvent.click(screen.getByRole("button", { name: "Install" }))
    await act(async () => {
      await vi.advanceTimersByTimeAsync(0)
    })

    expect(bridge.installSkill).toHaveBeenCalledTimes(1)
    expect(screen.getByText("Skill installed ✓")).toBeInTheDocument()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(SKILL_INSTALLED_CONFIRMATION_MS)
    })
    expect(screen.queryByText("Skill installed ✓")).not.toBeInTheDocument()
    expect(screen.queryByText("Claude detected — install Syrus skill?")).not.toBeInTheDocument()
  })

  it("keeps the box and shows the message inline when the install fails", async () => {
    installBridge(
      { claudeDetected: true },
      { installSkill: vi.fn().mockResolvedValue({ ok: false, message: "claude CLI not on PATH" }) }
    )

    render(<ShellNotices />)

    fireEvent.click(await screen.findByRole("button", { name: "Install" }))

    expect(await screen.findByText("claude CLI not on PATH")).toBeInTheDocument()
    expect(screen.getByText("Claude detected — install Syrus skill?")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Install" })).toBeEnabled()
  })

  it("dismisses the offer through the bridge and hides the box", async () => {
    const bridge = installBridge({ claudeDetected: true })

    render(<ShellNotices />)

    fireEvent.click(await screen.findByRole("button", { name: "Dismiss skill offer" }))

    expect(bridge.dismissSkillOffer).toHaveBeenCalledTimes(1)
    expect(screen.queryByText("Claude detected — install Syrus skill?")).not.toBeInTheDocument()
  })

  it("reacts to bridge state changes pushed through onStateChanged", async () => {
    let pushState: ((state: SyrusShellState) => void) | undefined
    const bridge = installBridge(
      {},
      {
        onStateChanged: vi.fn().mockImplementation((callback: (state: SyrusShellState) => void) => {
          pushState = callback
          return () => {}
        })
      }
    )

    render(<ShellNotices />)
    await waitFor(() => expect(bridge.getState).toHaveBeenCalled())
    expect(screen.queryByText("Relaunch to update")).not.toBeInTheDocument()

    act(() => pushState?.(shellState({ updateReadyVersion: "0.2.0" })))

    expect(await screen.findByText("Relaunch to update")).toBeInTheDocument()
    expect(screen.getByText("Version 0.2.0 ready")).toBeInTheDocument()
  })

  it("never lets the mount-time getState snapshot overwrite a fresher state-changed event", async () => {
    let resolveSnapshot: ((state: SyrusShellState) => void) | undefined
    let pushState: ((state: SyrusShellState) => void) | undefined
    installBridge(
      {},
      {
        getState: vi.fn().mockImplementation(() => new Promise<SyrusShellState>((resolve) => {
          resolveSnapshot = resolve
        })),
        onStateChanged: vi.fn().mockImplementation((callback: (state: SyrusShellState) => void) => {
          pushState = callback
          return () => {}
        })
      }
    )

    render(<ShellNotices />)

    // The event arrives while getState is still in flight...
    act(() => pushState?.(shellState({ updateReadyVersion: "0.2.0" })))
    expect(await screen.findByText("Version 0.2.0 ready")).toBeInTheDocument()

    // ...then the stale snapshot resolves. It must not clobber the event.
    await act(async () => {
      resolveSnapshot?.(shellState({ updateReadyVersion: null }))
    })

    expect(screen.getByText("Version 0.2.0 ready")).toBeInTheDocument()
  })

  it("unsubscribes from bridge state changes on unmount", async () => {
    const unsubscribe = vi.fn()
    const bridge = installBridge({}, { onStateChanged: vi.fn().mockReturnValue(unsubscribe) })

    const { unmount } = render(<ShellNotices />)
    await waitFor(() => expect(bridge.onStateChanged).toHaveBeenCalled())

    unmount()
    expect(unsubscribe).toHaveBeenCalledTimes(1)
  })
})
