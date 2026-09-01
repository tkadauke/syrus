import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { fireEvent, render, screen, waitFor, within } from "@testing-library/react"
import { afterEach, describe, expect, it, vi } from "vitest"
import { MemoryRouter, Route, Routes } from "react-router-dom"
import { jsonResponse } from "@app/testSupport"
import { DesignDocsSurface } from "./DesignDocsSurface"

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
          <Route path="/design_docs" element={<DesignDocsSurface mode="index" />} />
          <Route path="/design_docs/:id" element={<DesignDocsSurface mode="index" />} />
          <Route path="/repositories/:repositoryId/design_docs" element={<RepositoryDesignDocsTestRoute />} />
        </Routes>
      </MemoryRouter>
    </QueryClientProvider>
  )
}

function RepositoryDesignDocsTestRoute() {
  return <DesignDocsSurface mode="repository" repositoryId={10} />
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
    if (url.pathname === "/api/v1/app/design_docs/2" && (!init || init.method === undefined)) {
      return jsonResponse({ design_doc: secondDocDetail })
    }
    if (url.pathname === "/api/v1/app/design_docs/3" && (!init || init.method === undefined)) {
      return jsonResponse({ design_doc: reviewerDocDetail })
    }
    if (url.pathname === "/api/v1/app/design_docs/3" && init?.method === "PATCH") {
      return jsonResponse({ design_doc: reviewerDocDetail, mode: "suggestion", message: "Suggestion created." })
    }
    if (url.pathname === "/api/v1/app/design_docs/1/comments") {
      const payload = JSON.parse(String(init?.body ?? "{}"))
      if (payload.comment?.thread_id === 7) {
        return jsonResponse({
          design_doc: {
            ...docDetail,
            threads: [{
              ...docDetail.threads[0],
              comments: [...docDetail.threads[0].comments, { id: 10, author_kind: "user", author: docDetail.owner, body: "Follow up", created_at: "2026-08-29T12:03:00Z", updated_at: "2026-08-29T12:03:00Z" }]
            }]
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
    vi.restoreAllMocks()
    if (originalMatchMedia) {
      Object.defineProperty(window, "matchMedia", originalMatchMedia)
    } else {
      Reflect.deleteProperty(window, "matchMedia")
    }
  })

  it("shows the shared filter bar without duplicating desktop smart folders, and navigates into the detail editor", async () => {
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

    expect(await screen.findByRole("textbox", { name: "Markdown editor" })).toHaveValue("Alpha beta gamma")
    expect(screen.getByText("Threads")).toBeInTheDocument()
    expect(screen.getByText("Suggestions")).toBeInTheDocument()
    expect(screen.getByRole("region", { name: "Design doc title bar" })).toBeInTheDocument()
    expect(screen.getByRole("combobox", { name: "Version selection" })).toBeInTheDocument()
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

  it("creates and resolves comments from an editor selection", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")
    const editor = await screen.findByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement

    editor.setSelectionRange(6, 10)
    fireEvent.mouseUp(editor)
    fireEvent.change(screen.getByRole("textbox", { name: "Inline comment" }), { target: { value: "Clarify this" } })
    fireEvent.click(screen.getByRole("button", { name: "Comment" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const commentRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments")
    expect(JSON.parse(String(commentRequest?.[1]?.body))).toMatchObject({
      comment: { body: "Clarify this", start_offset: 6, end_offset: 10, selected_markdown: "beta" }
    })
    fireEvent.click(screen.getByRole("button", { name: "Resolve" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/threads/7/resolve", expect.objectContaining({ method: "POST" })))
  })

  it("creates comments from a WYSIWYG selection", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    const markdownEditor = await screen.findByRole("textbox", { name: "Markdown editor" })
    fireEvent.change(markdownEditor, { target: { value: "Alpha **beta** gamma" } })
    fireEvent.click(await screen.findByRole("tab", { name: "WYSIWYG" }))
    const editor = screen.getByRole("textbox", { name: "WYSIWYG editor" })
    const textNode = editor.querySelector("strong")!.firstChild!
    const range = document.createRange()
    range.setStart(textNode, 0)
    range.setEnd(textNode, 4)
    window.getSelection()?.removeAllRanges()
    window.getSelection()?.addRange(range)

    fireEvent.mouseUp(editor)
    fireEvent.change(screen.getByRole("textbox", { name: "Inline comment" }), { target: { value: "Clarify intro" } })
    fireEvent.click(screen.getByRole("button", { name: "Comment" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const commentRequest = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments")
    expect(JSON.parse(String(commentRequest?.[1]?.body))).toMatchObject({
      comment: { body: "Clarify intro", start_offset: 8, end_offset: 12, selected_markdown: "beta", selected_text: "beta" }
    })
  })

  it("synchronizes focus between inline highlights and the comment rail", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")
    const editor = await screen.findByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement

    expect(container.querySelector("mark[data-anchor-status='active']")).not.toBeNull()
    fireEvent.click(screen.getByText("Needs evidence"))

    expect(editor.selectionStart).toBe(6)
    expect(editor.selectionEnd).toBe(10)

    fireEvent.click(screen.getByRole("tab", { name: "WYSIWYG" }))
    const wysiwygHighlight = await waitFor(() => container.querySelector("mark[data-thread-id='7']"))
    fireEvent.click(wysiwygHighlight!)

    expect(screen.getByText("Needs evidence").closest("[data-anchor-offset]")).toHaveClass("border-amber-400")
  })

  it("groups replies beneath their parent comment thread", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/1")

    await screen.findByText("Needs evidence")
    fireEvent.change(screen.getByRole("textbox", { name: "Reply to thread 7" }), { target: { value: "Follow up" } })
    fireEvent.click(screen.getByRole("button", { name: "Reply" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/1/comments", expect.objectContaining({ method: "POST" })))
    const replyRequest = fetchSpy.mock.calls.filter((call) => String(call[0]) === "/api/v1/app/design_docs/1/comments").at(-1)
    expect(JSON.parse(String(replyRequest?.[1]?.body))).toMatchObject({
      comment: { body: "Follow up", thread_id: 7 }
    })
    expect(await screen.findByText("Follow up")).toBeInTheDocument()
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

  it("switches editor tabs without losing unsaved local edits", async () => {
    mockFetch()
    renderSurface("/design_docs/1")

    const markdownTab = await screen.findByRole("tab", { name: "Markdown" })
    const wysiwygTab = screen.getByRole("tab", { name: "WYSIWYG" })
    const markdownEditor = screen.getByRole("textbox", { name: "Markdown editor" })

    expect(markdownTab).toHaveAttribute("aria-selected", "true")
    fireEvent.change(markdownEditor, { target: { value: "Unsaved **local** edits" } })
    fireEvent.click(wysiwygTab)

    expect(wysiwygTab).toHaveAttribute("aria-selected", "true")
    const wysiwygEditor = screen.getByRole("textbox", { name: "WYSIWYG editor" })
    expect(wysiwygEditor).toHaveTextContent("Unsaved local edits")
    expect(wysiwygEditor).not.toHaveTextContent("**local**")

    wysiwygEditor.textContent = "Edited from WYSIWYG"
    fireEvent.input(wysiwygEditor)
    fireEvent.click(markdownTab)

    expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue("Edited from WYSIWYG")
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

    await waitFor(() => expect(screen.getByRole("textbox", { name: "Markdown editor" })).toHaveValue("Historical body"))
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

  it("renders pending suggestions inline in Markdown and WYSIWYG without changing canonical markdown", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")

    const markdownEditor = await screen.findByRole("textbox", { name: "Markdown editor" })
    expect(markdownEditor).toHaveValue("Alpha beta gamma")
    const markdownSuggestion = container.querySelector("[data-inline-suggestion-state='pending']")
    expect(markdownSuggestion?.querySelector("del")).toHaveTextContent("gamma")
    expect(markdownSuggestion?.querySelector("ins")).toHaveTextContent("delta")
    expect(markdownSuggestion?.querySelector("del")).toHaveClass("text-warning")
    expect(markdownSuggestion?.querySelector("ins")).toHaveClass("text-success")

    fireEvent.click(screen.getByRole("tab", { name: "WYSIWYG" }))
    const wysiwygEditor = screen.getByRole("textbox", { name: "WYSIWYG editor" })
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

    const markdownEditor = await screen.findByRole("textbox", { name: "Markdown editor" }) as HTMLTextAreaElement
    const mirror = container.querySelector("[data-testid='markdown-highlight-mirror']")
    expect(mirror).not.toBeNull()

    markdownEditor.scrollTop = 144
    fireEvent.scroll(markdownEditor)

    expect(mirror).toHaveStyle({ transform: "translateY(-144px)" })
  })

  it("shows review-only suggestion state for non-owners without direct-commit affordances", async () => {
    const fetchSpy = mockFetch()
    renderSurface("/design_docs/3")

    expect(await screen.findByRole("button", { name: "Propose changes" })).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Accept" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Reject" })).not.toBeInTheDocument()
    expect(screen.getByText("Pending owner review.")).toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Share" })).not.toBeInTheDocument()
    expect(screen.queryByRole("button", { name: "Add repository" })).not.toBeInTheDocument()

    fireEvent.change(screen.getByRole("textbox", { name: "Markdown editor" }), { target: { value: "Alpha beta delta" } })
    fireEvent.click(screen.getByRole("button", { name: "Propose changes" }))

    await waitFor(() => expect(fetchSpy).toHaveBeenCalledWith("/api/v1/app/design_docs/3", expect.objectContaining({ method: "PATCH" })))
    const request = fetchSpy.mock.calls.find((call) => String(call[0]) === "/api/v1/app/design_docs/3" && call[1]?.method === "PATCH")
    expect(JSON.parse(String(request?.[1]?.body))).toMatchObject({
      design_doc: { markdown: "Alpha beta delta" }
    })
  })

  it("keeps the editor layout responsive with fixed grid constraints", async () => {
    mockFetch()
    const { container } = renderSurface("/design_docs/1")

    await screen.findByRole("textbox", { name: "Markdown editor" })
    expect(container.querySelector(".min-h-\\[36rem\\]")).not.toBeNull()
    expect(container.querySelector(".xl\\:grid-cols-\\[minmax\\(0\\,1fr\\)_22rem\\]")).not.toBeNull()
    expect(container.querySelector(".lg\\:grid-cols-2")).toBeNull()
  })
})
