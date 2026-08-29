import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { jsonResponse } from "@app/testSupport"
import { DesignDocsSurface } from "./DesignDocsSurface"

const docDetail = {
  id: 1,
  display_id: "DOC-1",
  title: "Checkout design",
  visibility: "private",
  state: "draft",
  owner: { id: 1, name: "Owner", email_address: "owner@example.com" },
  repository_ids: [10],
  repositories: [{ id: 10, slug: "acme/widgets" }],
  current_version_number: 1,
  origin_chat_session_id: 5,
  updated_at: "2026-08-29T12:00:00Z",
  created_at: "2026-08-29T11:00:00Z",
  markdown: "Alpha beta gamma",
  rendered_markdown: "Alpha beta gamma",
  collaborator_ids: [2],
  collaborators: [{ id: 2, name: "Editor", email_address: "editor@example.com" }],
  pending_suggestions_count: 1,
  open_threads_count: 1,
  threads: [{
    id: 7,
    state: "open",
    anchor: {
      id: 20,
      anchor_key: "a",
      marker_id: "m1",
      anchor_kind: "range",
      status: "active",
      start_offset: 6,
      end_offset: 10,
      last_known_start_offset: 6,
      last_known_end_offset: 10,
      selected_markdown: "beta",
      selected_text: "beta",
      prefix_context: null,
      suffix_context: null
    },
    opened_by: { id: 2, name: "Editor", email_address: "editor@example.com" },
    resolved_by: null,
    resolved_at: null,
    comments: [{ id: 8, author_kind: "user", author: { id: 2, name: "Editor", email_address: "editor@example.com" }, body: "Needs evidence", created_at: "2026-08-29T12:01:00Z", updated_at: "2026-08-29T12:01:00Z" }],
    created_at: "2026-08-29T12:01:00Z",
    updated_at: "2026-08-29T12:01:00Z"
  }],
  suggestions: [{
    id: 9,
    state: "pending",
    suggested_by_kind: "user",
    suggested_by: { id: 2, name: "Editor", email_address: "editor@example.com" },
    original_markdown: "gamma",
    suggested_markdown: "delta",
    proposed_markdown: "delta",
    change_type: "replace",
    change_summary: "Use newer name",
    base_version_id: 1,
    provenance: {},
    conflict_reason: null,
    anchor: {
      id: 21,
      anchor_key: "b",
      marker_id: "m2",
      anchor_kind: "range",
      status: "active",
      start_offset: 11,
      end_offset: 16,
      last_known_start_offset: 11,
      last_known_end_offset: 16,
      selected_markdown: "gamma",
      selected_text: "gamma",
      prefix_context: null,
      suffix_context: null
    },
    reviewed_by: null,
    reviewed_at: null,
    created_at: "2026-08-29T12:02:00Z"
  }]
}

const secondDocDetail = {
  ...docDetail,
  id: 2,
  display_id: "DOC-2",
  title: "Billing design",
  repository_ids: [],
  repositories: [],
  markdown: "Second document body",
  rendered_markdown: "Second document body",
  collaborator_ids: [],
  collaborators: [],
  pending_suggestions_count: 0,
  open_threads_count: 0,
  threads: [],
  suggestions: []
}

function renderSurface(path = "/design_docs") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/design_docs" element={<DesignDocsSurface mode="index" />} />
          <Route path="/design_docs/:id" element={<DesignDocsSurface mode="index" />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function mockFetch() {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const path = String(input)
    if (path === "/api/v1/app/repositories") {
      return jsonResponse({ active_repositories: [{ id: 10, slug: "acme/widgets" }], archived_repositories: [], new_repository_path: "/repositories/new" })
    }
    if (path === "/api/v1/app/design_docs" && (!init || init.method === undefined)) {
      return jsonResponse({ design_docs: [docDetail, secondDocDetail] })
    }
    if (path === "/api/v1/app/design_docs/1" && (!init || init.method === undefined)) {
      return jsonResponse({ design_doc: docDetail })
    }
    if (path === "/api/v1/app/design_docs/2" && (!init || init.method === undefined)) {
      return jsonResponse({ design_doc: secondDocDetail })
    }
    if (path === "/api/v1/app/design_docs/1/comments") {
      return jsonResponse({ design_doc: { ...docDetail, open_threads_count: 2 }, message: "Comment created." }, 201)
    }
    if (path === "/api/v1/app/design_docs/1/threads/7/resolve") {
      return jsonResponse({ thread: { ...docDetail.threads[0], state: "resolved" }, message: "Comment thread resolved." })
    }
    if (path === "/api/v1/app/design_docs/1/suggestions/9/accept") {
      return jsonResponse({ design_doc: { ...docDetail, suggestions: [{ ...docDetail.suggestions[0], state: "accepted" }] }, suggestion: { ...docDetail.suggestions[0], state: "accepted" }, message: "Suggestion accepted." })
    }
    if (path === "/api/v1/app/design_docs/1/versions") {
      return jsonResponse({ design_doc: docDetail, versions: [{ id: 1, version_number: 1, markdown: "Alpha beta gamma", actor_kind: "user", actor: docDetail.owner, change_summary: "Initial", metadata: {}, created_at: "2026-08-29T12:00:00Z" }] })
    }
    return jsonResponse({ error: { message: `Unhandled ${path}` } }, 404)
  })
}

describe("DesignDocsSurface", () => {
  afterEach(() => {
    vi.restoreAllMocks()
  })

  it("shows list filters and navigates into the detail editor", async () => {
    mockFetch()
    renderSurface()

    expect(await screen.findByRole("heading", { name: "Design Docs" })).toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: "Repository filter" })).toBeInTheDocument()
    fireEvent.click(await screen.findByRole("button", { name: /Checkout design/ }))

    expect(await screen.findByRole("textbox", { name: "Markdown editor" })).toHaveValue("Alpha beta gamma")
    expect(screen.getByText("Threads")).toBeInTheDocument()
    expect(screen.getByText("Suggestions")).toBeInTheDocument()
    expect(screen.getByText("Controls")).toBeInTheDocument()
    expect(screen.getByText("Versions")).toBeInTheDocument()
  })

  it("creates and resolves comments from an editor selection", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")
    const editor = await screen.findByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement

    editor.setSelectionRange(6, 10)
    fireEvent.mouseUp(editor)
    fireEvent.change(screen.getByRole("textbox", { name: "Inline comment" }), { target: { value: "Clarify this" } })
    fireEvent.click(screen.getByRole("button", { name: "Comment" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    fireEvent.click(screen.getByRole("button", { name: "Resolve" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/threads/7/resolve", expect.objectContaining({ method: "POST" })))
  })

  it("resets draft editor state when switching between design docs", async () => {
    mockFetch()
    renderSurface()

    fireEvent.click(await screen.findByRole("button", { name: /Checkout design/ }))
    const firstEditor = await screen.findByRole("textbox", { name: "Markdown editor" })
    fireEvent.change(firstEditor, { target: { value: "Unsaved first doc edits" } })
    fireEvent.click(await screen.findByRole("button", { name: /Billing design/ }))

    expect(await screen.findByRole("textbox", { name: "Markdown editor" })).toHaveValue("Second document body")
    expect(screen.getByRole("textbox", { name: "Design doc title" })).toHaveValue("Billing design")
  })

  it("reviews suggestions and opens version history", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByText("Use newer name")
    fireEvent.click(screen.getByRole("button", { name: "Accept" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/suggestions/9/accept", expect.objectContaining({ method: "POST" })))
    fireEvent.click(within(screen.getByText("Versions").closest("div")!).getByRole("button", { name: "Show" }))

    expect(await screen.findByText("Version 1")).toBeInTheDocument()
  })

  it("keeps the editor layout responsive with fixed grid constraints", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")

    await screen.findByRole("textbox", { name: "Markdown editor" })
    expect(container.querySelector(".min-h-\\[36rem\\]")).not.toBeNull()
    expect(container.querySelector(".xl\\:grid-cols-\\[minmax\\(0\\,1fr\\)_22rem\\]")).not.toBeNull()
  })
})
