import { render, screen } from "@testing-library/react"
import { expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import messageCoworkerCard from "./message_coworker"

const context: ToolCardContext = {
  toolName: "message_coworker",
  resultBody: "",
  resultError: false,
  parsedResult: { queued: true, from_handle: "maya", to_handle: "rin" }
}

it("renders queued coworker delivery without exposing the message text", () => {
  expect(messageCoworkerCard.collapsedSummary?.(context)).toBe("Queued for @rin")
  render(<>{messageCoworkerCard.renderExpanded(context)}</>)
  expect(screen.getByText("queued")).toBeInTheDocument()
  expect(screen.getByText("@maya")).toBeInTheDocument()
  expect(screen.getByText("@rin")).toBeInTheDocument()
})
