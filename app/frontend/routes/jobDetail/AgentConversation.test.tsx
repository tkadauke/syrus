import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { describe, expect, it, vi } from "vitest"
import type { AgentConversationEdge, AgentConversationNode, AgentConversationPayload } from "../../api/jobs"
import {
  AgentConversationTab,
  agentConversationEdgeLabel,
  computeAgentConversationColumns,
  splitAgentConversationSegments
} from "./AgentConversation"

function node(overrides: Partial<AgentConversationNode> & Pick<AgentConversationNode, "id" | "kind">): AgentConversationNode {
  return {
    workflow_id: 1,
    trigger_kind: null,
    step_id: null,
    step_kind: null,
    label: overrides.id,
    state: null,
    started_at: null,
    finished_at: null,
    agentic: overrides.kind === "agent_session",
    summary: null,
    detail: {},
    ...overrides
  }
}

function graphPayload(): AgentConversationPayload {
  const trigger = node({ id: "et-1", kind: "external_trigger", trigger_kind: "pr_comment", label: "PR feedback", summary: "PR comment from @alice", detail: { comments: [{ id: 99, author: "alice", created_at: "2026-01-01T00:00:00Z" }] } })
  const implementA = node({ id: "as-1", kind: "agent_session", step_kind: "implement", role: "workflow:implement", label: "Implement", run_id: 10, state: "succeeded", summary: "Implemented the fix", iteration: 1 })
  const graderFail = node({ id: "dc-1", kind: "deterministic_check", step_kind: "grader", label: "rspec", state: "failed", summary: "rspec failed", detail: { command: "bin/rspec", output: "1 example, 1 failure", exit_code: 1 } })
  const graderPass = node({ id: "dc-2", kind: "deterministic_check", step_kind: "grader", label: "eslint", state: "succeeded", summary: "eslint passed", detail: { command: "eslint .", output: "", exit_code: 0 } })
  const implementB = node({ id: "as-2", kind: "agent_session", step_kind: "implement", role: "workflow:implement", label: "Implement", run_id: 11, state: "succeeded", summary: "Fixed rspec failure", iteration: 2 })

  const nodes = [trigger, implementA, graderFail, graderPass, implementB]
  const edges: AgentConversationEdge[] = [
    { from_id: "as-1", to_id: "dc-1" },
    { from_id: "as-1", to_id: "dc-2" },
    { from_id: "dc-1", to_id: "as-2" },
    { from_id: "dc-2", to_id: "as-2" }
  ]

  return { job_id: 7, nodes, edges }
}

describe("splitAgentConversationSegments", () => {
  it("groups nodes into one segment per external trigger, dropping cross-segment edges", () => {
    const { nodes, edges } = graphPayload()
    const segments = splitAgentConversationSegments(nodes, edges)

    expect(segments).toHaveLength(1)
    expect(segments[0].trigger?.id).toBe("et-1")
    expect(segments[0].nodes.map((n) => n.id)).toEqual(["as-1", "dc-1", "dc-2", "as-2"])
    expect(segments[0].edges).toHaveLength(4)
  })

  it("produces a leading trigger-less segment when the first workflow has no external trigger", () => {
    const first = node({ id: "as-1", kind: "agent_session", label: "Implement" })
    const trigger = node({ id: "et-1", kind: "external_trigger", label: "PR feedback" })
    const second = node({ id: "as-2", kind: "agent_session", label: "Respond" })
    const segments = splitAgentConversationSegments([first, trigger, second], [{ from_id: "as-1", to_id: "as-2" }])

    expect(segments).toHaveLength(2)
    expect(segments[0].trigger).toBeNull()
    expect(segments[0].nodes.map((n) => n.id)).toEqual(["as-1"])
    expect(segments[1].trigger?.id).toBe("et-1")
    expect(segments[1].nodes.map((n) => n.id)).toEqual(["as-2"])
    // the edge crosses segments, so neither segment claims it
    expect(segments[0].edges).toHaveLength(0)
    expect(segments[1].edges).toHaveLength(0)
  })
})

describe("computeAgentConversationColumns", () => {
  it("puts fanned-out graders in the same column and merges their successor one column over", () => {
    const { nodes, edges } = graphPayload()
    const segment = splitAgentConversationSegments(nodes, edges)[0]
    const columns = computeAgentConversationColumns(segment.nodes, segment.edges)

    expect(columns.map((column) => column.map((n) => n.id))).toEqual([
      ["as-1"],
      ["dc-1", "dc-2"],
      ["as-2"]
    ])
  })
})

describe("agentConversationEdgeLabel", () => {
  const t = ((key: string, options?: Record<string, unknown>) => {
    const templates: Record<string, string> = {
      "conversation.edge_trigger_started": "{{trigger}} started this attempt",
      "conversation.edge_reviewer_replied": "{{reviewer}} replied {{verdict}}",
      "conversation.edge_check_passed": "{{check}} passed",
      "conversation.edge_check_failed": "{{check}} failed — repair requested",
      "conversation.edge_sent_for_check": "diff sent for grading",
      "conversation.edge_sent_for_review": "diff sent for review",
      "conversation.edge_default": "{{from}} → {{to}}"
    }
    let result = templates[key] ?? key
    for (const [k, v] of Object.entries(options ?? {})) result = result.replaceAll(`{{${k}}}`, String(v))
    return result
  }) as unknown as Parameters<typeof agentConversationEdgeLabel>[2]

  it("labels a failed grader edge as a repair request", () => {
    const grader = node({ id: "dc-1", kind: "deterministic_check", label: "rspec", state: "failed" })
    const implement = node({ id: "as-2", kind: "agent_session", label: "Implement" })
    expect(agentConversationEdgeLabel(grader, implement, t)).toBe("rspec failed — repair requested")
  })

  it("labels a passed grader edge", () => {
    const grader = node({ id: "dc-2", kind: "deterministic_check", label: "eslint", state: "succeeded" })
    const summarize = node({ id: "as-3", kind: "agent_session", label: "Summarize" })
    expect(agentConversationEdgeLabel(grader, summarize, t)).toBe("eslint passed")
  })

  it("labels a reviewer verdict edge using the reviewer's own submitted verdict", () => {
    const reviewer = node({ id: "as-2", kind: "agent_session", step_kind: "adversarial_review", label: "Adversarial review", detail: { verdict: "needs_work" } })
    const repair = node({ id: "as-3", kind: "agent_session", label: "Implement" })
    expect(agentConversationEdgeLabel(reviewer, repair, t)).toBe("Adversarial review replied needs_work")
  })

  it("labels an implement -> review edge as sent for review", () => {
    const implement = node({ id: "as-1", kind: "agent_session", step_kind: "implement", label: "Implement" })
    const reviewer = node({ id: "as-2", kind: "agent_session", step_kind: "adversarial_review", label: "Adversarial review" })
    expect(agentConversationEdgeLabel(implement, reviewer, t)).toBe("diff sent for review")
  })

  it("labels an external trigger edge with the trigger's own label", () => {
    const trigger = node({ id: "et-1", kind: "external_trigger", label: "PR feedback" })
    const respond = node({ id: "as-1", kind: "agent_session", label: "Address feedback" })
    expect(agentConversationEdgeLabel(trigger, respond, t)).toBe("PR feedback started this attempt")
  })

  it("falls back to a generic from/to description for unmatched edges", () => {
    const implement = node({ id: "as-1", kind: "agent_session", label: "Implement" })
    const summarize = node({ id: "as-2", kind: "agent_session", label: "Summarize" })
    expect(agentConversationEdgeLabel(implement, summarize, t)).toBe("Implement → Summarize")
  })
})

function renderTab(overrides: { prUrl?: string | null } = {}) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <AgentConversationTab externalPrUrl={null} jobId="7" prUrl={overrides.prUrl ?? "https://github.com/acme/widgets/pull/5"} />
    </QueryClientProvider>
  )
}

describe("AgentConversationTab", () => {
  it("renders the three node kinds, a derived trigger link, and opens a session transcript on click", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/7/agent_conversation") {
        return Promise.resolve(new Response(JSON.stringify(graphPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      if (path === "/api/v1/app/jobs/7/runs/10/artifacts") {
        return Promise.resolve(new Response(JSON.stringify({
          job_id: 7,
          workflow_id: 1,
          run_id: 10,
          base_ref: null,
          head_ref: null,
          agent_diff: null,
          agent_diff_bytes: 0,
          step_agent_diff: null,
          logs_count: 1,
          logs: [{ id: 1, sequence: 1, kind: "assistant_text", chunk: "implemented the fix" }]
        }), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    renderTab()

    await screen.findByText("PR feedback")
    expect(screen.getByText("Agent session")).toBeInTheDocument()
    expect(screen.getByText("Deterministic check")).toBeInTheDocument()
    expect(screen.getByText("External trigger")).toBeInTheDocument()

    const sourceLink = screen.getByRole("link", { name: "View source" })
    expect(sourceLink).toHaveAttribute("href", "https://github.com/acme/widgets/pull/5#issuecomment-99")

    expect(screen.getAllByText("Implement")).toHaveLength(2)
    expect(screen.getByText("rspec")).toBeInTheDocument()
    expect(screen.getByText("eslint")).toBeInTheDocument()

    fireEvent.click(screen.getAllByText("Implement")[0])

    await waitFor(() => expect(screen.getByText("implemented the fix")).toBeInTheDocument())
  })

  it("shows raw command output (no agent framing) when a deterministic check node is clicked", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path === "/api/v1/app/jobs/7/agent_conversation") {
        return Promise.resolve(new Response(JSON.stringify(graphPayload()), { status: 200, headers: { "Content-Type": "application/json" } }))
      }
      return Promise.resolve(new Response(JSON.stringify({}), { status: 200, headers: { "Content-Type": "application/json" } }))
    })

    renderTab()

    await screen.findByText("rspec")
    fireEvent.click(screen.getByText("rspec"))

    expect(await screen.findByText("bin/rspec")).toBeInTheDocument()
    expect(screen.getByText("1 example, 1 failure")).toBeInTheDocument()
  })

  it("renders an empty-state message when the job has no recorded agent activity", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(new Response(JSON.stringify({ job_id: 7, nodes: [], edges: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
    )

    renderTab()

    expect(await screen.findByText("No agent activity recorded for this Job yet.")).toBeInTheDocument()
  })
})
