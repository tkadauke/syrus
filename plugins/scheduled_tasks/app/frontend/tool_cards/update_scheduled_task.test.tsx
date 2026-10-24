import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult } from "@app/toolCardParsing"
import updateScheduledTaskToolCard from "./update_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "update_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const task = {
  id: 12,
  repository_slug: "tkadauke/syrus",
  label: "Nightly main-branch health check",
  kind: "cron",
  state: "auto_paused",
  cron_expression: "0 5 * * *",
  schedule_input: "Every day at 5am",
  schedule_explanation: null,
  schedule_timezone: null,
  fire_at: null,
  pr_pileup_policy: "replace",
  enabled: false,
  consecutive_failure_count: 4,
  next_fire_at: "2026-09-07T05:00:00Z",
  prompt: "Check main and repair it."
}

describe("update_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(updateScheduledTaskToolCard.toolName).toBe("update_scheduled_task")
  })

  it("summarizes the collapsed row as an update outcome", () => {
    const parsedResult = { scheduled_task: task }

    expect(updateScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Updated Nightly main-branch health check (#12)")
  })

  it("renders the post-update snapshot including the auto-paused state", () => {
    render(<>{updateScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("Updated scheduled task")).toBeInTheDocument()
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("auto paused")).toBeInTheDocument()
    expect(screen.getByText("4 consecutive failures")).toBeInTheDocument()
    expect(screen.getByText("replace")).toBeInTheDocument()
  })

  it("falls back to the cron expression when there is no schedule explanation", () => {
    render(<>{updateScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("0 5 * * *")).toBeInTheDocument()
  })

  it("shows the updated prompt behind a disclosure", () => {
    render(<>{updateScheduledTaskToolCard.renderExpanded(context({ parsedResult: { scheduled_task: task } }))}</>)

    expect(screen.getByText("Prompt")).toBeInTheDocument()
    expect(screen.getByText("Check main and repair it.")).toBeInTheDocument()
  })

  it("shows only supplied fields and compares them with an earlier task snapshot", () => {
    const updated = { ...task, label: "Weekday health check", prompt: "Review **main** and JOB-42 at https://example.test/runbook." }
    render(
      <>
        {updateScheduledTaskToolCard.renderExpanded(
          context({
            input: { scheduled_task_id: 12, name: "Weekday health check", prompt: updated.prompt },
            parsedResult: { scheduled_task: updated },
            priorCalls: [{ toolName: "read_scheduled_task", input: { scheduled_task_id: 12 }, parsedResult: { scheduled_task: task } }]
          })
        )}
      </>
    )

    expect(screen.getByText("Changed fields")).toBeInTheDocument()
    expect(screen.getByText("Nightly main-branch health check → Weekday health check")).toBeInTheDocument()
    expect(screen.queryByText("Fire at")).not.toBeInTheDocument()
    expect(screen.getByText("main")).toBeInTheDocument()
    expect(screen.getByText("Previous prompt")).toBeInTheDocument()
    expect(screen.getByText("Check main and repair it.")).toBeInTheDocument()
    expect(screen.getAllByTestId("markdown-preview-content").at(-1)).toHaveTextContent("JOB-42")
    expect(screen.getByRole("link", { name: "https://example.test/runbook" })).toHaveAttribute("href", "https://example.test/runbook")
  })

  it("renders all update inputs and uses new values when no prior snapshot is available", () => {
    const updated = { ...task, fire_at: "2026-10-25T08:30:00Z", prompt: "" }
    render(
      <>
        {updateScheduledTaskToolCard.renderExpanded(
          context({
            input: {
              scheduled_task_id: 12,
              name: task.label,
              prompt: "",
              schedule_input: "Every weekday at 5am",
              fire_at: updated.fire_at,
              pr_pileup_policy: "replace"
            },
            parsedResult: { scheduled_task: updated }
          })
        )}
      </>
    )

    expect(screen.getByText("Name")).toBeInTheDocument()
    expect(screen.getByText("Schedule")).toBeInTheDocument()
    expect(screen.getByText("Fire at")).toBeInTheDocument()
    expect(screen.getByText("Updated prompt")).toBeInTheDocument()
    expect(screen.getByText("No prompt was provided.")).toBeInTheDocument()
  })

  it.each([
    [{ error: { message: "Schedule could not be parsed." } }, "Schedule could not be parsed."],
    [{ message: "Scheduled task was not found." }, "Scheduled task was not found."],
    ["Repository write access is required.", "Repository write access is required."]
  ])("renders a styled error card for %j", (parsedResult, message) => {
    render(
      <>
        {updateScheduledTaskToolCard.renderExpanded(
          context({ parsedResult, resultBody: typeof parsedResult === "string" ? parsedResult : "", resultError: true })
        )}
      </>
    )

    expect(screen.getByText("Scheduled task")).toBeInTheDocument()
    expect(screen.getByText(message)).toBeInTheDocument()
  })

  it("accepts normalized structured-content and text-block provider envelopes", () => {
    const envelopes = [{ structured_content: { scheduled_task: task } }, { content: [{ type: "text", text: JSON.stringify({ scheduled_task: task }) }] }]

    for (const envelope of envelopes) {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(updateScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBe("Updated Nightly main-branch health check (#12)")
    }
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(updateScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(updateScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(updateScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(updateScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })
})
