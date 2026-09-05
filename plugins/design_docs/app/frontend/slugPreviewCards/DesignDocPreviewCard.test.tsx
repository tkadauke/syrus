import { jsonResponse } from "@app/testSupport"
import { QueryClient, QueryClientProvider } from "@tanstack/react-query"
import { render, screen, waitFor } from "@testing-library/react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { DesignDocPreviewCard } from "./DesignDocPreviewCard"

function renderCard(id: number, compact = false) {
  const qc = new QueryClient({ defaultOptions: { queries: { retry: false } } })
  render(
    <QueryClientProvider client={qc}>
      <MemoryRouter>
        <DesignDocPreviewCard compact={compact} id={id} />
      </MemoryRouter>
    </QueryClientProvider>
  )
}

describe("DesignDocPreviewCard", () => {
  afterEach(() => vi.restoreAllMocks())

  it("shows a skeleton while the preview is loading", () => {
    vi.spyOn(window, "fetch").mockReturnValue(new Promise(() => {}))
    renderCard(20)
    expect(document.querySelector(".animate-pulse")).toBeInTheDocument()
  })

  it("renders the copyable slug, linked title, preview text, owner, comment count, version, and updated time", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      design_doc: {
        id: 20,
        display_id: "DOC-20",
        accessible: true,
        title: "Target Graphs for Project-Aware Workflows",
        visibility: "public",
        state: "draft",
        owner: { id: 1, name: "Ada", email_address: "ada@example.com" },
        collaborators: [{ id: 2, name: "Grace", email_address: "grace@example.com" }],
        comments_count: 4,
        latest_version_number: 21,
        updated_at: "2026-09-01T12:00:00Z",
        preview_text: "## Summary\nA short design overview."
      }
    }))

    renderCard(20)

    await waitFor(() => expect(screen.getByRole("link", { name: "Target Graphs for Project-Aware Workflows" })).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Copy DOC-20 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "Target Graphs for Project-Aware Workflows" })).toHaveAttribute("href", "/design_docs/20")
    expect(screen.getByText("Summary")).toBeInTheDocument()
    expect(screen.queryByText(/## Summary/)).not.toBeInTheDocument()
    expect(screen.getByText("Owner: Ada")).toBeInTheDocument()
    expect(screen.getByText("Collaborators: Grace")).toBeInTheDocument()
    expect(screen.getByText("4 comments")).toBeInTheDocument()
    expect(screen.getByText("v21")).toBeInTheDocument()
    expect(screen.getByRole("link", { name: "See more" })).toHaveAttribute("href", "/design_docs/20")
  })

  it("clamps preview-rendered heading font size so the card stays compact", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      design_doc: {
        id: 20,
        display_id: "DOC-20",
        accessible: true,
        title: "T",
        owner: { id: 1, name: "Ada", email_address: "ada@example.com" },
        collaborators: [],
        comments_count: 0,
        latest_version_number: 1,
        updated_at: "2026-09-01T12:00:00Z",
        preview_text: "# Heading\nBody text."
      }
    }))

    renderCard(20)

    const heading = await screen.findByRole("heading", { level: 1, name: "Heading" })
    // font-size clamping lives in a plain, unlayered CSS rule
    // (.chat-prose-compact-headings h1..h4 in application.css), not a Tailwind
    // utility class, because Tailwind v4 wraps utilities -- including
    // arbitrary-variant ones -- in `@layer utilities`, which always loses to
    // an unlayered rule like `.chat-prose h1` regardless of specificity. This
    // asserts the wiring that activates that rule; the rule's actual effect
    // is not visible under jsdom, which doesn't apply the compiled stylesheet.
    expect(heading.closest(".chat-prose")).toHaveClass("chat-prose-compact-headings")
  })

  it("shows a concise collaborator summary when there are many collaborators", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      design_doc: {
        id: 20,
        display_id: "DOC-20",
        accessible: true,
        title: "T",
        owner: { id: 1, name: "Ada", email_address: "ada@example.com" },
        collaborators: [
          { id: 2, name: "Grace", email_address: "grace@example.com" },
          { id: 3, name: "Alan", email_address: "alan@example.com" },
          { id: 4, name: "Barbara", email_address: "barbara@example.com" },
          { id: 5, name: "Edsger", email_address: "edsger@example.com" },
          { id: 6, name: "Margaret", email_address: "margaret@example.com" }
        ],
        comments_count: 0,
        latest_version_number: 1,
        updated_at: "2026-09-01T12:00:00Z",
        preview_text: "Body"
      }
    }))

    renderCard(20)

    await waitFor(() => expect(screen.getByText("Collaborators: Grace, Alan, Barbara +2")).toBeInTheDocument())
  })

  it("renders a minimal not-accessible state without leaking title, owner, or content", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      design_doc: { id: 99, display_id: "DOC-99", accessible: false }
    }))

    renderCard(99)

    await waitFor(() => expect(screen.getByText("Not accessible")).toBeInTheDocument())
    expect(screen.getByRole("button", { name: "Copy DOC-99 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByRole("link")).not.toBeInTheDocument()
    expect(screen.queryByText(/Owner/)).not.toBeInTheDocument()
  })

  it("renders an empty document without a preview text block or crashing", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      design_doc: {
        id: 20,
        display_id: "DOC-20",
        accessible: true,
        title: "Empty doc",
        owner: { id: 1, name: "Ada", email_address: "ada@example.com" },
        collaborators: [],
        comments_count: 0,
        latest_version_number: 1,
        updated_at: "2026-09-01T12:00:00Z",
        preview_text: ""
      }
    }))

    renderCard(20)

    await waitFor(() => expect(screen.getByRole("link", { name: "Empty doc" })).toBeInTheDocument())
    expect(screen.getByText("0 comments")).toBeInTheDocument()
    expect(screen.queryByText(/Collaborators/)).not.toBeInTheDocument()
  })

  it("compact: hides preview text, owner, collaborators, and the see-more link", async () => {
    vi.spyOn(window, "fetch").mockResolvedValue(jsonResponse({
      design_doc: {
        id: 20,
        display_id: "DOC-20",
        accessible: true,
        title: "T",
        owner: { id: 1, name: "Ada", email_address: "ada@example.com" },
        collaborators: [{ id: 2, name: "Grace", email_address: "grace@example.com" }],
        comments_count: 1,
        latest_version_number: 1,
        updated_at: "2026-09-01T12:00:00Z",
        preview_text: "Body text"
      }
    }))

    renderCard(20, true)

    await waitFor(() => expect(screen.getByRole("link", { name: "T" })).toBeInTheDocument())
    expect(screen.queryByText("Body text")).not.toBeInTheDocument()
    expect(screen.queryByText(/Owner/)).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "See more" })).not.toBeInTheDocument()
  })
})
