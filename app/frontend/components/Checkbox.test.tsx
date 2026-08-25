import { createRef } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Checkbox } from "./Checkbox"

describe("Checkbox", () => {
  it("renders an unlabeled checkbox input", () => {
    render(<Checkbox aria-label="Enabled" />)
    expect(screen.getByRole("checkbox", { name: "Enabled" })).toBeInTheDocument()
  })

  it("renders a visible label and associates it via wrapping", () => {
    render(<Checkbox label="Enable feature" />)
    expect(screen.getByRole("checkbox", { name: "Enable feature" })).toBeInTheDocument()
    expect(screen.getByText("Enable feature")).toBeInTheDocument()
  })

  it("reflects the checked state", () => {
    render(<Checkbox checked label="Enable feature" readOnly />)
    expect(screen.getByRole("checkbox", { name: "Enable feature" })).toBeChecked()
  })

  it("calls onChange when toggled", () => {
    const onChange = vi.fn()
    render(<Checkbox label="Enable feature" onChange={onChange} />)
    fireEvent.click(screen.getByRole("checkbox", { name: "Enable feature" }))
    expect(onChange).toHaveBeenCalledTimes(1)
  })

  it("respects disabled", () => {
    render(<Checkbox disabled label="Enable feature" />)
    expect(screen.getByRole("checkbox", { name: "Enable feature" })).toBeDisabled()
  })

  it("forwards a ref to the underlying input element even without a label", () => {
    const ref = createRef<HTMLInputElement>()
    render(<Checkbox aria-label="Enabled" ref={ref} />)
    expect(ref.current).toBeInstanceOf(HTMLInputElement)
  })
})
