import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { BeforeAfterVisualComparison } from "./BeforeAfterVisualComparison"

describe("BeforeAfterVisualComparison", () => {
  it("uses opaque black canvases so differently sized images cannot show through each other", () => {
    render(
      <BeforeAfterVisualComparison
        after={{ image_url: "/after-wide.png", title: "After" }}
        before={{ image_url: "/before-narrow.png", title: "Before" }}
        title="Different sizes"
      />
    )

    expect(screen.getByTestId("visual-comparison")).toHaveClass("bg-black")
    expect(screen.getByTestId("visual-before-layer")).toHaveClass("bg-black")
  })
})
