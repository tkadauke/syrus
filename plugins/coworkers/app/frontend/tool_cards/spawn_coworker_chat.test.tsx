import { render, screen } from "@testing-library/react"
import { expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import card from "./spawn_coworker_chat"

const context: ToolCardContext = {
  toolName: "spawn_coworker_chat",
  resultBody: "",
  resultError: false,
  input: { handle: "maya", prompt: "Research this" },
  parsedResult: { pending_action_id: 12 }
}

it("identifies a same-coworker side chat and points engineering work to the Syrus tool", () => {
  expect(card.collapsedSummary?.(context)).toBe("Start side chat of this coworker")
  render(<>{card.renderExpanded(context)}</>)
  expect(screen.getByText("Start side chat of this coworker")).toHaveClass("min-w-0", "break-words")
  expect(screen.getByText("Not a Syrus planner chat")).toBeInTheDocument()
  expect(screen.getByText(/spawn_syrus_chat/)).toBeInTheDocument()
})
