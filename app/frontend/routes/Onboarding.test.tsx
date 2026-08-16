import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import { OnboardingRoute } from "./Onboarding"

// Completed onboarding steps used to collapse to a bare "Complete" badge
// with no way back into the setting they configured (GitHub token, agent
// credentials, repositories, instance mode, account). These specs guard
// that every completed step still exposes an actionable control alongside
// the badge, per the "let the user change/edit them after the fact" bug.
function bootstrap(overrides: Partial<BootstrapPayload> = {}): BootstrapPayload {
  return {
    current_user: {
      id: 1,
      email_address: "operator@example.com",
      name: "Operator",
      first_name: null,
      last_name: null,
      display_name: "Operator",
      admin: true,
      role: "admin",
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      chat_provider: "claude",
      agent_max_turns: 200,
      gemini_configured: false,
      theme: "light",
      locale: "en"
    },
    team_user_count: 1,
    app: {
      revision: "dev",
      revision_url: null,
      version: null,
      built_at: null,
      bug_report_mode: null,
      report_issue_repo_slug: "tkadauke/syrus",
      mode: "advanced",
      mode_configured: true
    },
    setup_status: {
      state: "first_successful_job",
      next_step: null,
      next_step_path: null,
      first_admin: true,
      credentials_configured: true,
      repository_configured: true,
      first_job_started: true,
      first_successful_job_completed: true,
      first_epic_created: true,
      first_epic_started: true,
      first_epic_landed: true,
      onboarding_chat_started: true,
      credential_status: {
        github: true,
        github_pat: true,
        github_app: true,
        agent: true,
        active_agent_provider: "claude"
      },
      readiness: { status: "ok", checks: [] },
      counts: { repositories: 1, jobs: 1, successful_jobs: 1 }
    },
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/users/new",
      sign_in_path: "/session/new",
      docs_url: "https://syrus.dev/docs/getting-started",
      evaluation_url: "https://syrus.dev/docs/deployment/docker-compose"
    },
    csrf_token: "csrf-token",
    unread_notifications_count: 0,
    ...overrides
  } as BootstrapPayload
}

function renderOnboarding(payload: BootstrapPayload) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter>
        <OnboardingRoute bootstrap={payload} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("OnboardingRoute — revisiting completed steps", () => {
  beforeEach(() => {
    // Reopening the GitHub/agent modals triggers their own nested queries
    // (bootstrap refetch, GitHub App registration status, a Claude CLI
    // preflight probe); stub a generic response shape broad enough to
    // satisfy all of them so opening the modals doesn't blow up on
    // unrelated code paths.
    vi.spyOn(window, "fetch").mockImplementation(() => Promise.resolve(jsonResponse({
      credential_test: { credential: "claude", ok: false, message: "", details: {} }
    })))
  })

  afterEach(() => vi.restoreAllMocks())

  it("keeps every completed step actionable instead of collapsing to a static badge", () => {
    renderOnboarding(bootstrap())

    const badges = screen.getAllByText("Complete")
    expect(badges).toHaveLength(7)

    expect(screen.getByRole("link", { name: "Open account settings" })).toHaveAttribute("href", "/profile")

    expect(screen.getByRole("button", { name: "Yes, I write code" })).toBeEnabled()
    expect(screen.getByRole("button", { name: "No, build things for me" })).toBeEnabled()

    expect(screen.getByRole("button", { name: "Edit GitHub connection" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Edit agent settings" })).toBeInTheDocument()

    expect(screen.getByRole("link", { name: "Manage repositories" })).toHaveAttribute("href", "/repositories")

    expect(screen.getAllByRole("button", { name: "Open Syrus chat" }).length).toBe(2)
  })

  it("reopens the GitHub connection modal from a completed step", () => {
    renderOnboarding(bootstrap())

    fireEvent.click(screen.getByRole("button", { name: "Edit GitHub connection" }))

    expect(screen.getByRole("dialog")).toBeInTheDocument()
  })

  it("reopens the agent configuration modal from a completed step", () => {
    renderOnboarding(bootstrap())

    fireEvent.click(screen.getByRole("button", { name: "Edit agent settings" }))

    const dialog = screen.getByRole("dialog")
    expect(within(dialog).getByRole("heading", { level: 2 })).toBeInTheDocument()
  })

  it("still shows the primary CTA (not an edit link) for an incomplete step", () => {
    renderOnboarding(bootstrap({
      setup_status: {
        ...bootstrap().setup_status!,
        credential_status: {
          github: false,
          github_pat: false,
          github_app: false,
          agent: true,
          active_agent_provider: "claude"
        }
      }
    }))

    expect(screen.getByRole("button", { name: "Configure GitHub" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Edit GitHub connection" })).not.toBeInTheDocument()
  })
})
