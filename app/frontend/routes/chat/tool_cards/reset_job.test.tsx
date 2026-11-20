import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { toolCardContextForExample } from "@app/pluginToolCards"
import resetJobCard, { examples } from "./reset_job"

describe("reset_job tool card", () => {
  it("lists every destructive effect in the pending confirmation fixture", () => {
    render(<>{resetJobCard.renderExpanded(toolCardContextForExample("reset_job", examples[0]))}</>)

    expect(screen.getByText("PR #812")).toBeInTheDocument()
    expect(screen.getByText("syrus/stale-implementation")).toBeInTheDocument()
    expect(screen.getByText("3")).toBeInTheDocument()
    expect(screen.getByText("WF-65840, WF-65841")).toBeInTheDocument()
  })
})
