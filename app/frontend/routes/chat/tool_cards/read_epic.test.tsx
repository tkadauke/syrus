import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import readEpicToolCard from "./read_epic"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "read_epic",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

describe("read_epic tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(readEpicToolCard.toolName).toBe("read_epic")
  })

  it("summarizes the collapsed row with the canonical EPIC id and title", () => {
    const parsedResult = { epic: { id: 291, display_number: "the Tier 1 tool-card work", title: "Tier 1 Custom Tool Cards", state: "running" } }
    expect(readEpicToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("the Tier 1 tool-card work: Tier 1 Custom Tool Cards")
  })

  it("renders the canonical EPIC id, title, state, and repository", () => {
    const parsedResult = {
      epic: { id: 291, display_number: "the Tier 1 tool-card work", title: "Tier 1 Custom Tool Cards", state: "running", repository: "tkadauke/syrus" },
      child_jobs: []
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("the Tier 1 tool-card work")).toBeInTheDocument()
    expect(screen.getByText("Tier 1 Custom Tool Cards")).toBeInTheDocument()
    expect(screen.getByText("running")).toBeInTheDocument()
    expect(screen.getByText("tkadauke/syrus")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "the Tier 1 tool-card work" })).toHaveAttribute("href", "/epics/291")
    expect(screen.getByRole("button", { name: "Copy the Tier 1 tool-card work to clipboard" })).toBeInTheDocument()
  })

  it("renders dependency badges for depends-on and dependent Epics", () => {
    const parsedResult = {
      epic: {
        id: 291,
        display_number: "the Tier 1 tool-card work",
        title: "Tier 1 Custom Tool Cards",
        state: "running",
        depends_on_epics: [{ id: 288, display_number: "EPIC-58", title: "Extension point", state: "merged" }],
        dependent_epics: [{ id: 300, display_number: "EPIC-70", title: "Tier 2", state: "pending" }]
      },
      child_jobs: []
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Depends on")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-58" })).toHaveAttribute("href", "/epics/288")
    expect(screen.getByText(/merged/)).toBeInTheDocument()
    expect(screen.getByText("Dependents")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-70" })).toHaveAttribute("href", "/epics/300")
    expect(screen.getByText(/pending/)).toBeInTheDocument()
  })

  it("renders the child Job chain with a done/total progress count", () => {
    const parsedResult = {
      epic: { id: 291, display_number: "the Tier 1 tool-card work", title: "Tier 1 Custom Tool Cards", state: "running" },
      child_jobs: [
        {
          id: 319,
          issue_title: "Add extension point",
          state: "merged",
          depends_on_jobs: [
            {
              id: 318,
              state: "closed",
              satisfaction_mode: "deployment_stage",
              required_deployment_stage_name: "production",
              latest_deployment_stage: { name: "staging", label: "Staging" }
            }
          ]
        },
        { id: 320, issue_title: "Add core tool cards", state: "running" }
      ]
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByText("Child Jobs (1/2)")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-319" })).toHaveAttribute("href", "/jobs/319")
    expect(screen.getByRole("link", { name: "JOB-320" })).toHaveAttribute("href", "/jobs/320")
    expect(screen.getByText("Add extension point")).toBeVisible()
    expect(screen.getByText("Waits for")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-318" })).toHaveAttribute("href", "/jobs/318")
    expect(screen.getByText("· stage production · latest Staging")).toBeInTheDocument()
  })

  it("renders descriptions, provenance, lag, and all child Job details with links", () => {
    const parsedResult = {
      epic: {
        id: 291,
        display_number: "EPIC-291",
        title: "Detailed Epic",
        state: "running",
        repository: "tkadauke/syrus",
        github_issue_url: "https://github.com/tkadauke/syrus/issues/9",
        description: { text: "Epic **markdown** description", truncated: true, bytes: 40_000, omitted_bytes: 7_232 },
        auto_approve_mode: "after_review",
        goal_provenance: { chat_goal_id: 55, prompt_snapshot: { prompt: "Complete the **goal**" } },
        max_commits_behind_base: 7,
        furthest_behind_job: { id: 319, slug: "JOB-319" }
      },
      child_jobs: [
        {
          id: 319,
          issue_title: "Visible child title",
          issue_body: { text: "Child *markdown* body", truncated: true, bytes: 20_000, omitted_bytes: 3_616 },
          state: "closed",
          repository: "tkadauke/syrus",
          pr_number: 123,
          branch_name: "syrus/example",
          priority: "high",
          agent_provider: "codex",
          job_provider_setting: "inherit",
          closure_reason: "merged",
          landed_sha: "abcdef123456",
          depends_on_jobs: [{ unresolved_ref: "foundation-job", satisfaction_mode: "closed" }]
        }
      ]
    }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getAllByTestId("markdown-preview-content")[0]).toHaveTextContent("Epic markdown description")
    expect(screen.getAllByTestId("markdown-preview-content")[2]).toHaveTextContent("Child markdown body")
    expect(screen.getAllByText(/Source text was truncated/)).toHaveLength(2)
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus")
    expect(screen.getByRole("link", { name: "GitHub issue" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/issues/9")
    expect(screen.getByRole("link", { name: "CHAT-55" })).toHaveAttribute("href", "/chats/55")
    expect(screen.getByRole("link", { name: "PR #123" })).toHaveAttribute("href", "https://github.com/tkadauke/syrus/pull/123")
    expect(screen.getByText("syrus/example")).toBeInTheDocument()
    expect(screen.getByText("codex (inherit)")).toBeInTheDocument()
    expect(screen.getByText("merged")).toBeInTheDocument()
    expect(screen.getByText("abcdef123456")).toBeInTheDocument()
    expect(screen.getByText("foundation-job")).toBeVisible()
    expect(screen.getByText("7 commits")).toBeInTheDocument()
  })

  it("uses the shared normalizers for text and structured MCP envelopes and prefixed names", () => {
    const result = { epic: { id: 291, title: "Normalized", state: "running" }, child_jobs: [] }
    const textEnvelope = { content: [{ type: "text", text: JSON.stringify(result) }], structured_content: null }
    const structuredEnvelope = { content: [{ type: "text", text: "ignored" }], structured_content: result }

    expect(normalizedToolName("mcp__syrus-chat-sidecar__read_epic")).toBe("read_epic")
    expect(readEpicToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(textEnvelope) }))).toBe("EPIC-291: Normalized")
    expect(readEpicToolCard.collapsedSummary?.(context({ parsedResult: normalizedToolCardParsedResult(structuredEnvelope) }))).toBe("EPIC-291: Normalized")
  })

  it("renders error and pending cards", () => {
    const { rerender } = render(<>{readEpicToolCard.renderExpanded(context({ input: { id: 291 }, resultError: true, resultBody: "Epic not found" }))}</>)
    expect(screen.getByText("Epic not found")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-291" })).toHaveAttribute("href", "/epics/291")
    expect(readEpicToolCard.collapsedSummary?.(context({ input: { id: 291 }, resultError: true }))).toBe("Failed to read EPIC-291")

    rerender(<>{readEpicToolCard.renderExpanded(context({ input: { epic_id: 292 } }))}</>)
    expect(screen.getByText("Waiting for the Epic result.")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-292" })).toHaveAttribute("href", "/epics/292")
    expect(readEpicToolCard.collapsedSummary?.(context({ input: { epic_id: 292 } }))).toBe("Reading EPIC-292…")
  })

  it("omits optional sections when fields are missing", () => {
    const parsedResult = { epic: { id: 291, state: "running" } }

    render(<>{readEpicToolCard.renderExpanded(context({ parsedResult }))}</>)

    // Falls back to the canonical EPIC slug for both the header pill and the title when
    // display_number/title are absent, so it legitimately appears twice.
    expect(screen.getAllByText("EPIC-291")).toHaveLength(2)
    expect(screen.queryByText("Depends on")).not.toBeInTheDocument()
    expect(screen.getByText("Child Jobs (0/0)")).toBeInTheDocument()
    expect(screen.getByText("No child Jobs.")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload (missing epic object)", () => {
    expect(readEpicToolCard.collapsedSummary?.(context({ parsedResult: { oops: true } }))).toBeNull()
    expect(readEpicToolCard.renderExpanded(context({ parsedResult: { oops: true } }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    expect(readEpicToolCard.renderExpanded(context({ parsedResult: "not json", resultBody: "not json" }))).toBeNull()
  })
})
