import { createRef } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Select } from "./Select"

describe("Select", () => {
  it("renders its option children", () => {
    render(
      <Select aria-label="Provider">
        <option value="claude">Claude</option>
        <option value="codex">Codex</option>
      </Select>
    )
    const select = screen.getByLabelText("Provider") as HTMLSelectElement
    expect(select.options).toHaveLength(2)
  })

  it("is not marked invalid by default", () => {
    render(
      <Select aria-label="Provider">
        <option value="claude">Claude</option>
      </Select>
    )
    expect(screen.getByLabelText("Provider")).not.toHaveAttribute("aria-invalid")
  })

  it("marks itself aria-invalid and applies the danger token when invalid", () => {
    render(
      <Select aria-label="Provider" invalid>
        <option value="claude">Claude</option>
      </Select>
    )
    const select = screen.getByLabelText("Provider")
    expect(select).toHaveAttribute("aria-invalid", "true")
    expect(select.className).toContain("border-danger")
  })

  it("calls onChange when the selection changes", () => {
    const onChange = vi.fn()
    render(
      <Select aria-label="Provider" onChange={onChange}>
        <option value="claude">Claude</option>
        <option value="codex">Codex</option>
      </Select>
    )
    fireEvent.change(screen.getByLabelText("Provider"), { target: { value: "codex" } })
    expect(onChange).toHaveBeenCalledTimes(1)
  })

  it("forwards a ref to the underlying select element", () => {
    const ref = createRef<HTMLSelectElement>()
    render(
      <Select aria-label="Provider" ref={ref}>
        <option value="claude">Claude</option>
      </Select>
    )
    expect(ref.current).toBeInstanceOf(HTMLSelectElement)
  })

  it("is full width by default", () => {
    render(
      <Select aria-label="Provider">
        <option value="claude">Claude</option>
      </Select>
    )
    expect(screen.getByLabelText("Provider").className).toContain("w-full")
  })

  it("renders w-auto instead of w-full when fullWidth is false", () => {
    render(
      <Select aria-label="Provider" fullWidth={false}>
        <option value="claude">Claude</option>
      </Select>
    )
    const className = screen.getByLabelText("Provider").className
    expect(className).toContain("w-auto")
    expect(className).not.toMatch(/\bw-full\b/)
  })
})
