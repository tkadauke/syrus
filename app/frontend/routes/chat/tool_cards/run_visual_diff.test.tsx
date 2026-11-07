import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import type { ToolCardContext } from "@app/pluginToolCards"
import card from "./run_visual_diff"

function context(livePendingAction?: ToolCardContext["livePendingAction"]): ToolCardContext {
  return {
    toolName: "run_visual_diff",
    input: { job_id: 4222 },
    resultBody: JSON.stringify({ pending_confirmation_id: 502, state: "pending" }),
    resultError: false,
    parsedResult: { pending_confirmation_id: 502, state: "pending" },
    livePendingAction
  }
}

describe("run_visual_diff tool card", () => {
  it("renders the Job while confirmation is pending", () => {
    render(<>{card.renderExpanded(context())}</>)
    expect(screen.getByText("JOB-4222")).toBeInTheDocument()
  })

  it("uses the shared before/after artifact renderer for a completed comparison", () => {
    render(
      <>
        {card.renderExpanded(
          context({
            id: 502,
            action: "run_visual_diff",
            state: "confirmed",
            label: "Run visual diff",
            detail: "Complete",
            execution_status: "applied",
            execution_step: "Applied.",
            outcome: {
              workflow_id: 61271,
              job_id: 4222,
              comparison: {
                type: "visual_diff_comparison",
                title: "Before/after visual comparison",
                renderer_type: "before_after_visual_diff",
                payload: { pairs: [{ title: "Dashboard", before: { image_url: "/before.png" }, after: { image_url: "/after.png" } }] }
              }
            },
            app_confirm_path: "/confirm",
            app_reject_path: "/reject"
          })
        )}
      </>
    )

    expect(screen.getByText("Dashboard")).toBeInTheDocument()
    expect(screen.getByAltText(/before.*Dashboard/i)).toHaveAttribute("src", "/before.png")
    expect(screen.getByAltText(/after.*Dashboard/i)).toHaveAttribute("src", "/after.png")
  })
})
