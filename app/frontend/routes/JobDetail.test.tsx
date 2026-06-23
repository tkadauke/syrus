import { render, screen, within } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { TestPlanPanel } from "./JobDetail"

describe("TestPlanPanel", () => {
  it("renders numbered steps and notes", () => {
    render(
      <TestPlanPanel
        testPlan={{
          workflow_id: 5,
          steps: [ "Run bin/rspec spec/services/app/job_detail_payload_spec.rb", "Run bin/test-react" ],
          notes: "Check the Summary tab."
        }}
      />
    )

    const panel = screen.getByRole("heading", { name: "Test plan" }).closest("section")
    expect(panel).not.toBeNull()
    const listItems = within(panel as HTMLElement).getAllByRole("listitem")
    expect(listItems.map((item) => item.textContent)).toEqual([
      "Run bin/rspec spec/services/app/job_detail_payload_spec.rb",
      "Run bin/test-react"
    ])
    expect(screen.getByText("Check the Summary tab.")).toBeInTheDocument()
  })

  it("renders the empty state when no test plan is available", () => {
    render(<TestPlanPanel testPlan={null} />)

    expect(screen.getByRole("heading", { name: "Test plan" })).toBeInTheDocument()
    expect(screen.getByText("No test plan yet.")).toBeInTheDocument()
  })
})
