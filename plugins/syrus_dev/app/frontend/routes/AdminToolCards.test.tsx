import { fireEvent, render, screen, within } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
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

  it("places a 'Discuss this card' button next to the rendered preview, scoped to the selected example", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash")

    const region = screen.getByRole("region", { name: "Bash" })
    const discussButton = within(region).getByRole("button", { name: "Discuss this card" })
    const preview = within(region).getByLabelText(/Card preview constrained to/)

    // The button and the preview it captures share the same region -- it is
    // scoped to this tool's card, not a page-level action.
    expect(region).toContainElement(discussButton)
    expect(region).toContainElement(preview)
  })

  it("omits the 'Discuss this card' button for an example-less, fallback-only tool", () => {
    renderRoute("/admin/tool_cards?tool_name=NotebookEdit")

    const region = screen.getByRole("region", { name: "NotebookEdit" })
    expect(within(region).queryByRole("button", { name: "Discuss this card" })).not.toBeInTheDocument()
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

  it("defaults the preview viewport to desktop and lets an operator switch presets", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash")

    const switcher = screen.getByRole("tablist", { name: "Preview viewport" })
    expect(within(switcher).getByRole("tab", { name: "Desktop (1280px)", selected: true })).toBeInTheDocument()

    const region = screen.getByRole("region", { name: "Bash" })
    expandToolGroup(region)
    expect(within(region).getByText("Bash(ls)")).toBeInTheDocument()

    fireEvent.click(within(switcher).getByRole("tab", { name: "Phone (390px)" }))

    expect(within(switcher).getByRole("tab", { name: "Phone (390px)", selected: true })).toBeInTheDocument()
    expect(within(region).getByText("Bash(ls)")).toBeInTheDocument()
  })

  it("applies each preset's width as an explicit inline width, not a max-width, on the preview frame", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash")

    const region = screen.getByRole("region", { name: "Bash" })
    const frame = () => within(region).getByLabelText(/Card preview constrained to/)

    // Explicit `width` (not `max-width`) is required so a preset wider than
    // the ambient page content -- e.g. "wide desktop" at 1600px under the
    // page's max-w-[96rem]/1536px cap -- still applies its full requested
    // width and overflows into a scrollbar, instead of silently collapsing
    // to whatever width the surrounding container happens to have.
    expect(frame().style.width).toBe("1280px")
    expect(frame().style.maxWidth).toBe("")

    fireEvent.click(screen.getByRole("tab", { name: "Wide desktop (1600px)" }))
    expect(frame().style.width).toBe("1600px")
    expect(frame().style.maxWidth).toBe("")

    fireEvent.click(screen.getByRole("tab", { name: "Phone (390px)" }))
    expect(frame().style.width).toBe("390px")
  })

  it("reads the initial viewport preset from the URL and keeps it in the deep-link query params", () => {
    renderRoute("/admin/tool_cards?tool_name=Bash&viewport=wide")

    const switcher = screen.getByRole("tablist", { name: "Preview viewport" })
    expect(within(switcher).getByRole("tab", { name: "Wide desktop (1600px)", selected: true })).toBeInTheDocument()

    const wideTab = within(switcher).getByRole("tab", { name: "Wide desktop (1600px)" })
    expect(wideTab).toHaveAttribute("href", expect.stringContaining("viewport=wide"))

    const phoneTab = within(switcher).getByRole("tab", { name: "Phone (390px)" })
    expect(phoneTab).toHaveAttribute("href", expect.stringContaining("tool_name=Bash"))
  })
})

function renderRoute(initialEntry = "/admin/tool_cards") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[initialEntry]}>
        <Routes>
          <Route element={<AdminToolCards />} path="/admin/tool_cards" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function expandToolGroup(region: HTMLElement) {
  const summary = region.querySelector("details > summary")
  if (!summary) throw new Error("expected a ToolGroup <summary> element inside the entry region")
  fireEvent.click(summary)
}
