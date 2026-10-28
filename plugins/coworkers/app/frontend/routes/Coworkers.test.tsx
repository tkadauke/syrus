import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { beforeEach, expect, it, vi } from "vitest"
import CoworkersRoute from "./Coworkers"

beforeEach(() => {
  vi.stubGlobal(
    "fetch",
    vi.fn(
      async () =>
        new Response(
          JSON.stringify({
            syrus: {
              id: "syrus",
              name: "Syrus",
              handle: "syrus",
              role_summary: "Engineer",
              state: "active",
              color_key: "coral-deep",
              avatar_key: null,
              avatar_url: null,
              path: "/coworkers/syrus",
              built_in: true
            },
            coworkers: [
              {
                id: 7,
                name: "Maya",
                handle: "maya",
                role_summary: "Researcher",
                state: "active",
                color_key: "rose-soft",
                avatar_key: "comet",
                avatar_url: null,
                path: "/coworkers/7"
              }
            ]
          }),
          { status: 200, headers: { "Content-Type": "application/json" } }
        )
    )
  )
})

it("pins Syrus before custom coworkers and exposes creation", async () => {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={["/coworkers"]}>
        <Routes>
          <Route path="/coworkers/*" element={<CoworkersRoute />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )

  expect(await screen.findByText("Syrus")).toBeInTheDocument()
  expect(screen.getByText("Maya")).toBeInTheDocument()
  expect(screen.getByRole("link", { name: /New coworker/i })).toHaveAttribute("href", "/coworkers/new")
})
