import { render, screen } from "@testing-library/react"
import { expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import card from "./spawn_syrus_chat"

const context: ToolCardContext = {
  toolName: "spawn_syrus_chat",
  resultBody: "",
  resultError: false,
  input: { repository_id: 42, prompt: "Plan the release", title: "Release planning" },
  parsedResult: { repository: "acme/widget", thread_id: 17 }
}

it("distinguishes a Syrus engineering chat from a coworker side chat", () => {
  expect(card.collapsedSummary?.(context)).toBe("Release planning")
  render(<>{card.renderExpanded(context)}</>)
  expect(screen.getByText("Start Syrus engineering chat")).toBeInTheDocument()
  expect(screen.getByText("acme/widget")).toBeInTheDocument()
  expect(screen.getByText("Plan the release")).toBeInTheDocument()
})
