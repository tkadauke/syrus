import { render, screen } from "@testing-library/react"
import { expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import card from "./inspect_coworker_environment"

const context: ToolCardContext = {
  toolName: "inspect_coworker_environment",
  resultBody: "",
  resultError: false,
  parsedResult: {
    environment: {
      state: "candidate",
      active_digest: "sha256:active",
      error_code: null,
      build_status: { state: "succeeded" },
      compatibility: { status: "compatible" }
    }
  }
}

it("renders the safe lifecycle summary", () => {
  expect(card.collapsedSummary?.(context)).toBe("candidate")
  render(<>{card.renderExpanded(context)}</>)
  expect(screen.getByText("succeeded")).toBeInTheDocument()
  expect(screen.getByText("compatible")).toBeInTheDocument()
  expect(screen.getByText("sha256:active")).toBeInTheDocument()
})
