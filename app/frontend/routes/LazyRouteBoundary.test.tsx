import { lazy } from "react"
import { render, screen, waitFor } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { LazyRouteBoundary } from "./App"

describe("LazyRouteBoundary", () => {
  it("renders a lazy route through its loading state", async () => {
    let resolveRoute!: (module: { default: () => JSX.Element }) => void
    const LazyRoute = lazy(() => new Promise<{ default: () => JSX.Element }>((resolve) => {
      resolveRoute = resolve
    }))

    render(
      <LazyRouteBoundary>
        <LazyRoute />
      </LazyRouteBoundary>
    )

    expect(screen.getByRole("status")).toHaveTextContent("Loading")

    resolveRoute({ default: () => <main>Loaded lazy route</main> })

    expect(await screen.findByText("Loaded lazy route")).toBeInTheDocument()
  })

  it("shows the route error fallback when a lazy route chunk fails", async () => {
    vi.spyOn(console, "error").mockImplementation(() => undefined)
    vi.spyOn(window, "fetch").mockResolvedValue(new Response(JSON.stringify({ id: 123 }), {
      status: 200,
      headers: { "Content-Type": "application/json" }
    }))
    const MissingChunkRoute = lazy(() => Promise.reject(new Error("Failed to fetch dynamically imported module")))

    render(
      <LazyRouteBoundary>
        <MissingChunkRoute />
      </LazyRouteBoundary>
    )

    expect(await screen.findByText("Something went wrong")).toBeInTheDocument()
    expect(screen.getByText("Failed to fetch dynamically imported module")).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Reload page" })).toBeInTheDocument()
    await waitFor(() => expect(window.fetch).toHaveBeenCalledWith(
      "/api/v1/app/browser_errors",
      expect.objectContaining({ method: "POST" })
    ))
  })
})
