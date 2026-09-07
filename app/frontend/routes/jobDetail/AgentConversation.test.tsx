import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import type { AgentConversationGraph } from "../../api/jobs"
import { AgentConversationTab } from "./AgentConversation"

function graph(overrides: Partial<AgentConversationGraph> = {}): AgentConversationGraph {
  return {
    job_id: 1,
    nodes: [],
    edges: [],
    ...overrides
  }
}

function renderTab(jobId = 1, prUrl: string | null = null) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <AgentConversationTab jobId={jobId} prUrl={prUrl} />
    </QueryClientProvider>
  )
}

afterEach(() => {
  vi.restoreAllMocks()
})

describe("AgentConversationTab", () => {
  it("shows the empty state when the job has no recorded agent activity", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(graph()))

    renderTab()

    expect(await screen.findByText("No agent activity recorded for this Job yet.")).toBeInTheDocument()
  })

  it("renders an agent_session card and opens its transcript in a sidebar on click", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/1/agent_conversation") {
        return Promise.resolve(jsonResponse(graph({
          nodes: [
            {
              id: "agent_session-501",
              kind: "agent_session",
              workflow_id: 9,
              trigger_kind: "initial",
              step_id: 1,
              step_kind: "implement",
              run_id: 501,
              role: "workflow:implement",
              label: "Implement",
              state: "succeeded",
              started_at: null,
              finished_at: null,
              agentic: true,
              summary: "Added the greeting helper",
              detail: {}
            }
          ]
        })))
      }
      if (path === "/api/v1/app/jobs/1/runs/501/artifacts") {
        return Promise.resolve(jsonResponse({
          job_id: 1,
          workflow_id: 9,
          run_id: 501,
          base_ref: null,
          head_ref: null,
          agent_diff: null,
          agent_diff_bytes: 0,
          step_agent_diff: null,
          logs_count: 1,
          logs: [{ id: 1, sequence: 1, kind: "assistant_text", chunk: "Wrote the greeting helper.", created_at: null }]
        }))
      }
      return Promise.reject(new Error(`unexpected fetch ${path}`))
    })

    renderTab()

    expect(await screen.findByText("Implement")).toBeInTheDocument()
    expect(screen.getByText("Added the greeting helper")).toBeInTheDocument()
    expect(screen.queryByRole("complementary")).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: /Implement/ }))

    const sidebar = await screen.findByRole("complementary", { name: "Implement transcript" })
    await waitFor(() => expect(screen.getByTestId("run-transcript-log-stream")).toBeInTheDocument())
    expect(screen.getByText("Wrote the greeting helper.")).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Close transcript" }))
    expect(sidebar).not.toBeInTheDocument()
  })

  it("renders a deterministic_check card and shows raw output only, no reasoning framing", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(graph({
      nodes: [
        {
          id: "deterministic_check-77",
          kind: "deterministic_check",
          workflow_id: 9,
          trigger_kind: "initial",
          step_id: 77,
          step_kind: "grader",
          label: "rspec",
          state: "failed",
          started_at: null,
          finished_at: null,
          agentic: false,
          summary: "rspec failed",
          detail: { command: "bin/rspec", output: "1 example, 1 failure" }
        }
      ]
    })))

    renderTab()

    expect(await screen.findByText("rspec")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: /rspec/ }))

    expect(await screen.findByText("1 example, 1 failure")).toBeInTheDocument()
    expect(screen.getByText("$ bin/rspec")).toBeInTheDocument()
  })

  it("renders an external_trigger banner spanning the thread with a link to its source", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(graph({
      nodes: [
        {
          id: "external_trigger-9",
          kind: "external_trigger",
          workflow_id: 9,
          trigger_kind: "pr_comment",
          step_id: null,
          step_kind: null,
          label: "PR feedback",
          state: null,
          started_at: null,
          finished_at: null,
          agentic: false,
          summary: "PR comment from @alice",
          detail: { comments: [{ body: "Please rename this method" }] }
        }
      ]
    })))

    renderTab(1, "https://github.com/acme/widgets/pull/1")

    expect(await screen.findByText("PR feedback")).toBeInTheDocument()
    expect(screen.getByText("Please rename this method")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "View source" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/1")
  })

  it("renders a generated connector label between two nodes", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse(graph({
      nodes: [
        {
          id: "deterministic_check-1",
          kind: "deterministic_check",
          workflow_id: 9,
          trigger_kind: "initial",
          step_id: 1,
          step_kind: "grader",
          label: "rspec",
          state: "failed",
          started_at: null,
          finished_at: null,
          agentic: false,
          summary: null,
          detail: {}
        },
        {
          id: "agent_session-2",
          kind: "agent_session",
          workflow_id: 9,
          trigger_kind: "initial",
          step_id: 2,
          step_kind: "landing_fix",
          run_id: 502,
          role: "workflow:implement",
          label: "Landing fix",
          state: "running",
          started_at: null,
          finished_at: null,
          agentic: true,
          summary: null,
          detail: {}
        }
      ],
      edges: [{ from_id: "deterministic_check-1", to_id: "agent_session-2" }]
    })))

    renderTab()

    expect(await screen.findByText("rspec failed — Landing fix repair requested")).toBeInTheDocument()
  })
})
