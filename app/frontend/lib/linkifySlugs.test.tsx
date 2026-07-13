import { render, screen } from "@testing-library/react"
import { isValidElement, type ReactElement } from "react"
import { MemoryRouter, Link } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { SlugHoverCard } from "../components/SlugHoverCard"
import { linkifySlugs } from "./linkifySlugs"

describe("linkifySlugs", () => {
  it("links JOB slugs and keeps surrounding text", () => {
    const nodes = linkifySlugs("Submit feedback on JOB-42")
    const hoverCard = nodes.find((node) => isValidElement(node) && node.type === SlugHoverCard)

    expect(nodes[0]).toBe("Submit feedback on ")
    expect(hoverCard).toBeTruthy()
    const card = hoverCard as ReactElement<{ kind: string; id: number; children: ReactElement<{ to: string }> }>
    expect(card.props.kind).toBe("job")
    expect(card.props.id).toBe(42)
    expect(card.props.children.props.to).toBe("/jobs/42")
  })

  it("links EPIC slugs", () => {
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
})
