import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { StatusPill } from "./StatusPill"

describe("StatusPill", () => {
  it("renders the state as human-readable text", () => {
    render(<StatusPill state="approved" />)
    expect(screen.getByText("approved")).toBeInTheDocument()
  })

  it("adds Latin tooltip for approved state", () => {
    render(<StatusPill state="approved" />)
    expect(screen.getByTitle("Probatum est — It is proven")).toBeInTheDocument()
  })

  it("adds Latin tooltip for merged state", () => {
    render(<StatusPill state="merged" />)
    expect(screen.getByTitle("In annales scriptum — Written in the annals")).toBeInTheDocument()
  })

  it("adds Latin tooltip for unmergeable state", () => {
    render(<StatusPill state="unmergeable" />)
    expect(screen.getByTitle("Bellum Civile — Civil war between branches")).toBeInTheDocument()
  })

  it("adds Latin tooltip for mergeable state", () => {
    render(<StatusPill state="mergeable" />)
    expect(screen.getByTitle("Concordia — Harmony")).toBeInTheDocument()
  })

  it("renders without a title for unknown states", () => {
    render(<StatusPill state="custom_state" />)
    const pill = screen.getByText("custom state").closest("[data-status-pill]")
    expect(pill).not.toHaveAttribute("title")
  })
})
