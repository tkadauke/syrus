import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { StatusPill, TonePill } from "./StatusPill"
import i18n from "../i18n"

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

  it("translates the state label into the active locale", async () => {
    await i18n.changeLanguage("de")
    try {
      render(<StatusPill state="approved" />)
      expect(screen.getByText("genehmigt")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("falls back to the humanized state for locales missing the key", async () => {
    await i18n.changeLanguage("de")
    try {
      render(<StatusPill state="custom_state" />)
      expect(screen.getByText("custom state")).toBeInTheDocument()
    } finally {
      await i18n.changeLanguage("en")
    }
  })

  it("can opt into wrapped content for sentence-like pills", () => {
    render(<TonePill tone="gray" wrap>Waiting for JOB-1234 to merge</TonePill>)

    const pill = screen.getByText("Waiting for JOB-1234 to merge").closest("[data-status-pill]")
    expect(pill).toHaveClass("whitespace-normal", "flex-wrap", "max-w-full")
    expect(pill).not.toHaveClass("whitespace-nowrap")
  })
})
