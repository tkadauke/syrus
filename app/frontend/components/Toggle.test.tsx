import { createRef } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Toggle } from "./Toggle"

describe("Toggle", () => {
  it("renders as a switch", () => {
    render(<Toggle checked={false} label="Auto-merge" onChange={vi.fn()} />)
    expect(screen.getByRole("switch", { name: "Auto-merge" })).toBeInTheDocument()
  })

  it("uses a block-level flex wrapper for labeled toggles", () => {
    render(<Toggle checked={false} label="Auto-merge" onChange={vi.fn()} />)
    const label = screen.getByText("Auto-merge").closest("label")
    expect(label).toHaveClass("flex")
    expect(label).not.toHaveClass("inline-flex")
  })

  it("reflects the checked state via aria-checked", () => {
    render(<Toggle checked label="Auto-merge" onChange={vi.fn()} />)
    expect(screen.getByRole("switch", { name: "Auto-merge" })).toHaveAttribute("aria-checked", "true")
  })

  it("reflects the unchecked state via aria-checked", () => {
    render(<Toggle checked={false} label="Auto-merge" onChange={vi.fn()} />)
    expect(screen.getByRole("switch", { name: "Auto-merge" })).toHaveAttribute("aria-checked", "false")
  })

  it("calls onChange with the flipped value when clicked", () => {
    const onChange = vi.fn()
    render(<Toggle checked={false} label="Auto-merge" onChange={onChange} />)
    fireEvent.click(screen.getByRole("switch", { name: "Auto-merge" }))
    expect(onChange).toHaveBeenCalledWith(true)
  })

  it("calls onChange with false when clicked while checked", () => {
    const onChange = vi.fn()
    render(<Toggle checked label="Auto-merge" onChange={onChange} />)
    fireEvent.click(screen.getByRole("switch", { name: "Auto-merge" }))
    expect(onChange).toHaveBeenCalledWith(false)
  })

  it("respects disabled", () => {
    const onChange = vi.fn()
    render(<Toggle checked={false} disabled label="Auto-merge" onChange={onChange} />)
    const button = screen.getByRole("switch", { name: "Auto-merge" })
    expect(button).toBeDisabled()
    fireEvent.click(button)
    expect(onChange).not.toHaveBeenCalled()
  })

  it("works without a label using aria-label directly", () => {
    render(<Toggle aria-label="Auto-merge" checked={false} onChange={vi.fn()} />)
    expect(screen.getByRole("switch", { name: "Auto-merge" })).toBeInTheDocument()
  })

  it("forwards a ref to the underlying button element", () => {
    const ref = createRef<HTMLButtonElement>()
    render(<Toggle checked={false} label="Auto-merge" onChange={vi.fn()} ref={ref} />)
    expect(ref.current).toBeInstanceOf(HTMLButtonElement)
  })
})
