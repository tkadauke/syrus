import { fireEvent, render, screen, within } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { AdminToolCards } from "./AdminToolCards"

describe("AdminToolCards", () => {
  it("renders the heading, filter bar, and an empty state when nothing matches", () => {
    renderRoute("/admin/tool_cards?tool_name=zzz_does_not_exist_zzz")

    expect(screen.getByRole("heading", { name: "Tool Card Catalog" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "+ Add filter" })).toBeInTheDocument()
    expect(screen.getByText("No tools match these filters.")).toBeInTheDocument()
  })

  it("filters the catalog by tool name", () => {
    renderRoute("/admin/tool_cards?tool_name=list_insights")

    expect(screen.getByRole("button", { name: "Tool name contains list_insights" })).toBeInTheDocument()
    expect(screen.getByRole("region", { name: "List insights" })).toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "Bash" })).not.toBeInTheDocument()
    expect(screen.queryByRole("region", { name: "List jobs" })).not.toBeInTheDocument()
  })

  it("matches an entry when owner type, source type, renderer type, and coverage status filters all agree", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash&owner_type=provider&source_type=provider_builtin&renderer_type=generic_fallback&coverage_status=has_examples")

    expect(screen.getByRole("region", { name: "Bash" })).toBeInTheDocument()
  })

  it("excludes an entry once a combined filter field no longer matches it", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash&coverage_status=no_examples")

    expect(screen.queryByRole("region", { name: "Bash" })).not.toBeInTheDocument()
    expect(screen.getByText("No tools match these filters.")).toBeInTheDocument()
  })

  it("keeps a fallback-only, example-less provider tool visible instead of hiding it", () => {
    renderRoute("/admin/tool_cards?tool_name=NotebookEdit")

    const region = screen.getByRole("region", { name: "NotebookEdit" })
    expect(within(region).getByText("provider · claude")).toBeInTheDocument()
    expect(within(region).getByText("Generic fallback")).toBeInTheDocument()
    expect(within(region).getByText("No example fixtures registered for this tool yet.")).toBeInTheDocument()
  })

  it("renders a provider built-in's examples and lets an operator switch between them", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash")

    const region = screen.getByRole("region", { name: "Bash" })
    expect(within(region).getByText("provider_builtin")).toBeInTheDocument()
    expandToolGroup(region)

    expect(within(region).getByText("Bash(ls)")).toBeInTheDocument()

    fireEvent.click(within(region).getByRole("tab", { name: "List the repo root (Codex)" }))
    expect(within(region).getByText("Bash(ls -la)")).toBeInTheDocument()
  })

  it("renders a plugin-provided card's example through the real chat tool-card path", () => {
    renderRoute("/admin/tool_cards?tool_name=list_insights")

    const region = screen.getByRole("region", { name: "List insights" })
    expect(within(region).getByText("plugin · agent_insights")).toBeInTheDocument()
    expandToolGroup(region)

    expect(within(region).getByText("LandingQueueProcessor re-fetches PR mergeability on every poll tick")).toBeInTheDocument()

    fireEvent.click(within(region).getByRole("tab", { name: "No pending insights" }))
    expect(within(region).getByText("No insights match this query.")).toBeInTheDocument()
    expect(within(region).queryByText("LandingQueueProcessor re-fetches PR mergeability on every poll tick")).not.toBeInTheDocument()
  })

  it("renders a core mcp_tool card with multiple examples, including a malformed-payload fallback", () => {
    renderRoute("/admin/tool_cards?tool_name=list_jobs")

    const region = screen.getByRole("region", { name: "List jobs" })
    expandToolGroup(region)

    expect(within(region).getAllByText("JOB-101").length).toBeGreaterThan(0)
    expect(within(region).getAllByText("JOB-102").length).toBeGreaterThan(0)

    fireEvent.click(within(region).getByRole("tab", { name: "Malformed: missing jobs key" }))
    expect(within(region).queryByText("JOB-101")).not.toBeInTheDocument()
  })

  it("deep-links directly to a specific tool and example", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash&tool=Bash&example=command_failed")

    const region = screen.getByRole("region", { name: "Bash" })
    expect(within(region).getByRole("tab", { name: "Error: command failed", selected: true })).toBeInTheDocument()
  })
})

function renderRoute(initialEntry = "/admin/tool_cards") {
  return render(
    <MemoryRouter initialEntries={[initialEntry]}>
      <Routes>
        <Route element={<AdminToolCards />} path="/admin/tool_cards" />
      </Routes>
    </MemoryRouter>
  )
}

function expandToolGroup(region: HTMLElement) {
  const summary = region.querySelector("details > summary")
  if (!summary) throw new Error("expected a ToolGroup <summary> element inside the entry region")
  fireEvent.click(summary)
}
