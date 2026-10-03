import { render, screen } from "@testing-library/react"
import { isValidElement, type ReactElement, type ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { afterEach, describe, expect, it, vi } from "vitest"
import { SlugReferenceCard } from "../components/SlugHoverCard"
import { linkifySlugs } from "./linkifySlugs"
import { setSlugReferenceRegistryForTests, type SlugReferenceRegistryEntry } from "./slugReferenceRegistry"

vi.mock("../components/SlugHoverCard", () => ({
  SlugReferenceCard: ({ entry, id, slug, children }: { entry: SlugReferenceRegistryEntry; id: number; slug?: string; children: ReactNode }) => (
    <span data-testid="slug-reference-card" data-prefix={entry.prefix} data-type={entry.type} data-id={String(id)} data-slug={slug}>
      {children}
    </span>
  )
}))

const registryEntry = (overrides: Partial<SlugReferenceRegistryEntry> & Pick<SlugReferenceRegistryEntry, "prefix" | "type">): SlugReferenceRegistryEntry => ({
  displayLabel: overrides.prefix,
  copyable: true,
  linkable: true,
  previewAvailable: true,
  linkifiesGeneratedText: true,
  hrefTemplate: `/${overrides.type}s/:id`,
  mobileInteractionHints: { tap: "open", long_press: "copy" },
  pluginPreviewComponent: null,
  ...overrides
})

afterEach(() => setSlugReferenceRegistryForTests(null))

describe("linkifySlugs", () => {
  it("wraps registered slugs in SlugReferenceCard with registry metadata and numeric id", () => {
    setSlugReferenceRegistryForTests([registryEntry({ prefix: "TASK", type: "task", hrefTemplate: "/tasks/:id" })])

    const nodes = linkifySlugs("Submit feedback on TASK-42")
    const card = nodes.find((node) => isValidElement(node) && node.type === SlugReferenceCard)

    expect(nodes[0]).toBe("Submit feedback on ")
    expect(card).toBeTruthy()
    const reference = card as ReactElement<{ entry: SlugReferenceRegistryEntry; id: number }>
    expect(reference.props.entry.prefix).toBe("TASK")
    expect(reference.props.entry.type).toBe("task")
    expect(reference.props.id).toBe(42)
  })

  it("renders registered slug links with hrefs from the registry template", () => {
    setSlugReferenceRegistryForTests([
      registryEntry({ prefix: "JOB", type: "job", hrefTemplate: "/jobs/JOB-:id" }),
      registryEntry({ prefix: "EPIC", type: "epic", hrefTemplate: "/epics/EPIC-:id" }),
      registryEntry({ prefix: "DOC", type: "design_doc", hrefTemplate: "/design_docs/:id" }),
      registryEntry({ prefix: "INSIGHT", type: "insight", hrefTemplate: "/s/INSIGHT-:id" })
    ])

    render(<MemoryRouter>{linkifySlugs("See JOB-42, EPIC-7, DOC-9, and INSIGHT-5")}</MemoryRouter>)

    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/JOB-42")
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/epics/EPIC-7")
    expect(screen.getByRole("link", { name: "DOC-9" })).toHaveAttribute("href", "/design_docs/9")
    expect(screen.getByRole("link", { name: "INSIGHT-5" })).toHaveAttribute("href", "/s/INSIGHT-5")
  })

  it("keeps one polished control for registered refs that are both linked and copyable", () => {
    setSlugReferenceRegistryForTests([registryEntry({ prefix: "JOB", type: "job", hrefTemplate: "/jobs/JOB-:id" })])

    render(<MemoryRouter>{linkifySlugs("See JOB-42")}</MemoryRouter>)

    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/JOB-42")
    expect(screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })).toBeInTheDocument()
    expect(screen.getAllByText("JOB-42")).toHaveLength(1)
  })

  it("wraps registered copy-only refs so touch users can open actions", () => {
    setSlugReferenceRegistryForTests([registryEntry({ prefix: "INSIGHT", type: "insight", linkable: false, previewAvailable: false, hrefTemplate: null })])

    render(<MemoryRouter>{linkifySlugs("Captured as INSIGHT-5")}</MemoryRouter>)

    expect(screen.getByRole("button", { name: "Copy INSIGHT-5 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "INSIGHT-5" })).not.toBeInTheDocument()
    expect(screen.getByTestId("slug-reference-card")).toHaveAttribute("data-slug", "INSIGHT-5")
  })

  it("renders non-copyable registered refs as plain text when they do not linkify generated text", () => {
    setSlugReferenceRegistryForTests([
      registryEntry({
        prefix: "SECRET",
        type: "secret",
        copyable: false,
        linkable: false,
        previewAvailable: false,
        linkifiesGeneratedText: false,
        hrefTemplate: null
      })
    ])

    const { container } = render(<MemoryRouter>{linkifySlugs("Hidden SECRET-1")}</MemoryRouter>)

    expect(container).toHaveTextContent("Hidden SECRET-1")
    expect(screen.queryByRole("button", { name: "Copy SECRET-1 to clipboard" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "SECRET-1" })).not.toBeInTheDocument()
  })

  it("can render registered slugs as copy-only controls without preview cards", () => {
    setSlugReferenceRegistryForTests([
      registryEntry({ prefix: "JOB", type: "job", hrefTemplate: "/jobs/JOB-:id" }),
      registryEntry({ prefix: "EPIC", type: "epic", hrefTemplate: "/epics/EPIC-:id" })
    ])

    render(<MemoryRouter>{linkifySlugs("Waiting for JOB-42 and EPIC-7", { hoverCards: false, slugStyle: "copyable" })}</MemoryRouter>)

    expect(screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })).toBeInTheDocument()
    expect(screen.getByRole("button", { name: "Copy EPIC-7 to clipboard" })).toBeInTheDocument()
    expect(screen.queryAllByTestId("slug-reference-card")).toHaveLength(0)
  })

  it("keeps preview wrappers for registered copyable refs unless hover cards are disabled", () => {
    setSlugReferenceRegistryForTests([registryEntry({ prefix: "JOB", type: "job", hrefTemplate: "/jobs/JOB-:id" })])

    render(<MemoryRouter>{linkifySlugs("Waiting for JOB-42", { jobStyle: "copyable" })}</MemoryRouter>)

    expect(screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })).toBeInTheDocument()
    expect(screen.getByTestId("slug-reference-card")).toHaveAttribute("data-prefix", "JOB")
    expect(screen.queryByRole("link", { name: "JOB-42" })).not.toBeInTheDocument()
  })

  it("leaves unregistered uppercase Syrus-style slugs as plain text by default", () => {
    setSlugReferenceRegistryForTests([])

    const { container } = render(<MemoryRouter>{linkifySlugs("Blocked by WF-10")}</MemoryRouter>)

    expect(container).toHaveTextContent("Blocked by WF-10")
    expect(screen.queryByRole("button", { name: "Copy WF-10 to clipboard" })).not.toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "WF-10" })).not.toBeInTheDocument()
  })

  it("renders unregistered uppercase Syrus-style slugs as copyable text only when requested", () => {
    setSlugReferenceRegistryForTests([])

    render(<MemoryRouter>{linkifySlugs("Blocked by WF-10, WU-22, RUN-33, and STEP-44", { slugStyle: "copyable" })}</MemoryRouter>)

    for (const slug of ["WF-10", "WU-22", "RUN-33", "STEP-44"]) {
      expect(screen.getByRole("button", { name: `Copy ${slug} to clipboard` })).toBeInTheDocument()
      expect(screen.queryByRole("link", { name: slug })).not.toBeInTheDocument()
    }
  })
})
