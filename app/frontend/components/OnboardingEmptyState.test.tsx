import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import { OnboardingEmptyState } from "./OnboardingEmptyState"

type SetupStatus = NonNullable<BootstrapPayload["setup_status"]>

function makeSetupStatus(overrides: Pick<SetupStatus, "next_step" | "next_step_path">): SetupStatus {
  return {
    state: "not_started",
    first_admin: true,
    credentials_configured: false,
    repository_configured: false,
    first_job_started: false,
    first_successful_job_completed: false,
    first_epic_created: false,
    first_epic_started: false,
    first_epic_landed: false,
    onboarding_chat_started: false,
    credential_status: {
      github: false,
      github_pat: false,
      github_app: false,
      agent: false,
      active_agent_provider: "claude"
    },
    readiness: { status: "ok", checks: [] },
    counts: { repositories: 0, jobs: 0, successful_jobs: 0 },
    ...overrides
  }
}

function renderState(setupStatus: SetupStatus | null = null) {
  return render(
    <MemoryRouter>
      <OnboardingEmptyState
        fallbackTitle="Nothing here"
        fallbackDescription="Nothing to show."
        prefix="/app-shell"
        setupStatus={setupStatus}
      />
    </MemoryRouter>
  )
}

describe("OnboardingEmptyState", () => {
  it("shows the configure_credentials title and Latin subtitle", () => {
    renderState(makeSetupStatus({ next_step: "configure_credentials", next_step_path: "/credentials" }))

    expect(screen.getByRole("heading", { name: "Connect credentials first" })).toBeInTheDocument()
    expect(screen.getByText("Tesseram da")).toBeInTheDocument()
  })

  it("shows the add_repository title and Latin subtitle", () => {
    renderState(makeSetupStatus({ next_step: "add_repository", next_step_path: "/repositories/new" }))

    expect(screen.getByRole("heading", { name: "Add your first repository" })).toBeInTheDocument()
    expect(screen.getByText("Horrea aperi")).toBeInTheDocument()
  })

  it("shows the start_first_chat title and Latin subtitle", () => {
    renderState(makeSetupStatus({ next_step: "start_first_chat", next_step_path: "/onboarding" }))

    expect(screen.getByRole("heading", { name: "Meet Syrus in chat" })).toBeInTheDocument()
    expect(screen.getByText("Syrum conveni")).toBeInTheDocument()
  })

  it("does not render a Latin subtitle when showing the fallback", () => {
    renderState(null)

    expect(screen.getByRole("heading", { name: "Nothing here" })).toBeInTheDocument()
    expect(screen.queryByText("Tesseram da")).not.toBeInTheDocument()
    expect(screen.queryByText("Horrea aperi")).not.toBeInTheDocument()
    expect(screen.queryByText("Syrum conveni")).not.toBeInTheDocument()
  })
})
