import { act, render, screen } from "@testing-library/react"
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest"
import { OnboardingApp } from "./OnboardingApp"

function stubBridge(initialState: SyrusOnboardingState) {
  let logCallback: ((line: SyrusOnboardingLogLine) => void) | null = null
  const bridge = {
    getOnboardingState: vi.fn().mockResolvedValue(initialState),
    onOnboardingState: vi.fn().mockReturnValue(() => {}),
    onOnboardingLogLine: vi.fn((callback: (line: SyrusOnboardingLogLine) => void) => {
      logCallback = callback
      return () => {}
    }),
    onboardingBack: vi.fn(),
    chooseOnboardingMode: vi.fn(),
    connectRemote: vi.fn(),
    retryOnboarding: vi.fn(),
    finishOnboarding: vi.fn(),
    cancelInstall: vi.fn(),
    emitLogLine: (line: SyrusOnboardingLogLine) => logCallback?.(line)
  }
  ;(window as unknown as { syrusDesktop: unknown }).syrusDesktop = bridge
  return bridge
}

describe("OnboardingApp layout", () => {
  beforeEach(() => {
    stubBridge({ phase: "done", mode: "local", url: "http://localhost:3000" } as SyrusOnboardingState)
  })

  afterEach(() => {
    vi.restoreAllMocks()
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("vertically centers short content instead of top-aligning it", async () => {
    render(<OnboardingApp />)

    await screen.findByText("Syrus is installed and running")
    const wrapper = screen.getByTestId("onboarding-content")
    // my-auto centers when content is shorter than the window but still
    // lets tall content scroll from the top (items-center would clip it).
    expect(wrapper.className).toContain("my-auto")
    expect(wrapper.className).toContain("justify-center")
    expect(wrapper.parentElement?.className).not.toContain("items-start")
  })
})

describe("OnboardingApp install log", () => {
  const installingState = {
    phase: "local.installing",
    steps: [{ id: "image_pull", status: "running" }],
    currentStep: "image_pull",
    pullProgress: null
  } as SyrusOnboardingState

  afterEach(() => {
    vi.restoreAllMocks()
    delete (window as unknown as { syrusDesktop?: unknown }).syrusDesktop
  })

  it("replaces consecutive transient progress lines instead of appending them", async () => {
    const bridge = stubBridge(installingState)
    const { container } = render(<OnboardingApp />)
    await screen.findByText("Installing Syrus…")

    act(() => {
      bridge.emitLogLine("Pulling images...")
      bridge.emitLogLine({ line: "Downloading Syrus image — 10% (74 MB / 745 MB)", transient: true })
      bridge.emitLogLine({ line: "Downloading Syrus image — 42% (312 MB / 745 MB)", transient: true })
    })

    const pre = container.querySelector("pre")
    expect(pre?.textContent).toBe("Pulling images...\nDownloading Syrus image — 42% (312 MB / 745 MB)")
  })

  it("keeps the last transient line when a plain line follows it", async () => {
    const bridge = stubBridge(installingState)
    const { container } = render(<OnboardingApp />)
    await screen.findByText("Installing Syrus…")

    act(() => {
      bridge.emitLogLine({ line: "Downloading Syrus image — 99% (740 MB / 745 MB)", transient: true })
      bridge.emitLogLine("Image pulled.")
      bridge.emitLogLine({ line: "next transient", transient: true })
    })

    // The plain line breaks the transient run: the summary before it stays in
    // history, and a later transient starts a fresh replaceable line.
    const pre = container.querySelector("pre")
    expect(pre?.textContent).toBe("Downloading Syrus image — 99% (740 MB / 745 MB)\nImage pulled.\nnext transient")
  })
})
