import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { PageHeading, SectionHeading } from "./Heading"

describe("PageHeading", () => {
  it("renders an h1 with the canonical page-title classes", () => {
    render(<PageHeading>Repositories</PageHeading>)
    const heading = screen.getByRole("heading", { level: 1, name: "Repositories" })
    expect(heading.className).toContain("text-2xl")
    expect(heading.className).toContain("font-semibold")
    expect(heading.className).not.toContain("font-mono")
  })

  it("adds the mono/break-words treatment for slug-style titles", () => {
    render(<PageHeading mono>tkadauke/syrus</PageHeading>)
    const heading = screen.getByRole("heading", { level: 1 })
    expect(heading.className).toContain("font-mono")
    expect(heading.className).toContain("break-words")
  })

  it("merges an extra className onto the base classes", () => {
    render(<PageHeading className="mt-1">Title</PageHeading>)
    const heading = screen.getByRole("heading", { level: 1 })
    expect(heading.className).toContain("mt-1")
    expect(heading.className).toContain("text-2xl")
  })
})

describe("SectionHeading", () => {
  it("renders an h2 by default with the canonical section-title classes", () => {
    render(<SectionHeading>Credential modes</SectionHeading>)
    const heading = screen.getByRole("heading", { level: 2, name: "Credential modes" })
    expect(heading.className).toContain("text-base")
    expect(heading.className).toContain("font-semibold")
  })

  it("renders an h3 when as=\"h3\" is passed", () => {
    render(<SectionHeading as="h3">Nested section</SectionHeading>)
    expect(screen.getByRole("heading", { level: 3, name: "Nested section" })).toBeInTheDocument()
  })
})
