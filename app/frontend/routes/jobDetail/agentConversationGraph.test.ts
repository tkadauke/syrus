import { describe, expect, it } from "vitest"
import type { AgentConversationEdge, AgentConversationNode } from "../../api/jobs"
import {
  avatarColorClass,
  buildConversationRows,
  connectorLabel,
  deterministicRawOutput,
  edgeLabel,
  externalTriggerContent,
  externalTriggerSourceUrl
} from "./agentConversationGraph"

function node(overrides: Partial<AgentConversationNode> = {}): AgentConversationNode {
  return {
    id: "agent_session-1",
    kind: "agent_session",
    workflow_id: 1,
    trigger_kind: "initial",
    step_id: 1,
    step_kind: "implement",
    label: "Implement",
    state: "succeeded",
    started_at: null,
    finished_at: null,
    agentic: true,
    summary: "Did the thing",
    detail: {},
    ...overrides
  }
}

describe("buildConversationRows", () => {
  it("gives every agent_session and external_trigger node its own row", () => {
    const nodes = [
      node({ id: "a", kind: "agent_session" }),
      node({ id: "b", kind: "external_trigger", trigger_kind: "pr_comment" })
    ]
    const rows = buildConversationRows(nodes, [])
    expect(rows).toEqual([[nodes[0]], [nodes[1]]])
  })

  it("groups adjacent deterministic_check nodes that share the same predecessor into one row", () => {
    const nodes = [
      node({ id: "implement-1", kind: "agent_session" }),
      node({ id: "grader-a", kind: "deterministic_check", step_kind: "grader", label: "rspec" }),
      node({ id: "grader-b", kind: "deterministic_check", step_kind: "grader", label: "eslint" }),
      node({ id: "summarize-1", kind: "agent_session" })
    ]
    const edges: AgentConversationEdge[] = [
      { from_id: "implement-1", to_id: "grader-a" },
      { from_id: "implement-1", to_id: "grader-b" },
      { from_id: "grader-a", to_id: "summarize-1" },
      { from_id: "grader-b", to_id: "summarize-1" }
    ]
    const rows = buildConversationRows(nodes, edges)
    expect(rows).toEqual([[nodes[0]], [nodes[1], nodes[2]], [nodes[3]]])
  })

  it("does not group deterministic_check nodes with different predecessors", () => {
    const nodes = [
      node({ id: "format-1", kind: "deterministic_check", step_kind: "format" }),
      node({ id: "generate-1", kind: "deterministic_check", step_kind: "generate" })
    ]
    const edges: AgentConversationEdge[] = [{ from_id: "format-1", to_id: "generate-1" }]
    const rows = buildConversationRows(nodes, edges)
    expect(rows).toEqual([[nodes[0]], [nodes[1]]])
  })

  it("does not group deterministic_check nodes that have no predecessors at all", () => {
    const nodes = [
      node({ id: "check-a", kind: "deterministic_check", step_kind: "grader" }),
      node({ id: "check-b", kind: "deterministic_check", step_kind: "grader" })
    ]
    const rows = buildConversationRows(nodes, [])
    expect(rows).toEqual([[nodes[0]], [nodes[1]]])
  })
})

describe("edgeLabel", () => {
  it("describes a deterministic_check failure handing off to a repair step", () => {
    const from = node({ id: "grader-1", kind: "deterministic_check", label: "rspec", state: "failed" })
    const to = node({ id: "landing_fix-1", kind: "agent_session", label: "Landing fix" })
    expect(edgeLabel(from, to)).toBe("rspec failed — Landing fix repair requested")
  })

  it("describes a passing deterministic_check handing off to the next step", () => {
    const from = node({ id: "grader-1", kind: "deterministic_check", label: "rspec", state: "succeeded" })
    const to = node({ id: "summarize-1", kind: "agent_session", label: "Summarize" })
    expect(edgeLabel(from, to)).toBe("rspec passed — Summarize started")
  })

  it("describes an agent_session verdict handing off to a repair step", () => {
    const from = node({ id: "review-1", kind: "agent_session", label: "Adversarial reviewer", detail: { verdict: "needs_work" } })
    const to = node({ id: "implement-2", kind: "agent_session", label: "Implement" })
    expect(edgeLabel(from, to)).toBe("Adversarial reviewer replied needs_work — Implement repair requested")
  })

  it("describes an external_trigger handing off to its first agent session", () => {
    const from = node({ id: "external_trigger-1", kind: "external_trigger", label: "PR feedback", summary: "PR comment from @alice" })
    const to = node({ id: "respond-1", kind: "agent_session", label: "Respond" })
    expect(edgeLabel(from, to)).toBe("PR comment from @alice — Respond started")
  })
})

describe("connectorLabel", () => {
  it("aggregates a fan-in row of deterministic checks into one connector", () => {
    const checks = [
      node({ id: "grader-a", kind: "deterministic_check", label: "rspec", state: "succeeded" }),
      node({ id: "grader-b", kind: "deterministic_check", label: "eslint", state: "failed" })
    ]
    const to = [node({ id: "landing_fix-1", kind: "agent_session", label: "Landing fix" })]
    expect(connectorLabel(checks, to)).toBe("1/2 checks passed — Landing fix repair requested")
  })

  it("summarizes a fan-out row starting from a single predecessor", () => {
    const from = [node({ id: "implement-1", kind: "agent_session", label: "Implement", state: "succeeded" })]
    const checks = [
      node({ id: "grader-a", kind: "deterministic_check", label: "rspec" }),
      node({ id: "grader-b", kind: "deterministic_check", label: "eslint" })
    ]
    expect(connectorLabel(from, checks)).toBe("Implement finished — 2 checks started")
  })
})

describe("avatarColorClass", () => {
  it("assigns a distinct color per known workflow role", () => {
    expect(avatarColorClass("workflow:implement")).toBe("bg-brand")
    expect(avatarColorClass("workflow:adversarial_reviewer")).toBe("bg-purple-500")
  })

  it("falls back to a neutral color for unknown roles", () => {
    expect(avatarColorClass("workflow:something_new")).toBe("bg-slate-500")
    expect(avatarColorClass(undefined)).toBe("bg-slate-500")
  })
})

describe("externalTriggerContent", () => {
  it("reads the latest PR comment body", () => {
    const trigger = node({
      kind: "external_trigger",
      trigger_kind: "pr_comment",
      summary: "PR comment from @alice",
      detail: { comments: [{ body: "first" }, { body: "please fix the header" }] }
    })
    expect(externalTriggerContent(trigger)).toBe("please fix the header")
  })

  it("reads chat feedback text", () => {
    const trigger = node({ kind: "external_trigger", trigger_kind: "chat_feedback", summary: "Chat feedback", detail: { feedback: "make it faster" } })
    expect(externalTriggerContent(trigger)).toBe("make it faster")
  })

  it("lists failing CI check names", () => {
    const trigger = node({
      kind: "external_trigger",
      trigger_kind: "ci_failure",
      summary: "CI failure",
      detail: { failed_checks: [{ name: "rspec" }, { name: "eslint" }] }
    })
    expect(externalTriggerContent(trigger)).toBe("Failing checks: rspec, eslint")
  })
})

describe("externalTriggerSourceUrl", () => {
  it("links pr_comment triggers to the job's PR", () => {
    const trigger = node({ kind: "external_trigger", trigger_kind: "pr_comment", detail: {} })
    expect(externalTriggerSourceUrl(trigger, "https://github.com/acme/widgets/pull/1")).toBe("https://github.com/acme/widgets/pull/1")
  })

  it("links ci_failure triggers to the first check with an html_url", () => {
    const trigger = node({
      kind: "external_trigger",
      trigger_kind: "ci_failure",
      detail: { failed_checks: [{ name: "rspec", html_url: null }, { name: "eslint", html_url: "https://github.com/acme/widgets/runs/2" }] }
    })
    expect(externalTriggerSourceUrl(trigger, null)).toBe("https://github.com/acme/widgets/runs/2")
  })

  it("has no source link for chat_feedback triggers", () => {
    const trigger = node({ kind: "external_trigger", trigger_kind: "chat_feedback", detail: {} })
    expect(externalTriggerSourceUrl(trigger, "https://github.com/acme/widgets/pull/1")).toBeNull()
  })
})

describe("deterministicRawOutput", () => {
  it("returns the grader's captured output excerpt", () => {
    const check = node({ kind: "deterministic_check", step_kind: "grader", detail: { output: "1 example, 0 failures" } })
    expect(deterministicRawOutput(check)).toBe("1 example, 0 failures")
  })

  it("falls back to format/generate failure command + output tail", () => {
    const check = node({
      kind: "deterministic_check",
      step_kind: "format",
      detail: { format_failures: [{ command: "rubocop -a", output_tail: "1 offense detected" }] }
    })
    expect(deterministicRawOutput(check)).toBe("$ rubocop -a\n1 offense detected")
  })

  it("returns null when there is nothing to show", () => {
    const check = node({ kind: "deterministic_check", step_kind: "format", detail: {} })
    expect(deterministicRawOutput(check)).toBeNull()
  })
})
