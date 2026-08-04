import { render, screen } from "@testing-library/react"
import { isValidElement, type ReactElement, type ReactNode } from "react"
import { MemoryRouter } from "react-router-dom"
import { describe, expect, it, vi } from "vitest"
import { SlugHoverCard } from "../components/SlugHoverCard"
import { linkifySlugs } from "./linkifySlugs"

// Stub SlugHoverCard so tests focus on linkifySlugs wiring, not hover behaviour.
// This also avoids jsdom's lack of window.matchMedia.
vi.mock("../components/SlugHoverCard", () => ({
  SlugHoverCard: ({ kind, id, children }: { kind: string; id: number; children: ReactNode }) => (
    <span data-testid="slug-hover-card" data-kind={kind} data-id={String(id)}>
      {children}
    </span>
  ),
}))

describe("linkifySlugs", () => {
  it("wraps JOB slugs in SlugHoverCard with kind=job and numeric id", () => {
    const nodes = linkifySlugs("Submit feedback on JOB-42")
    const hoverCard = nodes.find((node) => isValidElement(node) && node.type === SlugHoverCard)

    expect(nodes[0]).toBe("Submit feedback on ")
    expect(hoverCard).toBeTruthy()
    const card = hoverCard as ReactElement<{ kind: string; id: number; children: ReactElement<{ to: string }> }>
    expect(card.props.kind).toBe("job")
    expect(card.props.id).toBe(42)
    expect(card.props.children.props.to).toBe("/jobs/42")
  })

  it("wraps EPIC slugs in SlugHoverCard with kind=epic and numeric id", () => {
    const nodes = linkifySlugs("See EPIC-7 for context")
    const hoverCard = nodes.find((node) => isValidElement(node) && node.type === SlugHoverCard)

    expect(hoverCard).toBeTruthy()
    const card = hoverCard as ReactElement<{ kind: string; id: number; children: ReactElement<{ to: string }> }>
    expect(card.props.kind).toBe("epic")
    expect(card.props.id).toBe(7)
    expect(card.props.children.props.to).toBe("/epics/7")
  })

  it("returns plain text unchanged when there are no slugs", () => {
    expect(linkifySlugs("plain text with no slugs")).toEqual(["plain text with no slugs"])
  })

  it("renders slug links with the expected hrefs", () => {
    render(<MemoryRouter>{linkifySlugs("See JOB-42 and EPIC-7")}</MemoryRouter>)

    expect(screen.getByRole("link", { name: "JOB-42" })).toHaveAttribute("href", "/jobs/42")
    expect(screen.getByRole("link", { name: "EPIC-7" })).toHaveAttribute("href", "/epics/7")
  })

  it("can render JOB slugs as copyable hover-card references", () => {
    render(<MemoryRouter>{linkifySlugs("Filed as JOB-42", { jobStyle: "copyable" })}</MemoryRouter>)

    expect(screen.getByRole("button", { name: "Copy JOB-42 to clipboard" })).toBeInTheDocument()
    expect(screen.queryByRole("link", { name: "JOB-42" })).not.toBeInTheDocument()
  })

  it("renders one SlugHoverCard per slug with correct kind and id attributes", () => {
    render(<MemoryRouter>{linkifySlugs("See JOB-42 and EPIC-7")}</MemoryRouter>)

    const cards = screen.getAllByTestId("slug-hover-card")
    const jobCard = cards.find((el) => el.getAttribute("data-kind") === "job")
    const epicCard = cards.find((el) => el.getAttribute("data-kind") === "epic")

    expect(jobCard).toHaveAttribute("data-id", "42")
    expect(epicCard).toHaveAttribute("data-id", "7")
  })
})
