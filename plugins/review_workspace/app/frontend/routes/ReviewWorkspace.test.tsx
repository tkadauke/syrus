import "@testing-library/jest-dom/vitest"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import ReviewWorkspaceRoute from "./ReviewWorkspace"

afterEach(() => vi.restoreAllMocks())

function renderRoute(path = "/review") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes><Route path="/review" element={<ReviewWorkspaceRoute />} /><Route path="/review/:job_id" element={<ReviewWorkspaceRoute />} /></Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("ReviewWorkspaceRoute", () => {
  it("falls back from a stale deep link to the first eligible Job", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ count: 1, jobs: [{ id: 42, slug: "JOB-42", title: "Review me", priority: "high", ready_at: "2026-11-19T00:00:00Z", dependency_blocked: false, repository: { id: 1, slug: "acme/widgets" }, pr_number: 7 }] }), { status: 200, headers: { "Content-Type": "application/json" } }))

    renderRoute("/review/JOB-999")

    expect(await screen.findByRole("heading", { name: "Review me" })).toBeInTheDocument()
    await waitFor(() => expect(screen.getByRole("link", { name: "Open active review" })).toHaveAttribute("href", "/jobs/JOB-42?tab=review"))
  })

  it("renders the caught-up state for an empty stack", async () => {
    vi.spyOn(globalThis, "fetch").mockResolvedValue(new Response(JSON.stringify({ count: 0, jobs: [] }), { status: 200, headers: { "Content-Type": "application/json" } }))
    renderRoute()
    expect(await screen.findByRole("heading", { name: "All caught up" })).toBeInTheDocument()
  })
})
