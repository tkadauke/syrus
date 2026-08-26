import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { DismissButton } from "./DismissButton"

describe("DismissButton", () => {
  it("renders the given label and calls onClick", () => {
    const onClick = vi.fn()
    render(<DismissButton label="Dismiss notification" onClick={onClick} />)

    fireEvent.click(screen.getByRole("button", { name: "Dismiss notification" }))

    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it("defaults to the larger toast size", () => {
    render(<DismissButton label="Dismiss" onClick={() => {}} />)

    expect(screen.getByRole("button", { name: "Dismiss" }).className).toContain("h-6 w-6")
  })

  it("renders the compact size for inline notices", () => {
    render(<DismissButton label="Dismiss" onClick={() => {}} size="sm" />)

    expect(screen.getByRole("button", { name: "Dismiss" }).className).toContain("h-5 w-5")
  })
})
