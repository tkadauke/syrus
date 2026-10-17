import { jsonResponse } from "../testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { RepositoryCognitiveDebtRoute } from "./RepositoryCognitiveDebt"
import type { RepositoryDetailPayload } from "../api/repositories"

const detailPayload = {
  repository: { id: 1, slug: "acme/widgets" },
  tabs: [
    { key: "overview", label: "Overview", path: "/repositories/1" },
    { key: "cognitive_debt", label: "Cognitive Debt", path: "/repositories/1/cognitive_debt" }
  ]
} as RepositoryDetailPayload

function cognitiveDebtPayload(overrides = {}) {
  return {
    generated_at: "2026-09-28T12:00:00Z",
    target_sha: "abc123",
    proxy_notice: "Cognitive coverage is a proxy for human engagement, not guaranteed understanding.",
    projection_notice: null,
    unsupported_projection_count: 0,
    empty: false,
    summary: { key: "acme/widgets", line_count: 3, covered_count: 1, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 33.3 },
    subsystems: [{ key: "app", line_count: 3, covered_count: 1, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 33.3 }],
    files: [{ key: "app/risky.rb", line_count: 2, covered_count: 0, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 0 }],
    review_queue: [
      {
        kind: "file" as const,
        path: "app/risky.rb",
        risk_score: 100,
        coverage_state: "blind",
        explanations: ["blind", "high churn", "untested"],
        rollup: { key: "app/risky.rb", line_count: 2, covered_count: 0, stale_count: 0, blind_count: 2, cognitive_coverage_pct: 0 },
        signals: { churn: 5, test_coverage_pct: 0, unhealthy_target: false, reliability: null, unsupported_engagements: 0 },
        source: { github_url: "https://github.com/acme/widgets/blob/abc123/app/risky.rb#L1", review_path: "/jobs/4?tab=review", latest_engagement: null }
      }
    ],
    ...overrides
  }
}

function renderRoute(debtResponse: Promise<Response> = Promise.resolve(jsonResponse({ cognitive_debt: cognitiveDebtPayload() }))) {
  vi.spyOn(window, "fetch").mockImplementation((input) => {
    const url = String(input)
    return url.endsWith("/cognitive_debt") ? debtResponse : Promise.resolve(jsonResponse(detailPayload))
  })
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/app-shell/repositories/1/cognitive_debt"]}>
        <Routes>
          <Route element={<RepositoryCognitiveDebtRoute />} path="/app-shell/repositories/:repositoryId/cognitive_debt" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("RepositoryCognitiveDebtRoute", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the cognitive debt workspace on its dedicated tab", async () => {
    renderRoute()

    expect(await screen.findByRole("region", { name: "Cognitive debt review queue" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Cognitive Debt" })).toHaveAttribute("href", "/app-shell/repositories/1/cognitive_debt")
    expect(screen.getByTestId("cognitive-debt-metrics")).toHaveClass("sm:grid-cols-2", "lg:w-[24rem]", "lg:shrink-0")
    expect(screen.getByRole("link", { name: "app/risky.rb" })).toHaveAttribute("href", "https://github.com/acme/widgets/blob/abc123/app/risky.rb#L1")
    expect(screen.getByText("high churn")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Open review" })).toHaveAttribute("href", "/app-shell/jobs/4?tab=review")
  })

  it("renders the empty state when there is no cognitive evidence", async () => {
    renderRoute(
      Promise.resolve(
        jsonResponse({
          cognitive_debt: cognitiveDebtPayload({
            empty: true,
            summary: { key: "acme/widgets", line_count: 0, covered_count: 0, stale_count: 0, blind_count: 0, cognitive_coverage_pct: null },
            subsystems: [],
            files: [],
            review_queue: []
          })
        })
      )
    )

    expect(await screen.findByText(/No cognitive coverage evidence is available yet/)).toBeInTheDocument()
  })

  it("shows a loading state while cognitive debt is being calculated", async () => {
    renderRoute(new Promise<Response>(() => undefined))

    expect(await screen.findByText("Loading cognitive debt...")).toBeInTheDocument()
  })

  it("shows an error with a retry action when cognitive debt fails to load", async () => {
    const debtResponse = Promise.resolve(jsonResponse({ error: "Cognitive debt calculation failed." }, 500))
    renderRoute(debtResponse)

    expect(await screen.findByText("Request failed with 500")).toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Try again" }))

    await waitFor(() => expect(window.fetch).toHaveBeenCalledTimes(3))
  })
})
