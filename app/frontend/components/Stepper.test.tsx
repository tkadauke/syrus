import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { Stepper } from "./Stepper"

describe("Stepper", () => {
  it("uses semantic brand tokens for the current step", () => {
    render(
      <Stepper
        active="two"
        steps={[
          { key: "one", label: "One", done: true },
          { key: "two", label: "Two", done: false },
          { key: "three", label: "Three", done: false }
        ]}
      />
    )

    const current = screen.getByText("Two").closest("span")
    expect(current).toHaveClass("bg-brand/10", "text-brand", "dark:bg-brand/10", "dark:text-brand-emphasis")
    expect(current?.className).not.toMatch(/\b(?:bg|text)-blue-/)
  })
})
