import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample, type ToolCardContext } from "@app/pluginToolCards"
import { normalizedToolCardParsedResult, normalizedToolName } from "../toolRendering"
import cancelCodingCheckoutCard, { examples } from "./cancel_coding_checkout"

function context(overrides: Partial<ToolCardContext> = {}): ToolCardContext {
  return { toolName: "cancel_coding_checkout", resultBody: "", resultError: false, parsedResult: null, ...overrides }
}

const releasedResult = {
  canceled: true,
  repository_id: 7,
  repository_slug: "tkadauke/syrus",
  released_job: { id: 4225, slug: "JOB-4225", state: "implemented", branch_name: "syrus/direct-4225-a-very-long-branch-name" },
  before: { path: "/workspace/tkadauke/syrus", current_branch: "syrus/direct-4225-a-very-long-branch-name", dirty: true },
  after: { path: "/workspace/tkadauke/syrus", current_branch: "main", dirty: false },
  message: "JOB-4225 was **detached**. No code changes were preserved."
}

describe("cancel_coding_checkout tool card", () => {
  it.each([{ content: [{ type: "text", text: JSON.stringify(releasedResult) }] }, { structured_content: releasedResult }])(
    "renders released-job results from normalized provider envelopes",
    (envelope) => {
      const parsedResult = normalizedToolCardParsedResult(envelope)
      expect(normalizedToolName("mcp__syrus-chat-sidecar__cancel_coding_checkout")).toBe("cancel_coding_checkout")

      render(<>{cancelCodingCheckoutCard.renderExpanded(context({ input: { repository_id: 7 }, parsedResult }))}</>)

      expect(screen.getByText("canceled")).toBeInTheDocument()
      expect(screen.getByRole("link", { name: "tkadauke/syrus" })).toHaveAttribute("href", "/repositories/7")
      expect(screen.getByRole("link", { name: /JOB-4225/ })).toHaveAttribute("href", "/jobs/4225")
      expect(screen.getByText("implemented")).toBeInTheDocument()
      expect(screen.getAllByTitle("syrus/direct-4225-a-very-long-branch-name")[0]).toHaveClass("whitespace-normal", "break-all")
      expect(screen.getByText(/No code changes were preserved or applied by this cancellation/)).toBeInTheDocument()
      expect(screen.getByText("detached", { selector: "strong" })).toBeInTheDocument()

      fireEvent.click(screen.getByText("Before and after checkout state"))
      const disclosure = screen.getByText("Before and after checkout state").closest("details")!
      expect(within(disclosure).getByText("Before")).toBeInTheDocument()
      expect(within(disclosure).getByText("After")).toBeInTheDocument()
      expect(within(disclosure).getByTitle("main")).toBeInTheDocument()
      expect(within(disclosure).getByTitle("true")).toHaveTextContent("true")
      expect(within(disclosure).getByTitle("false")).toHaveTextContent("false")
    }
  )

  it("renders a successful cancellation with no released job", () => {
    render(<>{cancelCodingCheckoutCard.renderExpanded(context({ parsedResult: { ...releasedResult, released_job: null } }))}</>)
    expect(screen.getByText("No Coding Mode job was attached to this checkout.")).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: /JOB-4225/ })).not.toBeInTheDocument()
  })

  it("renders plain-text errors", () => {
    const errorContext = context({ resultBody: "No active Coding Mode checkout.", resultError: true })
    expect(cancelCodingCheckoutCard.collapsedSummary?.(errorContext)).toBe("Coding Mode cancellation failed")
    render(<>{cancelCodingCheckoutCard.renderExpanded(errorContext)}</>)
    expect(screen.getByText("No active Coding Mode checkout.")).toBeInTheDocument()
  })

  it("provides review catalog examples for released-job, no-job, and error states", () => {
    expect(examples.map((example) => example.id)).toEqual(["released_job", "checkout_only", "error"])
    for (const example of examples) {
      const exampleContext = toolCardContextForExample("cancel_coding_checkout", example)
      expect(cancelCodingCheckoutCard.renderExpanded(exampleContext)).not.toBeNull()
    }
  })
})
