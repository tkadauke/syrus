import { render, screen } from "@testing-library/react"
import { expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import card from "./manage_coworker_schedule"

const context: ToolCardContext = {
  toolName: "manage_coworker_schedule",
  resultBody: "",
  resultError: false,
  parsedResult: {
    fired: true,
    schedules: [{ id: 3, name: "Morning briefing", schedule: "Every day at 9:00 AM UTC", state: "scheduled" }]
  }
}

it("renders schedule state and a started run", () => {
  expect(card.collapsedSummary?.(context)).toBe("1 schedule")
  render(<>{card.renderExpanded(context)}</>)
  expect(screen.getByText("Morning briefing")).toBeInTheDocument()
  expect(screen.getByText(/Every day at 9:00 AM UTC/)).toBeInTheDocument()
  expect(screen.getByText("Started")).toBeInTheDocument()
})
