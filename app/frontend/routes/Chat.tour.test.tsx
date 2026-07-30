import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import type { Step } from "react-joyride"
import { ChatTour } from "./Chat"
import type { BootstrapPayload } from "../api/bootstrap"

vi.mock("../components/SyrusTour", () => ({
  SyrusTour: ({ run, steps }: { run: boolean; steps: Step[] }) => (
    <div data-testid="syrus-tour" data-run={String(run)} data-step-count={String(steps.length)} />
  )
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
      report_issue_repo_slug: "owner/repo",
      mode: "advanced" as const,
      mode_configured: false
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

function renderChatTour(seenTours: string[] = []) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  queryClient.setQueryData(["bootstrap"], buildBootstrap(seenTours))
  return render(
    <QueryClientProvider client={queryClient}>
      <ChatTour />
    </QueryClientProvider>
  )
}

describe("ChatTour", () => {
  it("run is true when 'chat' is not in seen_tours", () => {
    renderChatTour([])
    expect(screen.getByTestId("syrus-tour")).toHaveAttribute("data-run", "true")
  })

  it("run is false when 'chat' is already in seen_tours", () => {
    renderChatTour(["chat"])
    expect(screen.getByTestId("syrus-tour")).toHaveAttribute("data-run", "false")
  })

  it("run is true when other tours are seen but not 'chat'", () => {
    renderChatTour(["dashboard", "job_detail"])
    expect(screen.getByTestId("syrus-tour")).toHaveAttribute("data-run", "true")
  })

  it("includes 3 tour steps", () => {
    renderChatTour([])
    expect(screen.getByTestId("syrus-tour")).toHaveAttribute("data-step-count", "3")
  })
})
