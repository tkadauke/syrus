import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { RepositoryPipelineRoute } from "./RepositoryPipeline"

describe("RepositoryPipelineRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders bounded stage summaries, evidence, and attention highlights", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(jsonResponse({
      repository: { id: 1, slug: "acme/widgets" },
      tabs: [ { key: "sdlc_pipeline.repository", label: "Pipeline", path: "/repositories/1/plugin/sdlc-pipeline" } ],
      stages: [ {
        key: "review", label: "Review", kind: "lifecycle", total: 12,
        attention_count: 2, aging_count: 4, oldest_age_seconds: 100,
        highlighted_items: [ {
          id: 9, slug: "JOB-9", title: "Explain placement", state: "implemented",
          needs_attention: true, age_seconds: 50, evidence: { type: "job_state", state: "implemented" }
        } ]
      } ]
    }))

    render(
      <QueryClientProvider client={new QueryClient({ defaultOptions: { queries: { retry: false } } })}>
        <MemoryRouter><RepositoryPipelineRoute repositoryId="1" prefix="" /></MemoryRouter>
      </QueryClientProvider>
    )

    expect(await screen.findByText("acme/widgets")).toBeInTheDocument()
    expect(screen.getByText("2 need attention · 4 aging")).toBeInTheDocument()
    expect(screen.getByText("Explain placement")).toBeInTheDocument()
    expect(screen.getByText("JOB-9 · Job state")).toBeInTheDocument()
    expect(screen.getByText("Attention")).toBeInTheDocument()
  })
})
