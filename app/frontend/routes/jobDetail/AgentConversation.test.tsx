import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import type { AgentConversationGraph } from "../../api/jobs"
import { AgentConversationTab } from "./AgentConversation"

function graph(overrides: Partial<AgentConversationGraph> = {}): AgentConversationGraph {
  return {
    job_id: 1,
    selected_workflow_id: 9,
    workflows: [
      { id: 9, slug: "WF-9", trigger_kind: "initial", trigger_label: "Initial", state: "succeeded", created_at: null, started_at: null, finished_at: null }
    ],
    nodes: [],
    edges: [],
    ...overrides
  }
}

function renderTab(jobId = 1, prUrl: string | null = null, initialEntry = "/jobs/1?tab=conversation") {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false, staleTime: Infinity } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route element={<AgentConversationTab jobId={jobId} prUrl={prUrl} />} path="/jobs/:id" />
        </Routes>
      </MemoryRouter>
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
        return Promise.resolve(
          jsonResponse(
            graph({
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
            })
          )
        )
      }
      if (path.startsWith("/api/v1/app/jobs/1/runs/501/artifacts?artifact=transcript")) {
        const page = new URL(path, "http://example.test").searchParams.get("page")
        return Promise.resolve(
          jsonResponse({
            job_id: 1,
            workflow_id: 9,
            run_id: 501,
            base_ref: null,
            head_ref: null,
            artifact: "transcript",
            logs_count: 101,
            logs_page: Number(page),
            logs_per_page: 100,
            logs_total_pages: 2,
            logs_has_older: page === "1",
            logs:
              page === "1"
                ? [{ id: 101, sequence: 101, kind: "assistant_text", chunk: "Wrote the greeting helper.", created_at: null }]
                : [{ id: 1, sequence: 1, kind: "assistant_text", chunk: "Started the implementation.", created_at: null }]
          })
        )
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
    expect(screen.getByTestId("run-transcript-log-stream")).toHaveClass("min-h-0", "flex-1", "max-h-none")
    expect(screen.getByTestId("run-transcript-log-stream")).not.toHaveClass("max-h-[32rem]")
    expect(screen.getByText("Wrote the greeting helper.")).toBeInTheDocument()
    expect(screen.getByText("Older transcript rows are not shown.")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Older" }))
    expect(await screen.findByText("Started the implementation.")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Newer" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Close transcript" }))
    expect(sidebar).not.toBeInTheDocument()
  })

  it("renders panel members as one expandable consensus round", async () => {
    const panel = {
      panel_id: "panel-1",
      panel_verdict: "approved",
      vote_breakdown: { approved: 1, needs_work: 1, skipped: 0, counted: 2, total: 2, required_approvals: 2, min_members: 2 }
    }
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        graph({
          nodes: [
            {
              id: "agent_session-601",
              kind: "agent_session",
              workflow_id: 9,
              trigger_kind: "initial",
              step_id: 61,
              step_kind: "adversarial_review",
              run_id: 601,
              role: "workflow:adversarial_reviewer",
              agent_provider: "claude",
              agent_model: "sonnet",
              iteration: 1,
              label: "Adversarial review",
              state: "succeeded",
              started_at: null,
              finished_at: null,
              agentic: true,
              summary: "**Clean.** See [evidence](https://example.test/panel).",
              detail: { ...panel, verdict: "approved" }
            },
            {
              id: "agent_session-602",
              kind: "agent_session",
              workflow_id: 9,
              trigger_kind: "initial",
              step_id: 62,
              step_kind: "adversarial_review",
              run_id: 602,
              role: "workflow:adversarial_reviewer",
              agent_provider: "codex",
              agent_model: "gpt-5",
              iteration: 1,
              label: "Adversarial review",
              state: "succeeded",
              started_at: null,
              finished_at: null,
              agentic: true,
              summary: "Minor concern.",
              detail: { ...panel, verdict: "needs_work" }
            }
          ]
        })
      )
    )

    renderTab()

    expect(await screen.findByText("Adversarial review · Round 1")).toBeInTheDocument()
    expect(screen.getByText(/1 approved, 1 needs work, 0 skipped/)).toBeInTheDocument()
    expect(screen.getByText(/2 approvals required/)).toBeInTheDocument()
    expect(screen.getByText("claude / sonnet")).toBeInTheDocument()
    expect(screen.getByText("codex / gpt-5")).toBeInTheDocument()
    expect(screen.getByText("Clean.").tagName).toBe("STRONG")
    expect(screen.getByRole("link", { name: "evidence" }).closest("button")).toBeNull()
    expect(document.querySelectorAll("details")).toHaveLength(1)
  })

  it("renders agent summaries with light Markdown without heading elements", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        graph({
          nodes: [
            {
              id: "agent_session-501",
              kind: "agent_session",
              workflow_id: 9,
              trigger_kind: "initial",
              step_id: 1,
              step_kind: "adversarial_review",
              run_id: 501,
              role: "workflow:adversarial_review",
              label: "Adversarial review",
              state: "succeeded",
              started_at: null,
              finished_at: null,
              agentic: true,
              summary: "## Findings\n\nThe **hidden header** uses `top: 0`.",
              detail: {}
            }
          ]
        })
      )
    )

    const { container } = renderTab()

    expect((await screen.findByText("Findings")).tagName).toBe("STRONG")
    expect(screen.getByText("hidden header").tagName).toBe("STRONG")
    expect(screen.getByText("top: 0").tagName).toBe("CODE")
    expect(container.querySelector("h1, h2, h3, h4, h5, h6")).not.toBeInTheDocument()
    expect(screen.queryByText(/## Findings/)).not.toBeInTheDocument()
  })

  it("keeps links in light Markdown summaries outside card buttons", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        graph({
          nodes: [
            {
              id: "agent_session-501",
              kind: "agent_session",
              workflow_id: 9,
              trigger_kind: "initial",
              step_id: 1,
              step_kind: "adversarial_review",
              run_id: 501,
              role: "workflow:adversarial_review",
              label: "Adversarial review",
              state: "succeeded",
              started_at: null,
              finished_at: null,
              agentic: true,
              summary: "See [agent evidence](https://example.test/agent).",
              detail: {}
            },
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
              summary: "See [check output](https://example.test/check).",
              detail: {}
            }
          ]
        })
      )
    )

    renderTab()

    const agentLink = await screen.findByRole("link", { name: "agent evidence" })
    const checkLink = screen.getByRole("link", { name: "check output" })

    expect(agentLink.closest("button")).toBeNull()
    expect(checkLink.closest("button")).toBeNull()
  })

  it("renders a deterministic_check card and shows raw output only, no reasoning framing", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        graph({
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
        })
      )
    )

    renderTab()

    expect(await screen.findByText("rspec")).toBeInTheDocument()
    expect(document.querySelector("svg path")?.getAttribute("d")).toContain("M12.22 2h-.44")
    fireEvent.click(screen.getByRole("button", { name: /rspec/ }))

    expect(await screen.findByText("1 example, 1 failure")).toBeInTheDocument()
    expect(screen.getByText("$ bin/rspec")).toBeInTheDocument()
  })

  it("renders an external_trigger banner spanning the thread with a link to its source", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        graph({
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
        })
      )
    )

    renderTab(1, "https://github.com/acme/widgets/pull/1")

    expect(await screen.findByText("PR feedback")).toBeInTheDocument()
    expect(screen.getByText("Please rename this method")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "View source" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/1")
  })

  it("renders a generated connector label between two nodes", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        graph({
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
        })
      )
    )

    renderTab()

    expect(await screen.findByText("rspec failed — Landing fix repair requested")).toBeInTheDocument()
  })

  it("contains long conversation content inside the thread and cards", async () => {
    const longSummary =
      "Review found a long unbroken path tmp/workspaces/syrus/direct-746/design_docs/app/services/design_docs/normalize_anchor_markers.rb-with-a-very-long-token-that-should-not-widen-the-page"
    vi.spyOn(window, "fetch").mockResolvedValue(
      jsonResponse(
        graph({
          nodes: [
            {
              id: "agent_session-501",
              kind: "agent_session",
              workflow_id: 9,
              trigger_kind: "initial",
              step_id: 1,
              step_kind: "adversarial_review",
              run_id: 501,
              role: "workflow:adversarial_review",
              label: "Adversarial review with a long label",
              state: "succeeded",
              started_at: null,
              finished_at: null,
              agentic: true,
              summary: longSummary,
              detail: {}
            }
          ]
        })
      )
    )

    const { container } = renderTab()

    const summary = await screen.findByText(longSummary)
    expect(container.querySelector(".overflow-x-auto")).toHaveClass("max-w-3xl")
    expect(summary).toHaveClass("max-h-48", "overflow-y-auto", "break-words")
    expect(summary.closest(".basis-64")).toHaveClass("min-w-0", "overflow-hidden")
  })

  it("shows a workflow selector and refetches the selected workflow only", async () => {
    const fetchMock = vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/1/agent_conversation") {
        return Promise.resolve(
          jsonResponse(
            graph({
              selected_workflow_id: 10,
              workflows: [
                {
                  id: 10,
                  slug: "WF-10",
                  trigger_kind: "retry",
                  trigger_label: "Retry",
                  state: "running",
                  created_at: null,
                  started_at: null,
                  finished_at: null
                },
                {
                  id: 9,
                  slug: "WF-9",
                  trigger_kind: "initial",
                  trigger_label: "Initial",
                  state: "succeeded",
                  created_at: null,
                  started_at: null,
                  finished_at: null
                }
              ],
              nodes: [
                {
                  id: "agent_session-1002",
                  kind: "agent_session",
                  workflow_id: 10,
                  trigger_kind: "retry",
                  step_id: 2,
                  step_kind: "implement",
                  run_id: 1002,
                  role: "workflow:implement",
                  label: "Retry implement",
                  state: "running",
                  started_at: null,
                  finished_at: null,
                  agentic: true,
                  summary: "Retry work",
                  detail: {}
                }
              ]
            })
          )
        )
      }
      if (path === "/api/v1/app/jobs/1/agent_conversation?workflow_id=9") {
        return Promise.resolve(
          jsonResponse(
            graph({
              selected_workflow_id: 9,
              workflows: [
                {
                  id: 10,
                  slug: "WF-10",
                  trigger_kind: "retry",
                  trigger_label: "Retry",
                  state: "running",
                  created_at: null,
                  started_at: null,
                  finished_at: null
                },
                {
                  id: 9,
                  slug: "WF-9",
                  trigger_kind: "initial",
                  trigger_label: "Initial",
                  state: "succeeded",
                  created_at: null,
                  started_at: null,
                  finished_at: null
                }
              ],
              nodes: [
                {
                  id: "agent_session-901",
                  kind: "agent_session",
                  workflow_id: 9,
                  trigger_kind: "initial",
                  step_id: 1,
                  step_kind: "implement",
                  run_id: 901,
                  role: "workflow:implement",
                  label: "Initial implement",
                  state: "succeeded",
                  started_at: null,
                  finished_at: null,
                  agentic: true,
                  summary: "Initial work",
                  detail: {}
                }
              ]
            })
          )
        )
      }
      return Promise.reject(new Error(`unexpected fetch ${path}`))
    })

    renderTab()

    const selector = await screen.findByLabelText("Workflow")
    expect(screen.getByRole("option", { name: "WF-10 - Retry - running" })).toBeInTheDocument()
    expect(screen.getByText("Retry work")).toBeInTheDocument()

    fireEvent.change(selector, { target: { value: "9" } })

    expect(await screen.findByText("Initial work")).toBeInTheDocument()
    expect(screen.queryByText("Retry work")).not.toBeInTheDocument()
    expect(fetchMock.mock.calls.some(([input]) => String(input) === "/api/v1/app/jobs/1/agent_conversation?workflow_id=9")).toBe(true)
  })
})
