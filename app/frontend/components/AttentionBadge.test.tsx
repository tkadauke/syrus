import { render, screen } from "@testing-library/react"
import { describe, expect, it } from "vitest"
import { AttentionBadge } from "./AttentionBadge"

describe("AttentionBadge", () => {
  it("pairs the semantic danger background with theme-aware surface text", () => {
    render(<AttentionBadge className="min-w-4">3</AttentionBadge>)

    expect(screen.getByText("3")).toHaveClass("bg-danger", "text-surface", "min-w-4")
    expect(screen.getByText("3")).not.toHaveClass("text-white")
  })
})
