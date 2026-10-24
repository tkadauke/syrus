import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import { resetBackendUpdateStoreForTests } from "../hooks/useBackendUpdate"
import { ReadinessPanel } from "./Dashboard"

type Readiness = NonNullable<NonNullable<BootstrapPayload["setup_status"]>["readiness"]>

const failingReadiness: Readiness = {
  status: "error",
  checks: [
    {
      key: "github",
      label: "GitHub credentials",
      status: "error",
      message: "GitHub credentials missing.",
      remediation: "Add a personal access token.",
      optional: false
    }
  ]
}

function renderPanel(readiness: Readiness, prefix = "") {
  return render(
    <MemoryRouter>
      <ReadinessPanel prefix={prefix} readiness={readiness} />
    </MemoryRouter>
  )
}

function installShellBridge(backendUpdate: { phase: "starting" | "downloading" | "migrating"; percent: number | null; outage: boolean }) {
  window.syrusShell = {
    getState: vi.fn().mockResolvedValue({
      updateReadyVersion: null,
      claudeDetected: false,
      skillInstalled: false,
      skillOfferDismissed: true,
      backendUpdate
    }),
    onStateChanged: vi.fn().mockReturnValue(() => {}),
    relaunchToUpdate: vi.fn(),
    installSkill: vi.fn(),
    dismissSkillOffer: vi.fn()
  }
  resetBackendUpdateStoreForTests()
}

describe("ReadinessPanel", () => {
  afterEach(() => {
    delete window.syrusShell
    resetBackendUpdateStoreForTests()
  })

  it("shows failing readiness checks in a plain browser", () => {
    renderPanel(failingReadiness)

    expect(screen.getByText("GitHub credentials missing.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open Operator Console" })).toHaveAttribute("href", "/admin/console")
  })

  it("prefixes the Operator Console link in the app shell", () => {
    renderPanel(failingReadiness, "/app-shell")

    expect(screen.getByRole("link", { name: "Open Operator Console" })).toHaveAttribute("href", "/app-shell/admin/console")
  })

  it("suppresses the failing checks while the backend update has the containers down", async () => {
    // The checks fail BECAUSE the backend is deliberately unreachable —
    // showing "GitHub credentials missing" here is the exact scare this
    // feature exists to prevent. The sidebar's update notice explains the
    // outage instead; the panel returns once the update finishes.
    installShellBridge({ phase: "migrating", percent: null, outage: true })

    renderPanel(failingReadiness)

    await waitFor(() => expect(screen.queryByText("GitHub credentials missing.")).not.toBeInTheDocument())
  })

  it("keeps showing genuine failing checks during the image pull — no outage yet", async () => {
    // The old backend serves throughout the pull, so a real readiness
    // problem must stay visible; suppressing it then would be over-gating.
    installShellBridge({ phase: "downloading", percent: 42, outage: false })

    renderPanel(failingReadiness)

    await waitFor(() => expect(window.syrusShell?.getState).toHaveBeenCalled())
    expect(screen.getByText("GitHub credentials missing.")).toBeInTheDocument()
  })
})
