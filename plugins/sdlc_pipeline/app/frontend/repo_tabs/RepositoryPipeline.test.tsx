import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { RepositoryPipelineRoute } from "./RepositoryPipeline"

describe("RepositoryPipelineRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders bounded stage summaries, evidence, and attention highlights", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(
      jsonResponse({
        repository: { id: 1, slug: "acme/widgets" },
        generated_at: "2026-10-31T12:00:00Z",
        evidence: { status: "complete", incomplete_count: 0 },
        tabs: [{ key: "sdlc_pipeline.repository", label: "Pipeline", path: "/repositories/1/plugin/sdlc-pipeline" }],
        groups: [
          {
            key: "epic:2",
            label: "Release reliability",
            epic: { id: 2, slug: "EPIC-2", title: "Release reliability" },
            total: 10,
            stage_totals: { review: 10 }
          },
          { key: "ungrouped", label: "Ungrouped", total: 2, stage_totals: { review: 2 } }
        ],
        stages: [
          {
            key: "review",
            label: "Review",
            kind: "lifecycle",
            total: 12,
            attention_count: 2,
            aging_count: 4,
            oldest_age_seconds: 100,
            highlighted_items: [
              {
                id: 9,
                slug: "JOB-9",
                title: "Explain placement",
                state: "implemented",
                needs_attention: true,
                age_seconds: 50,
                paths: { job: "/jobs/JOB-9", workflow: "/jobs/JOB-9?tab=workflows#workflow-3" },
                evidence: { type: "job_state", state: "implemented" }
              }
            ]
          }
        ]
      })
    )

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <RepositoryPipelineRoute repositoryId="1" prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("acme/widgets")).toBeInTheDocument()
    expect(screen.getByText("2 attention")).toBeInTheDocument()
    expect(screen.getByText("4 aging")).toBeInTheDocument()
    expect(screen.getByText("Explain placement")).toBeInTheDocument()
    expect(screen.getByText("JOB-9")).toBeInTheDocument()
    expect(screen.getByText("Job state")).toBeInTheDocument()
    expect(screen.getByText("Release reliability")).toBeInTheDocument()
    expect(screen.getByText("12 items represented")).toBeInTheDocument()
    expect(screen.getByText(/No deployment stages are configured/)).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Workflow" })).toHaveAttribute("href", "/jobs/JOB-9?tab=workflows#workflow-3")
  })

  it("opens an accessible drill-down and restores focus when Escape closes it", async () => {
    const overview = {
      repository: { id: 1, slug: "acme/widgets" },
      generated_at: "2026-10-31T12:00:00Z",
      evidence: { status: "partial", incomplete_count: 1 },
      tabs: [],
      groups: [],
      stages: [
        {
          key: "deployment:production",
          label: "Production",
          kind: "deployment",
          release_tail: true,
          total: 1,
          attention_count: 0,
          aging_count: 0,
          oldest_age_seconds: 60,
          highlighted_items: [
            {
              id: 9,
              slug: "JOB-9",
              title: "Ship it",
              state: "closed",
              needs_attention: false,
              age_seconds: 60,
              paths: { job: "/jobs/JOB-9", delivery: "/jobs/JOB-9", release: "/jobs/JOB-9" },
              evidence: { type: "deployment_stage", stage_name: "production" }
            }
          ]
        }
      ]
    }
    vi.spyOn(globalThis, "fetch").mockImplementation(async (input) => {
      const url = String(input)
      if (url.includes("?stage="))
        return jsonResponse({
          ...overview,
          drill_down: { stage: "deployment:production", page: 1, limit: 25, total: 1, next_page: null, items: overview.stages[0].highlighted_items }
        })
      return jsonResponse(overview)
    })

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter>
          <RepositoryPipelineRoute repositoryId="1" prefix="" />
        </MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText(/Delivery evidence is partial/)).toBeInTheDocument()
    const opener = screen.getByRole("region", { name: "Production, 1 items" }).querySelector("button") as HTMLButtonElement
    opener.focus()
    fireEvent.click(opener)
    const dialog = await screen.findByRole("dialog", { name: "Production stage details" })
    await waitFor(() => expect(screen.getByRole("button", { name: "Close details" })).toHaveFocus())
    expect(within(dialog).getByRole("link", { name: "Release" })).toHaveAttribute("href", "/jobs/JOB-9")
    fireEvent.keyDown(document, { key: "Escape" })
    await waitFor(() => expect(screen.queryByRole("dialog")).not.toBeInTheDocument())
    expect(opener).toHaveFocus()
  })
})
