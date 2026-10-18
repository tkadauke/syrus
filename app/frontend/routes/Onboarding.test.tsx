import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi, afterEach, beforeEach } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import { OnboardingRoute } from "./Onboarding"

// Completed onboarding steps used to collapse to a bare "Complete" badge
// with no way back into the setting they configured (GitHub token, agent
// credentials, repositories, account). These specs guard that every
// completed step still exposes an actionable control alongside the badge,
// per the "let the user change/edit them after the fact" bug.
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
      report_issue_repo_slug: "tkadauke/syrus"
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

function renderOnboarding(payload: BootstrapPayload | null) {
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

  it("renders after bootstrap becomes available without changing its hook order", () => {
    const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
    const view = render(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <OnboardingRoute bootstrap={null} />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(screen.getByText("Loading setup status...")).toBeInTheDocument()

    expect(() => view.rerender(
      <QueryClientProvider client={client}>
        <MemoryRouter>
          <OnboardingRoute bootstrap={bootstrap()} />
        </MemoryRouter>
      </QueryClientProvider>
    )).not.toThrow()
    expect(screen.getByRole("heading", { name: "Set up Syrus" })).toBeInTheDocument()
  })

  it("shows the static readiness result and exact proposed commands after repository selection", async () => {
    vi.mocked(window.fetch).mockResolvedValue(jsonResponse({
      readiness: {
        status: "ready_with_warnings",
        summary: "Ready with warnings",
        revision: "abc123",
        repository_size_bytes: 42,
        file_count: 2,
        checks: [{ key: "configuration", level: "warning", message: ".syrus.yml is absent; commands are inferred." }],
        prepare_commands: ["bundle install"],
        grader_commands: ["bin/rspec"],
        required_capabilities: { os: ["linux"] }
      }
    }))

    renderOnboarding(bootstrap({
      setup_status: { ...bootstrap().setup_status!, onboarding_repository_id: 7 }
    }))

    expect(await screen.findByText("Ready with warnings")).toBeInTheDocument()
    expect(screen.getByText("$ bundle install")).toBeInTheDocument()
    expect(screen.getByText("$ bin/rspec")).toBeInTheDocument()
    expect(window.fetch).toHaveBeenCalledWith("/api/v1/app/repositories/7/readiness", expect.anything())
  })

  it("keeps every completed step actionable instead of collapsing to a static badge", () => {
    renderOnboarding(bootstrap())

    const badges = screen.getAllByText("Complete")
    expect(badges).toHaveLength(6)

    expect(screen.getByRole("link", { name: "Open account settings" })).toHaveAttribute("href", "/profile")

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

  it("labels Antigravity readiness with the selected provider instead of Claude", () => {
    renderOnboarding(bootstrap({
      setup_status: {
        ...bootstrap().setup_status!,
        credential_status: {
          github: true,
          github_pat: true,
          github_app: true,
          agent: true,
          active_agent_provider: "agy"
        }
      }
    }))

    expect(screen.getByText("Antigravity is ready for runs.")).toBeInTheDocument()
    expect(screen.queryByText("Claude is ready for runs.")).not.toBeInTheDocument()
  })

  it("uses semantic brand tokens for the current marker and onboarding actions", () => {
    const { unmount } = renderOnboarding(bootstrap({
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

    expect(screen.getByText(">")).toHaveClass("bg-brand", "text-on-brand")

    const primary = screen.getByRole("button", { name: "Configure GitHub" })
    expect(primary).toHaveClass("bg-brand", "text-on-brand", "hover:opacity-90", "focus-visible:ring-brand")
    expect(primary.className).not.toMatch(/\b(?:bg|text|hover:bg)-blue-/)

    unmount()
    renderOnboarding(bootstrap())

    const secondary = screen.getByRole("button", { name: "Edit GitHub connection" })
    expect(secondary).toHaveClass("text-brand", "dark:text-brand-emphasis")
    expect(secondary.className).not.toMatch(/\btext-blue-/)
  })
})
