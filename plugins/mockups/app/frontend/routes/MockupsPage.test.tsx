import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"

import MockupsPage from "./MockupsPage"

function summary(overrides: Record<string, unknown> = {}) {
  return {
    id: 1,
    slug: "MOCKUP-1",
    title: "Nav sketch",
    preview_panel_id: 4,
    chat_session_id: 2,
    entry_viewer_kind: "html",
    file_count: 3,
    published_at: "2026-09-05T10:00:00Z",
    updated_at: "2026-09-05T10:00:00Z",
    app_path: "/mockups/MOCKUP-1",
    ...overrides
  }
}

function detail() {
  return {
    mockup: summary(),
    panel: {
      id: 4,
      title: "Nav sketch",
      state: "open",
      visibility: "public",
      file_count: 3,
      url: "http://preview-panel-4.lvh.me",
      app_export_path: "/api/v1/app/preview_panels/4/export",
      app_file_base_path: "/api/v1/app/preview_panels/4/files",
      app_token_path: "/api/v1/app/preview_panels/4/token",
      current_version_id: 9,
      entry_path: "index.html",
      entry_content_type: "text/html",
      entry_viewer_kind: "html",
      updated_at: "2026-09-05T10:00:00Z",
      versions: [ { id: 9, created_at: "2026-09-05T10:00:00Z", entry_path: "index.html", entry_content_type: "text/html", entry_viewer_kind: "html" } ]
    }
  }
}

function renderPage(initialEntry = "/mockups") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[ initialEntry ]}>
        <Routes>
          <Route element={<MockupsPage />} path="/mockups" />
          <Route element={<MockupsPage />} path="/mockups/:id" />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("MockupsPage", () => {
  afterEach(() => vi.restoreAllMocks())

  it("lists mockups by slug and title", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(jsonResponse({ mockups: [ summary() ], filter: null, filter_schema: [], pagination: { page: 1, per_page: 30, total: 1, has_next_page: false, has_previous_page: false } })))

    renderPage()

    expect(await screen.findByText("MOCKUP-1")).toBeInTheDocument()
    expect(screen.getByText("Nav sketch")).toBeInTheDocument()
  })

  it("says so when there are none, rather than showing an empty frame", async () => {
    vi.spyOn(window, "fetch").mockImplementation(() =>
      Promise.resolve(jsonResponse({ mockups: [], filter: null, filter_schema: [], pagination: { page: 1, per_page: 30, total: 0, has_next_page: false, has_previous_page: false } })))

    renderPage()

    expect(await screen.findByText(/No mockups yet/)).toBeInTheDocument()
  })

  // The click opens the mockup beside the list rather than navigating away, so
  // the filtered list the operator built stays on screen.
  it("opens the selected mockup in the side panel", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/mockups/")) return Promise.resolve(jsonResponse(detail()))
      return Promise.resolve(jsonResponse({ mockups: [ summary() ], filter: null, filter_schema: [], pagination: { page: 1, per_page: 30, total: 1, has_next_page: false, has_previous_page: false } }))
    })

    renderPage()
    fireEvent.click(await screen.findByRole("button", { name: /MOCKUP-1/ }))

    expect(await screen.findByRole("complementary", { name: "Mockup preview" })).toBeInTheDocument()
    // The html panel renders in a sandboxed iframe titled after the mockup.
    expect(await screen.findByTitle("Nav sketch")).toBeInTheDocument()
  })

  it("renders the preview directly when the route carries a slug", async () => {
    vi.spyOn(window, "fetch").mockImplementation((input) => {
      const path = String(input)
      if (path.startsWith("/api/v1/app/mockups/")) return Promise.resolve(jsonResponse(detail()))
      return Promise.resolve(jsonResponse({ mockups: [ summary() ], filter: null, filter_schema: [], pagination: { page: 1, per_page: 30, total: 1, has_next_page: false, has_previous_page: false } }))
    })

    renderPage("/mockups/MOCKUP-1")

    await waitFor(() => expect(screen.getByRole("complementary", { name: "Mockup preview" })).toBeInTheDocument())
  })
})
