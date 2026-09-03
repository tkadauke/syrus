import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { act, fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes, useLocation, useParams } from "react-router-dom"
import { jsonResponse } from "@app/testSupport"
import { DesignDocsSurface } from "./DesignDocsSurface"
import type { DesignDocSummary } from "../api/designDocs"

const originalMatchMedia = Object.getOwnPropertyDescriptor(window, "matchMedia")

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
  permissions: {
    can_write_canonical: true,
    can_suggest: true,
    can_review_suggestions: true
  },
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
  }, {
    id: 17,
    state: "open",
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
    opened_by: { id: 2, name: "Editor", email_address: "editor@example.com" },
    resolved_by: null,
    resolved_at: null,
    comments: [{ id: 18, author_kind: "user", author: { id: 2, name: "Editor", email_address: "editor@example.com" }, body: "Why this wording?", created_at: "2026-08-29T12:02:30Z", updated_at: "2026-08-29T12:02:30Z" }],
    created_at: "2026-08-29T12:02:00Z",
    updated_at: "2026-08-29T12:02:30Z"
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
    thread: {
      id: 17,
      state: "open",
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
      opened_by: { id: 2, name: "Editor", email_address: "editor@example.com" },
      resolved_by: null,
      resolved_at: null,
      comments: [{ id: 18, author_kind: "user", author: { id: 2, name: "Editor", email_address: "editor@example.com" }, body: "Why this wording?", created_at: "2026-08-29T12:02:30Z", updated_at: "2026-08-29T12:02:30Z" }],
      created_at: "2026-08-29T12:02:00Z",
      updated_at: "2026-08-29T12:02:30Z"
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

const reviewerDocDetail = {
  ...docDetail,
  id: 3,
  display_id: "DOC-3",
  permissions: {
    can_write_canonical: false,
    can_suggest: true,
    can_review_suggestions: false
  }
}

function renderSurface(path = "/design_docs") {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(
    <QueryClientProvider client={client}>
      <MemoryRouter initialEntries={[path]}>
        <Routes>
          <Route path="/design_docs" element={<DesignDocsTestRoute />} />
          <Route path="/design_docs/:id" element={<DesignDocsTestRoute />} />
          <Route path="/repositories/:repositoryId/design_docs" element={<RepositoryDesignDocsTestRoute />} />
          <Route path="/chats/:id" element={<DesignDocsSurface chatId={237} compact designDocIds={[1]} initialDesignDocId={1} initialDesignDocs={[docDetail as DesignDocSummary]} mode="chat" repositoryId={10} />} />
          <Route path="/chats/:id/empty" element={<DesignDocsSurface chatId={237} compact designDocIds={[]} initialDesignDocs={[]} mode="chat" repositoryId={10} />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function DesignDocsTestRoute() {
  const params = useParams()

  return (
    <>
      <DesignDocsSurface mode={params.id ? "show" : "index"} />
      <LocationProbe />
    </>
  )
}

function RepositoryDesignDocsTestRoute() {
  return (
    <>
      <DesignDocsSurface mode="repository" repositoryId={10} />
      <LocationProbe />
    </>
  )
}

function LocationProbe() {
  const location = useLocation()
  return <output data-testid="location">{`${location.pathname}${location.search}`}</output>
}

function indexPayload() {
  return {
    active_smart_folder_id: null,
    filter: { and: [] },
    filter_schema: [
      { field: "repository_id", label: "Repository", bucket: "fk", operators: ["is", "is_not", "is_one_of", "is_none_of"], values: [], typeahead: true },
      { field: "owner_user_id", label: "Owner", bucket: "enum", operators: ["is", "is_not", "is_set", "is_unset"], values: [{ value: "me", label: "Me" }] },
      { field: "state", label: "State", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of"], values: [{ value: "draft", label: "Draft" }] },
      { field: "visibility", label: "Visibility", bucket: "enum", operators: ["is", "is_not", "is_one_of", "is_none_of"], values: [{ value: "public", label: "Public" }] },
      { field: "updated_at", label: "Updated", bucket: "date", operators: ["before", "after", "between", "within_last", "more_than_ago"], values: [] }
    ],
    smart_folders: [
      {
        id: 3,
        name: "My docs",
        i18n_key: "design_docs_mine",
        position: 0,
        kind: "builtin",
        subject_type: "design_doc",
        visibility: "always",
        count: 1,
        active: false,
        filter: { and: [{ field: "owner_user_id", op: "is", value: "me" }] },
        path: "/design_docs?smart_folder_id=3"
      },
      {
        id: 8,
        name: "Accepted docs",
        i18n_key: null,
        position: 1,
        kind: "user_defined",
        subject_type: "design_doc",
        visibility: "user_defined",
        count: 1,
        active: false,
        filter: { and: [{ field: "state", op: "is", value: "accepted" }] },
        path: "/design_docs?smart_folder_id=8"
      }
    ],
    design_docs: [docDetail, secondDocDetail]
  }
}

function mockFetch() {
  return vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
    const url = new URL(String(input), "http://test.host")
    if (url.pathname === "/api/v1/app/repositories") {
      return jsonResponse({ active_repositories: [{ id: 10, slug: "acme/widgets" }], archived_repositories: [], new_repository_path: "/repositories/new" })
    }
    if (url.pathname === "/api/v1/app/design_docs" && (!init || init.method === undefined)) {
      return jsonResponse(indexPayload())
    }
    if (url.pathname === "/api/v1/app/repositories/10/design_docs" && (!init || init.method === undefined)) {
      return jsonResponse(indexPayload())
    }
    if (url.pathname === "/api/v1/app/design_docs/1" && (!init || init.method === undefined)) {
      return jsonResponse({ design_doc: docDetail })
    }
    if (url.pathname === "/api/v1/app/design_docs/1" && init?.method === "PATCH") {
      return jsonResponse({ design_doc: docDetail, mode: "canonical", message: "Design doc updated." })
    }
    if (url.pathname === "/api/v1/app/design_docs/2" && (!init || init.method === undefined)) {
      return jsonResponse({ design_doc: secondDocDetail })
    }
    if (url.pathname === "/api/v1/app/design_docs/3" && (!init || init.method === undefined)) {
      return jsonResponse({ design_doc: reviewerDocDetail })
    }
    if (url.pathname === "/api/v1/app/design_docs/3" && init?.method === "PATCH") {
      return jsonResponse({ design_doc: reviewerDocDetail, mode: "suggestion", message: "Suggestion created." })
    }
    if (url.pathname === "/api/v1/app/design_docs/3/suggestions") {
      return jsonResponse({ design_doc: reviewerDocDetail, suggestion: { ...docDetail.suggestions[0], id: 11 }, message: "Suggestion created." }, 201)
    }
    if (url.pathname === "/api/v1/app/design_docs/1/suggestions") {
      return jsonResponse({ design_doc: docDetail, suggestion: { ...docDetail.suggestions[0], id: 12 }, message: "Suggestion created." }, 201)
    }
    if (url.pathname === "/api/v1/app/design_docs/1/comments") {
      const payload = JSON.parse(String(init?.body ?? "{}"))
      if (payload.comment?.thread_id === 7) {
        const commentThread = {
          ...docDetail.threads[0],
          comments: [...docDetail.threads[0].comments, { id: 10, author_kind: "user", author: docDetail.owner, body: "Follow up", created_at: "2026-08-29T12:03:00Z", updated_at: "2026-08-29T12:03:00Z" }]
        }
        return jsonResponse({
          design_doc: {
            ...docDetail,
            threads: [commentThread, docDetail.threads[1]]
          },
          message: "Comment created."
        }, 201)
      }
      if (payload.comment?.thread_id === 17) {
        const suggestionThread = {
          ...docDetail.threads[1],
          comments: [...docDetail.threads[1].comments, { id: 19, author_kind: "user", author: docDetail.owner, body: "Agreed", created_at: "2026-08-29T12:04:00Z", updated_at: "2026-08-29T12:04:00Z" }]
        }
        const suggestion = { ...docDetail.suggestions[0], thread: suggestionThread }
        return jsonResponse({
          design_doc: {
            ...docDetail,
            threads: [docDetail.threads[0], suggestionThread],
            suggestions: [suggestion]
          },
          message: "Comment created."
        }, 201)
      }
      return jsonResponse({ design_doc: { ...docDetail, open_threads_count: 2 }, message: "Comment created." }, 201)
    }
    if (url.pathname === "/api/v1/app/design_docs/1/threads/7/resolve") {
      return jsonResponse({ thread: { ...docDetail.threads[0], state: "resolved" }, message: "Comment thread resolved." })
    }
    if (url.pathname === "/api/v1/app/design_docs/1/suggestions/9/accept") {
      return jsonResponse({ design_doc: { ...docDetail, suggestions: [{ ...docDetail.suggestions[0], state: "accepted" }] }, suggestion: { ...docDetail.suggestions[0], state: "accepted" }, message: "Suggestion accepted." })
    }
    if (url.pathname === "/api/v1/app/design_docs/1/suggestions/9/reject") {
      return jsonResponse({ design_doc: { ...docDetail, suggestions: [{ ...docDetail.suggestions[0], state: "rejected" }] }, suggestion: { ...docDetail.suggestions[0], state: "rejected" }, message: "Suggestion rejected." })
    }
    if (url.pathname === "/api/v1/app/design_docs/1/versions") {
      return jsonResponse({ design_doc: docDetail, versions: [{ id: 1, version_number: 1, markdown: "Historical body", actor_kind: "user", actor: docDetail.owner, change_summary: "Initial", metadata: {}, created_at: "2026-08-29T12:00:00Z" }] })
    }
    return jsonResponse({ error: { message: `Unhandled ${url.pathname}` } }, 404)
  })
}

function mockMobileViewport() {
  Object.defineProperty(window, "matchMedia", {
    configurable: true,
    writable: true,
    value: vi.fn((query: string) => ({
      matches: false,
      media: query,
      onchange: null,
      addEventListener: vi.fn(),
      removeEventListener: vi.fn(),
      addListener: vi.fn(),
      removeListener: vi.fn(),
      dispatchEvent: vi.fn()
    }))
  })
}

describe("DesignDocsSurface", () => {
  afterEach(() => {
    vi.useRealTimers()
    vi.restoreAllMocks()
    if (originalMatchMedia) {
      Object.defineProperty(window, "matchMedia", originalMatchMedia)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  })

  it("shows index filters on the list page, then navigates into a focused detail editor", async () => {
    mockFetch()
    renderSurface()

    expect(await screen.findByRole("heading", { name: "Design Docs" })).toBeInTheDocument()
    expect(await screen.findByRole("button", { name: /Checkout design/ })).toBeInTheDocument()
    expect(screen.getByTestId("design-docs-filter-bar")).toBeInTheDocument()
    expect(await screen.findByRole("button", { name: /\+ Add filter/ })).toBeInTheDocument()
    expect(screen.queryByRole("combobox", { name: "Repository filter" })).not.toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Design Docs smart folders" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Accepted docs 1" })).not.toBeInTheDocument()
    fireEvent.click(await screen.findByRole("button", { name: /Checkout design/ }))

    expect(await screen.findByRole("textbox", { name: "Rich Text editor" })).toHaveTextContent("Alpha beta gamma")
    expect(screen.getByTestId("location")).toHaveTextContent("/design_docs/1")
    expect(screen.queryByTestId("design-docs-filter-bar")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Billing design/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Design Docs smart folders" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "Accepted docs 1" })).not.toBeInTheDocument()
    expect(screen.getByText("Threads")).toBeInTheDocument()
    expect(screen.getByText("Use newer name")).toBeInTheDocument()
    expect(screen.queryByText("Suggestions")).not.toBeInTheDocument()
    expect(screen.getByRole("region", { name: "Design doc title bar" })).toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: "Version selection" })).toBeInTheDocument()
    expect(screen.getByRole("toolbar", { name: "Formatting toolbar" })).toBeInTheDocument()
  })

  it("loads the focused detail route without fetching or rendering list-page controls", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    expect(await screen.findByRole("textbox", { name: "Rich Text editor" })).toHaveTextContent("Alpha beta gamma")
    expect(screen.queryByRole("heading", { name: "Design Docs" })).not.toBeInTheDocument()
    expect(screen.queryByTestId("design-docs-filter-bar")).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Checkout design/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: /Billing design/ })).not.toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Design Docs smart folders" })).not.toBeInTheDocument()
    expect(fetchSpy.mock.calls.some(([input]) => String(input) === "/api/v1/app/design_docs")).toBe(false)
  })

  it("shows smart folders and filters in a mobile disclosure", async () => {
    mockMobileViewport()
    mockFetch()
    renderSurface()

    fireEvent.click(await screen.findByText("Folders and filters"))

    expect(screen.getByTestId("design-docs-filter-bar")).toBeInTheDocument()
    expect(screen.getByRole("navigation", { name: "Design Docs smart folders" })).toBeInTheDocument()
    expect(await screen.findByRole("link", { name: "My docs 1" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Accepted docs 1" })).toBeInTheDocument()
  })

  it("keeps repository-scoped smart folders visible on desktop because the app sidebar does not own them", async () => {
    mockFetch()
    renderSurface("/repositories/10/design_docs")

    await screen.findByRole("link", { name: "My docs 1" })
    const folderNav = screen.getByRole("navigation", { name: "Design Docs smart folders" })
    const savedFolderNav = screen.getByRole("navigation", { name: "Design Docs smart folders saved" })

    expect(within(folderNav).getByRole("link", { name: "All design docs" })).toHaveAttribute("href", "/repositories/10/design_docs")
    expect(within(folderNav).getByRole("link", { name: "My docs 1" })).toBeInTheDocument()
    expect(within(savedFolderNav).getByRole("link", { name: "Accepted docs 1" })).toBeInTheDocument()
    expect(screen.getByTestId("design-docs-filter-bar")).toBeInTheDocument()
  })

  it("uses the explicit chat design doc instead of treating the chat route id as a doc id", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/chats/237")

    expect(await screen.findByRole("textbox", { name: "Rich Text editor" })).toHaveTextContent("Alpha beta gamma")
    expect(screen.queryByRole("heading", { name: "Design Docs" })).not.toBeInTheDocument()
    expect(screen.getAllByText("DOC-1").length).toBeGreaterThan(0)
    expect(screen.queryByTestId("design-docs-filter-bar")).not.toBeInTheDocument()
    expect(screen.queryByRole("navigation", { name: "Design Docs smart folders" })).not.toBeInTheDocument()
    expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1", expect.objectContaining({ credentials: "same-origin" }))
    expect(fetchSpy.mock.calls.some(([input]) => String(input) === "/api/v1/app/design_docs/237")).toBe(false)
    expect(fetchSpy.mock.calls.some(([input]) => String(input) === "/api/v1/app/design_docs")).toBe(false)
  })

  it("shows a chat empty state instead of guessing a design doc from the chat id", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/chats/237/empty")

    expect(await screen.findByText("No design docs are attached to this chat.")).toBeInTheDocument()
    expect(fetchSpy.mock.calls.some(([input]) => String(input).includes("/api/v1/app/design_docs/237"))).toBe(false)
    expect(fetchSpy.mock.calls.some(([input]) => String(input) === "/api/v1/app/design_docs")).toBe(false)
  })

  it("opens the Threads composer from a compact Markdown selection affordance", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")
    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const editor = screen.getByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement

    editor.setSelectionRange(6, 10)
    fireEvent.mouseUp(editor)
    expect(screen.getByRole("button", { name: "Comment on selection" })).toBeInTheDocument()
    expect(screen.queryByRole("textbox", { name: "Inline comment" })).not.toBeInTheDocument()
    expect(screen.queryByRole("textbox", { name: "Suggested replacement" })).not.toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: "New thread comment" })).toBeInTheDocument()

    fireEvent.click(screen.getByRole("button", { name: "Comment on selection" }))
    await waitFor(() => expect(screen.getByRole("textbox", { name: "New thread comment" })).toHaveFocus())
    fireEvent.change(screen.getByRole("textbox", { name: "New thread comment" }), { target: { value: "Clarify this" } })
    fireEvent.click(screen.getByRole("button", { name: "Comment" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const commentRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments")
    expect(JSON.parse(String(commentRequest?.[1]?.body))).toMatchObject({
      comment: { body: "Clarify this", start_offset: 6, end_offset: 10, selected_markdown: "beta" }
    })
    fireEvent.click(screen.getByRole("button", { name: "Resolve" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/threads/7/resolve", expect.objectContaining({ method: "POST" })))
  })

  it("keeps the compact selection affordance near right-side Markdown selections", async () => {
    mockFetch()
    renderSurface("/design_docs/1")
    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const editor = screen.getByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement
    editor.getBoundingClientRect = vi.fn(() => ({
      bottom: 600,
      height: 600,
      left: 0,
      right: 900,
      top: 0,
      width: 900,
      x: 0,
      y: 0,
      toJSON: () => ({})
    }))

    fireEvent.change(editor, { target: { value: "Alpha beta gamma ".repeat(8) } })
    editor.setSelectionRange(80, 84)
    fireEvent.mouseUp(editor)

    const affordance = screen.getByRole("button", { name: "Comment on selection" }).parentElement
    expect(affordance).toHaveStyle({ left: "688px" })
  })

  it("opens the Threads composer from a compact Rich Text selection affordance", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const markdownEditor = screen.getByRole("textbox", { name: "Markdown editor" })
    fireEvent.change(markdownEditor, { target: { value: "Alpha **beta** gamma" } })
    fireEvent.click(await screen.findByRole("tab", { name: "Rich Text" }))
    const editor = screen.getByRole("textbox", { name: "Rich Text editor" })
    const textNode = editor.querySelector("strong [data-source-start]")!.firstChild!
    const range = document.createRange()
    range.setStart(textNode, 0)
    range.setEnd(textNode, 4)
    window.getSelection()?.removeAllRanges()
    window.getSelection()?.addRange(range)

    fireEvent.mouseUp(editor)
    expect(screen.getByRole("button", { name: "Comment on selection" })).toBeInTheDocument()
    expect(screen.queryByRole("textbox", { name: "Inline comment" })).not.toBeInTheDocument()
    expect(screen.queryByRole("textbox", { name: "Suggested replacement" })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "Comment on selection" }))
    await waitFor(() => expect(screen.getByRole("textbox", { name: "New thread comment" })).toHaveFocus())
    fireEvent.change(screen.getByRole("textbox", { name: "New thread comment" }), { target: { value: "Clarify intro" } })
    fireEvent.click(screen.getByRole("button", { name: "Comment" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const commentRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments")
    expect(JSON.parse(String(commentRequest?.[1]?.body))).toMatchObject({
      comment: { body: "Clarify intro", start_offset: 8, end_offset: 12, selected_markdown: "beta", selected_text: "beta" }
    })
  })

  it("dismisses the Rich Text selection comment affordance when selection is cleared", async () => {
    mockFetch()
    renderSurface("/design_docs/1")

    const editor = await screen.findByRole("textbox", { name: "Rich Text editor" })
    const textNode = editor.querySelector("[data-source-start]")!.firstChild!
    const range = document.createRange()
    range.setStart(textNode, 0)
    range.setEnd(textNode, 5)
    window.getSelection()?.removeAllRanges()
    window.getSelection()?.addRange(range)

    fireEvent.mouseUp(editor)
    expect(screen.getByRole("button", { name: "Comment on selection" })).toBeInTheDocument()
    expect(screen.getByRole("textbox", { name: "New thread comment" })).toBeInTheDocument()

    window.getSelection()?.removeAllRanges()
    fireEvent.blur(editor)

    await waitFor(() => expect(screen.queryByRole("button", { name: "Comment on selection" })).not.toBeInTheDocument())
    expect(screen.queryByRole("textbox", { name: "New thread comment" })).not.toBeInTheDocument()
  })

  it("creates Rich Text comments from source offsets in long formatted list docs", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")
    const markdown = [
      "# Backlog",
      "",
      "- First item with `code` and [link](https://example.test).",
      "- Second item after enough syntax to drift rendered offsets.",
      "",
      "## Open Questions",
      "",
      "- Should backlogged Jobs be owned, claimed, both, or neither by default?"
    ].join("\n")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const markdownEditor = screen.getByRole("textbox", { name: "Markdown editor" })
    fireEvent.change(markdownEditor, { target: { value: markdown } })
    fireEvent.click(await screen.findByRole("tab", { name: "Rich Text" }))
    const editor = screen.getByRole("textbox", { name: "Rich Text editor" })
    const selected = "Should backlogged Jobs be owned, claimed, both, or neither by default?"
    const textNode = Array.from(editor.querySelectorAll("[data-source-start]"))
      .find((node) => node.textContent === selected)!
      .firstChild!
    const range = document.createRange()
    range.setStart(textNode, 0)
    range.setEnd(textNode, selected.length)
    window.getSelection()?.removeAllRanges()
    window.getSelection()?.addRange(range)

    fireEvent.mouseUp(editor)
    fireEvent.click(screen.getByRole("button", { name: "Comment on selection" }))
    await waitFor(() => expect(screen.getByRole("textbox", { name: "New thread comment" })).toHaveFocus())
    fireEvent.change(screen.getByRole("textbox", { name: "New thread comment" }), { target: { value: "Clarify question" } })
    fireEvent.click(screen.getByRole("button", { name: "Comment" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const commentRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments")
    expect(JSON.parse(String(commentRequest?.[1]?.body))).toMatchObject({
      comment: {
        body: "Clarify question",
        start_offset: markdown.indexOf(selected),
        end_offset: markdown.indexOf(selected) + selected.length,
        selected_markdown: selected,
        selected_text: selected
      }
    })
  })

  it("synchronizes focus between inline highlights and the comment rail", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")
    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const editor = screen.getByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement

    expect(container.querySelector("mark[data-anchor-status='active']")).not.toBeNull()
    fireEvent.click(screen.getByText("Needs evidence"))

    expect(editor.selectionStart).toBe(6)
    expect(editor.selectionEnd).toBe(10)

    fireEvent.click(screen.getByRole("tab", { name: "Rich Text" }))
    const wysiwygHighlight = await waitFor(() => container.querySelector("mark[data-thread-id='7']"))
    fireEvent.click(wysiwygHighlight!)

    expect(screen.getByText("Needs evidence").closest("[data-anchor-offset]")).toHaveClass("border-amber-400")
  })

  it("groups replies beneath their parent comment thread", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByText("Needs evidence")
    fireEvent.change(screen.getByRole("textbox", { name: "Reply to thread 7" }), { target: { value: "Follow up" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Reply" })[0])

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const replyRequest = fetchSpy.mock.calls.filter((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments").at(-1)
    expect(JSON.parse(String(replyRequest?.[1]?.body))).toMatchObject({
      comment: { body: "Follow up", thread_id: 7 }
    })
    expect(await screen.findByText("Follow up")).toBeInTheDocument()
  })

  it("supports replies on pending suggestion threads", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByText("Use newer name")
    expect(screen.getByText("Why this wording?")).toBeInTheDocument()
    fireEvent.change(screen.getByRole("textbox", { name: "Reply to suggestion 9" }), { target: { value: "Agreed" } })
    fireEvent.click(screen.getAllByRole("button", { name: "Reply" }).at(-1)!)

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const replyRequest = fetchSpy.mock.calls.filter((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments").at(-1)
    expect(JSON.parse(String(replyRequest?.[1]?.body))).toMatchObject({
      comment: { body: "Agreed", thread_id: 17 }
    })
    expect(await screen.findByText("Agreed")).toBeInTheDocument()
  })

  it("removes reviewed suggestions from active threads after accept or reject", async () => {
    const fetchSpy = mockFetch()
    const acceptedRender = renderSurface("/design_docs/1")

    await screen.findByText("Use newer name")
    fireEvent.click(screen.getByRole("button", { name: "Accept" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/suggestions/9/accept", expect.objectContaining({ method: "POST" })))
    await waitFor(() => expect(screen.queryByText("Use newer name")).not.toBeInTheDocument())
    expect(screen.queryByText("Why this wording?")).not.toBeInTheDocument()

    acceptedRender.unmount()
    renderSurface("/design_docs/1")
    await screen.findByText("Use newer name")
    fireEvent.click(screen.getByRole("button", { name: "Reject" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/suggestions/9/reject", expect.objectContaining({ method: "POST" })))
    await waitFor(() => expect(screen.queryByText("Use newer name")).not.toBeInTheDocument())
    expect(screen.queryByText("Why this wording?")).not.toBeInTheDocument()
  })

  it("resets draft editor state when opening a different focused design doc route", async () => {
    mockFetch()
    const first = renderSurface("/design_docs/1")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const firstEditor = screen.getByRole("textbox", { name: "Markdown editor" })
    fireEvent.change(firstEditor, { target: { value: "Unsaved first doc edits" } })
    first.unmount()

    renderSurface("/design_docs/2")

    expect(await screen.findByRole("textbox", { name: "Rich Text editor" })).toHaveTextContent("Second document body")
    expect(screen.getByRole("textbox", { name: "Design doc title" })).toHaveValue("Billing design")
  })

  it("preserves active filters when selecting a design doc", async () => {
    mockFetch()
    renderSurface("/design_docs?q=eyJhbmQiOltdfQ%3D%3D")

    fireEvent.click(await screen.findByRole("button", { name: /Billing design/ }))

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue("Second document body")
    expect(screen.getByTestId("location")).toHaveTextContent("/design_docs/2?q=eyJhbmQiOltdfQ%3D%3D")
  })

  it("switches editor tabs without losing unsaved local edits", async () => {
    mockFetch()
    renderSurface("/design_docs/1")

    const richTextTab = await screen.findByRole("tab", { name: "Rich Text" })
    const markdownTab = screen.getByRole("tab", { name: "Markdown" })

    expect(richTextTab).toHaveAttribute("aria-selected", "true")
    fireEvent.click(markdownTab)
    const markdownEditor = screen.getByRole("textbox", { name: "Markdown editor" })
    fireEvent.change(markdownEditor, { target: { value: "Unsaved **local** edits" } })
    fireEvent.click(richTextTab)

    expect(richTextTab).toHaveAttribute("aria-selected", "true")
    const richTextEditor = screen.getByRole("textbox", { name: "Rich Text editor" })
    expect(richTextEditor).toHaveTextContent("Unsaved local edits")
    expect(richTextEditor).not.toHaveTextContent("**local**")

    richTextEditor.textContent = "Edited from Rich Text"
    fireEvent.input(richTextEditor)
    fireEvent.click(markdownTab)

    expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue("Edited from Rich Text")
  })

  it("renders the documented Markdown command set in the Rich Text editor without activating raw HTML", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")
    const markdown = [
      "#### Scope",
      "",
      "> Quote **important** context.",
      "",
      "| Feature | Status |",
      "| --- | --- |",
      "| `code` | ~~removed~~ |",
      "",
      "1. First",
      "   - Nested",
      "2. Second",
      "",
      "---",
      "",
      "Plain *italic*, **bold**, `inline`, [link](https://example.test), and ~~strike~~.",
      "",
      "```ts",
      "<script>alert('x')</script>",
      "```"
    ].join("\n")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: markdown } })
    fireEvent.click(screen.getByRole("tab", { name: "Rich Text" }))

    const editor = screen.getByRole("textbox", { name: "Rich Text editor" })
    expect(within(editor).getByRole("heading", { level: 4, name: "Scope" })).toBeInTheDocument()
    expect(editor.querySelector("blockquote strong")).toHaveTextContent("important")
    expect(editor.querySelector("table th")).toHaveTextContent("Feature")
    expect(editor.querySelector("table code")).toHaveTextContent("code")
    expect(editor.querySelector("table del")).toHaveTextContent("removed")
    expect(editor.querySelector("ol > li > ul")).toHaveTextContent("Nested")
    expect(editor.querySelector("hr")).not.toBeNull()
    expect(editor.querySelector("em")).toHaveTextContent("italic")
    expect(editor.querySelector("strong")).toHaveTextContent("important")
    expect(editor.querySelector("p code")).toHaveTextContent("inline")
    expect(within(editor).getByRole("link", { name: "link" })).toHaveAttribute("href", "https://example.test")
    expect(editor.querySelector("p del")).toHaveTextContent("strike")
    expect(editor.querySelector("pre code")).toHaveTextContent("<script>alert('x')</script>")
    expect(container.querySelector("script")).toBeNull()

    fireEvent.input(editor)
    fireEvent.click(screen.getByRole("tab", { name: "Markdown" }))
    expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue(markdown)
  })

  it("lets owners switch between Edit and Suggest change modes", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByRole("textbox", { name: "Rich Text editor" })
    const changeMode = screen.getByRole("group", { name: "Change mode" })
    const editButton = within(changeMode).getByRole("button", { name: "Edit" })
    const suggestButton = within(changeMode).getByRole("button", { name: "Suggest" })

    expect(editButton).toHaveAttribute("aria-pressed", "true")
    expect(suggestButton).toHaveAttribute("aria-pressed", "false")
    expect(screen.getByRole("button", { name: "Save" })).toBeInTheDocument()
    expect(screen.queryByRole("textbox", { name: "Change summary" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("tab", { name: "Markdown" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: "Owner direct edit" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    expect(screen.getByRole("textbox", { name: "Change summary" })).toHaveAttribute("placeholder", "Optional change summary")
    fireEvent.change(screen.getByRole("textbox", { name: "Change summary" }), { target: { value: "Checkpoint notes" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1", expect.objectContaining({ method: "PATCH" })))
    const checkpointRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1" && call[1]?.method === "PATCH")
    expect(JSON.parse(String(checkpointRequest?.[1]?.body))).toMatchObject({
      design_doc: { markdown: "Owner direct edit", checkpoint: true, change_summary: "Checkpoint notes" }
    })

    fireEvent.click(suggestButton)
    expect(suggestButton).toHaveAttribute("aria-pressed", "true")
    expect(screen.getByRole("button", { name: "Suggest changes" })).toBeInTheDocument()
    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: "Owner suggested edit" } })
    fireEvent.click(screen.getByRole("button", { name: "Suggest changes" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/suggestions", expect.objectContaining({ method: "POST" })))
    const suggestionRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1/suggestions")
    expect(JSON.parse(String(suggestionRequest?.[1]?.body))).toMatchObject({
      suggestion: { original_markdown: "Alpha beta gamma", proposed_markdown: "Owner suggested edit" }
    })
  })

  it("uses the shared temporary toast for design doc notices", async () => {
    vi.useFakeTimers({ shouldAdvanceTime: true })
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByRole("textbox", { name: "Rich Text editor" })
    fireEvent.click(screen.getByRole("tab", { name: "Markdown" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: "Owner direct edit" } })
    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    fireEvent.click(screen.getByRole("button", { name: "Save" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1", expect.objectContaining({ method: "PATCH" })))
    const toast = screen.getAllByRole("status").find((element) => element.textContent?.includes("Design doc saved."))
    expect(toast).toBeDefined()
    expect(screen.getByRole("button", { name: "Dismiss notification" })).toBeInTheDocument()

    await act(async () => {
      await vi.advanceTimersByTimeAsync(3_000)
    })

    await waitFor(() => expect(screen.queryByText("Design doc saved.")).not.toBeInTheDocument())
  })

  it("runs formatting toolbar commands against Markdown and persists Suggest mode as a suggestion", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByRole("textbox", { name: "Rich Text editor" })
    const changeMode = screen.getByRole("group", { name: "Change mode" })
    fireEvent.click(within(changeMode).getByRole("button", { name: "Suggest" }))
    fireEvent.click(screen.getByRole("tab", { name: "Markdown" }))
    const editor = screen.getByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement
    editor.setSelectionRange(6, 10)
    fireEvent.mouseUp(editor)
    fireEvent.click(screen.getByRole("button", { name: "Bold" }))

    await waitFor(() => expect(editor).toHaveValue("Alpha **beta** gamma"))
    fireEvent.click(screen.getByRole("button", { name: "Suggest changes" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/suggestions", expect.objectContaining({ method: "POST" })))
    const suggestionRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1/suggestions")
    expect(JSON.parse(String(suggestionRequest?.[1]?.body))).toMatchObject({
      suggestion: {
        original_markdown: "Alpha beta gamma",
        proposed_markdown: "Alpha **beta** gamma"
      }
    })
  })

  it("visibly applies formatting toolbar commands while the Rich Text editor stays focused", async () => {
    mockFetch()
    renderSurface("/design_docs/1")

    const editor = await screen.findByRole("textbox", { name: "Rich Text editor" })
    fireEvent.click(screen.getByRole("button", { name: "Bold" }))

    await waitFor(() => expect(within(editor).getByText("text").closest("strong")).not.toBeNull())
    fireEvent.click(screen.getByRole("tab", { name: "Markdown" }))
    expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue("**text**Alpha beta gamma")
  })

  it("applies toolbar block dropdown and More menu insert commands while keeping Rich Text synchronized", async () => {
    mockFetch()
    renderSurface("/design_docs/1")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const editor = screen.getByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement
    fireEvent.change(editor, { target: { value: "Alpha\nbeta\ngamma" } })
    editor.setSelectionRange(6, 10)
    fireEvent.mouseUp(editor)
    fireEvent.change(screen.getByRole("combobox", { name: "Block type" }), { target: { value: "heading_2" } })

    await waitFor(() => expect(editor).toHaveValue("Alpha\n## beta\ngamma"))
    expect(screen.getByRole("combobox", { name: "Block type" })).toHaveValue("heading_2")

    editor.setSelectionRange(editor.value.length, editor.value.length)
    fireEvent.mouseUp(editor)
    fireEvent.click(screen.getByRole("button", { name: "More formatting" }))
    fireEvent.click(screen.getByRole("menuitem", { name: "Divider" }))

    await waitFor(() => expect(editor).toHaveValue("Alpha\n## beta\ngamma\n\n---"))
    fireEvent.click(screen.getByRole("tab", { name: "Rich Text" }))
    expect(screen.getByRole("textbox", { name: "Rich Text editor" }).querySelector("hr")).not.toBeNull()
  })

  it("collapses list controls into the formatting overflow menu on narrow viewports", async () => {
    mockMobileViewport()
    mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByRole("textbox", { name: "Rich Text editor" })
    expect(screen.queryByRole("group", { name: "List formatting" })).not.toBeInTheDocument()
    fireEvent.click(screen.getByRole("button", { name: "More formatting" }))

    expect(screen.getByRole("menuitem", { name: "Bulleted list" })).toBeInTheDocument()
    expect(screen.getByRole("menuitem", { name: "Numbered list" })).toBeInTheDocument()
    expect(screen.getByTestId("design-doc-formatting-toolbar")).not.toHaveClass("overflow-x-auto")
    expect(screen.getByTestId("design-doc-formatting-toolbar-scroll")).toHaveClass("overflow-x-auto")
    expect(screen.getByRole("menu").parentElement).toHaveClass("relative")
  })

  it("dismisses the formatting overflow menu with outside pointer input or Escape", async () => {
    mockFetch()
    renderSurface("/design_docs/1")

    const editor = await screen.findByRole("textbox", { name: "Rich Text editor" })
    const moreButton = screen.getByRole("button", { name: "More formatting" })
    fireEvent.click(moreButton)
    expect(screen.getByRole("menu")).toBeInTheDocument()

    fireEvent.pointerDown(editor)
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()

    fireEvent.click(moreButton)
    expect(screen.getByRole("menu")).toBeInTheDocument()
    fireEvent.keyDown(window, { key: "Escape" })
    expect(screen.queryByRole("menu")).not.toBeInTheDocument()
  })

  it("disables formatting commands that would rewrite protected Markdown spans", async () => {
    mockFetch()
    renderSurface("/design_docs/1")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const editor = screen.getByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement
    fireEvent.change(editor, { target: { value: "Alpha `beta` gamma" } })
    editor.setSelectionRange(7, 11)
    fireEvent.mouseUp(editor)

    expect(screen.getByRole("button", { name: "Bold" })).toBeDisabled()
    expect(screen.getByRole("button", { name: "Inline code" })).toBeDisabled()
  })

  it("renders title-bar controls for repositories, sharing, and far-right versions", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    const titleBar = await screen.findByRole("region", { name: "Design doc title bar" })
    expect(within(titleBar).getByRole("textbox", { name: "Design doc title" })).toHaveValue("Checkout design")
    expect(within(titleBar).getByText("DOC-1")).toBeInTheDocument()
    expect(within(titleBar).getByText("private")).toBeInTheDocument()
    expect(within(titleBar).getByText("draft")).toBeInTheDocument()
    expect(within(titleBar).getByText("acme/widgets")).toBeInTheDocument()
    expect(within(titleBar).getByRole("button", { name: "Add repository" })).toBeInTheDocument()
    expect(within(titleBar).getByRole("button", { name: "Share" })).toBeInTheDocument()
    expect(within(titleBar).getByRole("combobox", { name: "Version selection" })).toHaveClass("ml-auto")

    fireEvent.click(within(titleBar).getByRole("button", { name: "Add repository" }))
    expect(within(titleBar).getByRole("listbox", { name: "Repository associations" })).toBeInTheDocument()

    fireEvent.click(within(titleBar).getByRole("button", { name: "Share" }))
    expect(within(titleBar).getByRole("combobox", { name: "Share visibility" })).toBeInTheDocument()
    expect(within(titleBar).getByRole("textbox", { name: "Collaborator user IDs" })).toHaveValue("2")

    const versionSelect = within(titleBar).getByRole("combobox", { name: "Version selection" })
    fireEvent.focus(versionSelect)
    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/versions", expect.objectContaining({ credentials: "same-origin" })))
    await within(titleBar).findByRole("option", { name: "v1 - Initial" })
    fireEvent.change(versionSelect, { target: { value: "1" } })

    await waitFor(() => expect(screen.getByRole("textbox", { name: "Rich Text editor" })).toHaveTextContent("Historical body"))
  })

  it("opens the share popup toward available space inside the wrapped title bar", async () => {
    mockFetch()
    renderSurface("/chats/237")

    const titleBar = await screen.findByRole("region", { name: "Design doc title bar" })
    vi.spyOn(titleBar, "getBoundingClientRect").mockReturnValue({
      bottom: 360,
      height: 142,
      left: 1364,
      right: 2018,
      top: 218,
      width: 654,
      x: 1364,
      y: 218,
      toJSON: () => ({})
    } as DOMRect)
    const shareButton = within(titleBar).getByRole("button", { name: "Share" })
    vi.spyOn(shareButton, "getBoundingClientRect").mockReturnValue({
      bottom: 350,
      height: 32,
      left: 1400,
      right: 1456,
      top: 318,
      width: 56,
      x: 1400,
      y: 318,
      toJSON: () => ({})
    } as DOMRect)

    fireEvent.click(shareButton)

    const shareMenu = screen.getByTestId("design-doc-share-menu")
    expect(shareMenu).toHaveClass("left-0")
    expect(shareMenu).not.toHaveClass("right-0")
  })

  it("reviews suggestions and exposes version history from the title bar", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByText("Use newer name")
    fireEvent.click(screen.getByRole("button", { name: "Accept" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/suggestions/9/accept", expect.objectContaining({ method: "POST" })))
    fireEvent.focus(screen.getByRole("combobox", { name: "Version selection" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/versions", expect.objectContaining({ credentials: "same-origin" })))
  })

  it("renders pending suggestions inline in Markdown and Rich Text without changing canonical markdown", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const markdownEditor = screen.getByRole("textbox", { name: "Markdown editor" })
    expect(markdownEditor).toHaveValue("Alpha beta gamma")
    const markdownSuggestion = container.querySelector("[data-inline-suggestion-state='pending']")
    expect(markdownSuggestion?.querySelector("del")).toHaveTextContent("gamma")
    expect(markdownSuggestion?.querySelector("ins")).toHaveTextContent("delta")
    expect(markdownSuggestion?.querySelector("del")).toHaveClass("text-warning")
    expect(markdownSuggestion?.querySelector("ins")).toHaveClass("text-success")

    fireEvent.click(screen.getByRole("tab", { name: "Rich Text" }))
    const wysiwygEditor = screen.getByRole("textbox", { name: "Rich Text editor" })
    const wysiwygSuggestion = wysiwygEditor.querySelector("[data-inline-suggestion-state='pending']")
    expect(wysiwygSuggestion?.querySelector("del")).toHaveTextContent("gamma")
    expect(wysiwygSuggestion?.querySelector("ins")).toHaveTextContent("delta")

    fireEvent.input(wysiwygEditor)
    fireEvent.click(screen.getByRole("tab", { name: "Markdown" }))
    expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue("Alpha beta gamma")
  })

  it("keeps Markdown inline rendering synchronized with textarea scrolling", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    const markdownEditor = screen.getByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement
    const mirror = container.querySelector("[data-testid='markdown-highlight-mirror']")
    expect(mirror).not.toBeNull()

    markdownEditor.scrollTop = 144
    fireEvent.scroll(markdownEditor)

    expect(mirror).toHaveStyle({ transform: "translateY(-144px)" })
  })

  it("shows review-only suggestion state for non-owners without direct-commit affordances", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/3")

    expect(await screen.findByRole("button", { name: "Suggest changes" })).toBeInTheDocument()
    expect(screen.getByRole("group", { name: "Change mode" })).toHaveTextContent("Suggest")
    expect(screen.queryByRole("button", { name: "Edit" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Reject" })).not.toBeInTheDocument()
    expect(screen.getByText("Pending owner review.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Share" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Add repository" })).not.toBeInTheDocument()

    fireEvent.click(screen.getByRole("tab", { name: "Markdown" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: "Alpha beta delta" } })
    fireEvent.click(screen.getByRole("button", { name: "Suggest changes" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/3/suggestions", expect.objectContaining({ method: "POST" })))
    const request = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/3/suggestions" && call[1]?.method === "POST")
    expect(JSON.parse(String(request?.[1]?.body))).toMatchObject({
      suggestion: { original_markdown: "Alpha beta gamma", proposed_markdown: "Alpha beta delta" }
    })
  })

  it("keeps the editor layout responsive with fixed grid constraints", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")

    await screen.findByRole("textbox", { name: "Rich Text editor" })
    expect(container.querySelector(".min-h-\\[36rem\\]")).not.toBeNull()
    expect(container.querySelector(".xl\\:grid-cols-\\[minmax\\(0\\,1fr\\)_22rem\\]")).not.toBeNull()
    expect(container.querySelector(".lg\\:grid-cols-2")).toBeNull()
  })

  it("autosaves owner draft edits so reload preserves them before checkpoint save", async () => {
    let currentDoc = { ...docDetail }
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      const url = new URL(String(input), "http://test.host")
      if (url.pathname === "/api/v1/app/repositories") {
        return jsonResponse({ active_repositories: [{ id: 10, slug: "acme/widgets" }], archived_repositories: [], new_repository_path: "/repositories/new" })
      }
      if (url.pathname === "/api/v1/app/design_docs/1" && (!init || init.method === undefined)) {
        return jsonResponse({ design_doc: currentDoc })
      }
      if (url.pathname === "/api/v1/app/design_docs/1" && init?.method === "PATCH") {
        const payload = JSON.parse(String(init.body))
        currentDoc = {
          ...currentDoc,
          title: payload.design_doc.title,
          markdown: payload.design_doc.markdown,
          rendered_markdown: payload.design_doc.markdown
        }
        return jsonResponse({ design_doc: currentDoc, mode: "canonical", message: "Design doc updated." })
      }
      return jsonResponse({ error: { message: `Unhandled ${url.pathname}` } }, 404)
    })

    const first = renderSurface("/design_docs/1")
    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: "Autosaved owner draft" } })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1", expect.objectContaining({ method: "PATCH" }))
    }, { timeout: 1500 })
    const autosaveRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1" && call[1]?.method === "PATCH")
    expect(JSON.parse(String(autosaveRequest?.[1]?.body))).toMatchObject({
      design_doc: { markdown: "Autosaved owner draft" }
    })
    expect(JSON.parse(String(autosaveRequest?.[1]?.body)).design_doc.checkpoint).toBeUndefined()

    first.unmount()
    renderSurface("/design_docs/1")

    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue("Autosaved owner draft")
  })

  it("autosaves pending suggestions so reload preserves them before owner review", async () => {
    const reviewerDoc = { ...reviewerDocDetail, suggestions: [] as typeof docDetail.suggestions, pending_suggestions_count: 0 }
    let currentDoc = reviewerDoc
    const fetchSpy = vi.spyOn(window, "fetch").mockImplementation(async (input, init) => {
      const url = new URL(String(input), "http://test.host")
      if (url.pathname === "/api/v1/app/repositories") {
        return jsonResponse({ active_repositories: [{ id: 10, slug: "acme/widgets" }], archived_repositories: [], new_repository_path: "/repositories/new" })
      }
      if (url.pathname === "/api/v1/app/design_docs/3" && (!init || init.method === undefined)) {
        return jsonResponse({ design_doc: currentDoc })
      }
      if (url.pathname === "/api/v1/app/design_docs/3/suggestions" && init?.method === "POST") {
        const payload = JSON.parse(String(init.body))
        currentDoc = {
          ...currentDoc,
          suggestions: [{
            ...docDetail.suggestions[0],
            id: 40,
            original_markdown: payload.suggestion.original_markdown,
            proposed_markdown: payload.suggestion.proposed_markdown,
            suggested_markdown: payload.suggestion.proposed_markdown,
            provenance: { autosave: true }
          }],
          pending_suggestions_count: 1
        }
        return jsonResponse({ design_doc: currentDoc, suggestion: currentDoc.suggestions[0], message: "Suggestion created." }, 201)
      }
      return jsonResponse({ error: { message: `Unhandled ${url.pathname}` } }, 404)
    })

    const first = renderSurface("/design_docs/3")
    fireEvent.click(await screen.findByRole("tab", { name: "Markdown" }))
    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: "Autosaved suggestion draft" } })

    await waitFor(() => {
      expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/3/suggestions", expect.objectContaining({ method: "POST" }))
    }, { timeout: 1500 })
    const autosaveRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/3/suggestions" && call[1]?.method === "POST")
    expect(JSON.parse(String(autosaveRequest?.[1]?.body))).toMatchObject({
      suggestion: { proposed_markdown: "Autosaved suggestion draft", autosave: true }
    })

    first.unmount()
    renderSurface("/design_docs/3")

    await waitFor(() => expect(screen.getAllByText("Autosaved suggestion draft").length).toBeGreaterThan(0))
  })
})
