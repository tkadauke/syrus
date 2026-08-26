import { createRef } from "react"
import { fireEvent, render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { Button, buttonClasses } from "./Button"

describe("Button", () => {
  it("renders its children", () => {
    render(<Button>Save</Button>)
    expect(screen.getByRole("button", { name: "Save" })).toBeInTheDocument()
  })

  it("defaults to type=button so it never accidentally submits a form", () => {
    render(<Button>Save</Button>)
    expect(screen.getByRole("button", { name: "Save" })).toHaveAttribute("type", "button")
  })

  it("respects an explicit type override", () => {
    render(<Button type="submit">Save</Button>)
    expect(screen.getByRole("button", { name: "Save" })).toHaveAttribute("type", "submit")
  })

  it("defaults to the primary variant styled from the brand token", () => {
    render(<Button>Save</Button>)
    expect(screen.getByRole("button", { name: "Save" }).className).toContain("bg-brand")
  })

  it("applies the secondary variant's token classes", () => {
    render(<Button variant="secondary">Cancel</Button>)
    const button = screen.getByRole("button", { name: "Cancel" })
    expect(button.className).toContain("bg-surface")
    expect(button.className).toContain("border-border")
  })

  it("applies the danger variant's token classes", () => {
    render(<Button variant="danger">Delete</Button>)
    expect(screen.getByRole("button", { name: "Delete" }).className).toContain("bg-danger")
  })

  it("applies the success variant's token classes", () => {
    render(<Button variant="success">Approve</Button>)
    expect(screen.getByRole("button", { name: "Approve" }).className).toContain("bg-success")
  })

  it("never renders raw blue-* or terracotta-* utility classes", () => {
    for (const variant of ["primary", "secondary", "danger", "success"] as const) {
      render(<Button variant={variant}>{variant}</Button>)
      const className = screen.getByRole("button", { name: variant }).className
      expect(className).not.toMatch(/\bblue-\d/)
      expect(className).not.toMatch(/\bterracotta-\d/)
    }
  })

  it("applies size classes", () => {
    render(<Button size="sm">Small</Button>)
    expect(screen.getByRole("button", { name: "Small" }).className).toContain("text-xs")
  })

  it("fires onClick", () => {
    const onClick = vi.fn()
    render(<Button onClick={onClick}>Save</Button>)
    fireEvent.click(screen.getByRole("button", { name: "Save" }))
    expect(onClick).toHaveBeenCalledTimes(1)
  })

  it("respects disabled", () => {
    const onClick = vi.fn()
    render(
      <Button disabled onClick={onClick}>
        Save
      </Button>
    )
    const button = screen.getByRole("button", { name: "Save" })
    expect(button).toBeDisabled()
    fireEvent.click(button)
    expect(onClick).not.toHaveBeenCalled()
  })

  it("merges a caller-supplied className instead of replacing the base classes", () => {
    render(<Button className="w-full">Save</Button>)
    const className = screen.getByRole("button", { name: "Save" }).className
    expect(className).toContain("w-full")
    expect(className).toContain("bg-brand")
  })

  it("forwards a ref to the underlying button element", () => {
    const ref = createRef<HTMLButtonElement>()
    render(<Button ref={ref}>Save</Button>)
    expect(ref.current).toBeInstanceOf(HTMLButtonElement)
  })
})

describe("buttonClasses", () => {
  it("matches the classes the Button component itself renders", () => {
    render(<Button variant="danger">Delete</Button>)
    expect(buttonClasses("danger")).toBe(screen.getByRole("button", { name: "Delete" }).className)
  })

  it("merges a caller-supplied className", () => {
    expect(buttonClasses("primary", "md", "w-full")).toContain("w-full")
  })
})
