import { render, screen } from "@testing-library/react"
import { describe, expect, it, vi } from "vitest"
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

  it("scrolls horizontally to keep the current step in view", () => {
    const scrollIntoView = vi.fn()
    Object.defineProperty(HTMLElement.prototype, "scrollIntoView", {
      configurable: true,
      value: scrollIntoView
    })

    const { rerender } = render(
      <Stepper
        active="one"
        steps={[
          { key: "one", label: "Question 1", done: false },
          { key: "two", label: "Question 2", done: false },
          { key: "three", label: "Question 3", done: false },
          { key: "four", label: "Question 4", done: false }
        ]}
      />
    )

    const stepper = screen.getByRole("list")
    expect(stepper).toHaveClass("w-full", "min-w-0", "overflow-x-auto")
    expect(screen.getByText("Question 4").closest("li")).toHaveClass("shrink-0")

    scrollIntoView.mockClear()
    rerender(
      <Stepper
        active="four"
        steps={[
          { key: "one", label: "Question 1", done: true },
          { key: "two", label: "Question 2", done: true },
          { key: "three", label: "Question 3", done: true },
          { key: "four", label: "Question 4", done: false }
        ]}
      />
    )

    expect(screen.getByRole("listitem", { current: "step" })).toHaveTextContent("Question 4")
    expect(scrollIntoView).toHaveBeenCalledWith({ block: "nearest", inline: "nearest" })
  })
})
