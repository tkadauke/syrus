import { jsonResponse } from "@app/testSupport"
import { resetApiClientStateForTests } from "@app/api/clientTestState"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { InsightPreviewCard } from "./INSIGHT.InsightPreviewCard"

function renderCard(id: number) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <InsightPreviewCard id={id} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("InsightPreviewCard", () => {
  afterEach(() => {
    resetApiClientStateForTests()
    vi.restoreAllMocks()
  })

  it("renders accessible insight preview details", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      insight: {
        id: 42,
        display_id: "INSIGHT-42",
        accessible: true,
        title: "Repeated prepare failures",
        summary: "Fix **bundle install** before more jobs fail.",
        category: "repeated_failure",
        severity: "high",
        confidence: 0.85,
        state: "pending",
        proposal_type: "create_job",
        repository: { id: 7, slug: "acme/widgets", repository_path: "/repositories/7", insights_path: "/repositories/7/plugin/insights" },
        created_job: { id: 9, slug: "JOB-9", title: "Fix prepare", state: "open", job_path: "/jobs/JOB-9" },
        created_at: "2026-09-01T12:00:00Z",
        web_path: "/repositories/7/plugin/insights?state=all#INSIGHT-42"
      }
    }))

    renderCard(42)

    expect(await screen.findByRole("link", { name: "Repeated prepare failures" })).toHaveAttribute("href", "/repositories/7/plugin/insights?state=all#INSIGHT-42")
    expect(screen.getByRole("button", { name: "Copy INSIGHT-42 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "acme/widgets" })).toHaveAttribute("href", "/repositories/7/plugin/insights")
    expect(screen.getByText("High")).toBeInTheDocument()
    expect(screen.getByText("Pending")).toBeInTheDocument()
    expect(screen.getByText("85% confidence")).toBeInTheDocument()
    expect(screen.getByText("bundle install", { selector: "strong" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Created job: JOB-9" })).toHaveAttribute("href", "/jobs/JOB-9")
  })

  it("renders inaccessible insights without leaking details", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      insight: { display_id: "INSIGHT-99", accessible: false }
    }))

    renderCard(99)

    await waitFor(() => expect(screen.getByText("You do not have access to this insight.")).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Copy INSIGHT-99 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
    expect(screen.queryByText(/Repeated prepare/)).not.toBeInTheDocument()
  })
})
