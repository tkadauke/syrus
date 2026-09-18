import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import type { BootstrapPayload } from "../api/bootstrap"
import { DashboardTour } from "./Dashboard"

vi.mock("../components/SyrusTour", () => ({
  SyrusTour: vi.fn(({ run, steps }: { run: boolean; steps: Array<{ target: string; title: string; content: string }> }) => (
    <div data-testid="syrus-tour" data-run={String(run)}>
      {steps.map((step) => (
        <div data-target={step.target} data-testid="syrus-tour-step" key={step.target}>
          <span data-testid="syrus-tour-step-title">{step.title}</span>
          <span data-testid="syrus-tour-step-content">{step.content}</span>
        </div>
      ))}
    </div>
  ))
}))

function buildBootstrap(seenTours: string[] = []): BootstrapPayload {
  return {
    current_user: {
      id: 1,
      email_address: "test@example.com",
      name: "Test User",
      first_name: null,
      last_name: null,
      display_name: "Test User",
      admin: false,
      role: "developer",
      scheduling_paused: false,
      landing_paused: false,
      agent_provider: "claude",
      chat_provider: null,
      agent_max_turns: 200,
      gemini_configured: false,
      theme: "light",
      locale: "en",
      seen_tours: seenTours
    },
    team_user_count: 1,
    app: {
      revision: "abc123",
      revision_url: null,
      version: null,
      built_at: null,
      bug_report_mode: null,
      report_issue_repo_slug: "owner/repo"
    },
    setup_status: null,
    public: {
      first_signup: false,
      signups_open: false,
      signup_path: "/session/new",
      sign_in_path: "/session/new",
      docs_url: "https://docs.example.com",
      evaluation_url: "https://example.com"
    },
    unread_notifications_count: 0,
    csrf_token: "test-token",
    feature_flags: {}
  }
}

function renderTour(seenTours: string[] = []) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  queryClient.setQueryData(["bootstrap"], buildBootstrap(seenTours))
  return render(
    <QueryClientProvider client={queryClient}>
      <DashboardTour />
    </QueryClientProvider>
  )
}

describe("DashboardTour", () => {
  it("renders Joyride with run=true when dashboard is not in seen_tours", () => {
    renderTour([])
    expect(screen.getByTestId("syrus-tour")).toHaveAttribute("data-run", "true")
  })

  it("renders Joyride with run=false when dashboard is already in seen_tours", () => {
    renderTour(["dashboard"])
    expect(screen.getByTestId("syrus-tour")).toHaveAttribute("data-run", "false")
  })

  it("renders Joyride with run=true when other tours are seen but not dashboard", () => {
    renderTour(["job_detail", "chat"])
    expect(screen.getByTestId("syrus-tour")).toHaveAttribute("data-run", "true")
  })

  it("renders all 4 steps", () => {
    renderTour([])
    const steps = screen.getAllByTestId("syrus-tour-step")
    expect(steps).toHaveLength(4)
    expect(steps.map((step) => step.getAttribute("data-target"))).toEqual([
      "[data-tour='dashboard-filter-bar']",
      "[data-tour='dashboard-view-switcher']",
      "[data-tour='dashboard-create-actions']",
      "[data-tour='dashboard-table']"
    ])
    expect(screen.getByText("Start new work")).toBeInTheDocument()
    expect(screen.getByText("'New Job' opens a quick-start form; 'New Epic' groups related jobs together. The recommended way to create jobs and epics is through Chat — describe your task there and Syrus turns it into a pull request.")).toBeInTheDocument()
    expect(screen.getByText("Click any job to dive in")).toBeInTheDocument()
    expect(screen.getByText("Opening a job shows the full implementation timeline, the pull request diff, and lets you give feedback or approve the work.")).toBeInTheDocument()
  })
})
