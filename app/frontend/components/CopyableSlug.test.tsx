import { fireEvent, render, screen, waitFor } from "@testing-library/react"
import { beforeEach, describe, expect, it, vi } from "vitest"
import { CopyableSlug } from "./CopyableSlug"

describe("CopyableSlug", () => {
  beforeEach(() => {
    Object.assign(navigator, {
      clipboard: { writeText: vi.fn().mockResolvedValue(undefined) }
    })
  })

  it("renders the slug text", () => {
    render(<CopyableSlug slug="EPIC-42" />)
    expect(screen.getByText("EPIC-42")).toBeInTheDocument()
  })

  it("renders a copy button with accessible label", () => {
    render(<CopyableSlug slug="EPIC-42" />)
    expect(screen.getByRole("button", { name: "Copy EPIC-42 to clipboard" })).toBeInTheDocument()
  })

  it("copies the slug to clipboard when clicked", async () => {
    render(<CopyableSlug slug="EPIC-42" />)
    fireEvent.click(screen.getByRole("button", { name: "Copy EPIC-42 to clipboard" }))
    expect(navigator.clipboard.writeText).toHaveBeenCalledWith("EPIC-42")
  })

  it("updates the button title to Copied after click", async () => {
    render(<CopyableSlug slug="EPIC-42" />)
    const button = screen.getByRole("button", { name: "Copy EPIC-42 to clipboard" })
    fireEvent.click(button)
    await waitFor(() => expect(button).toHaveAttribute("title", "Copied"))
  })
})
