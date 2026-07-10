import { render, screen } from "@testing-library/react"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { afterEach, describe, expect, it, vi } from "vitest"
import { CoverageSparkline } from "./CoverageSparkline"

function renderSparkline(repositoryId = 42) {
  const queryClient = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={queryClient}>
      <CoverageSparkline repositoryId={repositoryId} />
    </QueryClientProvider>
  )
}

function jsonResponse(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { "Content-Type": "application/json" }
  })
}

describe("CoverageSparkline", () => {
  afterEach(() => vi.restoreAllMocks())

  it("renders the sparkline when at least 2 data points with non-null lines_pct are present", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      repository_id: 42,
      days: 30,
      points: [
        { date: "2026-07-01", lines_pct: 80.0, branches_pct: 70.0, functions_pct: null, branch: "main" },
        { date: "2026-07-05", lines_pct: 85.5, branches_pct: 75.0, functions_pct: null, branch: "main" }
      ]
    }))

    renderSparkline()

    expect(await screen.findByTestId("coverage-sparkline")).toBeInTheDocument()
    expect(screen.getByRole("img")).toBeInTheDocument()
    expect(screen.getByText("85.5%")).toBeInTheDocument()
  })

  it("renders nothing when there is only one valid data point", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      repository_id: 42,
      days: 30,
      points: [
        { date: "2026-07-05", lines_pct: 85.5, branches_pct: null, functions_pct: null, branch: "main" }
      ]
    }))

    const { container } = renderSparkline()

    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(screen.queryByTestId("coverage-sparkline")).not.toBeInTheDocument()
    expect(container).toBeEmptyDOMElement()
  })

  it("renders nothing when there are no data points", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      repository_id: 42,
      days: 30,
      points: []
    }))

    const { container } = renderSparkline()

    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(screen.queryByTestId("coverage-sparkline")).not.toBeInTheDocument()
    expect(container).toBeEmptyDOMElement()
  })

  it("renders nothing while the request is pending", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))

    const { container } = renderSparkline()

    expect(screen.queryByTestId("coverage-sparkline")).not.toBeInTheDocument()
    expect(container).toBeEmptyDOMElement()
  })

  it("renders nothing when the request errors", async () => {
    vi.spyOn(window, "fetch").mockRejectedValue(new Error("network error"))

    const { container } = renderSparkline()

    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(screen.queryByTestId("coverage-sparkline")).not.toBeInTheDocument()
    expect(container).toBeEmptyDOMElement()
  })

  it("ignores points with null lines_pct when counting valid points", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      repository_id: 42,
      days: 30,
      points: [
        { date: "2026-07-01", lines_pct: null, branches_pct: null, functions_pct: null, branch: "main" },
        { date: "2026-07-05", lines_pct: 85.5, branches_pct: null, functions_pct: null, branch: "main" }
      ]
    }))

    const { container } = renderSparkline()

    await new Promise((resolve) => setTimeout(resolve, 50))
    expect(screen.queryByTestId("coverage-sparkline")).not.toBeInTheDocument()
    expect(container).toBeEmptyDOMElement()
  })
})
