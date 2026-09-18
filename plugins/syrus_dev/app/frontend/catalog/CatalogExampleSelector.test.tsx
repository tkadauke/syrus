import { fireEvent, render, screen, within } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
import { CatalogExampleSelector } from "./CatalogExampleSelector"

const EXAMPLES = [
  { id: "one", label: "First example" },
  { id: "two", label: "Second example" }
]

describe("CatalogExampleSelector", () => {
  it("renders nothing when there are zero or one examples", () => {
    const { container: empty } = render(<CatalogExampleSelector ariaLabel="Examples" examples={[]} onSelect={() => {}} selectedId={null} />)
    expect(empty.firstChild).toBeNull()

    const { container: single } = render(<CatalogExampleSelector ariaLabel="Examples" examples={[ EXAMPLES[0] ]} onSelect={() => {}} selectedId="one" />)
    expect(single.firstChild).toBeNull()
  })

  it("renders a tab per example and marks the selected one", () => {
    render(<CatalogExampleSelector ariaLabel="Examples" examples={EXAMPLES} onSelect={() => {}} selectedId="two" />)

    const list = screen.getByRole("tablist", { name: "Examples" })
    expect(within(list).getByRole("tab", { name: "First example", selected: false })).toBeInTheDocument()
    expect(within(list).getByRole("tab", { name: "Second example", selected: true })).toBeInTheDocument()
  })

  it("calls onSelect with the clicked example's id", () => {
    const onSelect = vi.fn()
    render(<CatalogExampleSelector ariaLabel="Examples" examples={EXAMPLES} onSelect={onSelect} selectedId="one" />)

    fireEvent.click(screen.getByRole("tab", { name: "Second example" }))
    expect(onSelect).toHaveBeenCalledWith("two")
  })
})
