import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext, ToolCardRenderer } from "@app/pluginToolCards"
import approveJobCard from "./approve_job"
import cancelJobCard from "./cancel_job"
import closeJobSuccessfullyCard from "./close_job_successfully"
import setJobPriorityCard from "./set_job_priority"
import updateJobCard from "./update_job"
import rebaseJobCard from "./rebase_job"
import reopenJobCard from "./reopen_job"
import pollJobFeedbackCard from "./poll_job_feedback"
import startEpicCard from "./start_epic"
import moveEpicToBacklogCard from "./move_epic_to_backlog"
import archiveEpicCard from "./archive_epic"
import updateEpicCard from "./update_epic"
import addEpicDependencyCard from "./add_epic_dependency"
import removeEpicDependencyCard from "./remove_epic_dependency"
import addJobDependencyCard from "./add_job_dependency"
import removeJobDependencyCard from "./remove_job_dependency"
import unapproveJobCard from "./unapprove_job"
import removeJobFromEpicCard from "./remove_job_from_epic"

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

  it("renders canceled and rejected pending action acknowledgements", () => {
    const canceled = context("rebase_job", {
      input: { job_id: 45 },
      parsedResult: { pending_action_id: 8, state: "canceled", message: "Rebase canceled by operator." }
    })
    const rejected = context("poll_job_feedback", {
      input: { job_id: 46 },
      parsedResult: { pending_action_id: 9, state: "rejected", message: "Feedback poll rejected." }
    })

    render(<>{rebaseJobCard.renderExpanded(canceled)}{pollJobFeedbackCard.renderExpanded(rejected)}</>)

    expect(screen.getByText("canceled")).toBeInTheDocument()
    expect(screen.getByText("Rebase canceled by operator.")).toBeInTheDocument()
    expect(screen.getByText("rejected")).toBeInTheDocument()
    expect(screen.getByText("Feedback poll rejected.")).toBeInTheDocument()
  })

  it("renders dependency add and remove details for Job and Epic targets", () => {
    const addJob = context("add_job_dependency", {
      input: { job_id: 50, depends_on_job_id: 49, satisfaction_mode: "closed" },
      parsedResult: { job_id: 50, depends_on_job_ids: [49], depends_on_epic_ids: [12] }
    })
    const removeEpic = context("remove_epic_dependency", {
      input: { epic_id: 20, depends_on_epic_id: 19 },
      parsedResult: { epic_id: 20, depends_on: [18] }
    })

    expect(addJobDependencyCard.collapsedSummary?.(addJob)).toBe("Dependency added · JOB-50")
    render(<>{addJobDependencyCard.renderExpanded(addJob)}{removeEpicDependencyCard.renderExpanded(removeEpic)}</>)

    expect(screen.getAllByText("JOB-49").length).toBeGreaterThan(0)
    expect(screen.getByText("closed")).toBeInTheDocument()
    expect(screen.getAllByText("Current dependencies").length).toBeGreaterThan(0)
    expect(screen.getByText("EPIC-12")).toBeInTheDocument()
    expect(screen.getByText("EPIC-19")).toBeInTheDocument()
    expect(screen.getByText("EPIC-18")).toBeInTheDocument()
  })

  it("renders priority changes", () => {
    const parsedResult = { job_id: 51, previous_priority: "medium", new_priority: "urgent" }

    expect(setJobPriorityCard.collapsedSummary?.(context("set_job_priority", { parsedResult }))).toBe("Priority changed · JOB-51")
    render(<>{setJobPriorityCard.renderExpanded(context("set_job_priority", { parsedResult }))}</>)

    expect(screen.getByText("medium")).toBeInTheDocument()
    expect(screen.getByText("urgent")).toBeInTheDocument()
  })

  it("renders approval and unapproval acknowledgements", () => {
    const approve = context("approve_job", { parsedResult: { job_id: 52, previous_state: "implemented", new_state: "approved" } })
    const unapprove = context("unapprove_job", { parsedResult: { job_id: 52, previous_state: "approved", new_state: "implemented" } })

    render(<>{approveJobCard.renderExpanded(approve)}{unapproveJobCard.renderExpanded(unapprove)}</>)

    expect(screen.getByText("Approve Job")).toBeInTheDocument()
    expect(screen.getByText("Unapprove Job")).toBeInTheDocument()
    expect(screen.getAllByText("JOB-52")).toHaveLength(2)
  })

  it("renders archive, backlog, and start Epic transitions", () => {
    render(
      <>
        {startEpicCard.renderExpanded(context("start_epic", { parsedResult: { epic_id: 60, previous_state: "ready", new_state: "in_progress" } }))}
        {moveEpicToBacklogCard.renderExpanded(context("move_epic_to_backlog", { parsedResult: { epic_id: 61, previous_state: "ready", new_state: "backlog" } }))}
        {archiveEpicCard.renderExpanded(context("archive_epic", { parsedResult: { epic_id: 62, previous_state: "ready", new_state: "archived" } }))}
      </>
    )

    expect(screen.getByText("EPIC-60")).toBeInTheDocument()
    expect(screen.getByText("in progress")).toBeInTheDocument()
    expect(screen.getByText("EPIC-61")).toBeInTheDocument()
    expect(screen.getAllByText("backlog").length).toBeGreaterThan(0)
    expect(screen.getByText("EPIC-62")).toBeInTheDocument()
    expect(screen.getAllByText("archived").length).toBeGreaterThan(0)
  })

  it("renders update and remove-from-epic metadata", () => {
    render(
      <>
        {updateJobCard.renderExpanded(context("update_job", { parsedResult: { job_id: 70, title: "New title", description: "New body", state: "open" } }))}
        {updateEpicCard.renderExpanded(context("update_epic", { parsedResult: { epic_id: 71, title: "New Epic", state: "ready" } }))}
        {removeJobFromEpicCard.renderExpanded(context("remove_job_from_epic", { parsedResult: { job_id: 72, removed_from_epic_id: 73, removed_from_epic_title: "Old Epic" } }))}
      </>
    )

    expect(screen.getByText("New title")).toBeInTheDocument()
    expect(screen.getByText("New Epic")).toBeInTheDocument()
    expect(screen.getByText("Old Epic")).toBeInTheDocument()
  })

  it("renders close-success details and grouped pending confirmations", () => {
    const close = context("close_job_successfully", {
      input: { job_id: 80, closure_reason: "no_changes" },
      parsedResult: { job_id: 80, pending_action_id: 15, state: "pending", closure_reason: "no_changes" }
    })
    const bulk = context("approve_job", {
      input: { job_ids: [81, 82] },
      parsedResult: { pending_action_group_id: 3, pending_action_id: 16, state: "pending", member_count: 2, message: "Approve 2 Jobs?" }
    })

    render(<>{closeJobSuccessfullyCard.renderExpanded(close)}{approveJobCard.renderExpanded(bulk)}</>)

    expect(screen.getByText("no_changes")).toBeInTheDocument()
    expect(screen.getByText("2 JOBs")).toBeInTheDocument()
    expect(screen.getByText("group #3")).toBeInTheDocument()
    expect(screen.getByText("2 actions")).toBeInTheDocument()
  })

  it("falls back to the generic renderer for malformed payloads without target context", () => {
    expect(updateJobCard.collapsedSummary?.(context("update_job", { parsedResult: { oops: true } }))).toBeNull()
    expect(updateEpicCard.renderExpanded(context("update_epic", { parsedResult: "not json" }))).toBeNull()
  })
})
