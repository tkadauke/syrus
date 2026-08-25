import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { Card, Skeleton } from "./Card"

describe("Card", () => {
  it("renders children with the base variant by default", () => {
    render(<Card data-testid="card">Content</Card>)
    const card = screen.getByTestId("card")
    expect(card).toHaveTextContent("Content")
    expect(card.className).toContain("rounded")
    expect(card.className).toContain("border-border")
    expect(card.className).toContain("bg-surface")
    expect(card.className).not.toContain("shadow-lg")
  })

  it("applies the preview variant's popover styling", () => {
    render(<Card data-testid="card" variant="preview">Content</Card>)
    const card = screen.getByTestId("card")
    expect(card.className).toContain("w-80")
    expect(card.className).toContain("shadow-lg")
    expect(card.className).toContain("rounded-lg")
  })

  it("applies the compact preview variant's narrower sizing", () => {
    render(
      <Card compact data-testid="card" variant="preview">
        Content
      </Card>
    )
    const card = screen.getByTestId("card")
    expect(card.className).toContain("w-40")
    expect(card.className).not.toContain("w-80")
  })

  it("ignores compact when the variant is base", () => {
    render(
      <Card compact data-testid="card">
        Content
      </Card>
    )
    const card = screen.getByTestId("card")
    expect(card.className).not.toContain("w-40")
    expect(card.className).not.toContain("w-80")
  })

  it("merges a caller-supplied className instead of replacing the base classes", () => {
    render(
      <Card className="mt-4" data-testid="card">
        Content
      </Card>
    )
    const card = screen.getByTestId("card")
    expect(card.className).toContain("mt-4")
    expect(card.className).toContain("border-border")
  })

  it("forwards other div props such as onClick", () => {
    render(<Card data-testid="card" role="button">Content</Card>)
    expect(screen.getByTestId("card")).toHaveAttribute("role", "button")
  })
})

describe("Skeleton", () => {
  it("renders a pulsing placeholder bar", () => {
    render(<Skeleton className="h-4 w-3/4" data-testid="skeleton" />)
    const skeleton = screen.getByTestId("skeleton")
    expect(skeleton.className).toContain("animate-pulse")
    expect(skeleton.className).toContain("bg-border")
    expect(skeleton.className).toContain("h-4")
    expect(skeleton.className).toContain("w-3/4")
  })
})
