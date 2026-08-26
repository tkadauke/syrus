import { createRef } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Input } from "./Input"

describe("Input", () => {
  it("renders a text input with a placeholder", () => {
    render(<Input placeholder="Search…" />)
    expect(screen.getByPlaceholderText("Search…")).toBeInTheDocument()
  })

  it("is not marked invalid by default", () => {
    render(<Input aria-label="Name" />)
    const input = screen.getByLabelText("Name")
    expect(input).not.toHaveAttribute("aria-invalid")
    expect(input.className).toContain("border-border")
  })

  it("marks itself aria-invalid and applies the danger token when invalid", () => {
    render(<Input aria-label="Name" invalid />)
    const input = screen.getByLabelText("Name")
    expect(input).toHaveAttribute("aria-invalid", "true")
    expect(input.className).toContain("border-danger")
  })

  it("calls onChange as the user types", () => {
    const onChange = vi.fn()
    render(<Input aria-label="Name" onChange={onChange} />)
    fireEvent.change(screen.getByLabelText("Name"), { target: { value: "Ada" } })
    expect(onChange).toHaveBeenCalledTimes(1)
  })

  it("respects disabled", () => {
    render(<Input aria-label="Name" disabled />)
    expect(screen.getByLabelText("Name")).toBeDisabled()
  })

  it("merges a caller-supplied className instead of replacing the base classes", () => {
    render(<Input aria-label="Name" className="font-mono" />)
    const className = screen.getByLabelText("Name").className
    expect(className).toContain("font-mono")
    expect(className).toContain("rounded-md")
  })

  it("forwards a ref to the underlying input element", () => {
    const ref = createRef<HTMLInputElement>()
    render(<Input aria-label="Name" ref={ref} />)
    expect(ref.current).toBeInstanceOf(HTMLInputElement)
  })

  it("is full width by default", () => {
    render(<Input aria-label="Name" />)
    expect(screen.getByLabelText("Name").className).toContain("w-full")
  })

  it("renders w-auto instead of w-full when fullWidth is false", () => {
    render(<Input aria-label="Name" fullWidth={false} />)
    const className = screen.getByLabelText("Name").className
    expect(className).toContain("w-auto")
    expect(className).not.toMatch(/\bw-full\b/)
  })
})
