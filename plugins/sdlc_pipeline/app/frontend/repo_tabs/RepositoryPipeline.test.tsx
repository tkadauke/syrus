import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
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
  })
})
