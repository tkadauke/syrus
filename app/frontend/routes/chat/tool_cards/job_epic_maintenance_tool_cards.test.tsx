import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext, type ToolCardRenderer } from "@app/pluginToolCards"
import type { ChatPendingActionInline, ChatPendingActionState } from "@app/api/chats"
import approveJobCard from "./approve_job"
import cancelJobCard from "./cancel_job"
import { examples as cancelJobExamples } from "./cancel_job"
import closeJobSuccessfullyCard from "./close_job_successfully"
import { examples as closeJobSuccessfullyExamples } from "./close_job_successfully"
import setJobPriorityCard from "./set_job_priority"
import { examples as setJobPriorityExamples } from "./set_job_priority"
import updateJobCard from "./update_job"
import rebaseJobCard from "./rebase_job"
import { examples as rebaseJobExamples } from "./rebase_job"
import reopenJobCard from "./reopen_job"
import { examples as reopenJobExamples } from "./reopen_job"
import pollJobFeedbackCard from "./poll_job_feedback"
import { examples as pollJobFeedbackExamples } from "./poll_job_feedback"
import startEpicCard from "./start_epic"
import moveEpicToBacklogCard from "./move_epic_to_backlog"
import { examples as moveEpicToBacklogExamples } from "./move_epic_to_backlog"
import archiveEpicCard from "./archive_epic"
import { examples as archiveEpicExamples } from "./archive_epic"
import updateEpicCard from "./update_epic"
import addEpicDependencyCard from "./add_epic_dependency"
import { examples as addEpicDependencyExamples } from "./add_epic_dependency"
import removeEpicDependencyCard from "./remove_epic_dependency"
import { examples as removeEpicDependencyExamples } from "./remove_epic_dependency"
import addJobDependencyCard from "./add_job_dependency"
import { examples as addJobDependencyExamples } from "./add_job_dependency"
import removeJobDependencyCard from "./remove_job_dependency"
import { examples as removeJobDependencyExamples } from "./remove_job_dependency"
import unapproveJobCard from "./unapprove_job"
import removeJobFromEpicCard from "./remove_job_from_epic"
import { examples as removeJobFromEpicExamples } from "./remove_job_from_epic"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"

function context(toolName: string, overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName,
    input: {},
    resultBody: "",
    resultError: false,
    parsedResult: {},
    ...overrides
  }
}

function livePendingAction(id: number, state: ChatPendingActionState, overrides: Partial<ChatPendingActionInline> = {}): ChatPendingActionInline {
  return {
    id,
    state,
    action: "approve_job",
    label: "Approve Job",
    detail: null,
    app_confirm_path: `/pending_actions/${id}/confirm`,
    app_reject_path: `/pending_actions/${id}/reject`,
    ...overrides
  }
}

const CARDS: Array<[string, ToolCardRenderer]> = [
  ["approve_job", approveJobCard],
  ["cancel_job", cancelJobCard],
  ["close_job_successfully", closeJobSuccessfullyCard],
  ["set_job_priority", setJobPriorityCard],
  ["update_job", updateJobCard],
  ["rebase_job", rebaseJobCard],
  ["reopen_job", reopenJobCard],
  ["poll_job_feedback", pollJobFeedbackCard],
  ["start_epic", startEpicCard],
  ["move_epic_to_backlog", moveEpicToBacklogCard],
  ["archive_epic", archiveEpicCard],
  ["update_epic", updateEpicCard],
  ["add_epic_dependency", addEpicDependencyCard],
  ["remove_epic_dependency", removeEpicDependencyCard],
  ["add_job_dependency", addJobDependencyCard],
  ["remove_job_dependency", removeJobDependencyCard],
  ["unapprove_job", unapproveJobCard],
  ["remove_job_from_epic", removeJobFromEpicCard]
]

describe("Job and Epic maintenance tool cards", () => {
  it("registers under the exact MCP tool names", () => {
    expect(CARDS).toHaveLength(18)
    expect(new Set(CARDS.map(([name]) => name)).size).toBe(18)
  })

  it.each(CARDS)("%s registers under its exact MCP tool name", (name, card) => {
    expect(card.toolName).toBe(name)
  })

  it("lets the structured rebase card own the input reason", () => {
    expect(rebaseJobCard.argumentSummary?.({ job_id: 48, reason: "Refresh after **main** changed." })).toBe("")
  })

  it("renders a Job success acknowledgement with before and after state", () => {
    const parsedResult = { job_id: 42, previous_state: "implemented", new_state: "approved" }

    expect(approveJobCard.collapsedSummary?.(context("approve_job", { parsedResult }))).toBe("Approved · JOB-42")
    render(<>{approveJobCard.renderExpanded(context("approve_job", { parsedResult }))}</>)

    expect(screen.getByText("Approve Job")).toBeInTheDocument()
    expect(screen.getByText("JOB-42")).toBeInTheDocument()
    expect(screen.getByText("implemented")).toBeInTheDocument()
    expect(screen.getAllByText("approved").length).toBeGreaterThan(0)
  })

  it("renders validation failure details without requiring JSON success fields", () => {
    const ctx = context("approve_job", {
      input: { job_id: 42 },
      resultError: true,
      resultBody: JSON.stringify({ error: "job must be in implemented state" }),
      parsedResult: { error: "job must be in implemented state" }
    })

    expect(approveJobCard.collapsedSummary?.(ctx)).toBe("Approve Job failed · JOB-42")
    render(<>{approveJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("job must be in implemented state")).toBeInTheDocument()
  })

  it("renders pending confirmation state with the target Job id from input", () => {
    const ctx = context("cancel_job", {
      input: { job_id: 44 },
      parsedResult: {
        pending_confirmation_id: 7,
        pending_action_id: 7,
        state: "pending",
        message: "Job cancellation requires operator confirmation."
      }
    })

    expect(cancelJobCard.collapsedSummary?.(ctx)).toBe("Cancel requested · JOB-44 · pending #7")
    render(<>{cancelJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("pending")).toBeInTheDocument()
    expect(screen.getByText("pending #7")).toBeInTheDocument()
    expect(screen.getByText("JOB-44")).toBeInTheDocument()
  })

  it("recovers the cancellation target from a normalized result when collapsed dispatch omits input", () => {
    const ctx = toolCardContextForExample("cancel_job", cancelJobExamples[0])

    expect(ctx.input).toBeUndefined()
    expect(cancelJobCard.collapsedSummary?.(ctx)).toBe("Cancel requested · JOB-44 · pending #27")
    render(<>{cancelJobCard.renderExpanded(ctx)}</>)

    const targetLinks = screen.getAllByRole("link", { name: "JOB-44" })
    expect(targetLinks.length).toBeGreaterThan(0)
    expect(targetLinks.every((link) => link.getAttribute("href") === "/jobs/44")).toBe(true)
  })

  it("links every Job in a normalized bulk cancellation result", () => {
    const ctx = toolCardContextForExample("cancel_job", cancelJobExamples[1])

    expect(cancelJobCard.collapsedSummary?.(ctx)).toBe("Cancel requested · 3 JOBs · pending group #8")
    render(<>{cancelJobCard.renderExpanded(ctx)}</>)

    for (const id of [44, 45, 46]) {
      expect(screen.getByRole("link", { name: `JOB-${id}` })).toHaveAttribute("href", `/jobs/${id}`)
    }
  })

  it.each([
    ["confirmed", "Cancelled · JOB-44", "cancelled"],
    ["cancelled", "Cancel Job cancelled · JOB-44", null],
    ["rejected", "Cancel Job rejected · JOB-44", null]
  ] as const)("renders a live %s cancellation outcome", (state, summary, subjectState) => {
    const pending = toolCardContextForExample("cancel_job", cancelJobExamples[0])
    const ctx = { ...pending, livePendingAction: livePendingAction(27, state) }

    expect(cancelJobCard.collapsedSummary?.(ctx)).toBe(summary)
    render(<>{cancelJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText(state)).toBeInTheDocument()
    if (subjectState) {
      expect(screen.getByText("Job state")).toBeInTheDocument()
      expect(screen.getByText(subjectState)).toBeInTheDocument()
    } else {
      expect(screen.queryByText("Job state")).not.toBeInTheDocument()
    }
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(reopenJobExamples[0].parsedResult) }] }],
    ["structured content", { structured_content: reopenJobExamples[0].parsedResult }]
  ] as const)("recovers and links the reopen target from normalized %s without input", (_label, envelope) => {
    const ctx = toolCardContextForExample(normalizedToolName("mcp__syrus-chat-sidecar__reopen_job"), {
      ...reopenJobExamples[0],
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(ctx.input).toBeUndefined()
    expect(reopenJobCard.collapsedSummary?.(ctx)).toBe("Reopen requested · JOB-71 · pending #35")
    render(<>{reopenJobCard.renderExpanded(ctx)}</>)

    expect(screen.getAllByRole("link", { name: "JOB-71" }).every((link) => link.getAttribute("href") === "/jobs/71")).toBe(true)
  })

  it("links every Job in a bulk reopen request", () => {
    const ctx = toolCardContextForExample("reopen_job", reopenJobExamples[1])

    expect(reopenJobCard.collapsedSummary?.(ctx)).toBe("Reopen requested · 3 JOBs · pending group #12")
    render(<>{reopenJobCard.renderExpanded(ctx)}</>)

    for (const id of [71, 72, 73]) {
      expect(screen.getByRole("link", { name: `JOB-${id}` })).toHaveAttribute("href", `/jobs/${id}`)
    }
  })

  it.each([
    ["confirmed", "Reopened · JOB-71", "triaging"],
    ["rejected", "Reopen Job rejected · JOB-71", null]
  ] as const)("renders the live %s reopen outcome", (state, summary, subjectState) => {
    const pending = toolCardContextForExample("reopen_job", reopenJobExamples[0])
    const ctx = {
      ...pending,
      livePendingAction: livePendingAction(35, state, {
        action: "reopen_job",
        label: "Reopen JOB-71",
        resource_title: "Restore the closed work",
        resource_url: "/jobs/71"
      })
    }

    expect(reopenJobCard.collapsedSummary?.(ctx)).toBe(summary)
    render(<>{reopenJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText(state)).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "JOB-71" }).every((link) => link.getAttribute("href") === "/jobs/71")).toBe(true)
    if (subjectState) {
      expect(screen.getByText("Job state")).toBeInTheDocument()
      expect(screen.getByText(subjectState)).toBeInTheDocument()
    } else {
      expect(screen.queryByText("Job state")).not.toBeInTheDocument()
    }
  })

  it("renders reopen errors with input context", () => {
    const ctx = toolCardContextForExample("reopen_job", reopenJobExamples[2])

    expect(reopenJobCard.collapsedSummary?.(ctx)).toBe("Job reopen failed: Error: JOB-74 is not closed.")
    render(<>{reopenJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("Error: JOB-74 is not closed.")).toBeInTheDocument()
    expect(screen.getByText("Reopen JOB-74")).toBeInTheDocument()
    expect(screen.getByText("JOB-74")).toBeInTheDocument()
  })

  it("renders canceled and rejected pending action acknowledgements", () => {
    const canceled = context("rebase_job", {
      input: { job_id: 45 },
      parsedResult: { pending_action_id: 8, state: "canceled", message: "Rebase canceled by operator." }
    })
    const rejected = context("poll_job_feedback", {
      input: { job_id: 46 },
      parsedResult: { pending_action_id: 9, state: "rejected", message: "Feedback poll rejected." }
    })

    render(
      <>
        {rebaseJobCard.renderExpanded(canceled)}
        {pollJobFeedbackCard.renderExpanded(rejected)}
      </>
    )

    expect(screen.getByText("canceled")).toBeInTheDocument()
    expect(screen.getByText("Rebase canceled by operator.")).toBeInTheDocument()
    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Feedback poll rejected.")).toBeInTheDocument()
    expect(screen.queryByText("pending #8")).not.toBeInTheDocument()
    expect(screen.queryByText("pending #9")).not.toBeInTheDocument()
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(pollJobFeedbackExamples[0].parsedResult) }] }, 46],
    ["structured content", { structured_content: pollJobFeedbackExamples[1].parsedResult }, 47]
  ] as const)("renders a linked pending feedback poll from normalized %s without relying on input", (_label, envelope, jobId) => {
    const ctx = toolCardContextForExample(normalizedToolName("mcp__syrus-chat-sidecar__poll_job_feedback"), {
      ...pollJobFeedbackExamples[1],
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(pollJobFeedbackCard.collapsedSummary?.(ctx)).toBe(`Feedback poll requested · JOB-${jobId} · pending #${jobId === 46 ? 29 : 30}`)
    render(<>{pollJobFeedbackCard.renderExpanded(ctx)}</>)

    expect(screen.getAllByRole("link", { name: `JOB-${jobId}` }).every((link) => link.getAttribute("href") === `/jobs/${jobId}`)).toBe(true)
  })

  it("renders the live feedback-poll outcome, linked resource, PR, and execution failure", () => {
    const pending = toolCardContextForExample("poll_job_feedback", pollJobFeedbackExamples[0])
    const confirmed = toolCardContextForExample("poll_job_feedback", pollJobFeedbackExamples[2])

    expect(pollJobFeedbackCard.collapsedSummary?.(confirmed)).toBe("Feedback poll queued · JOB-46")
    const { unmount } = render(<>{pollJobFeedbackCard.renderExpanded(confirmed)}</>)
    expect(screen.getAllByRole("link", { name: "JOB-46" }).some((link) => link.getAttribute("href") === "/jobs/46")).toBe(true)
    expect(screen.getByRole("link", { name: "PR #321" })).toHaveAttribute("href", "https://github.com/acme/widgets/pull/321")
    expect(screen.getByText("succeeded")).toBeInTheDocument()
    expect(screen.getByText("Queueing PR feedback poll...")).toBeInTheDocument()
    unmount()

    const failed = {
      ...pending,
      livePendingAction: livePendingAction(29, "failed", {
        action: "poll_job_feedback",
        label: "Poll PR feedback",
        execution_status: "failed",
        execution_error: "GitHub is temporarily unavailable."
      })
    }
    expect(pollJobFeedbackCard.collapsedSummary?.(failed)).toBe("Poll Job Feedback failed · JOB-46")
    render(<>{pollJobFeedbackCard.renderExpanded(failed)}</>)
    expect(screen.getByText("GitHub is temporarily unavailable.")).toBeInTheDocument()
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(rebaseJobExamples[0].parsedResult) }] }],
    ["structured content", { structured_content: rebaseJobExamples[0].parsedResult }]
  ] as const)("renders a pending rebase and Markdown reason from normalized %s", (_label, envelope) => {
    const example = rebaseJobExamples[0]
    const ctx = toolCardContextForExample(normalizedToolName("mcp__syrus-chat-sidecar__rebase_job"), {
      ...example,
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(rebaseJobCard.collapsedSummary?.(ctx)).toBe("Rebase requested · JOB-48 · pending #32")
    render(<>{rebaseJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByRole("link", { name: "JOB-48" })).toHaveAttribute("href", "/jobs/48")
    expect(screen.getByText("Reason")).toBeInTheDocument()
    expect(screen.getByText("main").tagName).toBe("STRONG")
  })

  it("falls back to the input reason when a rebase call errors", () => {
    const ctx = toolCardContextForExample("rebase_job", rebaseJobExamples[1])

    expect(rebaseJobCard.collapsedSummary?.(ctx)).toBe("Rebase Job failed · JOB-49")
    render(<>{rebaseJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("A rebase is already in progress.")).toBeInTheDocument()
    expect(screen.getByText("Retry after the dependency landed.")).toBeInTheDocument()
  })

  it("expands a long rebase reason instead of truncating it as a detail row", () => {
    const ctx = toolCardContextForExample("rebase_job", rebaseJobExamples[2])

    render(<>{rebaseJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("main").tagName).toBe("STRONG")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("shows the live rebase execution outcome and links its resulting workflow", () => {
    const pending = toolCardContextForExample("rebase_job", rebaseJobExamples[0])
    const ctx = {
      ...pending,
      livePendingAction: livePendingAction(32, "confirmed", {
        action: "rebase_job",
        label: "Rebase JOB-48",
        reason: "Refresh the branch after **main** changed.",
        execution_status: "applied",
        execution_step: "Applied.",
        resource_title: "Refresh the feature branch",
        resource_url: "/jobs/48",
        after_snapshot: { jobs: [{ id: 48, workflow: { id: 801, trigger_kind: "rebase", state: "running" } }] }
      })
    }

    expect(rebaseJobCard.collapsedSummary?.(ctx)).toBe("Rebase requested · JOB-48")
    render(<>{rebaseJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("applied")).toBeInTheDocument()
    expect(screen.getByText("Applied.")).toBeInTheDocument()
    expect(screen.getByText("Job rebase requires operator confirmation.")).toBeInTheDocument()
    expect(screen.getAllByText(/Refresh the branch after/)).toHaveLength(1)
    expect(screen.getByRole("link", { name: "WF-801" })).toHaveAttribute("href", "/jobs/48?tab=workflows#workflow-801")
  })

  it("shows a live rebase execution failure without hiding the requested reason", () => {
    const pending = toolCardContextForExample("rebase_job", rebaseJobExamples[0])
    const ctx = {
      ...pending,
      livePendingAction: livePendingAction(32, "failed", {
        action: "rebase_job",
        execution_status: "failed",
        execution_error: "ArgumentError: No PR on this Job to rebase."
      })
    }

    expect(rebaseJobCard.collapsedSummary?.(ctx)).toBe("Rebase Job failed · JOB-48")
    render(<>{rebaseJobCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("ArgumentError: No PR on this Job to rebase.")).toBeInTheDocument()
    expect(screen.getByText(/Refresh the branch after/)).toBeInTheDocument()
  })

  it("renders dependency add and remove details for Job and Epic targets", () => {
    const addJob = context("add_job_dependency", {
      input: { job_id: 50, depends_on_job_id: 49, satisfaction_mode: "deployment_stage", required_deployment_stage_name: "production" },
      parsedResult: { job_id: 50, depends_on_job_ids: [49], depends_on_epic_ids: [12] }
    })
    const removeEpic = context("remove_epic_dependency", {
      input: { epic_id: 20, depends_on_epic_id: 19 },
      parsedResult: { epic_id: 20, depends_on: [18] }
    })

    expect(addJobDependencyCard.collapsedSummary?.(addJob)).toBe("Dependency added · JOB-50")
    render(
      <>
        {addJobDependencyCard.renderExpanded(addJob)}
        {removeEpicDependencyCard.renderExpanded(removeEpic)}
      </>
    )

    expect(screen.getAllByText("JOB-49").length).toBeGreaterThan(0)
    expect(screen.getByText("deployment_stage")).toBeInTheDocument()
    expect(screen.getByText("production")).toBeInTheDocument()
    expect(screen.getAllByText("Current dependencies").length).toBeGreaterThan(0)
    expect(screen.getByText("EPIC-12")).toBeInTheDocument()
    expect(screen.getByText("EPIC-19")).toBeInTheDocument()
    expect(screen.getByText("EPIC-18")).toBeInTheDocument()
  })

  it("renders linked per-dependency satisfaction details from a normalized add Job dependency example", () => {
    const ctx = toolCardContextForExample("add_job_dependency", addJobDependencyExamples[0])

    render(<>{addJobDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getAllByRole("link", { name: "JOB-49" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "JOB-49" }).every((link) => link.getAttribute("href") === "/jobs/49")).toBe(true)
    expect(screen.getAllByRole("link", { name: "EPIC-12" })).toHaveLength(1)
    expect(screen.getByRole("link", { name: "EPIC-12" })).toHaveAttribute("href", "/epics/12")
    expect(screen.queryByRole("link", { name: "EPIC-102" })).not.toBeInTheDocument()
    expect(screen.getByText("· success")).toBeInTheDocument()
    expect(screen.getByText("· deployment_stage")).toBeInTheDocument()
    expect(screen.getByText("· stage production")).toBeInTheDocument()
  })

  it("renders add Job dependency plain-text errors from a normalized example", () => {
    const ctx = toolCardContextForExample("add_job_dependency", addJobDependencyExamples[1])

    expect(addJobDependencyCard.collapsedSummary?.(ctx)).toBe("Add Job Dependency failed · JOB-50")
    render(<>{addJobDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: Job cannot depend on itself")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "JOB-50" }).every((link) => link.getAttribute("href") === "/jobs/50")).toBe(true)
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(removeJobDependencyExamples[0].parsedResult) }] }],
    ["structured content", { structured_content: removeJobDependencyExamples[0].parsedResult }]
  ] as const)("renders the removed Job and remaining dependencies from normalized %s", (_label, envelope) => {
    const example = removeJobDependencyExamples[0]
    const ctx = toolCardContextForExample(normalizedToolName("mcp__syrus-chat-sidecar__remove_job_dependency"), {
      ...example,
      input: { ...example.input, satisfaction_mode: "deployment_stage" },
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(removeJobDependencyCard.collapsedSummary?.(ctx)).toBe("Dependency removed · JOB-50")
    render(<>{removeJobDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("Removed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-49" })).toHaveAttribute("href", "/jobs/49")
    expect(screen.getByText("Current dependencies")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-48" })).toHaveAttribute("href", "/jobs/48")
    expect(screen.getByRole("link", { name: "EPIC-12" })).toHaveAttribute("href", "/epics/12")
    expect(screen.queryByText("Satisfaction")).not.toBeInTheDocument()
    expect(screen.queryByText("deployment_stage")).not.toBeInTheDocument()
  })

  it("renders the removed Epic and an explicit empty remaining dependency state", () => {
    const ctx = toolCardContextForExample("remove_job_dependency", removeJobDependencyExamples[1])

    render(<>{removeJobDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("Removed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-12" })).toHaveAttribute("href", "/epics/12")
    expect(screen.getByText("No dependencies")).toBeInTheDocument()
    expect(screen.queryByText("No current dependencies")).not.toBeInTheDocument()
  })

  it("renders remove Job dependency errors with linked input context", () => {
    const ctx = toolCardContextForExample("remove_job_dependency", removeJobDependencyExamples[2])

    expect(removeJobDependencyCard.collapsedSummary?.(ctx)).toBe("Remove Job Dependency failed · JOB-50")
    render(<>{removeJobDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: Job dependency does not exist")).toBeInTheDocument()
    expect(screen.getByText("Removed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-49" })).toHaveAttribute("href", "/jobs/49")
  })

  it("renders an explicit empty state from a normalized add Job dependency example", () => {
    const ctx = toolCardContextForExample("add_job_dependency", addJobDependencyExamples[2])

    render(<>{addJobDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("Current dependencies")).toBeInTheDocument()
    expect(screen.getByText("No current dependencies")).toBeInTheDocument()
  })

  it("renders the added Epic as a linked and marked current dependency from a normalized example", () => {
    const example = addEpicDependencyExamples[0]
    const ctx = toolCardContextForExample("add_epic_dependency", example)

    render(<>{addEpicDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getAllByRole("link", { name: "EPIC-41" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "EPIC-41" }).every((link) => link.getAttribute("href") === "/epics/41")).toBe(true)
    expect(screen.getByText("added")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-40" })).toHaveAttribute("href", "/epics/40")
  })

  it("renders add Epic dependency plain-text errors from a normalized example", () => {
    const example = addEpicDependencyExamples[1]
    const ctx = toolCardContextForExample("add_epic_dependency", example)

    expect(addEpicDependencyCard.collapsedSummary?.(ctx)).toBe("Add Epic Dependency failed · EPIC-42")
    render(<>{addEpicDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: Epic cannot depend on itself")).toBeInTheDocument()
    expect(screen.getAllByRole("link", { name: "EPIC-42" }).every((link) => link.getAttribute("href") === "/epics/42")).toBe(true)
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(removeEpicDependencyExamples[0].parsedResult) }] }],
    ["structured content", { structured_content: removeEpicDependencyExamples[0].parsedResult }]
  ] as const)("renders the removed Epic and remaining dependencies from normalized %s", (_label, envelope) => {
    const example = removeEpicDependencyExamples[0]
    const ctx = toolCardContextForExample(normalizedToolName("mcp__syrus-chat-sidecar__remove_epic_dependency"), {
      ...example,
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(removeEpicDependencyCard.collapsedSummary?.(ctx)).toBe("Dependency removed · EPIC-42")
    render(<>{removeEpicDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("Removed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-41" })).toHaveAttribute("href", "/epics/41")
    expect(screen.getByText("Current dependencies")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-40" })).toHaveAttribute("href", "/epics/40")
  })

  it("renders an explicit empty remaining dependency state", () => {
    const ctx = toolCardContextForExample("remove_epic_dependency", removeEpicDependencyExamples[1])

    render(<>{removeEpicDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("Removed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-41" })).toHaveAttribute("href", "/epics/41")
    expect(screen.getByText("No dependencies")).toBeInTheDocument()
    expect(screen.queryByText("No current dependencies")).not.toBeInTheDocument()
  })

  it("renders remove Epic dependency errors with linked input context", () => {
    const ctx = toolCardContextForExample("remove_epic_dependency", removeEpicDependencyExamples[2])

    expect(removeEpicDependencyCard.collapsedSummary?.(ctx)).toBe("Remove Epic Dependency failed · EPIC-42")
    render(<>{removeEpicDependencyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: Epic dependency does not exist")).toBeInTheDocument()
    expect(screen.getByText("Removed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-41" })).toHaveAttribute("href", "/epics/41")
  })

  it.each([
    [
      "content text",
      { content: [{ type: "text", text: JSON.stringify(setJobPriorityExamples[0].parsedResult) }] },
      "mcp__syrus-chat-sidecar__set_job_priority"
    ],
    ["structured content", { structured_content: setJobPriorityExamples[0].parsedResult }, "set_job_priority"]
  ] as const)("renders priority changes with linked targets and toned pills from normalized %s", (_label, envelope, toolName) => {
    const ctx = toolCardContextForExample(normalizedToolName(toolName), {
      ...setJobPriorityExamples[0],
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(setJobPriorityCard.collapsedSummary?.(ctx)).toBe("Priority changed · JOB-51")
    render(<>{setJobPriorityCard.renderExpanded(ctx)}</>)

    expect(screen.getByRole("link", { name: "JOB-51" })).toHaveAttribute("href", "/jobs/51")
    expect(screen.getByText("Priority")).toBeInTheDocument()
    expect(screen.getByLabelText("medium to urgent")).toBeInTheDocument()
    expect(screen.getByText("→")).toBeInTheDocument()
    expect(screen.queryByText("Previous priority")).not.toBeInTheDocument()
    expect(screen.queryByText("New priority")).not.toBeInTheDocument()
  })

  it("renders the requested priority when validation fails", () => {
    const ctx = toolCardContextForExample("set_job_priority", setJobPriorityExamples[1])

    expect(setJobPriorityCard.collapsedSummary?.(ctx)).toBe("Set Job Priority failed · JOB-51")
    render(<>{setJobPriorityCard.renderExpanded(ctx)}</>)

    expect(screen.getByRole("link", { name: "JOB-51" })).toHaveAttribute("href", "/jobs/51")
    expect(screen.getByText("Requested priority")).toBeInTheDocument()
    expect(screen.getByText("immediate")).toBeInTheDocument()
    expect(screen.getByText("Error: priority must be urgent, high, medium, or low")).toBeInTheDocument()
  })

  it("renders approval and unapproval acknowledgements", () => {
    const approve = context("approve_job", { parsedResult: { job_id: 52, previous_state: "implemented", new_state: "approved" } })
    const unapprove = context("unapprove_job", { parsedResult: { job_id: 52, previous_state: "approved", new_state: "implemented" } })

    render(
      <>
        {approveJobCard.renderExpanded(approve)}
        {unapproveJobCard.renderExpanded(unapprove)}
      </>
    )

    expect(screen.getByText("Approve Job")).toBeInTheDocument()
    expect(screen.getByText("Unapprove Job")).toBeInTheDocument()
    expect(screen.getAllByText("JOB-52")).toHaveLength(2)
  })

  it("describes grouped approval changes as requests when no transition occurred", () => {
    const approve = context("approve_job", {
      input: { job_ids: [53, 54, 55] },
      parsedResult: { pending_action_group_id: 5, pending_action_id: 18, state: "pending", member_count: 3, message: "Approve 3 Jobs?" }
    })
    const unapprove = context("unapprove_job", {
      input: { job_ids: [56, 57] },
      parsedResult: { pending_action_group_id: 6, pending_action_id: 19, state: "rejected", member_count: 2, message: "Unapprove 2 Jobs?" }
    })

    expect(approveJobCard.collapsedSummary?.(approve)).toBe("Approval requested · 3 JOBs · pending group #5")
    expect(unapproveJobCard.collapsedSummary?.(unapprove)).toBe("Unapprove Job rejected · 2 JOBs")
  })

  it.each([
    ["rejected", "Approve Job rejected · 2 JOBs"],
    ["cancelled", "Approve Job cancelled · 2 JOBs"],
    ["failed", "Approve Job failed · 2 JOBs"]
  ] as const)("uses the terminal live %s outcome in the collapsed summary", (state, summary) => {
    const ctx = context("approve_job", {
      input: { job_ids: [53, 54] },
      parsedResult: {
        pending_action_group_id: 5,
        pending_action_id: 18,
        state: "pending",
        member_count: 2,
        message: "Approve 2 Jobs?"
      },
      livePendingAction: livePendingAction(18, state)
    })

    expect(approveJobCard.collapsedSummary?.(ctx)).toBe(summary)
  })

  it("does not show a frozen pending result's new state before live execution", () => {
    const pending = context("approve_job", {
      input: { job_id: 53 },
      parsedResult: { pending_action_id: 18, state: "pending", previous_state: "implemented", new_state: "approved" },
      livePendingAction: livePendingAction(18, "pending")
    })
    const confirmed = { ...pending, livePendingAction: livePendingAction(18, "confirmed") }

    render(<>{approveJobCard.renderExpanded(pending)}</>)
    expect(screen.queryByText("After")).not.toBeInTheDocument()

    render(<>{approveJobCard.renderExpanded(confirmed)}</>)
    expect(screen.getByText("After")).toBeInTheDocument()
  })

  it("renders archive, backlog, and start Epic transitions", () => {
    render(
      <>
        {startEpicCard.renderExpanded(context("start_epic", { parsedResult: { epic_id: 60, previous_state: "ready", new_state: "in_progress" } }))}
        {moveEpicToBacklogCard.renderExpanded(
          context("move_epic_to_backlog", { parsedResult: { epic_id: 61, previous_state: "ready", new_state: "backlog" } })
        )}
        {archiveEpicCard.renderExpanded(
          context("archive_epic", {
            input: { epic_id: 62 },
            parsedResult: {
              pending_action_id: 17,
              pending_confirmation_id: 17,
              state: "pending",
              message: "Archive EPIC-62? Open child Jobs will be cancelled and closed when confirmed."
            }
          })
        )}
      </>
    )

    expect(screen.getByText("EPIC-60")).toBeInTheDocument()
    expect(screen.getByText("in progress")).toBeInTheDocument()
    expect(screen.getByText("EPIC-61")).toBeInTheDocument()
    expect(screen.getAllByText("backlog").length).toBeGreaterThan(0)
    expect(screen.getAllByRole("link", { name: "EPIC-62" })).toHaveLength(2)
    expect(screen.getAllByRole("link", { name: "EPIC-62" }).every((link) => link.getAttribute("href") === "/epics/62")).toBe(true)
    expect(screen.getByText("pending #17")).toBeInTheDocument()
    expect(screen.getByRole("alert")).toHaveTextContent("Open child Jobs will be cancelled and closed when confirmed.")
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify({ epic_id: 61, previous_state: "ready", new_state: "backlog" }) }] }],
    ["structured content", { structured_content: { epic_id: 61, previous_state: "ready", new_state: "backlog" } }]
  ])("renders move-to-backlog details from a normalized %s envelope", (_label, envelope) => {
    const example = moveEpicToBacklogExamples[0]
    const ctx = toolCardContextForExample(normalizedToolName("mcp__syrus-chat-sidecar__move_epic_to_backlog"), {
      ...example,
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(ctx.toolName).toBe("move_epic_to_backlog")
    expect(moveEpicToBacklogCard.collapsedSummary?.(ctx)).toBe("Moved to backlog · EPIC-61")
    render(<>{moveEpicToBacklogCard.renderExpanded(ctx)}</>)

    expect(screen.getByRole("link", { name: "EPIC-61" })).toHaveAttribute("href", "/epics/61")
    expect(screen.getByText("Improve maintenance cards")).toBeInTheDocument()
    expect(screen.getByText("ready").parentElement).toHaveClass("uppercase")
    expect(screen.getAllByText("backlog").some((node) => node.parentElement?.classList.contains("uppercase"))).toBe(true)
  })

  it("renders a clear plain-text error for an Epic that cannot move", () => {
    const ctx = toolCardContextForExample("move_epic_to_backlog", moveEpicToBacklogExamples[1])

    expect(moveEpicToBacklogCard.collapsedSummary?.(ctx)).toBe("Move Epic To Backlog failed · EPIC-62")
    render(<>{moveEpicToBacklogCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByTestId("markdown-preview-content")).not.toHaveStyle({ overflow: "hidden" })
    expect(screen.getByText("Error: Epic cannot be moved to backlog from completed")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-62" })).toHaveAttribute("href", "/epics/62")
    expect(screen.getByText("Already completed Epic")).toBeInTheDocument()
  })

  it("renders archive Epic pending and error envelopes through the normalizer", () => {
    const pending = toolCardContextForExample("archive_epic", archiveEpicExamples[0])
    const failure = toolCardContextForExample("archive_epic", archiveEpicExamples[1])

    expect(archiveEpicCard.collapsedSummary?.(pending)).toBe("Archive requested · EPIC-62 · pending #17")
    expect(archiveEpicCard.collapsedSummary?.(failure)).toBe("Archive Epic failed · EPIC-62")

    render(
      <>
        {archiveEpicCard.renderExpanded(pending)}
        {archiveEpicCard.renderExpanded(failure)}
      </>
    )

    expect(screen.getByRole("alert")).toHaveClass("border-warning-border", "bg-warning-surface")
    expect(screen.getAllByRole("link", { name: "EPIC-62" })).toHaveLength(3)
    expect(screen.getByText("Error: epic is already archived")).toBeInTheDocument()
  })

  it("uses the live confirmation to show the Epic as archived", () => {
    const pending = toolCardContextForExample("archive_epic", archiveEpicExamples[0])
    const confirmed = { ...pending, livePendingAction: livePendingAction(17, "confirmed") }

    expect(archiveEpicCard.collapsedSummary?.(confirmed)).toBe("Archived · EPIC-62")
    render(<>{archiveEpicCard.renderExpanded(confirmed)}</>)

    expect(screen.getByText("confirmed")).toBeInTheDocument()
    expect(screen.getByText("Epic state")).toBeInTheDocument()
    expect(screen.getByText("archived")).toBeInTheDocument()
    expect(screen.queryByRole("alert")).not.toBeInTheDocument()
  })

  it("renders long archive warnings as expandable Markdown", () => {
    const warning = `Archive **EPIC-62**? ${"Open child Jobs will be cancelled and closed when confirmed. ".repeat(8)}`
    const ctx = context("archive_epic", {
      input: { epic_id: 62 },
      parsedResult: { pending_action_id: 17, state: "pending", message: warning }
    })

    render(<>{archiveEpicCard.renderExpanded(ctx)}</>)

    expect(screen.getByRole("alert").querySelector("strong")).toHaveTextContent("EPIC-62")
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
  })

  it("renders update metadata", () => {
    render(
      <>
        {updateJobCard.renderExpanded(context("update_job", { parsedResult: { job_id: 70, title: "New title", description: "New body", state: "open" } }))}
        {updateEpicCard.renderExpanded(context("update_epic", { parsedResult: { epic_id: 71, title: "New Epic", state: "ready" } }))}
      </>
    )

    expect(screen.getByText("New title")).toBeInTheDocument()
    expect(screen.getByText("New Epic")).toBeInTheDocument()
  })

  it.each([
    ["content text", { content: [{ type: "text", text: JSON.stringify(removeJobFromEpicExamples[0].parsedResult) }] }],
    ["structured content", { structured_content: removeJobFromEpicExamples[0].parsedResult }]
  ] as const)("renders the linked source Epic and title from a normalized %s envelope", (_label, envelope) => {
    const example = removeJobFromEpicExamples[0]
    const ctx = toolCardContextForExample(normalizedToolName("mcp__syrus-chat-sidecar__remove_job_from_epic"), {
      ...example,
      parsedResult: normalizedToolCardParsedResult(envelope)
    })

    expect(removeJobFromEpicCard.collapsedSummary?.(ctx)).toBe("Removed from Epic · JOB-72")
    render(<>{removeJobFromEpicCard.renderExpanded(ctx)}</>)

    expect(screen.getByRole("link", { name: "JOB-72" })).toHaveAttribute("href", "/jobs/72")
    expect(screen.getByText("Removed from")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "EPIC-73" })).toHaveAttribute("href", "/epics/73")
    expect(screen.getByText("Old Epic")).toBeInTheDocument()
  })

  it("renders the plain-text membership error with linked Job context", () => {
    const ctx = toolCardContextForExample("remove_job_from_epic", removeJobFromEpicExamples[1])

    expect(removeJobFromEpicCard.collapsedSummary?.(ctx)).toBe("Remove Job From Epic failed · JOB-72")
    render(<>{removeJobFromEpicCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("Error: job must currently belong to an epic")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "JOB-72" })).toHaveAttribute("href", "/jobs/72")
  })

  it("renders normalized close-success details and expandable Markdown comments", () => {
    const close = toolCardContextForExample("close_job_successfully", closeJobSuccessfullyExamples[0])
    const bulk = context("approve_job", {
      input: { job_ids: [81, 82] },
      parsedResult: { pending_action_group_id: 3, pending_action_id: 16, state: "pending", member_count: 2, message: "Approve 2 Jobs?" }
    })

    render(
      <>
        {closeJobSuccessfullyCard.renderExpanded(close)}
        {approveJobCard.renderExpanded(bulk)}
      </>
    )

    expect(screen.getByText("no_changes")).toBeInTheDocument()
    expect(screen.getByText("PR comment")).toBeInTheDocument()
    expect(screen.getByText("Closing note")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Show more" })).toBeInTheDocument()
    expect(screen.getByText("2 JOBs")).toBeInTheDocument()
    expect(screen.getByText("group #3")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
  })

  it("links every Job in a normalized bulk close request", () => {
    const ctx = toolCardContextForExample("close_job_successfully", closeJobSuccessfullyExamples[1])

    expect(closeJobSuccessfullyCard.collapsedSummary?.(ctx)).toBe("Close requested · 3 JOBs · pending group #9")
    render(<>{closeJobSuccessfullyCard.renderExpanded(ctx)}</>)

    for (const id of [81, 82, 83]) {
      expect(screen.getByRole("link", { name: `JOB-${id}` })).toHaveAttribute("href", `/jobs/${id}`)
    }
    expect(screen.getByText("duplicate")).toBeInTheDocument()
    expect(screen.getByText("JOB-40").tagName).toBe("STRONG")
  })

  it.each([
    ["confirmed", "Closed successfully · JOB-80", "closed"],
    ["rejected", "Close Job Successfully rejected · JOB-80", null]
  ] as const)("renders the live %s close outcome", (state, summary, subjectState) => {
    const pending = toolCardContextForExample("close_job_successfully", closeJobSuccessfullyExamples[0])
    const ctx = { ...pending, livePendingAction: livePendingAction(15, state) }

    expect(closeJobSuccessfullyCard.collapsedSummary?.(ctx)).toBe(summary)
    render(<>{closeJobSuccessfullyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText(state)).toBeInTheDocument()
    if (subjectState) expect(screen.getByText(subjectState)).toBeInTheDocument()
    else expect(screen.queryByText("Job state")).not.toBeInTheDocument()
  })

  it("renders a normalized close-success error with its linked target", () => {
    const ctx = toolCardContextForExample("close_job_successfully", closeJobSuccessfullyExamples[2])

    expect(closeJobSuccessfullyCard.collapsedSummary?.(ctx)).toBe("Close Job Successfully failed · JOB-84")
    render(<>{closeJobSuccessfullyCard.renderExpanded(ctx)}</>)

    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(document.body).toHaveTextContent("Error: JOB-84 cannot be closed from running.")
    expect(screen.getAllByRole("link", { name: "JOB-84" }).every((link) => link.getAttribute("href") === "/jobs/84")).toBe(true)
  })

  it("falls back to the generic renderer for malformed payloads without target context", () => {
    expect(updateJobCard.collapsedSummary?.(context("update_job", { parsedResult: { oops: true } }))).toBeNull()
    expect(updateEpicCard.renderExpanded(context("update_epic", { parsedResult: "not json" }))).toBeNull()
  })
})
