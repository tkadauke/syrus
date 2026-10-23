import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import pauseScheduledTaskToolCard, { examples } from "./pause_scheduled_task"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return {
    toolName: "pause_scheduled_task",
    resultBody: "",
    resultError: false,
    parsedResult: null,
    ...overrides
  }
}

const paused = { scheduled_task_id: 12, label: "Nightly main-branch health check", enabled: false }
const detailedPause = {
  ...paused,
  previous_state: "scheduled",
  state: "paused",
  next_fire_at: "2026-10-24T03:00:00Z",
  repository_id: 4,
  repository_slug: "tkadauke/syrus"
}

describe("pause_scheduled_task tool card", () => {
  it("registers under the exact MCP tool name", () => {
    expect(pauseScheduledTaskToolCard.toolName).toBe("pause_scheduled_task")
  })

  it("summarizes the collapsed row with the paused label and id", () => {
    expect(pauseScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult: paused }))).toBe("Paused 'Nightly main-branch health check' (#12)")
  })

  it("renders the paused outcome", () => {
    render(<>{pauseScheduledTaskToolCard.renderExpanded(context({ parsedResult: paused }))}</>)

    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "TASK-12" })).toHaveAttribute("href", "/scheduled_tasks/12")
    expect(screen.getByText("Nightly main-branch health check")).toBeInTheDocument()
    expect(screen.getByText("This task will not fire again until it is resumed.")).toBeInTheDocument()
  })

  it("renders the state transition, previous next fire, repository, and linked task", () => {
    render(<>{pauseScheduledTaskToolCard.renderExpanded(context({ input: { scheduled_task_id: 12 }, parsedResult: detailedPause }))}</>)

    expect(screen.getByRole("link", { name: "TASK-12" })).toHaveAttribute("href", "/scheduled_tasks/12")
    expect(screen.getByText("scheduled")).toBeInTheDocument()
    expect(screen.getByText("paused")).toBeInTheDocument()
    expect(screen.getByText("Previously due")).toBeInTheDocument()
    expect(screen.getByText("2026-10-24T03:00:00Z")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/4")
    expect(screen.getByText("Nightly main-branch health check")).toHaveClass("break-words")
  })

  it("accepts a named scheduled-task envelope", () => {
    const parsedResult = { scheduled_task: { id: "18", name: "Weekly dependency review", state: "paused", previous_state: "scheduled" } }
    render(<>{pauseScheduledTaskToolCard.renderExpanded(context({ parsedResult }))}</>)

    expect(screen.getByRole("link", { name: "TASK-18" })).toHaveAttribute("href", "/scheduled_tasks/18")
    expect(screen.getByText("Weekly dependency review")).toBeInTheDocument()
  })

  it("falls back to null for a malformed payload", () => {
    const parsedResult = { oops: true }

    expect(pauseScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(pauseScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("renders tool errors with the shared scheduled-task error card", () => {
    render(<>{pauseScheduledTaskToolCard.renderExpanded(context({ resultError: true, resultBody: "scheduled task is already disabled" }))}</>)

    expect(screen.getByText("Scheduled task")).toBeInTheDocument()
    expect(screen.getByText("failed")).toBeInTheDocument()
    expect(screen.getByText("scheduled task is already disabled")).toBeInTheDocument()
  })

  it("renders structured not-found and write-access errors", () => {
    const { rerender } = render(
      <>{pauseScheduledTaskToolCard.renderExpanded(context({ resultError: true, parsedResult: { error: { message: "scheduled task not found: 99" } } }))}</>
    )
    expect(screen.getByText("scheduled task not found: 99")).toBeInTheDocument()

    rerender(<>{pauseScheduledTaskToolCard.renderExpanded(context({ resultError: true, parsedResult: { message: "repository write access is required" } }))}</>)
    expect(screen.getByText("repository write access is required")).toBeInTheDocument()
  })

  it("falls back to null for a non-object payload", () => {
    const parsedResult = "not json"

    expect(pauseScheduledTaskToolCard.collapsedSummary?.(context({ parsedResult }))).toBeNull()
    expect(pauseScheduledTaskToolCard.renderExpanded(context({ parsedResult }))).toBeNull()
  })

  it("publishes success and failure catalog examples", () => {
    expect(examples.map((example) => example.id)).toEqual(["paused_task", "already_disabled"])
  })
})
