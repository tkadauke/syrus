import { render, screen } from "@testing-library/react"
import { isValidElement, type ReactElement } from "react"
import { MemoryRouter, Link } from "react-router-dom"
import { describe, expect, it } from "vitest"
import { linkifySlugs } from "./linkifySlugs"

describe("linkifySlugs", () => {
  it("links JOB slugs and keeps surrounding text", () => {
    const nodes = linkifySlugs("Submit feedback on JOB-42")
    const linkNode = nodes.find((node) => isValidElement(node) && node.type === Link)

    expect(nodes[0]).toBe("Submit feedback on ")
    expect(linkNode).toBeTruthy()
    expect(isValidElement(linkNode) ? (linkNode as ReactElement<{ to: string }>).props.to : null).toBe("/jobs/42")
  })

  it("links EPIC slugs", () => {
    const nodes = linkifySlugs("See EPIC-7 for context")
    const linkNode = nodes.find((node) => isValidElement(node) && node.type === Link)

    expect(linkNode).toBeTruthy()
    expect(isValidElement(linkNode) ? (linkNode as ReactElement<{ to: string }>).props.to : null).toBe("/epics/7")
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
